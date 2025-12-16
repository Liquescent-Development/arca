import Foundation
import Logging
#if canImport(Darwin)
import Darwin
#endif

/// Manages port mappings for containers (Phase 4.1)
///
/// Responsibilities:
/// - Parse port bindings from Docker API format
/// - Spawn userspace proxies for localhost bindings
/// - Call WireGuard gRPC for nftables rules (non-localhost bindings)
/// - Track proxy processes and port mappings per container
/// - Clean up proxies when containers stop
public actor PortMapManager {
    private let logger: Logger
    private let dumpNftablesOnPublish: Bool

    /// Internal port binding information for a container
    private struct InternalPortBinding: Sendable {
        let proto: String         // "tcp" or "udp"
        let hostIP: String        // e.g., "0.0.0.0", "127.0.0.1", "192.168.1.100"
        let hostPort: UInt16
        let containerPort: UInt16
        let needsProxy: Bool      // true for localhost bindings
    }

    /// Active port mapping for a container
    private struct ActiveMapping: Sendable {
        let binding: InternalPortBinding
        let proxy: ProxyInstance?  // nil for non-localhost bindings
    }

    /// Proxy instance (TCP or UDP)
    private enum ProxyInstance: Sendable {
        case tcp(TCPProxy)
        case udp(UDPProxy)
    }

    /// Per-container port mappings and proxy PIDs
    private var containerMappings: [String: [ActiveMapping]] = [:]

    /// Global port allocation tracking (for conflict detection)
    /// Key: "\(hostIP):\(hostPort)/\(proto)" -> containerID
    private var allocatedPorts: [String: String] = [:]

    public init(logger: Logger, dumpNftablesOnPublish: Bool = false) {
        self.logger = logger
        self.dumpNftablesOnPublish = dumpNftablesOnPublish
    }

    // MARK: - Port Publishing

    /// Publish ports for a container
    /// - Parameters:
    ///   - containerID: Container ID
    ///   - vmnetIP: Container's vmnet IP address (e.g., "192.168.65.10")
    ///   - overlayIP: Container's WireGuard overlay IP (e.g., "172.18.0.2")
    ///   - portBindings: Port bindings from Docker API (e.g., {"80/tcp": [InternalPortBinding(hostIp: "0.0.0.0", hostPort: "8080")]})
    ///   - wireguardClient: WireGuard client for calling gRPC
    public func publishPorts(
        containerID: String,
        vmnetIP: String,
        overlayIP: String,
        portBindings: [String: [PortBinding]],
        wireguardClient: WireGuardClient
    ) async throws {
        logger.info("Publishing ports for container", metadata: ["containerID": "\(containerID)"])

        var activeMappings: [ActiveMapping] = []

        // Parse port bindings
        for (portProto, bindings) in portBindings {
            guard !bindings.isEmpty else { continue }

            // Parse port/protocol (e.g., "80/tcp" -> port=80, protocol="tcp")
            // Docker may send just "80" without protocol - default to "tcp"
            let components = portProto.split(separator: "/")
            let containerPort: UInt16
            let proto: String

            if components.count == 2 {
                // Format: "port/protocol" (e.g., "80/tcp")
                guard let port = UInt16(components[0]) else {
                    logger.warning("Invalid port number", metadata: ["portProto": "\(portProto)"])
                    continue
                }
                containerPort = port
                proto = String(components[1])
            } else if components.count == 1 {
                // Format: "port" without protocol - default to tcp
                guard let port = UInt16(components[0]) else {
                    logger.warning("Invalid port number", metadata: ["portProto": "\(portProto)"])
                    continue
                }
                containerPort = port
                proto = "tcp"
                logger.debug("Port without protocol, defaulting to tcp", metadata: ["port": "\(containerPort)"])
            } else {
                logger.warning("Invalid port/protocol format", metadata: ["portProto": "\(portProto)"])
                continue
            }

            // Process each binding for this port
            for binding in bindings {
                let hostIP = binding.hostIp.isEmpty ? "0.0.0.0" : binding.hostIp
                guard let hostPort = UInt16(binding.hostPort) else {
                    logger.warning("Invalid host port", metadata: ["hostPort": "\(binding.hostPort)"])
                    continue
                }

                // Check for port conflicts
                let portKey = "\(hostIP):\(hostPort)/\(proto)"
                if let existingContainer = allocatedPorts[portKey] {
                    throw PortMapError.portAlreadyAllocated(
                        hostIP: hostIP,
                        hostPort: hostPort,
                        proto: proto,
                        existingContainer: existingContainer
                    )
                }

                // Determine if this binding needs a userspace proxy
                // TODO: Make this configurable - allow users to choose localhost-only,
                // vmnet-only, or both (current Docker-matching behavior)
                let needsProxy = shouldSpawnProxy(for: hostIP)

                let portBinding = InternalPortBinding(
                    proto: proto,
                    hostIP: hostIP,
                    hostPort: hostPort,
                    containerPort: containerPort,
                    needsProxy: needsProxy
                )

                // Publish the port
                let proxy: ProxyInstance?
                if needsProxy {
                    // Localhost binding: spawn proxy + call gRPC
                    proxy = try await publishLocalhostPort(
                        binding: portBinding,
                        vmnetIP: vmnetIP,
                        overlayIP: overlayIP,
                        wireguardClient: wireguardClient
                    )
                    logger.info("Published localhost port with proxy",
                               metadata: ["hostPort": "\(hostPort)",
                                         "protocol": "\(proto)"])
                } else {
                    // Non-localhost binding: just call gRPC for nftables rules
                    try await publishNonLocalhostPort(
                        binding: portBinding,
                        overlayIP: overlayIP,
                        wireguardClient: wireguardClient
                    )
                    proxy = nil
                    logger.info("Published non-localhost port",
                               metadata: ["hostIP": "\(hostIP)",
                                         "hostPort": "\(hostPort)",
                                         "protocol": "\(proto)"])
                }

                // Track the mapping
                let mapping = ActiveMapping(binding: portBinding, proxy: proxy)
                activeMappings.append(mapping)
                allocatedPorts[portKey] = containerID
            }
        }

        // Store all mappings for this container
        containerMappings[containerID] = activeMappings

        logger.info("Published \(activeMappings.count) port mappings for container",
                   metadata: ["containerID": "\(containerID)"])
    }

    /// Unpublish all ports for a container
    /// - Parameters:
    ///   - containerID: Container ID
    ///   - wireguardClient: Optional WireGuard client (if nil, skips nftables cleanup but still stops proxies)
    public func unpublishPorts(
        containerID: String,
        wireguardClient: WireGuardClient?
    ) async throws {
        guard let mappings = containerMappings[containerID] else {
            logger.debug("No port mappings found for container", metadata: ["containerID": "\(containerID)"])
            return
        }

        logger.info("Unpublishing \(mappings.count) port mappings for container",
                   metadata: ["containerID": "\(containerID)"])

        for mapping in mappings {
            let binding = mapping.binding

            // Stop proxy if it exists (ALWAYS do this, even if wireguardClient is nil)
            if let proxy = mapping.proxy {
                do {
                    switch proxy {
                    case .tcp(let tcpProxy):
                        try await tcpProxy.stop()
                        logger.debug("Stopped TCP proxy", metadata: ["port": "\(binding.hostPort)"])
                    case .udp(let udpProxy):
                        try await udpProxy.stop()
                        logger.debug("Stopped UDP proxy", metadata: ["port": "\(binding.hostPort)"])
                    }
                } catch {
                    logger.warning("Failed to stop proxy",
                                  metadata: ["error": "\(error)",
                                            "port": "\(binding.hostPort)"])
                }
            }

            // Remove nftables rules via gRPC (only if wireguardClient is available)
            if let wireguardClient = wireguardClient {
                do {
                    try await wireguardClient.unpublishPort(
                        proto: binding.proto,
                        hostPort: UInt32(binding.hostPort)
                    )
                } catch {
                    logger.warning("Failed to unpublish port via gRPC",
                                  metadata: ["error": "\(error)",
                                            "hostPort": "\(binding.hostPort)",
                                            "protocol": "\(binding.proto)"])
                }
            } else {
                logger.debug("Skipping nftables cleanup (no wireguardClient)", metadata: [
                    "port": "\(binding.hostPort)",
                    "protocol": "\(binding.proto)"
                ])
            }

            // Remove from port allocation tracking (ALWAYS do this)
            let portKey = "\(binding.hostIP):\(binding.hostPort)/\(binding.proto)"
            allocatedPorts.removeValue(forKey: portKey)
        }

        // Remove container's mappings
        containerMappings.removeValue(forKey: containerID)

        logger.info("Unpublished all port mappings for container",
                   metadata: ["containerID": "\(containerID)"])
    }

    // MARK: - Private Helpers

    /// Determine if a userspace proxy should be spawned for a given host IP
    ///
    /// Current behavior: Matches Docker by spawning proxies for ALL port bindings
    /// This exposes all published ports on localhost, regardless of the specified host IP.
    ///
    /// Future: This should be configurable to allow different binding behaviors:
    /// - "localhost-only": Only spawn proxies for 127.0.0.1 bindings
    /// - "vmnet-only": No proxies, ports only accessible via vmnet IP
    /// - "all" (current): Spawn proxies for all bindings (Docker-compatible)
    ///
    /// Configuration should be retrievable from daemon config or per-network settings.
    private func shouldSpawnProxy(for hostIP: String) -> Bool {
        // For now, match Docker behavior: ALL port bindings get proxies
        // This ensures published ports are accessible on localhost
        return true

        // Future implementation might look like:
        // switch proxyMode {
        // case .localhostOnly:
        //     return hostIP == "127.0.0.1" || hostIP == "::1" || hostIP == "localhost"
        // case .vmnetOnly:
        //     return false
        // case .all:
        //     return true
        // }
    }

    /// Publish a localhost port (spawn proxy + call gRPC)
    private func publishLocalhostPort(
        binding: InternalPortBinding,
        vmnetIP: String,
        overlayIP: String,
        wireguardClient: WireGuardClient
    ) async throws -> ProxyInstance {
        // Create and start native Swift proxy (TCP or UDP)
        let proxyInstance: ProxyInstance

        if binding.proto.lowercased() == "tcp" {
            // Only dump nftables on connection failure if debugging is enabled
            let onConnectionFailed: (@Sendable () async -> String?)? = dumpNftablesOnPublish ? { @Sendable [wireguardClient] in
                // Dump nftables when proxy fails to connect (for debugging)
                return try? await wireguardClient.dumpNftables()
            } : nil

            let tcpProxy = TCPProxy(
                listenAddress: binding.hostIP,
                listenPort: Int(binding.hostPort),
                targetAddress: vmnetIP,
                targetPort: Int(binding.hostPort), // Host connects to vmnet_ip:host_port, DNAT handles rest
                logger: logger,
                onConnectionFailed: onConnectionFailed
            )
            try await tcpProxy.start()
            proxyInstance = .tcp(tcpProxy)
        } else if binding.proto.lowercased() == "udp" {
            let udpProxy = UDPProxy(
                listenAddress: binding.hostIP,
                listenPort: Int(binding.hostPort),
                targetAddress: vmnetIP,
                targetPort: Int(binding.hostPort), // Host connects to vmnet_ip:host_port, DNAT handles rest
                logger: logger
            )
            try await udpProxy.start()
            proxyInstance = .udp(udpProxy)
        } else {
            throw PortMapError.unsupportedProtocol(binding.proto)
        }

        // Add nftables rules via gRPC (same as non-localhost)
        // The proxy forwards to vmnet_ip:host_port, then DNAT redirects to overlay_ip:container_port
        try await wireguardClient.publishPort(
            proto: binding.proto,
            hostPort: UInt32(binding.hostPort),
            containerIP: overlayIP,
            containerPort: UInt32(binding.containerPort)
        )

        // Dump nftables for debugging (shows rules + packet counters)
        // Only enabled when dumpNftablesOnPublish is true (e.g., log level is debug)
        if dumpNftablesOnPublish {
            if let ruleset = try? await wireguardClient.dumpNftables() {
                logger.debug("nftables state after publishing localhost port", metadata: [
                    "hostPort": "\(binding.hostPort)",
                    "protocol": "\(binding.proto)",
                    "ruleset": "\n\(ruleset)"
                ])
            }
        }

        return proxyInstance
    }

    /// Publish a non-localhost port (just call gRPC)
    private func publishNonLocalhostPort(
        binding: InternalPortBinding,
        overlayIP: String,
        wireguardClient: WireGuardClient
    ) async throws {
        // Add nftables rules via gRPC
        try await wireguardClient.publishPort(
            proto: binding.proto,
            hostPort: UInt32(binding.hostPort),
            containerIP: overlayIP,
            containerPort: UInt32(binding.containerPort)
        )

        // Dump nftables for debugging (shows rules + packet counters)
        // Only enabled when dumpNftablesOnPublish is true (e.g., log level is debug)
        if dumpNftablesOnPublish {
            if let ruleset = try? await wireguardClient.dumpNftables() {
                logger.debug("nftables state after publishing non-localhost port", metadata: [
                    "hostIP": "\(binding.hostIP)",
                    "hostPort": "\(binding.hostPort)",
                    "protocol": "\(binding.proto)",
                    "ruleset": "\n\(ruleset)"
                ])
            }
        }
    }
}

// MARK: - Errors

enum PortMapError: Error, CustomStringConvertible {
    case portAlreadyAllocated(hostIP: String, hostPort: UInt16, proto: String, existingContainer: String)
    case unsupportedProtocol(String)

    var description: String {
        switch self {
        case .portAlreadyAllocated(let hostIP, let hostPort, let proto, let existingContainer):
            return "Bind for \(hostIP):\(hostPort) failed: port is already allocated (container: \(existingContainer), protocol: \(proto))"
        case .unsupportedProtocol(let proto):
            return "Unsupported protocol: \(proto) (only tcp and udp are supported)"
        }
    }
}
