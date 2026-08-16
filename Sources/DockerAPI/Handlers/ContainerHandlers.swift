import Foundation
import Logging
import ContainerBridge
import Containerization
import NIOHTTP1

/// Simple Writer implementation that captures data to a Data buffer
private final class DataWriter: Writer, @unchecked Sendable {
    private(set) var data = Data()
    private let lock = NSLock()

    func write(_ buffer: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        data.append(buffer)
    }

    func close() throws {
        // No-op: data is already captured
    }
}

/// Handlers for Docker Engine API container endpoints
/// Reference: Documentation/DOCKER_ENGINE_API_SPEC.md
public struct ContainerHandlers: Sendable {
    private let containerManager: ContainerBridge.ContainerManager
    private let imageManager: ImageManager
    private let execManager: ExecManager
    private let logger: Logger

    public init(containerManager: ContainerBridge.ContainerManager, imageManager: ImageManager, execManager: ExecManager, logger: Logger) {
        self.containerManager = containerManager
        self.imageManager = imageManager
        self.execManager = execManager
        self.logger = logger
    }

    /// Get error description from Swift errors
    private func errorDescription(_ error: Error) -> String {
        // String interpolation automatically uses CustomStringConvertible.description
        // This gives us the proper error messages from ContainerManagerError
        return "\(error)"
    }

    /// Check if a container is the control plane
    private func isControlPlane(id: String) async -> Bool {
        guard let container = try? await containerManager.getContainer(id: id) else {
            return false
        }
        return container.config.labels["com.arca.internal"] == "true" &&
               container.config.labels["com.arca.role"] == "control-plane"
    }

    /// Handle GET /containers/json
    /// Lists all containers
    ///
    /// Query parameters:
    /// - all: Show all containers (default shows just running)
    /// - limit: Limit the number of results
    /// - size: Return container size information
    /// - filters: JSON encoded filters
    public func handleListContainers(all: Bool = false, limit: Int? = nil, size: Bool = false, filters: [String: [String]] = [:]) async -> ContainerListResponse {
        logger.debug("Handling list containers request", metadata: [
            "all": "\(all)",
            "limit": "\(limit?.description ?? "none")",
            "size": "\(size)",
            "filters": "\(filters)"
        ])

        do {
            // Get containers from ContainerManager
            var containers = try await containerManager.listContainers(
                all: all,
                filters: filters,
                includeInternal: ContainerManager.internalContainersRequested(in: filters)
            )

            // Apply limit if specified
            if let limit = limit, limit > 0 {
                containers = Array(containers.prefix(limit))
            }

            // Convert to Docker API format
            let dockerContainers = containers.map { summary in
                ContainerListItem(
                    id: summary.id,
                    names: summary.names,
                    image: summary.image,
                    imageID: summary.imageID,
                    command: summary.command,
                    created: summary.created,
                    state: summary.state,
                    status: summary.status,
                    ports: summary.ports.map { port in
                        Port(
                            privatePort: port.privatePort,
                            publicPort: port.publicPort,
                            type: port.type,
                            ip: port.ip
                        )
                    },
                    labels: summary.labels,
                    sizeRw: size ? summary.sizeRw : nil,
                    sizeRootFs: size ? summary.sizeRootFs : nil
                )
            }

            logger.info("Listed containers", metadata: [
                "count": "\(dockerContainers.count)"
            ])

            return ContainerListResponse(containers: dockerContainers)
        } catch {
            logger.error("Failed to list containers", metadata: [
                "error": "\(error)"
            ])

            return ContainerListResponse(containers: [], error: error)
        }
    }

    /// Handle POST /containers/create
    /// Creates a new container
    public func handleCreateContainer(
        request: ContainerCreateRequest,
        name: String?
    ) async -> Result<ContainerCreateResponse, ContainerError> {
        logger.info("Handling create container request", metadata: [
            "image": "\(request.image)",
            "name": "\(name ?? "auto")"
        ])

        // Check if image exists locally - return error if not (let Docker CLI handle the pull)
        do {
            _ = try await imageManager.getImage(nameOrId: request.image)
        } catch {
            logger.warning("Image not found, returning error to trigger client-side pull", metadata: [
                "image": "\(request.image)"
            ])
            return .failure(.imageNotFound(request.image))
        }

        do {
            // Convert RestartPolicyCreate to RestartPolicy
            let restartPolicy: RestartPolicy? = request.hostConfig?.restartPolicy.map { policy in
                RestartPolicy(
                    name: policy.name,
                    maximumRetryCount: policy.maximumRetryCount ?? 0
                )
            }

            // Convert PortBindingCreate to PortBinding
            let portBindings: [String: [PortBinding]]? = request.hostConfig?.portBindings?.mapValues { bindings in
                bindings.map { binding in
                    PortBinding(
                        hostIp: binding.hostIp ?? "",
                        hostPort: binding.hostPort ?? ""
                    )
                }
            }

            // Extract user-specified IP and aliases from NetworkingConfig (if provided)
            // Docker Compose sets Aliases to include the service name (e.g., "minio")
            var initialNetworkUserIP: String? = nil
            var initialNetworkAliases: [String] = []
            if let networkingConfig = request.networkingConfig,
               let endpointsConfig = networkingConfig.endpointsConfig {
                // Get the network mode to find the correct endpoint config
                let networkMode = request.hostConfig?.networkMode ?? "bridge"
                if let endpointConfig = endpointsConfig[networkMode] {
                    initialNetworkUserIP = endpointConfig.ipamConfig?.ipv4Address
                    initialNetworkAliases = endpointConfig.aliases ?? []
                }
            }

            logger.debug("Container create request resource limits", metadata: [
                "memory": "\(request.hostConfig?.memory?.description ?? "nil")",
                "memoryReservation": "\(request.hostConfig?.memoryReservation?.description ?? "nil")",
                "memorySwap": "\(request.hostConfig?.memorySwap?.description ?? "nil")",
                "cpuShares": "\(request.hostConfig?.cpuShares?.description ?? "nil")",
                "nanoCpus": "\(request.hostConfig?.nanoCpus?.description ?? "nil")"
            ])

            let containerID = try await containerManager.createContainer(
                image: request.image,
                name: name,
                hostname: request.hostname,
                entrypoint: request.entrypoint,
                command: request.cmd,
                env: request.env,
                workingDir: request.workingDir,
                labels: request.labels,
                attachStdin: request.attachStdin ?? false,
                attachStdout: request.attachStdout ?? false,
                attachStderr: request.attachStderr ?? false,
                tty: request.tty ?? false,
                openStdin: request.openStdin ?? false,
                networkMode: request.hostConfig?.networkMode,
                restartPolicy: restartPolicy,
                binds: request.hostConfig?.binds,
                volumes: request.volumes?.mapValues { $0.value },  // Convert AnyCodable to Any
                portBindings: portBindings,
                initialNetworkUserIP: initialNetworkUserIP,
                initialNetworkAliases: initialNetworkAliases,
                // Memory Limits (Phase 5 - Task 5.1)
                memory: request.hostConfig?.memory,
                memoryReservation: request.hostConfig?.memoryReservation,
                memorySwap: request.hostConfig?.memorySwap,
                memorySwappiness: request.hostConfig?.memorySwappiness,
                // CPU Limits (Phase 5 - Task 5.2)
                nanoCpus: request.hostConfig?.nanoCpus,
                cpuShares: request.hostConfig?.cpuShares,
                cpuPeriod: request.hostConfig?.cpuPeriod,
                cpuQuota: request.hostConfig?.cpuQuota,
                cpusetCpus: request.hostConfig?.cpusetCpus,
                cpusetMems: request.hostConfig?.cpusetMems,
                // User/UID Support (Phase 5 - Task 5.3)
                user: request.user,
                groupAdd: request.hostConfig?.groupAdd,
                // Security Capabilities (Phase 5 - Task 5.5)
                privileged: request.hostConfig?.privileged ?? false,
                capAdd: request.hostConfig?.capAdd,
                capDrop: request.hostConfig?.capDrop,
                securityOpt: request.hostConfig?.securityOpt,
                // Health Check (Phase 6 - Task 6.2)
                healthcheck: request.healthcheck,
                // Extra Hosts (Issue #34)
                extraHosts: request.hostConfig?.extraHosts
            )

            logger.info("Container created", metadata: [
                "id": "\(containerID)"
            ])

            return .success(ContainerCreateResponse(id: containerID))
        } catch let error as ContainerManagerError {
            // Handle specific ContainerManager errors
            switch error {
            case .nameConflict(let name, let existingID):
                logger.warning("Container name conflict", metadata: [
                    "name": "\(name)",
                    "existing_id": "\(existingID)"
                ])
                return .failure(ContainerError.nameAlreadyInUse(name))
            default:
                logger.error("Failed to create container", metadata: [
                    "error": "\(error)"
                ])
                return .failure(ContainerError.creationFailed(errorDescription(error)))
            }
        } catch {
            logger.error("Failed to create container", metadata: [
                "error": "\(error)"
            ])
            return .failure(ContainerError.creationFailed(errorDescription(error)))
        }
    }

    /// Handle POST /containers/{id}/start
    /// Starts a container
    public func handleStartContainer(id: String) async -> Result<Void, ContainerError> {
        logger.info("Handling start container request", metadata: [
            "id": "\(id)"
        ])

        do {
            try await containerManager.startContainer(id: id)

            logger.info("Container started", metadata: [
                "id": "\(id)"
            ])

            return .success(())
        } catch {
            logger.error("Failed to start container", metadata: [
                "id": "\(id)",
                "error": "\(error)"
            ])

            return .failure(ContainerError.startFailed(errorDescription(error)))
        }
    }

    /// Handle POST /containers/{id}/stop
    /// Stops a container
    public func handleStopContainer(id: String, timeout: Int?) async -> Result<Void, ContainerError> {
        logger.info("Handling stop container request", metadata: [
            "id": "\(id)",
            "timeout": "\(timeout ?? 10)"
        ])

        // Protect control plane from being stopped by users
        if await isControlPlane(id: id) {
            logger.warning("Attempted to stop control plane container", metadata: ["id": "\(id)"])
            return .failure(ContainerError.operationNotPermitted(
                "Cannot stop the control plane container 'arca-control-plane'. " +
                "This container is managed by the Arca daemon and uses restart policy 'always'. " +
                "It will automatically restart if stopped."
            ))
        }

        do {
            try await containerManager.stopContainer(id: id, timeout: timeout)

            logger.info("Container stopped", metadata: [
                "id": "\(id)"
            ])

            return .success(())
        } catch let error as ContainerManagerError {
            logger.error("Failed to stop container", metadata: [
                "id": "\(id)",
                "error": "\(error)"
            ])

            // Map ContainerManagerError to appropriate ContainerError
            switch error {
            case .containerNotFound:
                return .failure(ContainerError.notFound(id))
            default:
                return .failure(ContainerError.stopFailed(error.description))
            }
        } catch {
            logger.error("Failed to stop container", metadata: [
                "id": "\(id)",
                "error": "\(error)"
            ])

            return .failure(ContainerError.stopFailed(errorDescription(error)))
        }
    }

    /// Handle POST /containers/{id}/kill (Phase 5 - Task 5.4)
    /// Sends a signal to a container
    public func handleKillContainer(id: String, signal: String = "SIGKILL") async -> Result<Void, ContainerError> {
        logger.info("Handling kill container request", metadata: [
            "id": "\(id)",
            "signal": "\(signal)"
        ])

        // Protect control plane from being killed by users
        if await isControlPlane(id: id) {
            logger.warning("Attempted to kill control plane container", metadata: ["id": "\(id)"])
            return .failure(ContainerError.operationNotPermitted(
                "Cannot kill the control plane container 'arca-control-plane'. " +
                "This container is managed by the Arca daemon and uses restart policy 'always'."
            ))
        }

        do {
            try await containerManager.killContainer(id: id, signal: signal)

            logger.info("Container killed", metadata: [
                "id": "\(id)",
                "signal": "\(signal)"
            ])

            return .success(())
        } catch let error as ContainerManagerError {
            logger.error("Failed to kill container", metadata: [
                "id": "\(id)",
                "signal": "\(signal)",
                "error": "\(error)"
            ])

            // Map ContainerManagerError to appropriate ContainerError
            switch error {
            case .containerNotFound:
                return .failure(ContainerError.notFound(id))
            case .containerNotRunning:
                return .failure(ContainerError.invalidRequest("Container is not running"))
            default:
                return .failure(ContainerError.killFailed(error.description))
            }
        } catch {
            logger.error("Failed to kill container", metadata: [
                "id": "\(id)",
                "signal": "\(signal)",
                "error": "\(error)"
            ])

            return .failure(ContainerError.killFailed(errorDescription(error)))
        }
    }

    /// Handle POST /containers/{id}/restart
    /// Restarts a container
    public func handleRestartContainer(id: String, timeout: Int?) async -> Result<Void, ContainerError> {
        logger.info("Handling restart container request", metadata: [
            "id": "\(id)",
            "timeout": "\(timeout ?? 10)"
        ])

        // Protect control plane from being restarted by users
        if await isControlPlane(id: id) {
            logger.warning("Attempted to restart control plane container", metadata: ["id": "\(id)"])
            return .failure(ContainerError.operationNotPermitted(
                "Cannot restart the control plane container 'arca-control-plane'. " +
                "This container is managed by the Arca daemon and uses restart policy 'always'."
            ))
        }

        do {
            // Stop the container first (if running) - this is idempotent
            try await containerManager.stopContainer(id: id, timeout: timeout)

            logger.debug("Container stopped for restart", metadata: ["id": "\(id)"])

            // Start the container
            try await containerManager.startContainer(id: id)

            logger.info("Container restarted", metadata: ["id": "\(id)"])

            return .success(())
        } catch let error as ContainerManagerError {
            logger.error("Failed to restart container", metadata: [
                "id": "\(id)",
                "error": "\(error)"
            ])

            // Map ContainerManagerError to appropriate ContainerError
            switch error {
            case .containerNotFound:
                return .failure(ContainerError.notFound(id))
            default:
                return .failure(ContainerError.restartFailed(error.description))
            }
        } catch {
            logger.error("Failed to restart container", metadata: [
                "id": "\(id)",
                "error": "\(error)"
            ])

            return .failure(ContainerError.restartFailed(errorDescription(error)))
        }
    }

    /// Handle POST /containers/{id}/rename
    /// Renames a container
    public func handleRenameContainer(id: String, newName: String) async -> Result<Void, ContainerError> {
        logger.info("Handling rename container request", metadata: [
            "id": "\(id)",
            "newName": "\(newName)"
        ])

        // Protect control plane from being renamed
        if await isControlPlane(id: id) {
            logger.warning("Attempted to rename control plane container", metadata: ["id": "\(id)"])
            return .failure(ContainerError.operationNotPermitted(
                "Cannot rename the control plane container 'arca-control-plane'. " +
                "This container is managed by the Arca daemon."
            ))
        }

        do {
            try await containerManager.renameContainer(id: id, newName: newName)

            logger.info("Container renamed successfully", metadata: [
                "id": "\(id)",
                "newName": "\(newName)"
            ])

            return .success(())
        } catch let error as ContainerManagerError {
            logger.error("Failed to rename container", metadata: [
                "id": "\(id)",
                "error": "\(error)"
            ])

            // Map ContainerManagerError to appropriate ContainerError
            switch error {
            case .containerNotFound:
                return .failure(ContainerError.notFound(id))
            case .invalidConfiguration(let msg) where msg.contains("already in use"):
                return .failure(ContainerError.nameAlreadyInUse(newName))
            default:
                return .failure(ContainerError.renameFailed(error.description))
            }
        } catch {
            logger.error("Failed to rename container", metadata: [
                "id": "\(id)",
                "error": "\(error)"
            ])

            return .failure(ContainerError.renameFailed(errorDescription(error)))
        }
    }

    /// Handle POST /containers/{id}/pause
    /// Pauses a running container
    public func handlePauseContainer(id: String) async -> Result<Void, ContainerError> {
        logger.info("Handling pause container request", metadata: ["id": "\(id)"])

        do {
            try await containerManager.pauseContainer(id: id)

            logger.info("Container paused successfully", metadata: ["id": "\(id)"])

            return .success(())
        } catch let error as ContainerManagerError {
            logger.error("Failed to pause container", metadata: [
                "id": "\(id)",
                "error": "\(error)"
            ])

            // Map ContainerManagerError to appropriate ContainerError
            switch error {
            case .containerNotFound:
                return .failure(ContainerError.notFound(id))
            case .invalidConfiguration(let msg):
                return .failure(ContainerError.invalidRequest(msg))
            default:
                return .failure(ContainerError.pauseFailed(error.description))
            }
        } catch {
            logger.error("Failed to pause container", metadata: [
                "id": "\(id)",
                "error": "\(error)"
            ])

            return .failure(ContainerError.pauseFailed(errorDescription(error)))
        }
    }

    /// Handle POST /containers/{id}/unpause
    /// Unpauses a paused container
    public func handleUnpauseContainer(id: String) async -> Result<Void, ContainerError> {
        logger.info("Handling unpause container request", metadata: ["id": "\(id)"])

        do {
            try await containerManager.unpauseContainer(id: id)

            logger.info("Container unpaused successfully", metadata: ["id": "\(id)"])

            return .success(())
        } catch let error as ContainerManagerError {
            logger.error("Failed to unpause container", metadata: [
                "id": "\(id)",
                "error": "\(error)"
            ])

            // Map ContainerManagerError to appropriate ContainerError
            switch error {
            case .containerNotFound:
                return .failure(ContainerError.notFound(id))
            case .invalidConfiguration(let msg):
                return .failure(ContainerError.invalidRequest(msg))
            default:
                return .failure(ContainerError.unpauseFailed(error.description))
            }
        } catch {
            logger.error("Failed to unpause container", metadata: [
                "id": "\(id)",
                "error": "\(error)"
            ])

            return .failure(ContainerError.unpauseFailed(errorDescription(error)))
        }
    }

    /// Handle GET /containers/{id}/stats
    /// Gets container resource usage statistics
    public func handleGetContainerStats(id: String) async -> Result<ContainerStatsResponse, ContainerError> {
        logger.info("Handling get container stats request", metadata: ["id": "\(id)"])

        do {
            // Get container name for response
            guard let containerInfo = try await containerManager.getContainer(id: id) else {
                return .failure(ContainerError.notFound(id))
            }

            // Get statistics from container manager
            let stats = try await containerManager.getContainerStats(id: id)

            // Transform to Docker format
            let now = ISO8601DateFormatter().string(from: Date())
            let dockerStats = try transformToDockerStats(
                stats: stats,
                containerID: containerInfo.id,
                containerName: containerInfo.name,
                timestamp: now
            )

            logger.info("Container stats retrieved successfully", metadata: ["id": "\(id)"])

            return .success(dockerStats)
        } catch let error as ContainerManagerError {
            logger.error("Failed to get container stats", metadata: [
                "id": "\(id)",
                "error": "\(error)"
            ])

            switch error {
            case .containerNotFound:
                return .failure(ContainerError.notFound(id))
            case .invalidConfiguration(let msg):
                return .failure(ContainerError.invalidRequest(msg))
            default:
                return .failure(ContainerError.statsFailed(error.description))
            }
        } catch {
            logger.error("Failed to get container stats", metadata: [
                "id": "\(id)",
                "error": "\(error)"
            ])

            return .failure(ContainerError.statsFailed(errorDescription(error)))
        }
    }

    /// Transform Apple ContainerStatistics to Docker stats format
    ///
    /// Every `ContainerStatistics` category became optional upstream: a category is nil
    /// when the guest did not report it. Docker's `/stats` payload has no representation
    /// for "unknown" in the cpu/memory/pids objects, so a missing one is surfaced as an
    /// error rather than reported as zero. The blkio and network collections already model
    /// absence (they are omitted when empty), so nil there is just the empty case.
    private func transformToDockerStats(
        stats: Containerization.ContainerStatistics,
        containerID: String,
        containerName: String,
        timestamp: String
    ) throws -> ContainerStatsResponse {
        let cpuStats = try buildCPUStats(from: stats)

        guard let memory = stats.memory else {
            throw ContainerError.statsFailed("container \(containerID) reported no memory statistics")
        }
        guard let process = stats.process else {
            throw ContainerError.statsFailed("container \(containerID) reported no process statistics")
        }

        // Build memory stats
        let memoryStatsDetails = MemoryStatsDetails(
            cache: memory.cacheBytes,
            pgfault: memory.pageFaults,
            pgmajfault: memory.majorPageFaults
        )

        let memoryStats = MemoryStats(
            usage: memory.usageBytes,
            limit: memory.limitBytes,
            stats: memoryStatsDetails
        )

        // Build PID stats
        let pidsStats = PidsStats(
            current: process.current,
            limit: process.limit
        )

        // Build block I/O stats
        var blkioEntries: [BlkioStatEntry] = []
        for device in stats.blockIO?.devices ?? [] {
            blkioEntries.append(BlkioStatEntry(
                major: device.major,
                minor: device.minor,
                op: "Read",
                value: device.readBytes
            ))
            blkioEntries.append(BlkioStatEntry(
                major: device.major,
                minor: device.minor,
                op: "Write",
                value: device.writeBytes
            ))
        }

        let blkioStats = BlkioStats(
            ioServiceBytesRecursive: blkioEntries.isEmpty ? nil : blkioEntries
        )

        // Build network stats
        var networks: [String: NetworkStats] = [:]
        for netStat in stats.networks ?? [] {
            networks[netStat.interface] = NetworkStats(
                rxBytes: netStat.receivedBytes,
                rxPackets: netStat.receivedPackets,
                rxErrors: netStat.receivedErrors,
                rxDropped: 0,  // Not available in Apple's stats
                txBytes: netStat.transmittedBytes,
                txPackets: netStat.transmittedPackets,
                txErrors: netStat.transmittedErrors,
                txDropped: 0  // Not available in Apple's stats
            )
        }

        return ContainerStatsResponse(
            id: containerID,
            name: containerName,
            read: timestamp,
            preread: timestamp,  // Same as read for non-streaming
            pidsStats: pidsStats,
            cpuStats: cpuStats,
            precpuStats: cpuStats,  // Same as cpuStats for single-shot
            memoryStats: memoryStats,
            blkioStats: blkioStats,
            networks: networks.isEmpty ? nil : networks
        )
    }

    /// Handle GET /containers/{id}/stats with streaming support
    /// Streams container stats when stream=true (default), or returns single snapshot when stream=false
    public func handleGetContainerStatsStreaming(id: String, stream: Bool) async -> HTTPResponseType {
        logger.info("Handling container stats request (streaming)", metadata: [
            "id": "\(id)",
            "stream": "\(stream)"
        ])

        // Verify container exists and is running
        guard let containerInfo = try? await containerManager.getContainer(id: id) else {
            return .standard(HTTPResponse.notFound("container", id: id))
        }

        // Container must be running to get stats
        if !containerInfo.state.running {
            return .standard(HTTPResponse.error(
                "Container is not running",
                status: .internalServerError
            ))
        }

        // For non-streaming, get a single snapshot
        if !stream {
            let result = await handleGetContainerStats(id: id)
            switch result {
            case .success(let stats):
                return .standard(HTTPResponse.ok(stats))
            case .failure(let error):
                return .standard(HTTPResponse.error(
                    error.localizedDescription,
                    status: .internalServerError
                ))
            }
        }

        // Streaming response - poll stats every 1 second
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "application/json")

        return .streaming(status: .ok, headers: headers) { writer in
            var previousStats: Containerization.ContainerStatistics?
            var previousTimestamp: String?

            do {
                // Poll stats until the stream is cancelled or container stops
                while true {
                    // Check if container is still running
                    guard let currentInfo = try? await self.containerManager.getContainer(id: id),
                          currentInfo.state.running else {
                        // Container stopped, finish the stream
                        try await writer.finish()
                        return
                    }

                    do {
                        // Get current stats
                        let currentStats = try await self.containerManager.getContainerStats(id: id)
                        let currentTimestamp = ISO8601DateFormatter().string(from: Date())

                        // Build stats response with previous values for deltas
                        var statsResponse = try self.transformToDockerStats(
                            stats: currentStats,
                            containerID: containerInfo.id,
                            containerName: containerInfo.name,
                            timestamp: currentTimestamp
                        )

                        // Update preread and precpu stats if we have previous values
                        if let prevTimestamp = previousTimestamp {
                            let precpuStats = try previousStats.map { prevStats in
                                try self.buildCPUStats(from: prevStats)
                            }
                            statsResponse = ContainerStatsResponse(
                                id: statsResponse.id,
                                name: statsResponse.name,
                                read: statsResponse.read,
                                preread: prevTimestamp,
                                pidsStats: statsResponse.pidsStats,
                                cpuStats: statsResponse.cpuStats,
                                precpuStats: precpuStats ?? statsResponse.cpuStats,
                                memoryStats: statsResponse.memoryStats,
                                blkioStats: statsResponse.blkioStats,
                                networks: statsResponse.networks
                            )
                        }

                        // Encode and write JSON
                        let encoder = JSONEncoder()
                        encoder.outputFormatting = .withoutEscapingSlashes
                        encoder.dateEncodingStrategy = .iso8601
                        let jsonData = try encoder.encode(statsResponse)

                        // Docker stats format: newline-delimited JSON
                        var dataWithNewline = jsonData
                        dataWithNewline.append(contentsOf: "\n".utf8)

                        try await writer.write(dataWithNewline)

                        // Save for next iteration
                        previousStats = currentStats
                        previousTimestamp = currentTimestamp

                        // Wait 1 second before next poll (standard Docker stats interval)
                        try await Task.sleep(nanoseconds: 1_000_000_000)

                    } catch {
                        // Log error but continue trying
                        self.logger.error("Failed to get stats during streaming", metadata: [
                            "id": "\(id)",
                            "error": "\(error)"
                        ])

                        // If we get an error, wait a bit before retrying
                        try await Task.sleep(nanoseconds: 1_000_000_000)
                    }
                }
            } catch is CancellationError {
                // Stream was cancelled (client disconnected), this is normal
                self.logger.debug("Stats streaming cancelled", metadata: ["id": "\(id)"])
                try? await writer.finish()
            } catch {
                self.logger.error("Stats streaming error", metadata: [
                    "id": "\(id)",
                    "error": "\(error)"
                ])
                try? await writer.finish()
            }
        }
    }

    /// Helper to build CPUStats from ContainerStatistics (used for both cpu and precpu stats)
    private func buildCPUStats(from stats: Containerization.ContainerStatistics) throws -> CPUStats {
        guard let cpu = stats.cpu else {
            throw ContainerError.statsFailed("container \(stats.id) reported no CPU statistics")
        }

        // Convert microseconds to nanoseconds for Docker compatibility
        let cpuUsageNano = cpu.usageUsec * 1000
        let userUsageNano = cpu.userUsec * 1000
        let systemUsageNano = cpu.systemUsec * 1000
        let throttledTimeNano = cpu.throttledTimeUsec * 1000

        let cpuUsage = CPUUsage(
            totalUsage: cpuUsageNano,
            usageInKernelmode: systemUsageNano,
            usageInUsermode: userUsageNano
        )

        let throttlingData = ThrottlingData(
            periods: cpu.throttlingPeriods,
            throttledPeriods: cpu.throttledPeriods,
            throttledTime: throttledTimeNano
        )

        return CPUStats(
            cpuUsage: cpuUsage,
            systemCpuUsage: cpuUsageNano,  // Approximate
            onlineCpus: ProcessInfo.processInfo.processorCount,
            throttlingData: throttlingData
        )
    }

    /// Handle DELETE /containers/{id}
    /// Removes a container
    public func handleRemoveContainer(id: String, force: Bool, removeVolumes: Bool) async -> Result<Void, ContainerError> {
        logger.info("Handling remove container request", metadata: [
            "id": "\(id)",
            "force": "\(force)",
            "volumes": "\(removeVolumes)"
        ])

        // Protect control plane from being removed by users
        if await isControlPlane(id: id) {
            logger.warning("Attempted to remove control plane container", metadata: ["id": "\(id)"])
            return .failure(ContainerError.operationNotPermitted(
                "Cannot remove the control plane container 'arca-control-plane'. " +
                "This container is managed by the Arca daemon and is required for networking. " +
                "Removing it would break all network functionality."
            ))
        }

        do {
            try await containerManager.removeContainer(id: id, force: force, removeVolumes: removeVolumes)

            logger.info("Container removed", metadata: [
                "id": "\(id)"
            ])

            return .success(())
        } catch let error as ContainerManagerError {
            logger.error("Failed to remove container", metadata: [
                "id": "\(id)",
                "error": "\(error)"
            ])

            // Map ContainerManagerError to appropriate ContainerError
            switch error {
            case .containerNotFound:
                return .failure(ContainerError.notFound(id))
            default:
                return .failure(ContainerError.removeFailed(error.description))
            }
        } catch {
            logger.error("Failed to remove container", metadata: [
                "id": "\(id)",
                "error": "\(error)"
            ])

            return .failure(ContainerError.removeFailed(errorDescription(error)))
        }
    }

    /// Handle GET /containers/{id}/json
    /// Inspects a container
    public func handleInspectContainer(id: String) async -> Result<ContainerInspect, ContainerError> {
        logger.info("Handling inspect container request", metadata: [
            "id": "\(id)"
        ])

        do {
            guard let container = try await containerManager.getContainer(id: id) else {
                logger.warning("Container not found", metadata: [
                    "id": "\(id)"
                ])
                return .failure(ContainerError.notFound(id))
            }

            // Convert internal Container type to Docker API ContainerInspect
            let inspect = ContainerInspect(
                id: container.id,
                created: ISO8601DateFormatter().string(from: container.created),
                path: container.path,
                args: container.args,
                state: ContainerStateInspect(
                    status: container.state.status,
                    running: container.state.running,
                    paused: container.state.paused,
                    restarting: container.state.restarting,
                    oomKilled: container.state.oomKilled,
                    dead: container.state.dead,
                    pid: container.state.pid,
                    exitCode: container.state.exitCode,
                    error: container.state.error,
                    startedAt: container.state.startedAt.map { ISO8601DateFormatter().string(from: $0) } ?? "0001-01-01T00:00:00Z",
                    finishedAt: container.state.finishedAt.map { ISO8601DateFormatter().string(from: $0) } ?? "0001-01-01T00:00:00Z",
                    health: container.state.health
                ),
                image: container.image,
                name: "/\(container.name)",
                hostConfig: HostConfigInspect(
                    binds: container.hostConfig.binds,
                    networkMode: container.hostConfig.networkMode,
                    portBindings: container.hostConfig.portBindings.mapValues { bindings in
                        bindings.map { binding in
                            PortBindingInspect(hostIp: binding.hostIp, hostPort: binding.hostPort)
                        }
                    },
                    restartPolicy: RestartPolicyInspect(
                        name: container.hostConfig.restartPolicy.name,
                        maximumRetryCount: container.hostConfig.restartPolicy.maximumRetryCount
                    ),
                    autoRemove: container.hostConfig.autoRemove,
                    privileged: container.hostConfig.privileged,
                    // Memory Limits (Phase 5 - Task 5.1)
                    memory: container.hostConfig.memory,
                    memoryReservation: container.hostConfig.memoryReservation,
                    memorySwap: container.hostConfig.memorySwap,
                    memorySwappiness: container.hostConfig.memorySwappiness,
                    // CPU Limits (Phase 5 - Task 5.2)
                    nanoCpus: container.hostConfig.nanoCpus,
                    cpuShares: container.hostConfig.cpuShares,
                    cpuPeriod: container.hostConfig.cpuPeriod,
                    cpuQuota: container.hostConfig.cpuQuota,
                    cpusetCpus: container.hostConfig.cpusetCpus,
                    cpusetMems: container.hostConfig.cpusetMems,
                    // User/UID Support (Phase 5 - Task 5.3)
                    groupAdd: container.hostConfig.groupAdd,
                    // Security Capabilities (Phase 5 - Task 5.5)
                    capAdd: container.hostConfig.capAdd,
                    capDrop: container.hostConfig.capDrop,
                    securityOpt: container.hostConfig.securityOpt,
                    // Extra Hosts (Issue #34)
                    extraHosts: container.hostConfig.extraHosts
                ),
                config: ContainerConfigInspect(
                    hostname: container.config.hostname,
                    domainname: container.config.domainname,
                    user: container.config.user,
                    attachStdin: container.config.attachStdin,
                    attachStdout: container.config.attachStdout,
                    attachStderr: container.config.attachStderr,
                    tty: container.config.tty,
                    openStdin: container.config.openStdin,
                    stdinOnce: container.config.stdinOnce,
                    env: container.config.env,
                    cmd: container.config.cmd,
                    image: container.config.image,
                    volumes: nil,
                    workingDir: container.config.workingDir,
                    entrypoint: container.config.entrypoint,
                    labels: container.config.labels,
                    healthcheck: container.config.healthcheck
                ),
                networkSettings: NetworkSettingsInspect(
                    ipAddress: container.networkSettings.ipAddress,
                    ipPrefixLen: container.networkSettings.ipPrefixLen,
                    gateway: container.networkSettings.gateway,
                    macAddress: container.networkSettings.macAddress,
                    networks: container.networkSettings.networks.mapValues { endpoint in
                        NetworkEndpointInspect(
                            networkID: endpoint.networkID,
                            endpointID: endpoint.endpointID,
                            gateway: endpoint.gateway,
                            ipAddress: endpoint.ipAddress,
                            ipPrefixLen: endpoint.ipPrefixLen,
                            macAddress: endpoint.macAddress
                        )
                    }
                )
            )

            logger.info("Container inspected", metadata: [
                "id": "\(id)"
            ])

            return .success(inspect)
        } catch {
            logger.error("Failed to inspect container", metadata: [
                "id": "\(id)",
                "error": "\(error)"
            ])

            return .failure(ContainerError.inspectFailed(errorDescription(error)))
        }
    }

    /// Handle GET /containers/{id}/logs
    /// Gets container logs
    ///
    /// Query parameters:
    /// - follow: Keep connection after returning logs (not yet supported)
    /// - stdout: Return logs from stdout
    /// - stderr: Return logs from stderr
    /// - since: Only return logs since this time (UNIX timestamp)
    /// - until: Only return logs before this time (UNIX timestamp)
    /// - timestamps: Add timestamps to every log line
    /// - tail: Only return this number of log lines from the end
    public func handleLogsContainer(idOrName: String, stdout: Bool, stderr: Bool, follow: Bool, since: Int?, until: Int?, timestamps: Bool, tail: String?) async -> Result<Data, ContainerError> {
        logger.info("Handling container logs request", metadata: [
            "id_or_name": "\(idOrName)",
            "stdout": "\(stdout)",
            "stderr": "\(stderr)",
            "follow": "\(follow)",
            "timestamps": "\(timestamps)",
            "tail": "\(tail ?? "all")"
        ])

        // Resolve container name or ID to Docker ID
        guard let dockerID = await containerManager.resolveContainer(idOrName: idOrName) else {
            logger.warning("Container not found", metadata: [
                "id_or_name": "\(idOrName)"
            ])
            return .failure(ContainerError.notFound(idOrName))
        }

        logger.debug("Resolved container", metadata: [
            "input": "\(idOrName)",
            "docker_id": "\(dockerID)"
        ])

        // Get log file paths
        guard let logPaths = containerManager.getLogPaths(dockerID: dockerID) else {
            logger.warning("No logs found for container", metadata: ["docker_id": "\(dockerID)"])
            return .failure(ContainerError.notFound("logs for \(idOrName)"))
        }

        do {
            // Retrieve and filter logs
            let logs = try retrieveLogs(
                logPaths: logPaths,
                stdout: stdout,
                stderr: stderr,
                since: since,
                until: until,
                timestamps: timestamps,
                tail: tail
            )

            logger.info("Container logs retrieved", metadata: [
                "id": "\(dockerID)",
                "entries": "\(logs.count)"
            ])

            // Convert to Docker multiplexed stream format
            let multiplexedData = formatMultiplexedStream(logs: logs)
            return .success(multiplexedData)
        } catch {
            logger.error("Failed to retrieve logs", metadata: [
                "docker_id": "\(dockerID)",
                "error": "\(error)"
            ])
            return .failure(ContainerError.inspectFailed("Failed to retrieve logs: \(error)"))
        }
    }

    /// Handle GET /containers/{id}/logs with streaming support
    /// Streams container logs when follow=true
    public func handleLogsContainerStreaming(
        idOrName: String,
        stdout: Bool,
        stderr: Bool,
        follow: Bool,
        since: Int?,
        until: Int?,
        timestamps: Bool,
        tail: String?
    ) async -> HTTPResponseType {
        logger.info("Handling container logs request (streaming)", metadata: [
            "id_or_name": "\(idOrName)",
            "follow": "\(follow)"
        ])

        // Resolve container
        guard let dockerID = await containerManager.resolveContainer(idOrName: idOrName) else {
            return .standard(HTTPResponse.error("No such container: \(idOrName)", status: .notFound))
        }

        // Get log file paths
        guard let logPaths = containerManager.getLogPaths(dockerID: dockerID) else {
            return .standard(HTTPResponse.error("No logs found for container", status: .notFound))
        }

        // If not following, use standard response
        if !follow {
            do {
                let logs = try retrieveLogs(
                    logPaths: logPaths,
                    stdout: stdout,
                    stderr: stderr,
                    since: since,
                    until: until,
                    timestamps: timestamps,
                    tail: tail
                )
                let multiplexedData = formatMultiplexedStream(logs: logs)
                return .standard(HTTPResponse(
                    status: .ok,
                    headers: HTTPHeaders([("Content-Type", "application/vnd.docker.raw-stream")]),
                    body: multiplexedData
                ))
            } catch {
                return .standard(HTTPResponse.error("Failed to retrieve logs: \(error)", status: .internalServerError))
            }
        }

        // Streaming response
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "application/vnd.docker.raw-stream")

        return .streaming(status: .ok, headers: headers) { writer in
            do {
                // Stream existing logs first
                let existingLogs = try self.retrieveLogs(
                    logPaths: logPaths,
                    stdout: stdout,
                    stderr: stderr,
                    since: since,
                    until: until,
                    timestamps: timestamps,
                    tail: tail
                )

                let existingData = self.formatMultiplexedStream(logs: existingLogs)
                if !existingData.isEmpty {
                    try await writer.write(existingData)
                }

                // If following, watch for new log entries
                if follow {
                    try await self.streamNewLogs(
                        dockerID: dockerID,
                        logPaths: logPaths,
                        stdout: stdout,
                        stderr: stderr,
                        timestamps: timestamps,
                        writer: writer
                    )
                }

                try await writer.finish()
            } catch {
                self.logger.error("Log streaming error", metadata: ["error": "\(error)"])
                try? await writer.finish()
            }
        }
    }

    /// Stream new log entries as they appear
    private func streamNewLogs(
        dockerID: String,
        logPaths: ContainerBridge.ContainerLogManager.LogPaths,
        stdout: Bool,
        stderr: Bool,
        timestamps: Bool,
        writer: HTTPStreamWriter
    ) async throws {
        // Track last read positions
        var stdoutPosition = try? getFileSize(logPaths.stdoutPath)
        var stderrPosition = try? getFileSize(logPaths.stderrPath)

        // Poll for new log data every 100ms until container exits
        // This works for attach before start: waits for container to start, then streams logs
        while await containerManager.shouldStreamLogs(dockerID: dockerID) {
            try await Task.sleep(nanoseconds: 100_000_000) // 100ms

            // Check stdout for new data
            if stdout, let currentSize = try? getFileSize(logPaths.stdoutPath),
               currentSize > (stdoutPosition ?? 0) {
                if let newData = try? readNewLogData(
                    path: logPaths.stdoutPath,
                    from: stdoutPosition ?? 0,
                    streamType: "stdout",
                    timestamps: timestamps
                ) {
                    try await writer.write(newData)
                    stdoutPosition = currentSize
                }
            }

            // Check stderr for new data
            if stderr, let currentSize = try? getFileSize(logPaths.stderrPath),
               currentSize > (stderrPosition ?? 0) {
                if let newData = try? readNewLogData(
                    path: logPaths.stderrPath,
                    from: stderrPosition ?? 0,
                    streamType: "stderr",
                    timestamps: timestamps
                ) {
                    try await writer.write(newData)
                    stderrPosition = currentSize
                }
            }
        }
    }

    /// Get file size in bytes
    private func getFileSize(_ path: URL) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: path.path)
        return attributes[.size] as? UInt64 ?? 0
    }

    /// Read new log data from position to end of file
    private func readNewLogData(path: URL, from position: UInt64, streamType: String, timestamps: Bool) throws -> Data {
        let fileHandle = try FileHandle(forReadingFrom: path)
        defer { try? fileHandle.close() }

        try fileHandle.seek(toOffset: position)
        let data = fileHandle.readDataToEndOfFile()

        guard let content = String(data: data, encoding: .utf8) else {
            return Data()
        }

        let lines = content.components(separatedBy: .newlines)
        var logEntries: [LogEntry] = []

        for line in lines {
            guard !line.isEmpty else { continue }

            // Through ContainerBridge's codec rather than a second hand-rolled
            // parse: it is the writer's own, so a base64 entry decodes to its
            // bytes and the timestamp is read with the fractional-seconds
            // options the writer emits. A default-options ISO8601DateFormatter
            // returns nil for those stamps, which would drop every line here.
            guard let lineData = line.data(using: .utf8),
                  let entry = try? ContainerBridge.ContainerLogCodec.decode(line: lineData),
                  let payload = try? ContainerBridge.ContainerLogCodec.payload(of: entry),
                  let timestamp = ContainerBridge.LogEntryTimestamp.date(from: entry.time) else {
                continue
            }
            let logStream = entry.stream
            let logMessage = String(decoding: payload, as: UTF8.self)

            if logStream == streamType {
                logEntries.append(LogEntry(
                    stream: logStream,
                    message: logMessage,
                    timestamp: timestamp,
                    includeTimestamp: timestamps
                ))
            }
        }

        return formatMultiplexedStream(logs: logEntries)
    }

    /// Retrieve and filter container logs from JSON log files
    /// Returns array of log entries with stream type, message, and timestamp
    private func retrieveLogs(
        logPaths: ContainerBridge.ContainerLogManager.LogPaths,
        stdout: Bool,
        stderr: Bool,
        since: Int?,
        until: Int?,
        timestamps: Bool,
        tail: String?
    ) throws -> [LogEntry] {
        var allLogs: [LogEntry] = []

        // Helper to parse log files
        func parseLogs(from path: URL, forStream stream: String) throws {
            guard FileManager.default.fileExists(atPath: path.path) else {
                return
            }

            let content = try String(contentsOf: path, encoding: .utf8)
            let lines = content.components(separatedBy: .newlines)

            for line in lines {
                guard !line.isEmpty else { continue }

                // Parse the JSON log entry with the writer's own codec; see the
                // note in `readNewLogData` for why a second parse here would
                // read nothing.
                guard let data = line.data(using: .utf8),
                      let entry = try? ContainerBridge.ContainerLogCodec.decode(line: data),
                      let payload = try? ContainerBridge.ContainerLogCodec.payload(of: entry),
                      let timestamp = ContainerBridge.LogEntryTimestamp.date(from: entry.time) else {
                    continue
                }

                allLogs.append(LogEntry(
                    stream: entry.stream,
                    message: String(decoding: payload, as: UTF8.self),
                    timestamp: timestamp,
                    includeTimestamp: timestamps
                ))
            }
        }

        // Read from stdout log file if requested
        if stdout {
            try parseLogs(from: logPaths.stdoutPath, forStream: "stdout")
        }

        // Read from stderr log file if requested
        if stderr {
            try parseLogs(from: logPaths.stderrPath, forStream: "stderr")
        }

        // Sort by timestamp (logs from different streams need to be interleaved chronologically)
        allLogs.sort { $0.timestamp < $1.timestamp }

        // Filter by time range
        if let since = since {
            let sinceDate = Date(timeIntervalSince1970: TimeInterval(since))
            allLogs = allLogs.filter { $0.timestamp >= sinceDate }
        }

        if let until = until {
            let untilDate = Date(timeIntervalSince1970: TimeInterval(until))
            allLogs = allLogs.filter { $0.timestamp <= untilDate }
        }

        // Apply tail limit
        if let tailStr = tail, let tailCount = Int(tailStr) {
            allLogs = Array(allLogs.suffix(tailCount))
        }

        return allLogs
    }

    /// Format log entries as Docker multiplexed stream
    /// Docker format: [stream_type (1 byte)][padding (3 bytes)][size (4 bytes big-endian)][payload]
    /// Stream types: 0=stdin, 1=stdout, 2=stderr
    private func formatMultiplexedStream(logs: [LogEntry]) -> Data {
        var result = Data()
        let formatter = ISO8601DateFormatter()

        for entry in logs {
            // Determine stream type
            let streamType: UInt8 = entry.stream == "stdout" ? 1 : 2

            // Format message (with timestamp if requested)
            var message = entry.message
            if entry.includeTimestamp {
                let timestampStr = formatter.string(from: entry.timestamp)
                message = "\(timestampStr) \(message)"
            }

            // Convert message to data
            guard let messageData = message.data(using: .utf8) else {
                continue
            }

            // Build frame header: [stream_type][padding][size]
            var header = Data()
            header.append(streamType)                    // 1 byte: stream type
            header.append(contentsOf: [0, 0, 0])        // 3 bytes: padding

            // 4 bytes: size (big-endian UInt32)
            let size = UInt32(messageData.count)
            header.append(UInt8((size >> 24) & 0xFF))
            header.append(UInt8((size >> 16) & 0xFF))
            header.append(UInt8((size >> 8) & 0xFF))
            header.append(UInt8(size & 0xFF))

            // Append header + payload
            result.append(header)
            result.append(messageData)
        }

        return result
    }

    /// Internal structure for log entry parsing
    private struct LogEntry {
        let stream: String
        let message: String
        let timestamp: Date
        let includeTimestamp: Bool
    }

    /// Handle POST /containers/{id}/wait
    /// Wait for a container to stop
    public func handleWaitContainer(idOrName: String) async -> Result<Int, ContainerError> {
        logger.info("Handling container wait request", metadata: [
            "id_or_name": "\(idOrName)"
        ])

        // Resolve container name or ID to Docker ID
        guard let dockerID = await containerManager.resolveContainer(idOrName: idOrName) else {
            logger.warning("Container not found", metadata: [
                "id_or_name": "\(idOrName)"
            ])
            return .failure(ContainerError.notFound(idOrName))
        }

        do {
            // Wait for container to finish
            let exitCode = try await containerManager.waitContainer(id: dockerID)

            logger.info("Container wait completed", metadata: [
                "id": "\(dockerID)",
                "exit_code": "\(exitCode)"
            ])

            return .success(exitCode)
        } catch {
            logger.error("Failed to wait for container", metadata: [
                "id": "\(dockerID)",
                "error": "\(error)"
            ])
            return .failure(ContainerError.inspectFailed(errorDescription(error)))
        }
    }

    /// Handle GET /containers/{id}/top
    /// List processes running inside a container
    public func handleTopContainer(id: String, psArgs: String?) async -> Result<ContainerTopResponse, ContainerError> {
        logger.info("Handling container top request", metadata: [
            "id": "\(id)",
            "ps_args": "\(psArgs ?? "-ef")"
        ])

        // Verify container exists and is running
        guard let containerInfo = try? await containerManager.getContainer(id: id) else {
            return .failure(ContainerError.notFound(id))
        }

        // Container must be running to list processes
        if !containerInfo.state.running {
            return .failure(ContainerError.invalidRequest("Container is not running"))
        }

        // Get native container for gRPC connection
        guard let nativeContainer = await containerManager.getNativeContainer(id: id) else {
            logger.error("Native container not found", metadata: ["id": "\(id)"])
            return .failure(ContainerError.notFound(id))
        }

        do {
            // Use ProcessControlClient to list processes via gRPC (reads /proc directly)
            // This avoids the race condition of spawning /bin/ps inside the container
            let processClient = ProcessControlClient(
                containerID: id,
                container: nativeContainer,
                logger: logger
            )

            let processListResponse = try await processClient.listProcesses(psArgs: psArgs)

            // Disconnect from process control service
            try await processClient.disconnect()

            // Convert to ContainerTopResponse format
            let response = ContainerTopResponse(
                Titles: processListResponse.titles,
                Processes: processListResponse.processes
            )

            logger.info("Container top completed", metadata: [
                "id": "\(id)",
                "process_count": "\(response.Processes.count)"
            ])

            return .success(response)
        } catch {
            logger.error("Failed to get container top", metadata: [
                "id": "\(id)",
                "error": "\(error)"
            ])
            return .failure(ContainerError.topFailed(errorDescription(error)))
        }
    }

    /// Handle POST /containers/{id}/resize
    /// Resize the TTY for a container
    public func handleResizeContainer(id: String, height: Int?, width: Int?) async -> Result<Void, ContainerError> {
        logger.info("Handling container resize request", metadata: [
            "id": "\(id)",
            "height": "\(height ?? 0)",
            "width": "\(width ?? 0)"
        ])

        // TODO: Implement container TTY resizing via Containerization API
        // For now, just return success to prevent 404 errors
        // The container will use default terminal size
        logger.debug("Container resize not yet implemented, ignoring", metadata: ["id": "\(id)"])
        return .success(())
    }

    /// Handle POST /containers/prune
    /// Remove all stopped containers
    public func handlePruneContainers(filters: [String: [String]]? = nil) async -> Result<ContainerPruneResponse, ContainerError> {
        logger.info("Handling prune containers request", metadata: [
            "filters": "\(filters?.description ?? "none")"
        ])

        var deletedContainers: [String] = []
        var spaceReclaimed: Int64 = 0

        // Parse filters
        var untilDate: Date? = nil
        var labelFilters: [String] = []

        if let filters = filters {
            if let untilValues = filters["until"], let untilStr = untilValues.first {
                // Parse timestamp (Unix timestamp, RFC3339, or duration like "24h")
                if let timestamp = Double(untilStr) {
                    untilDate = Date(timeIntervalSince1970: timestamp)
                } else if let date = ISO8601DateFormatter().date(from: untilStr) {
                    untilDate = date
                } else if untilStr.hasSuffix("h"), let hours = Double(untilStr.dropLast()) {
                    untilDate = Date().addingTimeInterval(-hours * 3600)
                }
            }

            if let labels = filters["label"] {
                labelFilters = labels
            }
        }

        // Get all containers (including stopped ones)
        do {
            let containers = try await containerManager.listContainers(all: true, includeInternal: false)

            // Filter for stopped containers (not running)
            for container in containers {
                // Skip running containers
                guard container.state != "running" else {
                    continue
                }

                // Skip control plane
                if await isControlPlane(id: container.id) {
                    continue
                }

                // Apply until filter
                if let until = untilDate {
                    let containerCreated = Date(timeIntervalSince1970: TimeInterval(container.created))
                    if containerCreated > until {
                        continue
                    }
                }

                // Apply label filters
                if !labelFilters.isEmpty {
                    let matchesLabels = labelFilters.allSatisfy { labelFilter in
                        if labelFilter.contains("=") {
                            // Exact match: "key=value"
                            let parts = labelFilter.split(separator: "=", maxSplits: 1)
                            let key = String(parts[0])
                            let value = parts.count > 1 ? String(parts[1]) : ""
                            return container.labels[key] == value
                        } else {
                            // Existence check: "key"
                            return container.labels[labelFilter] != nil
                        }
                    }
                    if !matchesLabels {
                        continue
                    }
                }

                // Calculate container size before removal
                let containerSize = container.sizeRootFs ?? container.sizeRw ?? 0

                // Attempt to remove the container
                do {
                    try await containerManager.removeContainer(id: container.id)
                    deletedContainers.append(container.id)
                    spaceReclaimed += containerSize

                    logger.debug("Pruned stopped container", metadata: [
                        "id": "\(container.id)",
                        "name": "\(container.names.first ?? container.id)",
                        "size": "\(containerSize)"
                    ])
                } catch {
                    logger.warning("Failed to prune container", metadata: [
                        "id": "\(container.id)",
                        "error": "\(error)"
                    ])
                    // Continue with other containers
                }
            }

            logger.info("Container prune complete", metadata: [
                "deleted": "\(deletedContainers.count)",
                "space": "\(spaceReclaimed)"
            ])

            return .success(ContainerPruneResponse(
                containersDeleted: deletedContainers,
                spaceReclaimed: spaceReclaimed
            ))
        } catch {
            logger.error("Failed to list containers for prune", metadata: ["error": "\(error)"])
            return .failure(ContainerError.invalidRequest("Failed to list containers: \(error)"))
        }
    }

    // MARK: - Archive Operations

    /// Handle POST /containers/{id}/update
    /// Updates resource configuration of a container
    ///
    /// Phase 6 - Task 6.1: Container Update Endpoint
    /// Allows updating memory, CPU, restart policy, and other resource limits at runtime
    public func handleUpdateContainer(id: String, request: ContainerUpdateRequest) async -> Result<ContainerUpdateResponse, ContainerError> {
        logger.info("Handling update container request", metadata: [
            "container_id": "\(id)",
            "memory": "\(request.memory?.description ?? "nil")",
            "memoryReservation": "\(request.memoryReservation?.description ?? "nil")",
            "memorySwap": "\(request.memorySwap?.description ?? "nil")",
            "nanoCpus": "\(request.nanoCpus?.description ?? "nil")",
            "cpuShares": "\(request.cpuShares?.description ?? "nil")"
        ])

        // Resolve container ID
        guard let containerID = await containerManager.resolveContainer(idOrName: id) else {
            return .failure(.notFound(id))
        }

        // Verify container exists
        guard (try? await containerManager.getContainer(id: containerID)) != nil else {
            return .failure(.notFound(id))
        }

        do {
            // Update container with new configuration
            let warnings = try await containerManager.updateContainer(
                id: containerID,
                memory: request.memory,
                memoryReservation: request.memoryReservation,
                memorySwap: request.memorySwap,
                memorySwappiness: request.memorySwappiness,
                nanoCpus: request.nanoCpus,
                cpuShares: request.cpuShares,
                cpuPeriod: request.cpuPeriod,
                cpuQuota: request.cpuQuota,
                cpusetCpus: request.cpusetCpus,
                cpusetMems: request.cpusetMems,
                pidsLimit: request.pidsLimit,
                blkioWeight: request.blkioWeight,
                oomKillDisable: request.oomKillDisable,
                restartPolicyName: request.restartPolicy?.name,
                restartPolicyMaxRetryCount: request.restartPolicy?.maximumRetryCount
            )

            logger.info("Container updated successfully", metadata: [
                "container_id": "\(id)",
                "warnings_count": "\(warnings.count)"
            ])

            return .success(ContainerUpdateResponse(warnings: warnings.isEmpty ? nil : warnings))
        } catch {
            logger.error("Failed to update container", metadata: [
                "container_id": "\(id)",
                "error": "\(errorDescription(error))"
            ])
            return .failure(.invalidRequest(errorDescription(error)))
        }
    }

    /// Get an archive of a filesystem resource in a container (GET /containers/{id}/archive)
    /// Uses Filesystem RPC to create tar archive via Go's archive/tar library
    /// Works universally without requiring tar in container (Phase 6.5)
    public func handleGetArchive(id: String, path: String) async -> Result<(tarData: Data, stat: PathStat), ContainerError> {
        logger.info("Getting archive from container", metadata: [
            "container_id": "\(id)",
            "path": "\(path)"
        ])

        // Resolve container ID
        guard let containerID = await containerManager.resolveContainer(idOrName: id) else {
            return .failure(.notFound(id))
        }

        // Get container to access native container
        guard let containerInfo = try? await containerManager.getContainer(id: containerID),
              let nativeContainer = await containerManager.getNativeContainer(id: containerID) else {
            return .failure(.notFound(id))
        }

        // Container must be running to use RPC
        guard containerInfo.state.running else {
            return .failure(.invalidRequest("Container must be running to extract archive"))
        }

        // Connect to Filesystem service and read archive via RPC
        do {
            let client = FilesystemClient(containerID: containerID, container: nativeContainer, logger: logger)
            defer {
                Task {
                    try? await client.disconnect()
                }
            }

            let (tarData, stat) = try await client.readArchive(path: path)

            logger.info("Archive extracted successfully", metadata: [
                "container_id": "\(id)",
                "path": "\(path)",
                "size": "\(tarData.count) bytes"
            ])

            return .success((tarData, stat))
        } catch {
            logger.error("Failed to extract archive", metadata: [
                "container_id": "\(id)",
                "path": "\(path)",
                "error": "\(error.localizedDescription)"
            ])
            return .failure(.invalidRequest("Failed to extract archive: \(error.localizedDescription)"))
        }
    }

    /// Extract an archive to a directory in a container (PUT /containers/{id}/archive)
    /// Uses Filesystem RPC to extract tar archive via Go's archive/tar library
    /// Works universally without requiring tar in container (Phase 6.5)
    public func handlePutArchive(id: String, path: String, tarData: Data) async -> Result<Void, ContainerError> {
        logger.info("Putting archive to container", metadata: [
            "container_id": "\(id)",
            "path": "\(path)",
            "size": "\(tarData.count)"
        ])

        // Resolve container
        guard let containerID = await containerManager.resolveContainer(idOrName: id) else {
            return .failure(.notFound(id))
        }

        // Get container to access native container
        guard let containerInfo = try? await containerManager.getContainer(id: containerID),
              let nativeContainer = await containerManager.getNativeContainer(id: containerID) else {
            return .failure(.notFound(id))
        }

        // Container must be running to use RPC
        guard containerInfo.state.running else {
            return .failure(.invalidRequest("Container must be running to write archive"))
        }

        // Connect to Filesystem service and write archive via RPC
        do {
            let client = FilesystemClient(containerID: containerID, container: nativeContainer, logger: logger)
            defer {
                Task {
                    try? await client.disconnect()
                }
            }

            try await client.writeArchive(path: path, tarData: tarData)

            logger.info("Archive written successfully", metadata: [
                "container_id": "\(id)",
                "path": "\(path)"
            ])

            return .success(())
        } catch {
            logger.error("Failed to write archive", metadata: [
                "container_id": "\(id)",
                "path": "\(path)",
                "error": "\(error.localizedDescription)"
            ])
            return .failure(.invalidRequest("Failed to write archive: \(error.localizedDescription)"))
        }
    }

    /// Handle GET /containers/{id}/changes
    /// Returns filesystem changes since container was created
    /// Reference: Docker Engine API v1.51 - ContainerChanges operation
    public func handleContainerChanges(id: String) async -> Result<[FilesystemChange], ContainerError> {
        logger.info("Getting container filesystem changes", metadata: [
            "container_id": "\(id)"
        ])

        do {
            let changes = try await containerManager.getContainerChanges(id: id)
            logger.info("Container filesystem changes retrieved", metadata: [
                "container_id": "\(id)",
                "changes": "\(changes.count)"
            ])
            return .success(changes)
        } catch let error as ContainerBridge.ContainerManagerError {
            switch error {
            case .containerNotFound:
                return .failure(.notFound(id))
            case .containerNotRunning:
                // Container must be running to enumerate upperdir
                logger.warning("Container not running - cannot enumerate changes", metadata: [
                    "container_id": "\(id)"
                ])
                return .failure(.invalidRequest("Container must be running to view filesystem changes. Start the container first."))
            default:
                logger.error("Failed to get container changes", metadata: [
                    "container_id": "\(id)",
                    "error": "\(error)"
                ])
                return .failure(.inspectFailed(errorDescription(error)))
            }
        } catch {
            logger.error("Failed to get container changes", metadata: [
                "container_id": "\(id)",
                "error": "\(error)"
            ])
            return .failure(.inspectFailed("Unexpected error: \(error)"))
        }
    }
}

// MARK: - Response Types

/// Response wrapper for list containers
public struct ContainerListResponse {
    public let containers: [ContainerListItem]
    public let error: Error?

    public init(containers: [ContainerListItem], error: Error? = nil) {
        self.containers = containers
        self.error = error
    }
}

/// Response for POST /containers/prune
public struct ContainerPruneResponse: Codable {
    public let containersDeleted: [String]?
    public let spaceReclaimed: Int64

    enum CodingKeys: String, CodingKey {
        case containersDeleted = "ContainersDeleted"
        case spaceReclaimed = "SpaceReclaimed"
    }

    public init(containersDeleted: [String], spaceReclaimed: Int64) {
        self.containersDeleted = containersDeleted
        self.spaceReclaimed = spaceReclaimed
    }
}

// MARK: - Error Types

public enum ContainerError: Error, CustomStringConvertible {
    case creationFailed(String)
    case startFailed(String)
    case stopFailed(String)
    case killFailed(String)  // Phase 5 - Task 5.4: Kill endpoint
    case restartFailed(String)
    case renameFailed(String)
    case pauseFailed(String)
    case unpauseFailed(String)
    case statsFailed(String)
    case topFailed(String)
    case removeFailed(String)
    case inspectFailed(String)
    case notFound(String)
    case invalidRequest(String)
    case imageNotFound(String)
    case nameAlreadyInUse(String)
    case operationNotPermitted(String)

    public var description: String {
        switch self {
        case .creationFailed(let msg):
            return "Failed to create container: \(msg)"
        case .startFailed(let msg):
            return "Failed to start container: \(msg)"
        case .stopFailed(let msg):
            return "Failed to stop container: \(msg)"
        case .killFailed(let msg):
            return "Failed to kill container: \(msg)"
        case .restartFailed(let msg):
            return "Failed to restart container: \(msg)"
        case .renameFailed(let msg):
            return "Failed to rename container: \(msg)"
        case .pauseFailed(let msg):
            return "Failed to pause container: \(msg)"
        case .unpauseFailed(let msg):
            return "Failed to unpause container: \(msg)"
        case .statsFailed(let msg):
            return "Failed to get container stats: \(msg)"
        case .topFailed(let msg):
            return "Failed to list container processes: \(msg)"
        case .removeFailed(let msg):
            return "Failed to remove container: \(msg)"
        case .inspectFailed(let msg):
            return "Failed to inspect container: \(msg)"
        case .imageNotFound(let image):
            return "No such image: \(image)"
        case .notFound(let id):
            return "No such container: \(id)"
        case .invalidRequest(let msg):
            return "Invalid request: \(msg)"
        case .nameAlreadyInUse(let name):
            return "Conflict. The container name '\(name)' is already in use."
        case .operationNotPermitted(let msg):
            return "\(msg)"
        }
    }
}
