import Foundation
import Logging
import Containerization
import ArcaIP

/// WireGuard backend for Docker bridge networks
///
/// Provides full Docker Network API compatibility using WireGuard hub-and-spoke topology:
/// - Each container gets a WireGuard hub interface (wg0) when first attached to a network
/// - Each network the container joins becomes a peer on that hub
/// - WireGuard allowed-ips routing handles multi-network scenarios
/// - All configuration done via gRPC over vsock to WireGuard service in container
///
/// **Features:**
/// - Dynamic network attachment (docker network connect/disconnect)
/// - Multi-network containers (all networks on single wg0 interface)
/// - Network isolation via WireGuard cryptographic routing
/// - Ultra-low latency (~1ms) - WireGuard kernel-space routing
/// - No helper VM required
///
/// **Performance:**
/// - ~1ms latency (kernel-space routing)
/// - Single kernel-space routing decision per packet
/// - No vsock relay overhead (direct vmnet UDP)
public actor WireGuardNetworkBackend {
    private let logger: Logger
    private let stateStore: StateStore
    private let getContainer: (String) async throws -> Containerization.LinuxContainer

    // WireGuard runtime state (ephemeral - recreated on container start)
    // This state does NOT persist across daemon restarts - it's rebuilt when containers start

    // Track network index for each container-network pair: containerID -> networkID -> networkIndex
    private var containerNetworkIndices: [String: [String: UInt32]] = [:]

    // Track public keys per interface: containerID -> networkID -> publicKey
    private var containerInterfaceKeys: [String: [String: String]] = [:]

    // Container names for DNS resolution (Phase 3.1): containerID -> containerName
    private var containerNames: [String: String] = [:]

    // Subnet allocation tracking (simple counter for auto-allocation)
    private var nextSubnetByte: UInt8 = 18  // Start at 172.18.0.0/16

    // Cached host IP for host.docker.internal DNS resolution
    private var cachedHostIP: String?

    public init(
        logger: Logger,
        stateStore: StateStore,
        getContainer: @escaping (String) async throws -> Containerization.LinuxContainer
    ) {
        self.logger = logger
        self.stateStore = stateStore
        self.getContainer = getContainer
    }

    /// Restore network state from database on daemon startup
    /// Database is the source of truth - networks will be loaded on-demand
    public func restoreNetworks() async throws {
        // Restore nextSubnetByte from database (CRITICAL for preventing subnet overlaps after restart)
        let persistedSubnetByte = try await stateStore.getNextSubnetByte()
        nextSubnetByte = UInt8(persistedSubnetByte)

        logger.debug("Restored subnet allocation state", metadata: [
            "next_subnet_byte": "\(nextSubnetByte)"
        ])

        // Count networks for logging (database is source of truth - no need to load into memory)
        let persistedNetworks = try await stateStore.loadAllNetworks()
        let wireGuardNetworkCount = persistedNetworks.filter { $0.driver == "bridge" || $0.driver == "wireguard" }.count

        logger.info("WireGuard network backend ready - networks in database", metadata: [
            "count": "\(wireGuardNetworkCount)"
        ])
    }

    /// Get the host's primary LAN IP address for host.docker.internal DNS resolution
    /// Returns the first non-localhost IPv4 address found on the system
    private func getHostIP() -> String {
        // Return cached value if available
        if let cached = cachedHostIP {
            return cached
        }

        // Get all network interfaces
        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0, let firstAddr = addresses else {
            logger.warning("Failed to get network interfaces for host IP detection")
            return ""
        }
        defer { freeifaddrs(addresses) }

        // Look for the first non-localhost IPv4 address
        // Prefer en0 (WiFi/Ethernet) over other interfaces
        var fallbackIP: String?

        var currentAddr = firstAddr
        while true {
            let interface = currentAddr.pointee

            // Only consider IPv4 addresses (AF_INET)
            if interface.ifa_addr?.pointee.sa_family == UInt8(AF_INET) {
                let interfaceName = String(cString: interface.ifa_name)

                // Get the IP address
                var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                              &hostname, socklen_t(hostname.count),
                              nil, 0, NI_NUMERICHOST) == 0 {
                    let ipAddress = String(cString: hostname)

                    // Skip localhost
                    if ipAddress.hasPrefix("127.") {
                        if let next = interface.ifa_next {
                            currentAddr = next
                            continue
                        } else {
                            break
                        }
                    }

                    // Prefer en0 (primary network interface on macOS)
                    if interfaceName == "en0" {
                        logger.info("Detected host IP from en0", metadata: ["ip": "\(ipAddress)"])
                        cachedHostIP = ipAddress
                        return ipAddress
                    }

                    // Save as fallback if not en0
                    if fallbackIP == nil {
                        fallbackIP = ipAddress
                    }
                }
            }

            if let next = interface.ifa_next {
                currentAddr = next
            } else {
                break
            }
        }

        // Use fallback if en0 wasn't found
        if let ip = fallbackIP {
            logger.info("Detected host IP (fallback)", metadata: ["ip": "\(ip)"])
            cachedHostIP = ip
            return ip
        }

        logger.warning("Could not detect host IP address")
        return ""
    }

    // MARK: - Network Management

    /// Create a new bridge network using WireGuard
    public func createBridgeNetwork(
        id: String,
        name: String,
        subnet: String?,
        gateway: String?,
        ipRange: String?,
        options: [String: String],
        labels: [String: String],
        isDefault: Bool = false
    ) async throws -> NetworkMetadata {
        logger.info("Creating WireGuard bridge network", metadata: [
            "network_id": "\(id)",
            "network_name": "\(name)",
            "subnet": "\(subnet ?? "auto")"
        ])

        // Determine subnet (use provided or auto-allocate)
        let effectiveSubnet: String
        let effectiveGateway: String

        if let subnet = subnet {
            effectiveSubnet = subnet
            // Calculate gateway if not provided or if empty string provided
            // Docker CLI sends empty string "" when no gateway is specified
            effectiveGateway = (gateway?.isEmpty == false) ? gateway! : calculateGateway(subnet: subnet)
        } else {
            // Auto-allocate from 172.18.0.0/16 - 172.31.0.0/16
            // Get allocated subnets from database to detect conflicts
            let allocatedBytes = try await stateStore.getAllocatedSubnetBytes()

            // Find next available subnet byte that's not in use
            var candidateByte = nextSubnetByte
            var attempts = 0
            while allocatedBytes.contains(candidateByte) && attempts < 14 {
                candidateByte += 1
                if candidateByte > 31 {
                    candidateByte = 18  // Wrap around
                }
                attempts += 1
            }

            // Check if we exhausted all subnets
            if allocatedBytes.contains(candidateByte) {
                throw NetworkManagerError.noAvailableSubnets
            }

            effectiveSubnet = "172.\(candidateByte).0.0/16"
            effectiveGateway = "172.\(candidateByte).0.1"

            // Update and persist next subnet byte
            nextSubnetByte = candidateByte + 1
            if nextSubnetByte > 31 {
                nextSubnetByte = 18  // Wrap around
            }

            // Persist the updated nextSubnetByte to database
            try await stateStore.updateNextSubnetByte(Int(nextSubnetByte))

            logger.debug("Auto-allocated subnet", metadata: [
                "allocated_subnet": "172.\(candidateByte).0.0/16",
                "next_subnet_byte": "\(nextSubnetByte)"
            ])
        }

        // NOTE: We no longer use nextIPOctet counter for IP allocation
        // Instead, allocateIP() queries allocated IPs from network_attachments table
        // and finds first available IP, enabling automatic IP reclamation

        // Persist network to database
        let createdDate = Date()
        do {
            let optionsJSON = try JSONEncoder().encode(options)
            let labelsJSON = try JSONEncoder().encode(labels)

            try await stateStore.saveNetwork(
                id: id,
                name: name,
                driver: "wireguard",
                scope: "local",
                createdAt: createdDate,
                subnet: effectiveSubnet,
                gateway: effectiveGateway,
                ipRange: ipRange,
                optionsJSON: String(data: optionsJSON, encoding: .utf8),
                labelsJSON: String(data: labelsJSON, encoding: .utf8),
                isDefault: isDefault
            )

            logger.debug("WireGuard network persisted to database", metadata: ["network_id": "\(id)"])
        } catch {
            logger.error("Failed to persist WireGuard network to database", metadata: [
                "network_id": "\(id)",
                "error": "\(error)"
            ])
            // Continue - network is created in memory even if persistence fails
        }

        logger.info("WireGuard bridge network created", metadata: [
            "network_id": "\(id)",
            "subnet": "\(effectiveSubnet)",
            "gateway": "\(effectiveGateway)"
        ])

        // Load the network we just created from database to return
        guard let createdNetwork = try await loadNetwork(id: id) else {
            throw NetworkManagerError.networkNotFound(id)
        }

        return createdNetwork
    }

    /// Delete a bridge network
    public func deleteBridgeNetwork(id: String) async throws {
        // Check if network exists
        guard let metadata = try await loadNetwork(id: id) else {
            throw NetworkManagerError.networkNotFound(id)
        }

        // Check if any containers are still using this network
        if !metadata.containers.isEmpty {
            throw NetworkManagerError.hasActiveEndpoints(metadata.name, metadata.containers.count)
        }

        logger.info("Deleting WireGuard bridge network", metadata: ["network_id": "\(id)"])

        // Delete from database
        try await stateStore.deleteNetwork(id: id)
        logger.debug("WireGuard network deleted from database", metadata: ["network_id": "\(id)"])
    }

    // MARK: - Container Attachment

    /// Attach container to network
    ///
    /// Phase 2.2: Creates separate wgN/ethN interfaces for each network (wg0/eth0, wg1/eth1, etc.)
    public func attachContainer(
        containerID: String,
        container: Containerization.LinuxContainer,
        networkID: String,
        containerName: String,
        aliases: [String],
        userSpecifiedIP: String? = nil,
        extraHosts: [String] = []
    ) async throws -> NetworkAttachment {
        // Load network metadata from database
        guard let metadata = try await loadNetwork(id: networkID) else {
            throw NetworkManagerError.networkNotFound(networkID)
        }

        logger.info("Attaching container to WireGuard network", metadata: [
            "container_id": "\(containerID)",
            "network_id": "\(networkID)",
            "container_name": "\(containerName)",
            "user_specified_ip": "\(userSpecifiedIP ?? "auto")"
        ])

        // Check if already attached by querying database
        let containerNetworks = try await stateStore.getContainerNetworks(containerID: containerID)
        if containerNetworks.contains(networkID) {
            // Container is already in this network - check if this is a restoration after restart
            let attachments = try await stateStore.loadNetworkAttachments(containerID: containerID)
            if let existingAttachment = attachments.first(where: { $0.networkID == networkID }),
               let userIP = userSpecifiedIP,
               userIP == existingAttachment.ipAddress {
                // This is a restoration after container restart - same container, same IP
                // The WireGuard client was disconnected on stop, so we need to recreate interfaces
                logger.info("Container restart detected - recreating WireGuard interface with existing IP", metadata: [
                    "container_id": "\(containerID)",
                    "network_id": "\(networkID)",
                    "ip": "\(userIP)"
                ])
                // Allow the attachment to proceed - we'll recreate the WireGuard interface
            } else {
                // This is a duplicate connection attempt (not a restart)
                throw NetworkManagerError.alreadyConnected(containerID, metadata.name)
            }
        }

        // Generate MAC address early (needed for atomic IP reservation)
        let mac = generateMACAddress(containerID: containerID, networkID: networkID)
        let allAliases = aliases + [containerName]

        // Allocate and reserve IP address atomically (fixes #13 - IPAM race condition)
        let ipAddress: String
        // Check if user specified an IP (and it's not empty string)
        // Docker CLI/API can send empty string "" when no IP is specified
        if let userIP = userSpecifiedIP, !userIP.isEmpty {
            // Validate user-specified IP is within subnet
            guard isIPInSubnet(userIP, subnet: metadata.subnet) else {
                throw NetworkManagerError.invalidIPAddress("IP \(userIP) not in subnet \(metadata.subnet)")
            }

            // Check if this is a reconnect (same container, same IP)
            let allAttachments = try await stateStore.loadNetworkAttachments(containerID: containerID)
            let existingAttachment = allAttachments.first(where: { $0.networkID == networkID && $0.ipAddress == userIP })

            if existingAttachment != nil {
                // Reconnect - IP already reserved for this container
                ipAddress = userIP
                logger.info("Reconnecting with existing IP reservation", metadata: [
                    "ip": "\(ipAddress)",
                    "network_id": "\(networkID)"
                ])
            } else {
                // New reservation - atomically reserve the specific IP
                do {
                    try await stateStore.reserveSpecificIP(
                        containerID: containerID,
                        networkID: networkID,
                        ip: userIP,
                        macAddress: mac,
                        aliases: allAliases
                    )
                    ipAddress = userIP
                    logger.info("Reserved user-specified IP address", metadata: [
                        "ip": "\(ipAddress)",
                        "network_id": "\(networkID)"
                    ])
                } catch {
                    throw NetworkManagerError.ipAlreadyInUse(userIP)
                }
            }
        } else {
            // Auto-allocate IP atomically (prevents race condition)
            guard let block = IP.Block(metadata.subnet) else {
                throw NetworkManagerError.ipAllocationFailed("Invalid subnet format: \(metadata.subnet)")
            }

            let networkAddr = block.base
            let gatewayIP = IP.V4(value: networkAddr.value + 1)
            let startIP = IP.V4(value: gatewayIP.value + 1)

            let rangeStart: Int64
            let rangeEnd: Int64
            if let ipRangeStr = metadata.ipRange, let ipRange = IP.Block(ipRangeStr) {
                rangeStart = Int64(ipRange.range.lowerBound.value)
                rangeEnd = Int64(ipRange.range.upperBound.value)
            } else {
                rangeStart = Int64(startIP.value)
                // DEFECT (Vas-Solutus/arca#50), deliberately unfixed. This is
                // the LIVE allocation path. `range.upperBound` is the subnet's
                // broadcast address, not broadcast-1, and allocateAndReserveIP
                // treats the bound as inclusive, so a container can be
                // allocated its subnet's broadcast address.
                //
                // Worse on /31 and /32: rangeStart exceeds rangeEnd, so the
                // first attach silently allocates an address outside the
                // network and the second reaches `for ip in rangeStart...
                // rangeEnd` in StateStore.allocateAndReserveIP — a closed range
                // with lowerBound > upperBound — which traps and kills the
                // daemon. Subnets are accepted verbatim with no prefix-length
                // check (effectiveSubnet, ~line 178), so this is reachable from
                // `docker network create --subnet 10.0.0.0/31`.
                //
                // Fix HERE, not in allocateIP() below: that function has no
                // callers, though it carries a similar note.
                rangeEnd = Int64(block.range.upperBound.value)
            }

            ipAddress = try await stateStore.allocateAndReserveIP(
                containerID: containerID,
                networkID: networkID,
                rangeStart: rangeStart,
                rangeEnd: rangeEnd,
                gatewayInt: Int64(gatewayIP.value),
                macAddress: mac,
                aliases: allAliases
            )

            logger.info("Auto-allocated IP address atomically", metadata: [
                "ip": "\(ipAddress)",
                "network_id": "\(networkID)"
            ])
        }

        // Create WireGuard client for this container
        let wgClient = WireGuardClient(logger: logger)
        try await wgClient.connect(container: container, vsockPort: 51820)

        // Ensure we disconnect when done
        defer {
            Task {
                try? await wgClient.disconnect()
            }
        }

        // Determine network index for this container
        // On restart, reuse existing index to keep eth0 as eth0, eth1 as eth1, etc.
        // For new networks, calculate next available index
        var indices = containerNetworkIndices[containerID] ?? [:]
        let networkIndex: UInt32
        if let existingIndex = indices[networkID] {
            // Restart scenario - reuse existing index
            networkIndex = existingIndex
            logger.debug("Reusing existing network index for restart", metadata: [
                "container_id": "\(containerID)",
                "network_id": "\(networkID)",
                "network_index": "\(networkIndex)"
            ])
        } else {
            // New network attachment - calculate next available index
            networkIndex = UInt32(indices.count)
        }

        logger.info("Creating WireGuard interface for network", metadata: [
            "container_id": "\(containerID)",
            "network_id": "\(networkID)",
            "network_index": "\(networkIndex)",
            "interface": "wg\(networkIndex)/eth\(networkIndex)"
        ])

        // Generate WireGuard private key for this network's interface
        let privateKey = try generateWireGuardPrivateKey()

        // Calculate listen port (51820 + network_index)
        let listenPort = 51820 + networkIndex

        // Create wgN/ethN interface for this network (hub created lazily)
        // Pass host IP for host.docker.internal DNS resolution on first network
        let hostIP = getHostIP()

        // Resolve "host-gateway" special value in extra_hosts to actual host IP (Issue #34)
        // Docker Compose uses this for host.docker.internal:host-gateway
        let resolvedExtraHosts = extraHosts.map { entry -> String in
            if entry.hasSuffix(":host-gateway") {
                let hostname = String(entry.dropLast(":host-gateway".count))
                return "\(hostname):\(hostIP)"
            }
            return entry
        }

        let result = try await wgClient.addNetwork(
            networkID: networkID,
            networkIndex: networkIndex,
            containerID: containerID,
            privateKey: privateKey,
            listenPort: listenPort,
            peerEndpoint: "",  // Empty - no initial peer needed
            peerPublicKey: "",  // Empty - no initial peer needed
            ipAddress: ipAddress,
            networkCIDR: metadata.subnet,
            gateway: metadata.gateway,
            hostIP: hostIP,
            extraHosts: resolvedExtraHosts  // Pass extra hosts for DNS resolution (Issue #34)
        )

        // Store interface metadata
        indices[networkID] = networkIndex
        containerNetworkIndices[containerID] = indices

        var keys = containerInterfaceKeys[containerID] ?? [:]
        keys[networkID] = result.publicKey
        containerInterfaceKeys[containerID] = keys

        logger.info("WireGuard interface created", metadata: [
            "container_id": "\(containerID)",
            "network_id": "\(networkID)",
            "wg_interface": "\(result.wgInterface)",
            "eth_interface": "\(result.ethInterface)",
            "public_key": "\(result.publicKey)",
            "ip_address": "\(ipAddress)"
        ])

        // Phase 2.4: Configure full mesh with other containers on this network
        // Get this container's vmnet endpoint (vmnet IP:port for WireGuard UDP)
        let thisEndpoint = try await wgClient.getVmnetEndpoint()

        logger.info("Configuring full mesh for network", metadata: [
            "container_id": "\(containerID)",
            "network_id": "\(networkID)",
            "this_endpoint": "\(thisEndpoint)",
            "this_public_key": "\(result.publicKey)",
            "this_ip": "\(ipAddress)"
        ])

        // Get all OTHER containers already on this network from database
        let networkAttachments = try await stateStore.loadAttachmentsForNetwork(networkID: networkID)
        let otherContainerIDs = networkAttachments.map { $0.containerID }.filter { $0 != containerID }

        logger.debug("Found existing containers on network", metadata: [
            "network_id": "\(networkID)",
            "count": "\(otherContainerIDs.count)"
        ])

        // For each existing container on this network:
        // 1. Add THIS container as a peer to THAT container
        // 2. Add THAT container as a peer to THIS container
        for otherContainerID in otherContainerIDs {
            // Get peer runtime state (WireGuard keys and indices are ephemeral - recreated on start)
            guard let otherPublicKey = containerInterfaceKeys[otherContainerID]?[networkID],
                  let otherNetworkIndex = containerNetworkIndices[otherContainerID]?[networkID] else {
                logger.warning("Skipping peer - missing runtime state (container likely stopped)", metadata: [
                    "other_container_id": "\(otherContainerID)"
                ])
                continue
            }

            // Get IP address from database
            guard let otherAttachment = networkAttachments.first(where: { $0.containerID == otherContainerID }) else {
                continue
            }

            // Create WireGuard client for peer container
            let otherContainer: Containerization.LinuxContainer
            do {
                otherContainer = try await getContainer(otherContainerID)
            } catch {
                logger.error("Failed to get peer container", metadata: [
                    "peer_container_id": "\(otherContainerID)",
                    "error": "\(error)"
                ])
                continue
            }

            let otherClient = WireGuardClient(logger: logger)
            do {
                try await otherClient.connect(container: otherContainer, vsockPort: 51820)
            } catch {
                logger.error("Failed to connect to peer container", metadata: [
                    "peer_container_id": "\(otherContainerID)",
                    "error": "\(error)"
                ])
                continue
            }

            // Ensure we disconnect when done
            defer {
                Task {
                    try? await otherClient.disconnect()
                }
            }

            // Get the other container's vmnet endpoint
            let otherEndpoint: String
            do {
                otherEndpoint = try await otherClient.getVmnetEndpoint()
            } catch {
                logger.error("Failed to get vmnet endpoint from peer container", metadata: [
                    "peer_container_id": "\(otherContainerID)",
                    "error": "\(error)"
                ])
                continue
            }

            logger.debug("Configuring peer mesh", metadata: [
                "container_id": "\(containerID)",
                "peer_container_id": "\(otherContainerID)",
                "peer_endpoint": "\(otherEndpoint)",
                "peer_ip": "\(otherAttachment.ipAddress)"
            ])

            // Add THIS container as a peer to OTHER container
            do {
                let _ = try await otherClient.addPeer(
                    networkID: networkID,
                    networkIndex: otherNetworkIndex,
                    peerPublicKey: result.publicKey,
                    peerEndpoint: thisEndpoint,
                    peerIPAddress: ipAddress,
                    peerName: containerName,
                    peerContainerID: containerID,
                    peerAliases: aliases
                )
                logger.debug("Added this container as peer to other container (DNS registered)", metadata: [
                    "this_container": "\(containerID)",
                    "other_container": "\(otherContainerID)"
                ])
            } catch {
                logger.error("Failed to add this container as peer to other container", metadata: [
                    "this_container": "\(containerID)",
                    "other_container": "\(otherContainerID)",
                    "error": "\(error)"
                ])
                // Continue - try to add other peers
            }

            // Add OTHER container as a peer to THIS container
            do {
                // Get other container's name and aliases (stored when it was attached)
                let otherName = containerNames[otherContainerID] ?? otherContainerID
                let otherAliases = Array(otherAttachment.aliases.dropLast())  // Drop container name (last element)

                let _ = try await wgClient.addPeer(
                    networkID: networkID,
                    networkIndex: networkIndex,
                    peerPublicKey: otherPublicKey,
                    peerEndpoint: otherEndpoint,
                    peerIPAddress: otherAttachment.ipAddress,
                    peerName: otherName,
                    peerContainerID: otherContainerID,
                    peerAliases: otherAliases
                )
                logger.debug("Added other container as peer to this container (DNS registered)", metadata: [
                    "this_container": "\(containerID)",
                    "other_container": "\(otherContainerID)"
                ])
            } catch {
                logger.error("Failed to add other container as peer to this container", metadata: [
                    "this_container": "\(containerID)",
                    "other_container": "\(otherContainerID)",
                    "error": "\(error)"
                ])
                // Continue - try to add other peers
            }
        }

        logger.info("Full mesh configured for container", metadata: [
            "container_id": "\(containerID)",
            "network_id": "\(networkID)",
            "total_peers": "\(otherContainerIDs.count)"
        ])

        // Create attachment (IP already reserved atomically in database)
        let attachment = NetworkAttachment(
            networkID: networkID,
            ip: ipAddress,
            mac: mac,
            aliases: allAliases
        )

        // Store container name for DNS (Phase 3.1) - still needs in-memory for WireGuard client access
        containerNames[containerID] = containerName

        logger.info("Container attached to WireGuard network", metadata: [
            "container_id": "\(containerID)",
            "network_id": "\(networkID)",
            "ip": "\(ipAddress)"
        ])

        return attachment
    }

    /// Detach container from network
    ///
    /// Phase 2.2: Removes wgN/ethN interface for this network
    public func detachContainer(
        containerID: String,
        container: Containerization.LinuxContainer,
        networkID: String
    ) async throws {
        // Load network metadata from database
        guard let metadata = try await loadNetwork(id: networkID) else {
            throw NetworkManagerError.networkNotFound(networkID)
        }

        logger.info("Detaching container from WireGuard network", metadata: [
            "container_id": "\(containerID)",
            "network_id": "\(networkID)"
        ])

        // Check if attached by querying database
        let containerNetworks = try await stateStore.getContainerNetworks(containerID: containerID)
        guard containerNetworks.contains(networkID) else {
            throw NetworkManagerError.notConnected(containerID, metadata.name)
        }

        // Get network index for this network
        let indices = containerNetworkIndices[containerID]
        let networkIndex = indices?[networkID]

        // Try to create WireGuard client for the target container
        // If we can't connect, we'll still clean up peer relationships on OTHER containers
        var targetClient: WireGuardClient?
        if let container = try? await getContainer(containerID) {
            let client = WireGuardClient(logger: logger)
            if (try? await client.connect(container: container, vsockPort: 51820)) != nil {
                targetClient = client
            }
        }

        // Ensure we disconnect the target client when done
        if let client = targetClient {
            defer {
                Task {
                    try? await client.disconnect()
                }
            }
        }

        if targetClient == nil {
            logger.warning("Cannot connect to target container - will skip interface removal but still clean up peers", metadata: [
                "container_id": "\(containerID)",
                "network_id": "\(networkID)"
            ])
        }

        // ALWAYS try to remove this container as a peer from other containers
        // This ensures mesh consistency even if target container is unreachable
        if let networkIndex = networkIndex,
           let thisPublicKey = containerInterfaceKeys[containerID]?[networkID] {

            // Get all OTHER containers on this network from database
            let networkContainers = try await stateStore.getNetworkContainers(networkID: networkID)
            let otherContainerIDs = networkContainers.filter { $0 != containerID }

            logger.debug("Removing this container as peer from other containers", metadata: [
                "container_id": "\(containerID)",
                "network_id": "\(networkID)",
                "peer_count": "\(otherContainerIDs.count)"
            ])

            // Remove this container as a peer from each other container
            for otherContainerID in otherContainerIDs {
                guard let otherNetworkIndex = containerNetworkIndices[otherContainerID]?[networkID] else {
                    logger.warning("Skipping peer removal - missing metadata", metadata: [
                        "other_container_id": "\(otherContainerID)"
                    ])
                    continue
                }

                // Get peer container
                let otherContainer: Containerization.LinuxContainer
                do {
                    otherContainer = try await getContainer(otherContainerID)
                } catch {
                    logger.error("Failed to get peer container for removal", metadata: [
                        "peer_container_id": "\(otherContainerID)",
                        "error": "\(error)"
                    ])
                    continue
                }

                // Create WireGuard client for peer
                let otherClient = WireGuardClient(logger: logger)
                do {
                    try await otherClient.connect(container: otherContainer, vsockPort: 51820)
                } catch {
                    logger.error("Failed to connect to peer for removal", metadata: [
                        "peer_container_id": "\(otherContainerID)",
                        "error": "\(error)"
                    ])
                    continue
                }

                // Ensure we disconnect when done
                defer {
                    Task {
                        try? await otherClient.disconnect()
                    }
                }

                do {
                    // Get this container's name for DNS entry removal
                    let thisName = containerNames[containerID] ?? containerID

                    let _ = try await otherClient.removePeer(
                        networkID: networkID,
                        networkIndex: otherNetworkIndex,
                        peerPublicKey: thisPublicKey,
                        peerName: thisName
                    )
                    logger.debug("Removed this container as peer from other container (DNS unregistered)", metadata: [
                        "this_container": "\(containerID)",
                        "other_container": "\(otherContainerID)"
                    ])
                } catch {
                    logger.error("Failed to remove this container as peer from other container", metadata: [
                        "this_container": "\(containerID)",
                        "other_container": "\(otherContainerID)",
                        "error": "\(error)"
                    ])
                    // Continue - try to remove from other peers
                }
            }

            logger.info("Peer cleanup completed", metadata: [
                "container_id": "\(containerID)",
                "network_id": "\(networkID)",
                "peers_cleaned": "\(otherContainerIDs.count)"
            ])

            // Remove network interface (wgN/ethN) from target container if we have a client
            if let targetClient = targetClient {
                logger.info("Removing WireGuard interface from target container", metadata: [
                    "container_id": "\(containerID)",
                    "network_id": "\(networkID)",
                    "network_index": "\(networkIndex)",
                    "interface": "wg\(networkIndex)/eth\(networkIndex)"
                ])
                try await targetClient.removeNetwork(networkID: networkID, networkIndex: networkIndex)
            } else {
                logger.warning("Cannot remove interface from unreachable target container", metadata: [
                    "container_id": "\(containerID)",
                    "network_id": "\(networkID)"
                ])
            }

            // Update state
            var updatedIndices = indices!
            updatedIndices.removeValue(forKey: networkID)

            if updatedIndices.isEmpty {
                // Last network removed - cleanup state (client cleanup in defer block, hub auto-deleted)
                logger.info("Last network removed, cleaning up state", metadata: [
                    "container_id": "\(containerID)"
                ])

                containerNetworkIndices.removeValue(forKey: containerID)
                containerInterfaceKeys.removeValue(forKey: containerID)
                containerNames.removeValue(forKey: containerID)  // Phase 3.1: Clean up DNS name
            } else {
                containerNetworkIndices[containerID] = updatedIndices

                var keys = containerInterfaceKeys[containerID] ?? [:]
                keys.removeValue(forKey: networkID)
                containerInterfaceKeys[containerID] = keys
            }
        } else {
            // Container has no network index - already cleaned up or never had this network
            logger.info("Container has no network index, skipping WireGuard operations", metadata: [
                "container_id": "\(containerID)",
                "network_id": "\(networkID)"
            ])
        }

        // Delete attachment from database
        // This is the source of truth - network's container list is derived from database
        try await stateStore.deleteNetworkAttachment(containerID: containerID, networkID: networkID)

        logger.info("Container detached from WireGuard network", metadata: [
            "container_id": "\(containerID)",
            "network_id": "\(networkID)"
        ])
    }

    // MARK: - Network Queries

    /// Get network metadata
    public func getNetwork(id: String) async throws -> NetworkMetadata? {
        return try await loadNetwork(id: id)
    }

    /// List all networks
    public func listNetworks() async throws -> [NetworkMetadata] {
        let dbNetworks = try await stateStore.loadAllNetworks()
        var networks: [NetworkMetadata] = []

        for dbNetwork in dbNetworks {
            // Only include WireGuard/bridge networks
            guard dbNetwork.driver == "wireguard" || dbNetwork.driver == "bridge" else {
                continue
            }

            let containers = try await stateStore.getNetworkContainers(networkID: dbNetwork.id)
            let options = try? (dbNetwork.optionsJSON.flatMap { try JSONDecoder().decode([String: String].self, from: $0.data(using: .utf8)!) }) ?? [:]
            let labels = try? (dbNetwork.labelsJSON.flatMap { try JSONDecoder().decode([String: String].self, from: $0.data(using: .utf8)!) }) ?? [:]

            networks.append(NetworkMetadata(
                id: dbNetwork.id,
                name: dbNetwork.name,
                driver: dbNetwork.driver,
                subnet: dbNetwork.subnet,
                gateway: dbNetwork.gateway,
                ipRange: dbNetwork.ipRange,
                containers: containers,
                created: dbNetwork.createdAt,
                options: options ?? [:],
                labels: labels ?? [:],
                isDefault: dbNetwork.isDefault
            ))
        }

        return networks
    }

    /// Get network by name
    public func getNetworkByName(name: String) async throws -> NetworkMetadata? {
        // Query all networks and find by name
        let allNetworks = try await stateStore.loadAllNetworks()
        guard let dbNetwork = allNetworks.first(where: { $0.name == name }) else {
            return nil
        }

        let containers = try await stateStore.getNetworkContainers(networkID: dbNetwork.id)
        let options = try? (dbNetwork.optionsJSON.flatMap { try JSONDecoder().decode([String: String].self, from: $0.data(using: .utf8)!) }) ?? [:]
        let labels = try? (dbNetwork.labelsJSON.flatMap { try JSONDecoder().decode([String: String].self, from: $0.data(using: .utf8)!) }) ?? [:]

        return NetworkMetadata(
            id: dbNetwork.id,
            name: dbNetwork.name,
            driver: dbNetwork.driver,
            subnet: dbNetwork.subnet,
            gateway: dbNetwork.gateway,
            ipRange: dbNetwork.ipRange,
            containers: containers,
            created: dbNetwork.createdAt,
            options: options ?? [:],
            labels: labels ?? [:],
            isDefault: dbNetwork.isDefault
        )
    }

    // Attachment reads are not here: `StoredNetworkAttachments` in
    // NetworkManager.swift owns them. They read `network_attachments` and no
    // in-memory backend state, so routing them through a backend that only
    // `NetworkManager.initialize()` can install cost the ability to test them
    // and bought nothing. Do not add a second copy here: two answers to "who
    // is attached" is what `docker network prune` would then delete on.

    /// Clean up in-memory network state for a stopped/exited container
    /// Called when container stops to ensure state is clean for restart
    public func cleanupStoppedContainer(containerID: String) async {
        logger.debug("Cleaning up WireGuard state for stopped container", metadata: [
            "container_id": "\(containerID)"
        ])

        // Note: We don't cache WireGuard clients, so nothing to clean up here.
        // The container is still "attached" to networks metadata-wise, just stopped.
        // When it restarts, we'll recreate the WireGuard hub with same IPs.
    }

    // MARK: - Helper Methods

    /// Load NetworkMetadata from database
    private func loadNetwork(id: String) async throws -> NetworkMetadata? {
        guard let dbNetwork = try await stateStore.getNetwork(id: id) else {
            return nil
        }

        // Get containers attached to this network from database
        let containers = try await stateStore.getNetworkContainers(networkID: id)

        // Parse options and labels from JSON
        let options = try? (dbNetwork.optionsJSON.flatMap { try JSONDecoder().decode([String: String].self, from: $0.data(using: .utf8)!) }) ?? [:]
        let labels = try? (dbNetwork.labelsJSON.flatMap { try JSONDecoder().decode([String: String].self, from: $0.data(using: .utf8)!) }) ?? [:]

        return NetworkMetadata(
            id: dbNetwork.id,
            name: dbNetwork.name,
            driver: dbNetwork.driver,
            subnet: dbNetwork.subnet,
            gateway: dbNetwork.gateway,
            ipRange: dbNetwork.ipRange,
            containers: containers,
            created: dbNetwork.createdAt,
            options: options ?? [:],
            labels: labels ?? [:],
            isDefault: dbNetwork.isDefault
        )
    }

    /// Allocate an IP address for a container in a network
    /// Uses smart IP reclamation - finds first available IP by querying allocated IPs from database
    private func allocateIP(networkID: String, subnet: String) async throws -> String {
        // Parse subnet using swift-ip for type safety
        guard let block = IP.Block(subnet) else {
            throw NetworkManagerError.ipAllocationFailed("Invalid subnet format: \(subnet)")
        }

        // Get all currently allocated IPs from database (network_attachments table)
        // This automatically reflects freed IPs when containers are removed (CASCADE DELETE)
        let allocatedIPs = try await stateStore.getAllocatedIPs(networkID: networkID)

        // Determine IP allocation range
        // For Docker compatibility, we allocate from .2 (gateway is .1) to broadcast-1
        let networkAddr = block.base
        let gatewayIP = IP.V4(value: networkAddr.value + 1)  // .1 is gateway
        let startIP = IP.V4(value: gatewayIP.value + 1)  // Start at .2

        // Check if ipRange is specified for this network to constrain allocation
        let (rangeStart, rangeEnd): (IP.V4, IP.V4)
        if let metadata = try await loadNetwork(id: networkID), let ipRangeStr = metadata.ipRange,
           let ipRange = IP.Block(ipRangeStr) {
            // Use ip-range to constrain allocation
            rangeStart = ipRange.range.lowerBound
            rangeEnd = ipRange.range.upperBound
        } else {
            // Use full subnet range (excluding network address and broadcast)
            rangeStart = startIP
            // NOTE: this bound is the broadcast address itself, not broadcast-1
            // as this comment previously claimed, and the loop below is
            // inclusive of it. Tracked as a separate defect; behaviour is
            // deliberately unchanged here.
            rangeEnd = block.range.upperBound
        }

        // Iterate through IP range to find first available
        var currentValue = rangeStart.value
        let endValue = rangeEnd.value

        while currentValue <= endValue {
            let currentIP = IP.V4(value: currentValue)
            let candidateIPStr = String(describing: currentIP)

            // Skip gateway (.1) and already allocated IPs
            if currentIP != gatewayIP && !allocatedIPs.contains(candidateIPStr) {
                // Found an available IP!
                logger.debug("Allocated IP (reclaimed if previously used)", metadata: [
                    "network_id": "\(networkID)",
                    "ip": "\(candidateIPStr)",
                    "total_allocated": "\(allocatedIPs.count)"
                ])

                return candidateIPStr
            }

            // Move to next IP (handles overflow gracefully)
            if currentValue == UInt32.max {
                break  // Reached end of address space
            }
            currentValue += 1
        }

        // No available IPs in range
        throw NetworkManagerError.ipAllocationFailed(
            "IP pool exhausted for network \(networkID): all IPs from \(rangeStart) to \(rangeEnd) are allocated"
        )
    }

    /// Calculate gateway IP from subnet CIDR
    private func calculateGateway(subnet: String) -> String {
        // For Docker compatibility, use .1 as gateway (e.g., 172.18.0.1 for 172.18.0.0/16)
        guard let block = IP.Block(subnet) else {
            return "172.18.0.1"  // Fallback
        }

        // Gateway is always .1 (first host address after network address)
        let gatewayIP = IP.V4(value: block.base.value + 1)
        return String(describing: gatewayIP)
    }

    /// Generate a deterministic MAC address for a container on a network
    private func generateMACAddress(containerID: String, networkID: String) -> String {
        // Create a deterministic hash from containerID + networkID
        let input = "\(containerID)\(networkID)"
        let hash = input.utf8.reduce(0) { result, byte in
            ((result &<< 5) &- result) &+ UInt64(byte)
        }

        // Format as MAC address (locally administered, unicast)
        // 02:xx:xx:xx:xx:xx (locally administered bit set, unicast)
        let bytes = withUnsafeBytes(of: hash) { Array($0.prefix(6)) }
        return String(format: "02:%02x:%02x:%02x:%02x:%02x",
                     bytes[1], bytes[2], bytes[3], bytes[4], bytes[5])
    }

    /// Generate a WireGuard private key
    private func generateWireGuardPrivateKey() throws -> String {
        // Generate random 32 bytes for WireGuard private key
        var keyBytes = [UInt8](repeating: 0, count: 32)
        let result = SecRandomCopyBytes(kSecRandomDefault, 32, &keyBytes)

        guard result == errSecSuccess else {
            throw NetworkManagerError.ipAllocationFailed("Failed to generate WireGuard private key")
        }

        // Encode as base64 (WireGuard key format)
        let keyData = Data(keyBytes)
        return keyData.base64EncodedString()
    }

    /// Check if an IP address is within a subnet (CIDR)
    private func isIPInSubnet(_ ip: String, subnet: String) -> Bool {
        // Parse subnet and IP using swift-ip for type-safe checking
        guard let block = IP.Block(subnet),
              let address = IP.V4(ip) else {
            return false
        }

        // Use swift-ip's built-in contains check
        return block.contains(address)
    }
}

/// The bridge-network source `NetworkManager.listNetworks()` reads in
/// production. The conformance is empty: `listNetworks()` above already has the
/// signature the protocol asks for.
extension WireGuardNetworkBackend: NetworkLister {}
