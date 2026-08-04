import Foundation
import NIOCore
import NIOPosix
import Logging

/// UDP proxy that forwards datagrams from localhost to a target address
/// Used for `-p 127.0.0.1:8080:80/udp` style port mappings
///
/// Implements NAT-style connection tracking:
/// - Tracks client endpoints for reply routing
/// - Expires idle mappings after timeout
actor UDPProxy {
    private let logger: Logger
    private let listenAddress: String
    private let listenPort: Int
    private let targetAddress: String
    private let targetPort: Int
    private let idleTimeout: TimeInterval

    private var serverChannel: Channel?
    private var eventLoopGroup: MultiThreadedEventLoopGroup?
    private var cleanupTask: Task<Void, Never>?

    /// Client mapping for NAT-style tracking
    private var clientMappings: [SocketAddress: ClientMapping] = [:]

    init(
        listenAddress: String,
        listenPort: Int,
        targetAddress: String,
        targetPort: Int,
        idleTimeout: TimeInterval = 60.0,
        logger: Logger
    ) {
        self.listenAddress = listenAddress
        self.listenPort = listenPort
        self.targetAddress = targetAddress
        self.targetPort = targetPort
        self.idleTimeout = idleTimeout
        self.logger = logger
    }

    /// Start the UDP proxy server
    func start() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.eventLoopGroup = group

        let bootstrap = DatagramBootstrap(group: group)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .channelInitializer { channel in
                channel.pipeline.addHandler(
                    UDPProxyHandler(
                        proxy: self,
                        targetAddress: self.targetAddress,
                        targetPort: self.targetPort,
                        logger: self.logger
                    )
                )
            }

        do {
            let channel = try await bootstrap.bind(host: listenAddress, port: listenPort).get()
            self.serverChannel = channel

            // Start cleanup task for idle mappings
            startCleanupTask()

            logger.info("UDP proxy started",
                       metadata: ["listenAddress": "\(listenAddress)",
                                 "listenPort": "\(listenPort)",
                                 "targetAddress": "\(targetAddress)",
                                 "targetPort": "\(targetPort)",
                                 "idleTimeout": "\(idleTimeout)s"])
        } catch {
            try? await group.shutdownGracefully()
            throw UDPProxyError.bindFailed(address: listenAddress, port: listenPort, error: error)
        }
    }

    /// Stop the UDP proxy server
    func stop() async throws {
        // Cancel cleanup task
        cleanupTask?.cancel()
        cleanupTask = nil

        if let channel = serverChannel {
            try await channel.close()
            serverChannel = nil
        }

        if let group = eventLoopGroup {
            try await group.shutdownGracefully()
            eventLoopGroup = nil
        }

        clientMappings.removeAll()

        logger.info("UDP proxy stopped",
                   metadata: ["listenAddress": "\(listenAddress)",
                             "listenPort": "\(listenPort)"])
    }

    /// Track a client endpoint for reply routing
    func trackClient(_ clientAddress: SocketAddress, outboundChannel: Channel) {
        let mapping = ClientMapping(
            clientAddress: clientAddress,
            outboundChannel: outboundChannel,
            lastActivity: Date()
        )
        clientMappings[clientAddress] = mapping

        logger.debug("UDP proxy: Tracked client",
                    metadata: ["clientAddress": "\(clientAddress.description)"])
    }

    /// Get outbound channel for a client
    func getOutboundChannel(for clientAddress: SocketAddress) -> Channel? {
        // Update last activity time
        if var mapping = clientMappings[clientAddress] {
            mapping.lastActivity = Date()
            clientMappings[clientAddress] = mapping
        }
        return clientMappings[clientAddress]?.outboundChannel
    }

    /// Returns the outbound channel for a client, creating and tracking one if absent.
    ///
    /// Channel creation lives on the actor rather than in the calling handler's `Task`
    /// deliberately. Building the `DatagramBootstrap` involves an escaping
    /// `channelInitializer` that constructs a non-Sendable `UDPProxyBackendHandler`, and
    /// awaiting `bind()` on that bootstrap from inside a freshly-created task region makes
    /// Swift 6.3 fail with "pattern that the region-based isolation checker does not
    /// understand how to check. Please file a bug". Performing it under actor isolation
    /// keeps it out of the caller's task region. Awaiting an actor method that returns a
    /// `Channel` is checkable; doing the bind in the task region is not.
    ///
    /// Making this atomic on the actor also closes a check-then-act window in the previous
    /// arrangement, where two datagrams from the same client could each create a channel
    /// and the second would overwrite the first's mapping, orphaning it.
    func outboundChannel(
        for clientAddress: SocketAddress,
        eventLoop: EventLoop,
        inboundChannel: Channel
    ) async throws -> Channel {
        if let existing = getOutboundChannel(for: clientAddress) {
            return existing
        }

        // Bind the logger so the escaping initializer does not capture the actor.
        let logger = self.logger
        let bootstrap = DatagramBootstrap(group: eventLoop)
            .channelInitializer { channel in
                channel.pipeline.addHandler(
                    UDPProxyBackendHandler(
                        inboundChannel: inboundChannel,
                        clientAddress: clientAddress,
                        logger: logger
                    )
                )
            }

        let channel = try await bootstrap.bind(host: "0.0.0.0", port: 0).get()
        trackClient(clientAddress, outboundChannel: channel)

        logger.debug("UDP proxy: Created outbound channel",
                    metadata: ["clientAddress": "\(clientAddress.description)",
                              "localPort": "\(channel.localAddress?.port ?? 0)"])

        return channel
    }

    /// Start periodic cleanup task for idle mappings
    private func startCleanupTask() {
        cleanupTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(10 * 1_000_000_000)) // 10 seconds

                await cleanupIdleMappings()
            }
        }
    }

    /// Remove idle client mappings
    private func cleanupIdleMappings() {
        let now = Date()
        var expiredClients: [SocketAddress] = []

        for (clientAddress, mapping) in clientMappings {
            if now.timeIntervalSince(mapping.lastActivity) > idleTimeout {
                expiredClients.append(clientAddress)
            }
        }

        for clientAddress in expiredClients {
            if let mapping = clientMappings.removeValue(forKey: clientAddress) {
                mapping.outboundChannel.close(promise: nil)
                logger.debug("UDP proxy: Expired idle mapping",
                            metadata: ["clientAddress": "\(clientAddress.description)",
                                      "idleTime": "\(now.timeIntervalSince(mapping.lastActivity))s"])
            }
        }
    }

    /// Client mapping for NAT-style tracking
    private struct ClientMapping {
        let clientAddress: SocketAddress
        let outboundChannel: Channel
        var lastActivity: Date
    }
}

// MARK: - UDP Proxy Handler

/// Channel handler that forwards UDP datagrams bidirectionally
private final class UDPProxyHandler: ChannelInboundHandler {
    typealias InboundIn = AddressedEnvelope<ByteBuffer>
    typealias OutboundOut = AddressedEnvelope<ByteBuffer>

    private weak var proxy: UDPProxy?
    private let targetAddress: String
    private let targetPort: Int
    private let logger: Logger

    private var targetSocketAddress: SocketAddress?
    private var context: ChannelHandlerContext?

    init(proxy: UDPProxy, targetAddress: String, targetPort: Int, logger: Logger) {
        self.proxy = proxy
        self.targetAddress = targetAddress
        self.targetPort = targetPort
        self.logger = logger
    }

    func channelActive(context: ChannelHandlerContext) {
        self.context = context

        // Resolve target address
        do {
            self.targetSocketAddress = try SocketAddress.makeAddressResolvingHost(targetAddress, port: targetPort)
        } catch {
            logger.error("UDP proxy: Failed to resolve target address",
                        metadata: ["error": "\(error)",
                                  "targetAddress": "\(targetAddress)",
                                  "targetPort": "\(targetPort)"])
            context.close(promise: nil)
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let envelope = self.unwrapInboundIn(data)
        let clientAddress = envelope.remoteAddress
        let buffer = envelope.data

        guard let targetAddr = targetSocketAddress else {
            logger.warning("UDP proxy: Target address not resolved, dropping datagram")
            return
        }

        guard let proxy = self.proxy else { return }

        // channelRead already runs on the channel's event loop, so reading the handler's
        // state here is safe. Bind the Sendable values the Task needs: neither the handler
        // nor the ChannelHandlerContext is Sendable, and the context in particular is only
        // valid on this event loop, so neither may be captured by the Task.
        let eventLoop = context.eventLoop
        let inboundChannel = context.channel
        let logger = self.logger

        Task {
            do {
                let outbound = try await proxy.outboundChannel(
                    for: clientAddress,
                    eventLoop: eventLoop,
                    inboundChannel: inboundChannel
                )

                // Forward datagram to target
                let outboundEnvelope = AddressedEnvelope(remoteAddress: targetAddr, data: buffer)
                outbound.writeAndFlush(NIOAny(outboundEnvelope), promise: nil)
            } catch {
                logger.error("Failed to create outbound channel", metadata: ["error": "\(error)"])
            }
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        logger.debug("UDP proxy error",
                    metadata: ["error": "\(error)"])
    }

}

// MARK: - UDP Proxy Backend Handler

/// Channel handler for the target (backend) connection
private final class UDPProxyBackendHandler: ChannelInboundHandler {
    typealias InboundIn = AddressedEnvelope<ByteBuffer>
    typealias OutboundOut = AddressedEnvelope<ByteBuffer>

    private let inboundChannel: Channel
    private let clientAddress: SocketAddress
    private let logger: Logger

    init(inboundChannel: Channel, clientAddress: SocketAddress, logger: Logger) {
        self.inboundChannel = inboundChannel
        self.clientAddress = clientAddress
        self.logger = logger
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let envelope = self.unwrapInboundIn(data)
        var buffer = envelope.data

        // Forward datagram from target back to original client
        let outboundEnvelope = AddressedEnvelope(remoteAddress: clientAddress, data: buffer)
        inboundChannel.writeAndFlush(self.wrapOutboundOut(outboundEnvelope), promise: nil)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        logger.debug("UDP proxy backend error",
                    metadata: ["error": "\(error)"])
    }
}

// MARK: - Errors

enum UDPProxyError: Error, CustomStringConvertible {
    case bindFailed(address: String, port: Int, error: Error)

    var description: String {
        switch self {
        case .bindFailed(let address, let port, let error):
            return "Failed to bind UDP proxy to \(address):\(port): \(error)"
        }
    }
}
