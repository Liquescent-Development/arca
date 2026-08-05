import Foundation
import NIOCore
import NIOPosix
import Logging

/// TCP proxy that forwards connections from localhost to a target address
/// Used for `-p 127.0.0.1:8080:80` style port mappings
actor TCPProxy {
    private let logger: Logger
    private let listenAddress: String
    private let listenPort: Int
    private let targetAddress: String
    private let targetPort: Int

    private var serverChannel: Channel?
    private var eventLoopGroup: MultiThreadedEventLoopGroup?
    private let onConnectionFailed: (@Sendable () async -> String?)?

    init(
        listenAddress: String,
        listenPort: Int,
        targetAddress: String,
        targetPort: Int,
        logger: Logger,
        onConnectionFailed: (@Sendable () async -> String?)? = nil
    ) {
        self.listenAddress = listenAddress
        self.listenPort = listenPort
        self.targetAddress = targetAddress
        self.targetPort = targetPort
        self.logger = logger
        self.onConnectionFailed = onConnectionFailed
    }

    /// Start the TCP proxy server
    func start() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        self.eventLoopGroup = group

        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.addHandler(
                    TCPProxyHandler(
                        targetAddress: self.targetAddress,
                        targetPort: self.targetPort,
                        logger: self.logger,
                        onConnectionFailed: self.onConnectionFailed
                    )
                )
            }
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.maxMessagesPerRead, value: 16)
            .childChannelOption(ChannelOptions.recvAllocator, value: AdaptiveRecvByteBufferAllocator())

        do {
            let channel = try await bootstrap.bind(host: listenAddress, port: listenPort).get()
            self.serverChannel = channel

            logger.info("TCP proxy started",
                       metadata: ["listenAddress": "\(listenAddress)",
                                 "listenPort": "\(listenPort)",
                                 "targetAddress": "\(targetAddress)",
                                 "targetPort": "\(targetPort)"])
        } catch {
            try? await group.shutdownGracefully()
            throw TCPProxyError.bindFailed(address: listenAddress, port: listenPort, error: error)
        }
    }

    /// Stop the TCP proxy server
    func stop() async throws {
        if let channel = serverChannel {
            try await channel.close()
            serverChannel = nil
        }

        if let group = eventLoopGroup {
            try await group.shutdownGracefully()
            eventLoopGroup = nil
        }

        logger.info("TCP proxy stopped",
                   metadata: ["listenAddress": "\(listenAddress)",
                             "listenPort": "\(listenPort)"])
    }
}

// MARK: - TCP Proxy Handler

/// Channel handler that forwards TCP data bidirectionally
private final class TCPProxyHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private let targetAddress: String
    private let targetPort: Int
    private let logger: Logger
    private let onConnectionFailed: (@Sendable () async -> String?)?

    private var outboundChannel: Channel?
    private var inboundContext: ChannelHandlerContext?
    private var pendingWrites: [ByteBuffer] = []  // Buffer for data received before target connected

    init(targetAddress: String, targetPort: Int, logger: Logger, onConnectionFailed: (@Sendable () async -> String?)? = nil) {
        self.targetAddress = targetAddress
        self.targetPort = targetPort
        self.logger = logger
        self.onConnectionFailed = onConnectionFailed
    }

    func channelActive(context: ChannelHandlerContext) {
        self.inboundContext = context

        // When a client connects, establish connection to target
        let clientAddress = context.remoteAddress?.description ?? "unknown"
        logger.debug("TCP proxy: Client connected",
                    metadata: ["clientAddress": "\(clientAddress)"])

        connectToTarget(context: context)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = self.unwrapInboundIn(data)

        guard let outbound = outboundChannel else {
            // Target not connected yet, buffer data for later
            pendingWrites.append(buffer)
            logger.debug("TCP proxy: Buffering data until target connects",
                        metadata: ["bytes": "\(buffer.readableBytes)"])
            return
        }

        // Forward data from client to target
        outbound.writeAndFlush(buffer, promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        logger.debug("TCP proxy: Client disconnected")

        // Close target connection when client disconnects
        if let outbound = outboundChannel {
            outbound.close(promise: nil)
            outboundChannel = nil
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        logger.debug("TCP proxy error",
                    metadata: ["error": "\(error)"])
        context.close(promise: nil)
    }

    private func connectToTarget(context: ChannelHandlerContext) {
        let bootstrap = ClientBootstrap(group: context.eventLoop)
            .channelInitializer { channel in
                channel.pipeline.addHandler(
                    TCPProxyBackendHandler(
                        inboundChannel: context.channel,
                        logger: self.logger,
                        onDisconnect: self.onConnectionFailed
                    )
                )
            }

        bootstrap.connect(host: targetAddress, port: targetPort).whenComplete { result in
            switch result {
            case .success(let channel):
                self.outboundChannel = channel
                self.logger.debug("TCP proxy: Connected to target",
                                metadata: ["targetAddress": "\(self.targetAddress)",
                                          "targetPort": "\(self.targetPort)"])

                // Flush any buffered data that arrived before connection completed
                if !self.pendingWrites.isEmpty {
                    self.logger.debug("TCP proxy: Flushing buffered data",
                                    metadata: ["buffers": "\(self.pendingWrites.count)"])
                    for buffer in self.pendingWrites {
                        channel.write(buffer, promise: nil)
                    }
                    channel.flush()
                    self.pendingWrites.removeAll()
                }
            case .failure(let error):
                // Dump nftables state on connection failure (for debugging)
                if let dumpFn = self.onConnectionFailed {
                    // Bind the Sendable values the Task needs. The handler itself is a
                    // ChannelInboundHandler bound to this event loop and is not Sendable,
                    // so capturing self here would let it escape into the concurrent context.
                    let logger = self.logger
                    let targetAddress = self.targetAddress
                    let targetPort = self.targetPort
                    let errorDescription = "\(error)"
                    Task {
                        if let ruleset = await dumpFn() {
                            logger.error("TCP proxy: Failed to connect to target",
                                            metadata: ["error": "\(errorDescription)",
                                                      "targetAddress": "\(targetAddress)",
                                                      "targetPort": "\(targetPort)",
                                                      "nftables": "\n\(ruleset)"])
                        } else {
                            logger.warning("TCP proxy: Failed to connect to target",
                                              metadata: ["error": "\(errorDescription)",
                                                        "targetAddress": "\(targetAddress)",
                                                        "targetPort": "\(targetPort)"])
                        }
                    }
                } else {
                    self.logger.warning("TCP proxy: Failed to connect to target",
                                      metadata: ["error": "\(error)",
                                                "targetAddress": "\(self.targetAddress)",
                                                "targetPort": "\(self.targetPort)"])
                }
                context.close(promise: nil)
            }
        }
    }
}

// MARK: - TCP Proxy Backend Handler

/// Channel handler for the target (backend) connection
private final class TCPProxyBackendHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private let inboundChannel: Channel
    private let logger: Logger
    private let onDisconnect: (@Sendable () async -> String?)?

    init(inboundChannel: Channel, logger: Logger, onDisconnect: (@Sendable () async -> String?)?) {
        self.inboundChannel = inboundChannel
        self.logger = logger
        self.onDisconnect = onDisconnect
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = self.unwrapInboundIn(data)

        // Forward data from target back to client
        inboundChannel.writeAndFlush(buffer, promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        // Dump nftables state on disconnect (for debugging)
        if let dumpFn = self.onDisconnect {
            let logger = self.logger
            Task.detached {
                if let ruleset = await dumpFn() {
                    logger.debug("TCP proxy: Target disconnected",
                                    metadata: ["nftables": "\n\(ruleset)"])
                } else {
                    logger.debug("TCP proxy: Target disconnected")
                }
            }
        } else {
            logger.debug("TCP proxy: Target disconnected")
        }

        // Close client connection when target disconnects
        inboundChannel.close(promise: nil)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        logger.debug("TCP proxy backend error",
                    metadata: ["error": "\(error)"])
        context.close(promise: nil)
        inboundChannel.close(promise: nil)
    }
}

// MARK: - Errors

enum TCPProxyError: Error, CustomStringConvertible {
    case bindFailed(address: String, port: Int, error: Error)

    var description: String {
        switch self {
        case .bindFailed(let address, let port, let error):
            return "Failed to bind TCP proxy to \(address):\(port): \(error)"
        }
    }
}
