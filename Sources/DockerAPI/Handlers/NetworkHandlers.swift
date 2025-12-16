import Foundation
import Logging
import ContainerBridge
import NIOHTTP1

// Helper extension for converting arrays to tuples
extension Array where Element == String {
    func tuple() -> (String, String)? {
        guard count >= 2 else { return nil }
        return (self[0], self[1])
    }
}

/// Handlers for Docker Engine API network endpoints
/// Reference: Documentation/DOCKER_ENGINE_API_SPEC.md
public struct NetworkHandlers: Sendable {
    private let networkManager: NetworkManager
    private let containerManager: ContainerManager
    private let logger: Logger

    public init(networkManager: NetworkManager, containerManager: ContainerManager, logger: Logger) {
        self.networkManager = networkManager
        self.containerManager = containerManager
        self.logger = logger
    }

    /// Get error description from Swift errors
    private func errorDescription(_ error: Error) -> String {
        return error.localizedDescription
    }

    /// Handle GET /networks
    /// Lists all networks
    ///
    /// Query parameters:
    /// - filters: JSON encoded filters (name, id, driver, type, label, dangling, scope)
    public func handleListNetworks(filters: [String: [String]] = [:]) async -> Result<[Network], NetworkError> {
        logger.debug("Handling list networks request", metadata: [
            "filters": "\(filters)"
        ])

        // networkManager.listNetworks() doesn't throw - it returns an array directly
        // No failure case for listing (empty array on no networks)
        let allNetworks = await networkManager.listNetworks()

        // Apply sync filters first
        var filteredMetadata = applyFilters(allNetworks, filters: filters)

        // Apply dangling filter (async - requires checking attachments)
        if let danglingValues = filters["dangling"], !danglingValues.isEmpty {
            if let dangling = parseBool(danglingValues[0]) {
                var danglingFiltered: [NetworkMetadata] = []
                for network in filteredMetadata {
                    let attachments = await networkManager.getNetworkAttachments(networkID: network.id)
                    let isDangling = attachments.isEmpty
                    if dangling == isDangling {
                        danglingFiltered.append(network)
                    }
                }
                filteredMetadata = danglingFiltered
            }
        }

        // Convert to Docker API format
        var networks: [Network] = []
        for metadata in filteredMetadata {
            networks.append(await convertToDockerNetwork(metadata))
        }

        logger.info("Listed networks", metadata: ["count": "\(networks.count)"])
        return .success(networks)
    }

    /// Handle GET /networks/{id}
    /// Inspects a network
    ///
    /// Query parameters:
    /// - verbose: Include detailed information (not yet implemented)
    /// - scope: Filter by scope (not yet implemented)
    public func handleInspectNetwork(
        id: String,
        verbose: Bool = false,
        scope: String? = nil
    ) async -> Result<Network, NetworkError> {
        logger.debug("Handling inspect network request", metadata: [
            "id": "\(id)",
            "verbose": "\(verbose)",
            "scope": "\(scope ?? "none")"
        ])

        // TODO: Implement verbose mode (include peer info, services)
        if verbose {
            logger.warning("Verbose mode not yet implemented for network inspect")
        }

        // TODO: Implement scope filtering
        if let scope = scope {
            logger.warning("Scope filtering not yet implemented", metadata: ["scope": "\(scope)"])
        }

        // Try resolving as name or ID
        let resolvedID = await networkManager.resolveNetworkID(id) ?? id

        // networkManager methods don't throw - they return optionals
        // Failure case handled via guard statement
        guard let metadata = await networkManager.getNetwork(id: resolvedID) else {
            return .failure(NetworkError.notFound(id))
        }
        let network = await convertToDockerNetwork(metadata)

        logger.info("Inspected network", metadata: [
            "id": "\(network.id)",
            "name": "\(network.name)"
        ])
        return .success(network)
    }

    /// Handle POST /networks/create
    /// Creates a new network
    public func handleCreateNetwork(request: NetworkCreateRequest) async -> Result<NetworkCreateResponse, NetworkError> {
        logger.info("Handling create network request", metadata: [
            "name": "\(request.name)",
            "driver": "\(request.driver ?? "bridge")"
        ])

        // Log warnings for unsupported fields
        if let scope = request.scope, scope != "local" {
            logger.warning("Scope '\(scope)' not supported, using 'local'", metadata: ["network": "\(request.name)"])
        }

        if request.configOnly == true {
            logger.warning("ConfigOnly networks not supported", metadata: ["network": "\(request.name)"])
            return .failure(NetworkError.invalidRequest("ConfigOnly networks not supported"))
        }

        if request.configFrom != nil {
            logger.warning("ConfigFrom not supported", metadata: ["network": "\(request.name)"])
            return .failure(NetworkError.invalidRequest("ConfigFrom not supported"))
        }

        if request.enableIPv4 == false {
            logger.warning("Disabling IPv4 not supported", metadata: ["network": "\(request.name)"])
            return .failure(NetworkError.invalidRequest("IPv4 cannot be disabled"))
        }

        // Extract IPAM configuration
        let subnet = request.ipam?.config?.first?.subnet
        let gateway = request.ipam?.config?.first?.gateway
        let ipRange = request.ipam?.config?.first?.ipRange

        do {
            // Normalize empty driver string to nil (Docker Compose sends "" instead of nil)
            let normalizedDriver = request.driver?.isEmpty == false ? request.driver : nil

            let networkID = try await networkManager.createNetwork(
                name: request.name,
                driver: normalizedDriver ?? "bridge",
                subnet: subnet,
                gateway: gateway,
                ipRange: ipRange,
                options: request.options ?? [:],
                labels: request.labels ?? [:]
            )

            logger.info("Network created successfully", metadata: [
                "id": "\(networkID)",
                "name": "\(request.name)"
            ])

            return .success(NetworkCreateResponse(id: networkID))
        } catch let error as NetworkManagerError {
            logger.error("Failed to create network", metadata: [
                "name": "\(request.name)",
                "error": "\(error)"
            ])

            switch error {
            case .nameExists:
                return .failure(NetworkError.conflict(error.description))
            case .unsupportedDriver:
                return .failure(NetworkError.invalidRequest(error.description))
            default:
                return .failure(NetworkError.createFailed(error.description))
            }
        } catch {
            logger.error("Unexpected error creating network", metadata: [
                "name": "\(request.name)",
                "error": "\(error)"
            ])
            return .failure(NetworkError.createFailed(errorDescription(error)))
        }
    }

    /// Handle DELETE /networks/{id}
    /// Deletes a network
    public func handleDeleteNetwork(id: String, force: Bool = false) async -> Result<Void, NetworkError> {
        logger.info("Handling delete network request", metadata: [
            "id": "\(id)",
            "force": "\(force)"
        ])

        do {
            // Resolve network name or ID to full network ID
            guard let resolvedID = await networkManager.resolveNetworkID(id) else {
                return .failure(NetworkError.notFound(id))
            }

            try await networkManager.deleteNetwork(id: resolvedID)

            logger.info("Network deleted successfully", metadata: ["id": "\(id)"])
            return .success(())
        } catch let error as NetworkManagerError {
            logger.error("Failed to delete network", metadata: [
                "id": "\(id)",
                "error": "\(error)"
            ])

            switch error {
            case .networkNotFound:
                return .failure(NetworkError.notFound(id))
            case .hasActiveEndpoints, .cannotDeleteDefault:
                return .failure(NetworkError.conflict(error.description))
            default:
                return .failure(NetworkError.deleteFailed(error.description))
            }
        } catch {
            logger.error("Unexpected error deleting network", metadata: [
                "id": "\(id)",
                "error": "\(error)"
            ])
            return .failure(NetworkError.deleteFailed(errorDescription(error)))
        }
    }

    /// Handle POST /networks/{id}/connect
    /// Connects a container to a network
    public func handleConnectNetwork(
        networkID: String,
        containerID: String,
        containerName: String,
        endpointConfig: EndpointConfig?
    ) async -> Result<Void, NetworkError> {
        logger.info("Handling connect network request", metadata: [
            "network": "\(networkID)",
            "container": "\(containerID)"
        ])

        // Extract IPv4 address and aliases from endpoint config
        let userIP = endpointConfig?.ipamConfig?.ipv4Address
        let aliases = endpointConfig?.aliases ?? []

        do {
            // Check if container is using host or none network mode
            // Docker does not allow connecting additional networks to these containers
            if let networkMode = await containerManager.getContainerNetworkMode(dockerID: containerID) {
                if networkMode == "host" || networkMode == "none" {
                    logger.warning("Rejecting network connect for host/none network container", metadata: [
                        "container": "\(containerID)",
                        "networkMode": "\(networkMode)"
                    ])
                    return .failure(NetworkError.conflict(
                        "container sharing network namespace of another container cannot be connected to other networks"
                    ))
                }
            }

            // Resolve network name or ID to full network ID
            guard let resolvedNetworkID = await networkManager.resolveNetworkID(networkID) else {
                return .failure(NetworkError.notFound("network \(networkID) not found"))
            }

            // Get the container object
            guard let container = try await containerManager.getLinuxContainer(dockerID: containerID) else {
                return .failure(NetworkError.notFound("Container \(containerID) not found"))
            }

            // Get container name for DNS
            let containerName = await containerManager.getContainerName(dockerID: containerID) ?? String(containerID.prefix(12))

            // Attach to network via NetworkManager (OVS attachment)
            let attachment = try await networkManager.attachContainerToNetwork(
                containerID: containerID,
                container: container,
                networkID: resolvedNetworkID,
                containerName: containerName,
                aliases: aliases,
                userSpecifiedIP: userIP
            )

            // Record the attachment in ContainerManager (triggers DNS push)
            try await containerManager.attachContainerToNetwork(
                dockerID: containerID,
                networkID: resolvedNetworkID,
                ip: attachment.ip,
                mac: attachment.mac,
                aliases: attachment.aliases
            )

            logger.info("Container connected to network successfully", metadata: [
                "network": "\(networkID)",
                "container": "\(containerID)"
            ])
            return .success(())
        } catch let error as NetworkManagerError {
            logger.error("Failed to connect container to network", metadata: [
                "network": "\(networkID)",
                "container": "\(containerID)",
                "error": "\(error)"
            ])

            switch error {
            case .networkNotFound:
                return .failure(NetworkError.notFound(networkID))
            case .alreadyConnected:
                return .failure(NetworkError.conflict(error.description))
            default:
                return .failure(NetworkError.connectFailed(error.description))
            }
        } catch {
            logger.error("Unexpected error connecting container", metadata: [
                "network": "\(networkID)",
                "container": "\(containerID)",
                "error": "\(error)"
            ])
            return .failure(NetworkError.connectFailed(errorDescription(error)))
        }
    }

    /// Handle POST /networks/{id}/disconnect
    /// Disconnects a container from a network
    public func handleDisconnectNetwork(
        networkID: String,
        containerID: String,
        force: Bool = false
    ) async -> Result<Void, NetworkError> {
        logger.info("Handling disconnect network request", metadata: [
            "network": "\(networkID)",
            "container": "\(containerID)",
            "force": "\(force)"
        ])

        do {
            // Get the container object
            guard let container = try await containerManager.getLinuxContainer(dockerID: containerID) else {
                return .failure(NetworkError.notFound("Container \(containerID) not found"))
            }

            try await networkManager.detachContainerFromNetwork(
                containerID: containerID,
                container: container,
                networkID: networkID
            )

            logger.info("Container disconnected from network successfully", metadata: [
                "network": "\(networkID)",
                "container": "\(containerID)"
            ])
            return .success(())
        } catch let error as NetworkManagerError {
            logger.error("Failed to disconnect container from network", metadata: [
                "network": "\(networkID)",
                "container": "\(containerID)",
                "error": "\(error)"
            ])

            switch error {
            case .networkNotFound:
                return .failure(NetworkError.notFound(networkID))
            case .notConnected:
                return .failure(NetworkError.conflict(error.description))
            default:
                return .failure(NetworkError.disconnectFailed(error.description))
            }
        } catch {
            logger.error("Unexpected error disconnecting container", metadata: [
                "network": "\(networkID)",
                "container": "\(containerID)",
                "error": "\(error)"
            ])
            return .failure(NetworkError.disconnectFailed(errorDescription(error)))
        }
    }

    // MARK: - Helper Methods

    /// Apply filters to network list
    private func applyFilters(_ networks: [NetworkMetadata], filters: [String: [String]]) -> [NetworkMetadata] {
        var filtered = networks

        // Filter by name (supports regex patterns like Docker)
        if let names = filters["name"], !names.isEmpty {
            filtered = filtered.filter { network in
                names.contains { pattern in
                    // Try as regex first, fall back to exact match
                    if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
                        let range = NSRange(network.name.startIndex..., in: network.name)
                        return regex.firstMatch(in: network.name, options: [], range: range) != nil
                    }
                    return pattern == network.name
                }
            }
        }

        // Filter by ID (supports regex patterns like Docker)
        if let ids = filters["id"], !ids.isEmpty {
            filtered = filtered.filter { network in
                ids.contains { pattern in
                    // Try as regex first, fall back to prefix match
                    if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
                        let range = NSRange(network.id.startIndex..., in: network.id)
                        return regex.firstMatch(in: network.id, options: [], range: range) != nil
                    }
                    return network.id.hasPrefix(pattern)
                }
            }
        }

        // Filter by driver
        if let drivers = filters["driver"], !drivers.isEmpty {
            filtered = filtered.filter { network in
                drivers.contains(network.driver)
            }
        }

        // Filter by label
        if let labels = filters["label"], !labels.isEmpty {
            filtered = filtered.filter { network in
                labels.allSatisfy { labelFilter in
                    if let (key, value) = labelFilter.split(separator: "=", maxSplits: 1).map({ String($0) }).tuple() {
                        return network.labels[key] == value
                    } else {
                        return network.labels[labelFilter] != nil
                    }
                }
            }
        }

        // Filter by scope (local, swarm, global)
        if let scopes = filters["scope"], !scopes.isEmpty {
            filtered = filtered.filter { network in
                // For now, all networks are "local" scope (no swarm support)
                scopes.contains("local")
            }
        }

        // Filter by type (custom, builtin)
        if let types = filters["type"], !types.isEmpty {
            filtered = filtered.filter { network in
                if types.contains("builtin") && network.isDefault {
                    return true
                }
                if types.contains("custom") && !network.isDefault {
                    return true
                }
                return false
            }
        }

        return filtered
    }

    /// Convert NetworkMetadata to Docker API Network format
    private func convertToDockerNetwork(_ metadata: NetworkMetadata) async -> Network {
        // Format created timestamp as ISO8601
        let iso8601Formatter = ISO8601DateFormatter()
        let createdString = iso8601Formatter.string(from: metadata.created)

        // Create IPAM config
        let ipamConfig = IPAMConfig(
            subnet: metadata.subnet,
            gateway: metadata.gateway
        )
        let ipam = IPAM(driver: "default", config: [ipamConfig])

        // Get container attachments for this network
        let attachments = await networkManager.getNetworkAttachments(networkID: metadata.id)
        var containers: [String: NetworkContainer] = [:]

        for (containerID, attachment) in attachments {
            // Get container name
            let containerName = await containerManager.getContainerName(dockerID: containerID) ?? containerID

            containers[containerID] = NetworkContainer(
                name: containerName,
                endpointID: containerID,  // Use container ID as endpoint ID
                macAddress: attachment.mac,
                ipv4Address: "\(attachment.ip)/\(metadata.subnet.split(separator: "/").last ?? "16")",
                ipv6Address: ""  // IPv6 not supported yet
            )
        }

        return Network(
            name: metadata.name,
            id: metadata.id,
            created: createdString,
            scope: "local",
            driver: metadata.driver,
            enableIPv6: false,
            ipam: ipam,
            internal: false,
            attachable: false,
            ingress: false,
            containers: containers,
            options: metadata.options,
            labels: metadata.labels,
            enableIPv4: true,        // Always true for now
            configFrom: nil,          // Not supported yet
            configOnly: false,        // Not supported yet
            peers: nil                // No overlay networks
        )
    }

    /// Handle POST /networks/prune
    /// Deletes unused networks (no containers attached)
    ///
    /// Query parameters:
    /// - filters: JSON encoded filters (until, label)
    public func handlePruneNetworks(filters: [String: [String]] = [:]) async -> Result<NetworkPruneResponse, NetworkError> {
        logger.info("Handling prune networks request", metadata: ["filters": "\(filters)"])

        // Parse filters
        var untilDate: Date? = nil
        var labelFilters: [String] = []

        if let untilValues = filters["until"], let untilStr = untilValues.first {
            // Parse timestamp (Unix timestamp, RFC3339, or duration like "24h")
            untilDate = parseTimestamp(untilStr)
        }

        if let labels = filters["label"] {
            labelFilters = labels
        }

        // Get all networks from NetworkManager
        let allNetworks = await networkManager.listNetworks()

        var deletedNetworkNames: [String] = []

        for network in allNetworks {
            // Skip default networks (bridge, host, none)
            if network.isDefault {
                continue
            }

            // Skip networks with active containers
            let attachments = await networkManager.getNetworkAttachments(networkID: network.id)
            if !attachments.isEmpty {
                continue
            }

            // Apply until filter
            if let until = untilDate, network.created > until {
                continue
            }

            // Apply label filters
            if !labelFilters.isEmpty {
                let matchesLabels = labelFilters.allSatisfy { labelFilter in
                    if let (key, value) = labelFilter.split(separator: "=", maxSplits: 1).map({ String($0) }).tuple() {
                        return network.labels[key] == value
                    } else {
                        return network.labels[labelFilter] != nil
                    }
                }
                if !matchesLabels {
                    continue
                }
            }

            // Delete the network
            do {
                try await networkManager.deleteNetwork(id: network.id)
                deletedNetworkNames.append(network.name)  // Docker returns names, not IDs
                logger.info("Pruned network", metadata: ["id": "\(network.id)", "name": "\(network.name)"])
            } catch {
                logger.warning("Failed to prune network", metadata: [
                    "id": "\(network.id)",
                    "error": "\(error)"
                ])
            }
        }

        logger.info("Networks pruned", metadata: ["count": "\(deletedNetworkNames.count)"])
        return .success(NetworkPruneResponse(networksDeleted: deletedNetworkNames))
    }

    /// Parse timestamp from string (Unix timestamp, RFC3339, or Go duration)
    private func parseTimestamp(_ str: String) -> Date? {
        // Try Unix timestamp
        if let timestamp = TimeInterval(str) {
            return Date(timeIntervalSince1970: timestamp)
        }

        // Try RFC3339
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: str) {
            return date
        }

        // Try Go duration (e.g. "24h", "1h30m")
        if let duration = parseDuration(str) {
            return Date(timeIntervalSinceNow: -duration)
        }

        return nil
    }

    /// Parse Go duration string (e.g. "24h", "1h30m", "10m")
    private func parseDuration(_ str: String) -> TimeInterval? {
        var remaining = str
        var totalSeconds: TimeInterval = 0

        let units: [(suffix: String, multiplier: TimeInterval)] = [
            ("h", 3600),
            ("m", 60),
            ("s", 1)
        ]

        for (suffix, multiplier) in units {
            if let range = remaining.range(of: suffix) {
                let numberStr = String(remaining[..<range.lowerBound])
                if let number = Double(numberStr) {
                    totalSeconds += number * multiplier
                    remaining = String(remaining[range.upperBound...])
                }
            }
        }

        return totalSeconds > 0 ? totalSeconds : nil
    }

    /// Parse boolean value from string (true, false, 1, 0)
    private func parseBool(_ str: String) -> Bool? {
        if let boolVal = Bool(str) {
            return boolVal
        }
        if str == "1" || str.lowercased() == "true" {
            return true
        }
        if str == "0" || str.lowercased() == "false" {
            return false
        }
        return nil
    }
}

// MARK: - Network Errors

public enum NetworkError: Error, CustomStringConvertible {
    case notFound(String)
    case conflict(String)
    case invalidRequest(String)
    case listFailed(String)
    case inspectFailed(String)
    case createFailed(String)
    case deleteFailed(String)
    case connectFailed(String)
    case disconnectFailed(String)
    case pruneFailed(String)

    public var description: String {
        switch self {
        case .notFound(let id):
            return "network \(id) not found"
        case .conflict(let message):
            return message
        case .invalidRequest(let message):
            return message
        case .listFailed(let message):
            return "failed to list networks: \(message)"
        case .inspectFailed(let message):
            return "failed to inspect network: \(message)"
        case .createFailed(let message):
            return "failed to create network: \(message)"
        case .deleteFailed(let message):
            return "failed to delete network: \(message)"
        case .connectFailed(let message):
            return "failed to connect container to network: \(message)"
        case .disconnectFailed(let message):
            return "failed to disconnect container from network: \(message)"
        case .pruneFailed(let message):
            return "failed to prune networks: \(message)"
        }
    }
}
