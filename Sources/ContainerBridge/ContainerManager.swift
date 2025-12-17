import Foundation
import Logging
import Containerization
import ContainerizationOCI
import ContainerizationEXT4
import SystemPackage
import Virtualization


/// Manages containers using Apple's Containerization API
/// Provides translation layer between Docker API concepts and Containerization
/// Thread-safe via Swift actor isolation
public actor ContainerManager {
    private let imageManager: ImageManager
    private let logger: Logger
    private let kernelPath: String

    // Container state tracking
    // Actor isolation ensures thread-safe access to all mutable state
    private var containers: [String: ContainerInfo] = [:]  // Docker ID -> Info
    private var nativeContainers: [String: Containerization.LinuxContainer] = [:]  // Docker ID -> Native LinuxContainer
    private var idMapping: [String: String] = [:]  // Docker ID -> Native ID
    private var reverseMapping: [String: String] = [:]  // Native ID -> Docker ID

    // Log management
    // logManager is immutable and thread-safe, so it can be accessed from nonisolated contexts
    nonisolated public let logManager: ContainerLogManager
    private var logWriters: [String: (FileLogWriter, FileLogWriter)] = [:]  // Docker ID -> (stdout, stderr)
    private var broadcastWriters: [String: (BroadcastWriter, BroadcastWriter)] = [:]  // Docker ID -> (stdout, stderr) broadcast writers for dynamic attach

    // Filesystem clients for container filesystem operations (docker diff, archive ops)
    private var filesystemClients: [String: FilesystemClient] = [:]  // Docker ID -> FilesystemClient

    // Background monitoring tasks
    private var monitoringTasks: [String: Task<Void, Never>] = [:]  // Docker ID -> Monitoring Task

    // Pending attach connections for interactive containers (docker run -it)
    private var pendingAttaches: [String: (handles: AttachHandles, exitSignal: AsyncStream<Void>.Continuation)] = [:]

    // Deferred container configurations (for attached containers)
    private var deferredConfigs: [String: DeferredContainerConfig] = [:]  // Docker ID -> Config

    private var nativeManager: Containerization.ContainerManager?

    // Optional NetworkManager reference for auto-attachment to networks
    private var networkManager: NetworkManager?

    // Optional HealthChecker reference for health check management (Phase 6 - Task 6.2)
    private var healthChecker: HealthChecker?

    // Optional VolumeManager reference for named volume resolution
    private var volumeManager: VolumeManager?

    // Optional PortMapManager reference for port publishing
    private var portMapManager: PortMapManager?

    // Optional EventManager reference for emitting Docker events
    private var eventEmitter: EventEmitter?

    // Shared vmnet network for NAT networking with internet access
    private var sharedNetwork: SharedVmnetNetwork?

    // State persistence
    private let stateStore: StateStore

    // Layer unpacker for OverlayFS
    private var overlayUnpacker: OverlayFSUnpacker?

    /// Configuration for a volume needing direct EXT4 mount
    /// Used for local volumes that need POSIX compliance (Unix sockets, chmod, etc.)
    /// Direct mount uses the existing writable.ext4 instead of OverlayFS to avoid nested overlay issues
    private struct DirectMountConfig {
        let volumeName: String     // Volume name - Go uses this to create directory
        let targetPath: String     // Container path where EXT4 dir should be mounted
    }

    // Pending direct mounts that need to be set up after container starts
    private var pendingDirectMounts: [String: [DirectMountConfig]] = [:]  // Docker ID -> Direct Mounts

    /// Configuration for a container whose .create() was deferred
    private struct DeferredContainerConfig {
        let image: Containerization.Image
        let entrypoint: [String]?
        let command: [String]?
        let env: [String]?
        let workingDir: String?
        let hostname: String
        let mounts: [Containerization.Mount]

        // Memory Limits (Phase 5 - Task 5.1)
        let memory: Int64?
        let memoryReservation: Int64?
        let memorySwap: Int64?
        let memorySwappiness: Int?

        // CPU Limits (Phase 5 - Task 5.2)
        let nanoCpus: Int64?
        let cpuShares: Int64?
        let cpuPeriod: Int64?
        let cpuQuota: Int64?
        let cpusetCpus: String?
        let cpusetMems: String?

        // User/UID Support (Phase 5 - Task 5.3)
        let user: String?
        let groupAdd: [String]?

        // Security Capabilities (Phase 5 - Task 5.5)
        let privileged: Bool
        let capAdd: [String]?
        let capDrop: [String]?

        // Health Check (Phase 6 - Task 6.2)
        let healthcheck: HealthConfig?

        // Unix Socket Relays (k3d/kind support)
        let socketConfigs: [Containerization.UnixSocketConfiguration]

        // Extra block device for helper containers (stopped container filesystem access)
        let extraBlockDevice: String?
    }

    /// Complete configuration for creating a native Container object
    /// Used for both initial creation and recreation from persisted state
    private struct NativeContainerConfig {
        let dockerID: String
        let image: Containerization.Image
        let entrypoint: [String]?
        let command: [String]?
        let env: [String]?
        let workingDir: String?
        let hostname: String
        let tty: Bool
        let stdoutWriter: Writer
        let stderrWriter: Writer
        let stdinReader: ChannelReader?
        let mounts: [Containerization.Mount]
        let overlayConfig: Containerization.OverlayFSConfig?  // OverlayFS configuration for layered images
        let networkMode: String?  // "vmnet" or "bridge"/nil
        let labels: [String: String]  // Container labels for configuration

        // Memory Limits (Phase 5 - Task 5.1)
        let memory: Int64?              // --memory in bytes
        let memoryReservation: Int64?   // --memory-reservation (soft limit)
        let memorySwap: Int64?          // --memory-swap (-1 = unlimited)
        let memorySwappiness: Int?      // 0-100, -1 = use system default

        // CPU Limits (Phase 5 - Task 5.2)
        let nanoCpus: Int64?            // --cpus as nanocpus
        let cpuShares: Int64?           // --cpu-shares
        let cpuPeriod: Int64?           // --cpu-period
        let cpuQuota: Int64?            // --cpu-quota
        let cpusetCpus: String?         // --cpuset-cpus
        let cpusetMems: String?         // --cpuset-mems

        // User/UID Support (Phase 5 - Task 5.3)
        let user: String?               // -u, --user (username, uid, uid:gid, username:gid)
        let groupAdd: [String]?         // --group-add (additional groups)

        // Security Capabilities (Phase 5 - Task 5.5)
        let privileged: Bool            // --privileged (grant all capabilities)
        let capAdd: [String]?           // --cap-add (add Linux capabilities)
        let capDrop: [String]?          // --cap-drop (drop Linux capabilities)

        // Unix Socket Relays (k3d/kind support)
        let socketConfigs: [Containerization.UnixSocketConfiguration]

        // Extra block device for helper containers (stopped container filesystem access)
        let extraBlockDevice: String?
    }

    /// Handles for an attached container (stdin/stdout/stderr streams)
    public struct AttachHandles: Sendable {
        public let stdin: ChannelReader
        public let stdout: Writer
        public let stderr: Writer
        public let waitForExit: @Sendable () async throws -> Void

        public init(
            stdin: ChannelReader,
            stdout: Writer,
            stderr: Writer,
            waitForExit: @escaping @Sendable () async throws -> Void
        ) {
            self.stdin = stdin
            self.stdout = stdout
            self.stderr = stderr
            self.waitForExit = waitForExit
        }
    }

    public init(
        imageManager: ImageManager,
        kernelPath: String,
        stateStore: StateStore,
        logger: Logger
    ) {
        self.imageManager = imageManager
        self.kernelPath = kernelPath
        self.stateStore = stateStore
        self.logger = logger
        self.logManager = ContainerLogManager(logger: logger)
    }

    /// Set the NetworkManager (called after NetworkManager is initialized)
    public func setNetworkManager(_ manager: NetworkManager) {
        self.networkManager = manager
    }

    /// Set the HealthChecker (called after HealthChecker is initialized) - Phase 6, Task 6.2
    public func setHealthChecker(_ checker: HealthChecker) {
        self.healthChecker = checker
    }

    /// Set the VolumeManager (called after VolumeManager is initialized)
    public func setVolumeManager(_ manager: VolumeManager) {
        self.volumeManager = manager
    }

    /// Set the PortMapManager (called after PortMapManager is initialized)
    public func setPortMapManager(_ manager: PortMapManager) {
        self.portMapManager = manager
    }

    public func setEventEmitter(_ emitter: EventEmitter) {
        self.eventEmitter = emitter
    }

    /// Set the SharedVmnetNetwork (called after network is initialized)
    public func setSharedVmnetNetwork(_ network: SharedVmnetNetwork) {
        self.sharedNetwork = network
    }

    /// Initialize the Containerization manager
    public func initialize() async throws {
        logger.info("Initializing ContainerManager", metadata: [
            "kernel_path": "\(kernelPath)"
        ])

        // Verify kernel file exists
        guard FileManager.default.fileExists(atPath: kernelPath) else {
            throw ContainerManagerError.kernelNotFound(kernelPath)
        }

        // Create kernel configuration
        let kernel = Kernel(
            path: URL(fileURLWithPath: kernelPath),
            platform: detectSystemPlatform(),
            commandline: Kernel.CommandLine(debug: false, panic: 0)
        )

        logger.info("Initializing Containerization.ContainerManager", metadata: [
            "kernel_path": "\(kernelPath)",
            "platform": "\(kernel.platform.os)/\(kernel.platform.architecture)"
        ])

        // Initialize the native container manager with kernel, initfs, and vmnet network
        // Note: Custom vminit is loaded centrally in ArcaDaemon before any ContainerManagers are created
        // The custom vminit is tagged as "arca-vminit:latest"
        // VmnetNetwork provides NAT with internet access - used by containers with NATInterface
        // Using default subnet (let vmnet framework choose) to ensure gateway/NAT routing works
        nativeManager = try await Containerization.ContainerManager(
            kernel: kernel,
            initfsReference: "arca-vminit:latest",  // Custom vminit loaded and tagged by ArcaDaemon
            network: try Containerization.ContainerManager.VmnetNetwork()
        )

        // Initialize OverlayFS unpacker for parallel layer caching
        let layerCachePath = NSString(string: "~/.arca/layers").expandingTildeInPath
        overlayUnpacker = OverlayFSUnpacker(
            layerCachePath: URL(fileURLWithPath: layerCachePath),
            stateStore: stateStore,
            logger: logger
        )

        logger.info("ContainerManager initialized successfully")

        // Load persisted container state and reconcile
        try await loadPersistedState()
    }

    /// Load persisted containers from StateStore and reconcile with actual state
    private func loadPersistedState() async throws {
        logger.info("Loading persisted container state...")

        // Load all containers from database
        let persistedContainers = try await stateStore.loadAllContainers()

        logger.info("Found persisted containers", metadata: [
            "count": "\(persistedContainers.count)"
        ])

        // Reconstruct in-memory state for each container
        for containerData in persistedContainers {
            // Parse config and hostConfig JSON
            guard let configData = containerData.configJSON.data(using: .utf8),
                  let hostConfigData = containerData.hostConfigJSON.data(using: .utf8) else {
                logger.warning("Failed to parse JSON for container", metadata: [
                    "id": "\(containerData.id)"
                ])
                continue
            }

            // Decode JSON into structs
            let decoder = JSONDecoder()
            let config: ContainerConfiguration
            let hostConfig: HostConfig

            do {
                config = try decoder.decode(ContainerConfiguration.self, from: configData)
                hostConfig = try decoder.decode(HostConfig.self, from: hostConfigData)
            } catch {
                logger.error("Failed to decode container config", metadata: [
                    "id": "\(containerData.id)",
                    "error": "\(error)"
                ])
                continue
            }

            // Load network attachments
            let attachments = try await stateStore.loadNetworkAttachments(containerID: containerData.id)
            var networkAttachments: [String: NetworkAttachment] = [:]
            for attachment in attachments {
                networkAttachments[attachment.networkID] = NetworkAttachment(
                    networkID: attachment.networkID,
                    ip: attachment.ipAddress,
                    mac: attachment.macAddress,
                    aliases: attachment.aliases
                )
            }

            // Reconstruct ContainerInfo
            // After daemon restart, containers that were "running" are now exited (VMs are gone)
            let actualState: String
            let actualExitCode: Int
            let actualFinishedAt: Date?

            if containerData.status == "running" {
                // CRASH RECOVERY: Container was killed when daemon stopped
                // Exit code 137 = SIGKILL (128 + 9)
                // When daemon dies (crash, kill -9, power loss), kernel kills all child VMs
                actualState = "exited"
                actualExitCode = 137
                actualFinishedAt = Date()

                logger.warning("Crash recovery: Container was killed when daemon stopped", metadata: [
                    "id": "\(containerData.id)",
                    "name": "\(containerData.name)",
                    "oldStatus": "running",
                    "newStatus": "exited",
                    "exitCode": "137"
                ])

                // Update database: mark as exited with exit code 137
                try await stateStore.updateContainerStatus(
                    id: containerData.id,
                    status: "exited",
                    exitCode: 137,
                    finishedAt: Date()
                )
            } else {
                // Preserve other states (created, exited, etc.)
                actualState = containerData.status
                actualExitCode = containerData.exitCode
                actualFinishedAt = containerData.finishedAt
            }

            // Native ID is the same as Docker ID for container storage paths
            // We pass the full 64-char Docker ID to manager.create(), so containers
            // are stored at ~/Library/Application Support/com.apple.containerization/containers/{dockerID}/
            let nativeID = containerData.id

            let containerInfo = ContainerInfo(
                nativeID: nativeID,  // Same as Docker ID for storage path lookups
                name: containerData.name,
                image: containerData.image,
                imageID: containerData.imageID,
                created: containerData.createdAt,
                state: actualState,
                command: config.cmd,
                path: config.entrypoint?.first ?? "",
                args: Array(config.cmd.dropFirst()),
                env: config.env,
                workingDir: config.workingDir,
                labels: config.labels,
                ports: convertPortBindingsToMappings(hostConfig.portBindings),
                hostConfig: hostConfig,
                config: config,
                networkSettings: NetworkSettings(networks: [:]),
                pid: containerData.pid,
                exitCode: actualExitCode,
                startedAt: containerData.startedAt,
                finishedAt: actualFinishedAt,
                tty: config.tty,
                needsCreate: false,
                networkAttachments: networkAttachments,
                anonymousVolumes: [],  // Anonymous volumes loaded from volume_mounts table
                initialNetworkUserIP: nil,  // Only relevant during container creation, not restoration
                initialNetworkAliases: []  // Aliases from network attachments, not needed for restoration
            )

            // Store in containers map
            containers[containerData.id] = containerInfo

            // Create ID mappings (dockerID -> nativeID, nativeID -> dockerID)
            idMapping[containerData.id] = nativeID
            reverseMapping[nativeID] = containerData.id

            // Register log paths if they exist (for attach/logs commands)
            // Log files are persisted even after daemon restart
            let logDir = logManager.containerLogDir(dockerID: containerData.id)
            let stdoutPath = logDir.appendingPathComponent("stdout.log")
            let stderrPath = logDir.appendingPathComponent("stderr.log")
            let combinedPath = logDir.appendingPathComponent("combined.log")

            // Only register if log files exist
            if FileManager.default.fileExists(atPath: stdoutPath.path) &&
               FileManager.default.fileExists(atPath: stderrPath.path) {
                // Register log paths in logManager (internal method call needed)
                // We can't use createLogWriters() because it would truncate existing logs
                // Instead, we directly register the paths using the LogPaths struct
                // Note: We don't create FileLogWriter instances here because the container isn't running
                // Log writers will be created lazily when container is started
                try logManager.registerExistingLogPaths(
                    dockerID: containerData.id,
                    stdoutPath: stdoutPath,
                    stderrPath: stderrPath,
                    combinedPath: combinedPath
                )

                logger.debug("Registered existing log paths", metadata: [
                    "docker_id": "\(containerData.id)",
                    "log_dir": "\(logDir.path)"
                ])
            } else {
                logger.debug("No existing log files found for container", metadata: [
                    "docker_id": "\(containerData.id)",
                    "log_dir": "\(logDir.path)"
                ])
            }

            logger.debug("Restored container from state", metadata: [
                "docker_id": "\(containerData.id)",
                "native_id": "\(nativeID)",
                "name": "\(containerData.name)",
                "status": "\(containerData.status)"
            ])
        }

        logger.info("Container state recovery complete", metadata: [
            "restored": "\(containers.count)"
        ])

        // NOTE: Restart policies are NOT applied here
        // They must be applied AFTER NetworkManager and VolumeManager are wired up
        // See ArcaDaemon.swift for the applyRestartPolicies() call
    }

    /// Apply restart policies to containers on startup
    /// IMPORTANT: Must be called AFTER NetworkManager and VolumeManager are wired up!
    public func applyRestartPolicies() async throws {
        logger.info("Applying restart policies...")

        let containersToRestart = try await stateStore.getContainersToRestart()

        logger.info("Found containers to restart from database", metadata: [
            "count": "\(containersToRestart.count)"
        ])

        for container in containersToRestart {
            logger.info("Auto-restarting container", metadata: [
                "id": "\(container.id)",
                "name": "\(container.name)",
                "policy": "\(container.policy)",
                "exitCode": "\(container.exitCode)"
            ])

            do {
                try await startContainer(id: container.id)
                logger.info("Container auto-restarted successfully", metadata: [
                    "id": "\(container.id)"
                ])
            } catch {
                logger.error("Failed to auto-restart container", metadata: [
                    "id": "\(container.id)",
                    "error": "\(error)"
                ])
            }
        }

        logger.info("Restart policy application complete", metadata: [
            "restarted": "\(containersToRestart.count)"
        ])
    }

    // MARK: - Graceful Shutdown

    /// Gracefully shutdown ContainerManager
    /// Cancels all monitoring tasks and waits briefly for cleanup to complete
    public func shutdown() async {
        logger.info("ContainerManager graceful shutdown started")

        let taskCount = monitoringTasks.count
        logger.info("Cancelling monitoring tasks", metadata: [
            "task_count": "\(taskCount)"
        ])

        // Cancel all monitoring tasks - they will clean up asynchronously
        // We don't wait for them because they block on container.wait() indefinitely
        for (dockerID, task) in monitoringTasks {
            task.cancel()
            logger.debug("Cancelled monitoring task", metadata: [
                "container": "\(dockerID)"
            ])
        }

        // Clear the monitoring tasks dictionary
        monitoringTasks.removeAll()

        // Wait briefly (200ms) to allow any in-flight cleanup operations to complete
        // This prevents EventLoop crashes when gRPC calls (port unpublishing, etc.) are still running
        logger.debug("Waiting for cleanup operations to complete...")
        try? await Task.sleep(nanoseconds: 200_000_000)  // 200ms

        logger.info("ContainerManager graceful shutdown complete", metadata: [
            "tasks_cancelled": "\(taskCount)"
        ])
    }

    // MARK: - Platform Detection

    /// Detect the current system platform
    private func detectSystemPlatform() -> SystemPlatform {
        #if arch(arm64)
        return SystemPlatform.linuxArm
        #else
        return SystemPlatform.linuxAmd
        #endif
    }

    // MARK: - Container Lifecycle

    /// List all containers
    public func listContainers(all: Bool = false, filters: [String: [String]] = [:]) async throws -> [ContainerSummary] {
        logger.debug("Listing containers", metadata: [
            "all": "\(all)",
            "filters": "\(filters)"
        ])

        // Check if user wants to see internal containers
        // By default, internal containers (com.arca.internal=true) are hidden
        let showInternal = filters["label"]?.contains(where: { $0.contains("com.arca.internal") }) ?? false

        // Extract label filters for matching
        let labelFilters = filters["label"] ?? []

        // Pre-fetch health statuses if health filter is present
        var healthStatuses: [String: String] = [:]
        if let healthFilters = filters["health"], !healthFilters.isEmpty, let healthChecker = healthChecker {
            // Fetch health status for all containers
            for (dockerID, _) in containers {
                if let health = await healthChecker.getStatus(containerID: dockerID) {
                    healthStatuses[dockerID] = health.status
                }
            }
        }

        // List containers from our internal state tracking
        // Background monitoring tasks automatically update state when containers exit
        return containers.values.compactMap { info -> ContainerSummary? in
            // Filter by state if not showing all
            if !all && info.state != "running" {
                return nil
            }

            // Filter out internal containers unless explicitly requested
            if !showInternal && info.labels["com.arca.internal"] == "true" {
                return nil
            }

            // Apply label filters
            // Each filter can be "key" (label exists) or "key=value" (exact match)
            if !labelFilters.isEmpty {
                let matchesAllLabels = labelFilters.allSatisfy { labelFilter in
                    if labelFilter.contains("=") {
                        // Exact match: "key=value"
                        let parts = labelFilter.split(separator: "=", maxSplits: 1)
                        let key = String(parts[0])
                        let value = parts.count > 1 ? String(parts[1]) : ""
                        return info.labels[key] == value
                    } else {
                        // Existence check: "key"
                        return info.labels[labelFilter] != nil
                    }
                }

                if !matchesAllLabels {
                    return nil
                }
            }

            // Get the docker ID for this container (needed for some filters below)
            guard let dockerID = reverseMapping[info.nativeID] else {
                logger.error("BUG: Container has invalid nativeID mapping", metadata: [
                    "native_id": "\(info.nativeID)",
                    "name": "\(info.name ?? "unknown")",
                    "state": "\(info.state)",
                    "reverse_mapping_keys": "\(reverseMapping.keys.sorted())"
                ])
                return nil
            }

            // Apply name filter (supports regex patterns like Docker's API)
            // Docker name filter supports regex: ^name$ for exact match, name for partial match
            if let nameFilters = filters["name"], !nameFilters.isEmpty {
                let containerName = info.name ?? ""
                // Docker's name filter is case-insensitive and supports regex
                let matchesName = nameFilters.contains { filterName in
                    // Check if filter looks like a regex pattern (contains ^ or $)
                    if filterName.contains("^") || filterName.contains("$") {
                        // Use regex matching
                        do {
                            let regex = try NSRegularExpression(pattern: filterName, options: .caseInsensitive)
                            let range = NSRange(containerName.startIndex..., in: containerName)
                            return regex.firstMatch(in: containerName, options: [], range: range) != nil
                        } catch {
                            // If regex fails, fall back to substring match
                            return containerName.lowercased().contains(filterName.lowercased())
                        }
                    } else {
                        // Simple substring match (case insensitive like Docker)
                        return containerName.lowercased().contains(filterName.lowercased())
                    }
                }
                if !matchesName {
                    return nil
                }
            }

            // Apply id filter (exact or prefix match on container ID)
            if let idFilters = filters["id"], !idFilters.isEmpty {
                let matchesID = idFilters.contains { filterId in
                    dockerID.hasPrefix(filterId) || dockerID == filterId
                }
                if !matchesID {
                    return nil
                }
            }

            // Apply status filter (match container state)
            if let statusFilters = filters["status"], !statusFilters.isEmpty {
                let matchesStatus = statusFilters.contains { filterStatus in
                    info.state.lowercased() == filterStatus.lowercased()
                }
                if !matchesStatus {
                    return nil
                }
            }

            // Apply network filter (check if container is on specific network)
            if let networkFilters = filters["network"], !networkFilters.isEmpty {
                let matchesNetwork = networkFilters.contains { filterNetwork in
                    // Check if container is attached to this network (by ID or name)
                    info.networkAttachments.contains { networkID, _ in
                        networkID == filterNetwork || networkID.hasPrefix(filterNetwork)
                    }
                }
                if !matchesNetwork {
                    return nil
                }
            }

            // Apply volume filter (check if container has specific volume/mount)
            if let volumeFilters = filters["volume"], !volumeFilters.isEmpty {
                let matchesVolume = volumeFilters.contains { filterVolume in
                    // Check if any bind matches the volume name or mount point
                    info.hostConfig.binds.contains { bind in
                        // Binds format: "source:destination" or "source:destination:ro"
                        let parts = bind.split(separator: ":")
                        if parts.count >= 2 {
                            let source = String(parts[0])
                            let destination = String(parts[1])
                            return source.contains(filterVolume) || destination.contains(filterVolume)
                        }
                        return false
                    }
                }
                if !matchesVolume {
                    return nil
                }
            }

            // Apply ancestor filter (match imageID)
            if let ancestorFilters = filters["ancestor"], !ancestorFilters.isEmpty {
                let matchesAncestor = ancestorFilters.contains { filterAncestor in
                    // Match against image name or imageID
                    info.image == filterAncestor ||
                    info.imageID == filterAncestor ||
                    info.imageID.hasPrefix(filterAncestor)
                }
                if !matchesAncestor {
                    return nil
                }
            }

            // Apply exited filter (match exit code for exited containers)
            if let exitedFilters = filters["exited"], !exitedFilters.isEmpty {
                if info.state == "exited" {
                    let matchesExitCode = exitedFilters.contains { filterExitCode in
                        if let exitCodeInt = Int(filterExitCode) {
                            return info.exitCode == exitCodeInt
                        }
                        return false
                    }
                    if !matchesExitCode {
                        return nil
                    }
                } else {
                    // Container is not exited, so it doesn't match the exited filter
                    return nil
                }
            }

            // Apply health filter (match health status)
            if let healthFilters = filters["health"], !healthFilters.isEmpty {
                // Get current health status (pre-fetched or default to "none")
                let currentHealth = healthStatuses[dockerID] ?? "none"

                // Match against filter values (case-insensitive)
                let matches = healthFilters.contains { filter in
                    filter.lowercased() == currentHealth.lowercased()
                }

                if !matches {
                    return nil
                }
            }

            // Apply before filter (created before specified container)
            if let beforeFilters = filters["before"], !beforeFilters.isEmpty {
                if let beforeContainerID = beforeFilters.first,
                   let beforeContainer = containers.values.first(where: { reverseMapping[$0.nativeID] == beforeContainerID }) {
                    if info.created >= beforeContainer.created {
                        return nil
                    }
                }
            }

            // Apply since filter (created after specified container)
            if let sinceFilters = filters["since"], !sinceFilters.isEmpty {
                if let sinceContainerID = sinceFilters.first,
                   let sinceContainer = containers.values.first(where: { reverseMapping[$0.nativeID] == sinceContainerID }) {
                    if info.created <= sinceContainer.created {
                        return nil
                    }
                }
            }

            return ContainerSummary(
                id: dockerID,
                nativeID: info.nativeID,
                names: ["/\(info.name ?? String(dockerID.prefix(12)))"],
                image: info.image,
                imageID: info.imageID,
                command: info.command.joined(separator: " "),
                created: Int64(info.created.timeIntervalSince1970),
                state: info.state,
                status: formatStatusFromState(info),
                ports: info.ports,
                labels: info.labels
            )
        }
    }

    /// Resolve container ID or name to Docker ID
    /// Handles full IDs, short IDs (min 4 chars), and container names
    public func resolveContainer(idOrName: String) -> String? {
        return resolveContainerID(idOrName)
    }

    /// Get a specific container by ID (for inspect)
    public func getContainer(id: String) async throws -> Container? {
        logger.debug("Getting container", metadata: ["id": "\(id)"])

        // Resolve name or ID to Docker ID
        guard let dockerID = resolveContainer(idOrName: id) else {
            logger.warning("Container not found in state", metadata: ["id": "\(id)"])
            return nil
        }

        // Look up in our state
        // Background monitoring tasks automatically update state when containers exit
        guard let info = containers[dockerID] else {
            logger.warning("Container not found in state", metadata: ["docker_id": "\(dockerID)"])
            return nil
        }

        // Build NetworkSettings from current network attachments
        var networks: [String: EndpointSettings] = [:]
        if let networkManager = networkManager {
            for (networkID, attachment) in info.networkAttachments {
                // Get full network metadata (includes subnet, gateway)
                if let networkMeta = await networkManager.getNetwork(id: networkID) {
                    // Parse prefix length from subnet CIDR (e.g., "172.18.0.0/16" -> 16)
                    let prefixLen: Int
                    if let slashIndex = networkMeta.subnet.firstIndex(of: "/"),
                       let prefix = Int(networkMeta.subnet[networkMeta.subnet.index(after: slashIndex)...]) {
                        prefixLen = prefix
                    } else {
                        prefixLen = 16  // Default fallback
                    }

                    networks[networkMeta.name] = EndpointSettings(
                        ipamConfig: nil,
                        links: [],
                        aliases: attachment.aliases,
                        networkID: networkID,
                        endpointID: "",
                        gateway: networkMeta.gateway,
                        ipAddress: attachment.ip,
                        ipPrefixLen: prefixLen,
                        macAddress: attachment.mac
                    )
                }
            }
        }

        // For host network (vmnet driver) containers, add network information
        // host network containers use Apple's vmnet framework and don't have networkAttachments
        if info.hostConfig.networkMode == "host", let nativeContainer = nativeContainers[dockerID] {
            // Get all vmnet interfaces from native container
            // Try to cast each interface to ContainerManager.VmnetNetwork.Interface
            var vmnetIndex = 0
            for iface in nativeContainer.interfaces {
                if let vmnetInterface = iface as? Containerization.ContainerManager.VmnetNetwork.Interface {
                    // Parse address string "192.168.81.2/24" into IP and prefix
                    let addressComponents = vmnetInterface.address.split(separator: "/")
                    let ipString = String(addressComponents[0])  // "192.168.81.2"
                    let prefixLen = addressComponents.count > 1 ? Int(addressComponents[1]) ?? 24 : 24

                    let gatewayString = vmnetInterface.gateway

                    // Use "host" for the first interface, "host1", "host2" for additional ones
                    let networkName = vmnetIndex == 0 ? "host" : "host\(vmnetIndex)"

                    networks[networkName] = EndpointSettings(
                        ipamConfig: nil,
                        links: [],
                        aliases: [],
                        networkID: networkName,
                        endpointID: "",
                        gateway: gatewayString ?? "",
                        ipAddress: ipString,
                        ipPrefixLen: prefixLen,
                        macAddress: ""
                    )
                    vmnetIndex += 1
                }
            }
        }

        let networkSettings = NetworkSettings(
            bridge: "",
            sandboxID: "",
            hairpinMode: false,
            linkLocalIPv6Address: "",
            linkLocalIPv6PrefixLen: 0,
            ports: [:],
            sandboxKey: "",
            ipAddress: networks.values.first?.ipAddress ?? "",
            ipPrefixLen: networks.values.first?.ipPrefixLen ?? 0,
            gateway: networks.values.first?.gateway ?? "",
            macAddress: networks.values.first?.macAddress ?? "",
            networks: networks
        )

        // Get health status if health checker is available (Phase 6 - Task 6.2)
        let health: Health?
        if let healthChecker = healthChecker {
            health = await healthChecker.getStatus(containerID: dockerID)
        } else {
            health = nil
        }

        return Container(
            id: dockerID,
            nativeID: info.nativeID,
            created: info.created,
            path: info.path,
            args: info.args,
            state: ContainerState(
                status: info.state,
                running: info.state == "running",
                paused: false,
                restarting: false,
                oomKilled: false,
                dead: false,
                pid: info.pid,
                exitCode: info.exitCode,
                error: "",
                startedAt: info.startedAt,
                finishedAt: info.finishedAt,
                health: health
            ),
            image: info.image,
            name: info.name ?? "",
            restartCount: 0,
            hostConfig: info.hostConfig,
            config: info.config,
            networkSettings: networkSettings
        )
    }

    // MARK: - Container Creation Helpers

    /// Convert Docker portBindings to PortMapping array for container list API
    /// Format: {"80/tcp": [PortBinding(hostIp: "0.0.0.0", hostPort: "8080")]} -> [PortMapping(...)]
    private func convertPortBindingsToMappings(_ portBindings: [String: [PortBinding]]) -> [PortMapping] {
        var mappings: [PortMapping] = []

        for (portProto, bindings) in portBindings {
            // Parse port/protocol (e.g., "80/tcp" -> port=80, protocol="tcp")
            let components = portProto.split(separator: "/")
            guard components.count == 2,
                  let containerPort = Int(components[0]) else {
                continue
            }
            let proto = String(components[1])

            for binding in bindings {
                let publicPort = Int(binding.hostPort)
                let hostIP = binding.hostIp.isEmpty ? nil : binding.hostIp

                mappings.append(PortMapping(
                    privatePort: containerPort,
                    publicPort: publicPort,
                    type: proto,
                    ip: hostIP
                ))
            }
        }

        return mappings
    }

    /// Build LinuxCapabilities from Docker capability parameters
    /// Docker semantics:
    /// - privileged=true: Grant ALL capabilities (CAP_CHOWN, CAP_NET_ADMIN, etc.)
    /// - Otherwise: Start with Docker's default caps, then apply cap-add/cap-drop
    private func buildLinuxCapabilities(
        privileged: Bool,
        capAdd: [String]?,
        capDrop: [String]?
    ) -> ContainerizationOCI.LinuxCapabilities {
        // Full list of all Linux capabilities (as of Linux 5.x)
        let allCapabilities = [
            "CAP_CHOWN", "CAP_DAC_OVERRIDE", "CAP_DAC_READ_SEARCH", "CAP_FOWNER",
            "CAP_FSETID", "CAP_KILL", "CAP_SETGID", "CAP_SETUID", "CAP_SETPCAP",
            "CAP_LINUX_IMMUTABLE", "CAP_NET_BIND_SERVICE", "CAP_NET_BROADCAST",
            "CAP_NET_ADMIN", "CAP_NET_RAW", "CAP_IPC_LOCK", "CAP_IPC_OWNER",
            "CAP_SYS_MODULE", "CAP_SYS_RAWIO", "CAP_SYS_CHROOT", "CAP_SYS_PTRACE",
            "CAP_SYS_PACCT", "CAP_SYS_ADMIN", "CAP_SYS_BOOT", "CAP_SYS_NICE",
            "CAP_SYS_RESOURCE", "CAP_SYS_TIME", "CAP_SYS_TTY_CONFIG", "CAP_MKNOD",
            "CAP_LEASE", "CAP_AUDIT_WRITE", "CAP_AUDIT_CONTROL", "CAP_SETFCAP",
            "CAP_MAC_OVERRIDE", "CAP_MAC_ADMIN", "CAP_SYSLOG", "CAP_WAKE_ALARM",
            "CAP_BLOCK_SUSPEND", "CAP_AUDIT_READ", "CAP_PERFMON", "CAP_BPF",
            "CAP_CHECKPOINT_RESTORE"
        ]

        // Docker's default capabilities (matches Docker 20.10+)
        // These are the capabilities granted to non-privileged containers
        let dockerDefaultCapabilities = [
            "CAP_CHOWN", "CAP_DAC_OVERRIDE", "CAP_FSETID", "CAP_FOWNER",
            "CAP_MKNOD", "CAP_NET_RAW", "CAP_SETGID", "CAP_SETUID",
            "CAP_SETFCAP", "CAP_SETPCAP", "CAP_NET_BIND_SERVICE",
            "CAP_SYS_CHROOT", "CAP_KILL", "CAP_AUDIT_WRITE"
        ]

        var caps: [String]

        if privileged {
            // Privileged mode: Grant ALL capabilities
            caps = allCapabilities
            logger.debug("Privileged mode enabled - granting all capabilities", metadata: [
                "capability_count": "\(allCapabilities.count)"
            ])
        } else {
            // Normal mode: Start with Docker default capabilities
            caps = dockerDefaultCapabilities
        }

        // Apply cap-add (add capabilities)
        if let add = capAdd, !add.isEmpty {
            for cap in add {
                let normalizedCap = cap.hasPrefix("CAP_") ? cap : "CAP_\(cap.uppercased())"
                if !caps.contains(normalizedCap) {
                    caps.append(normalizedCap)
                }
            }
            logger.debug("Added capabilities", metadata: [
                "added": "\(add.joined(separator: ", "))"
            ])
        }

        // Apply cap-drop (remove capabilities)
        if let drop = capDrop, !drop.isEmpty {
            for cap in drop {
                let normalizedCap = cap.hasPrefix("CAP_") ? cap : "CAP_\(cap.uppercased())"
                caps.removeAll { $0 == normalizedCap }
            }
            logger.debug("Dropped capabilities", metadata: [
                "dropped": "\(drop.joined(separator: ", "))"
            ])
        }

        // LinuxCapabilities has 5 sets: bounding, effective, inheritable, permitted, ambient
        // Docker's behavior: Set the same capabilities in all sets for simplicity
        return ContainerizationOCI.LinuxCapabilities(
            bounding: caps,
            effective: caps,
            inheritable: caps,
            permitted: caps,
            ambient: caps
        )
    }

    /// Create a native LinuxContainer from configuration
    /// This is the core container creation logic, used by:
    /// 1. createContainer() - initial container creation from API request
    /// 2. startContainer() - recreating containers from persisted state
    /// 3. Deferred containers - creating attached containers on first start
    private func createNativeContainer(
        config: NativeContainerConfig
    ) async throws -> Containerization.LinuxContainer {
        guard var manager = nativeManager else {
            logger.error("ContainerManager not initialized")
            throw ContainerManagerError.notInitialized
        }

        // Capture values for @Sendable closure
        let dockerID = config.dockerID
        let configLogger = self.logger
        let tty = config.tty
        let stdoutWriter = config.stdoutWriter
        let stderrWriter = config.stderrWriter
        let stdinReader = config.stdinReader
        let skipEmbeddedDNS = config.labels["com.arca.skip-embedded-dns"] == "true"

        // Normalize networkMode BEFORE network lookup and capture for closure

        // Normalize networkMode: empty, "default", or "bridge" all mean the default bridge network
        // This must happen BEFORE network lookup to ensure correct network namespace configuration
        var normalizedNetworkMode: String? = config.networkMode
        if let mode = config.networkMode, (mode.isEmpty || mode == "default") {
            normalizedNetworkMode = "bridge"
            logger.debug("Normalized networkMode", metadata: [
                "docker_id": "\(dockerID)",
                "original": "\(mode)",
                "normalized": "bridge"
            ])
        }

        // Determine if network namespace is needed by checking network driver
        var tempNeedsNetworkNamespace = false
        if let networkMode = normalizedNetworkMode, networkMode != "host" && networkMode != "none" {
            // Look up network to check its driver
            if let network = await networkManager?.getNetworkByName(name: networkMode) {
                tempNeedsNetworkNamespace = (network.driver == "wireguard" || network.driver == "bridge")
                logger.debug("Network driver check", metadata: [
                    "docker_id": "\(dockerID)",
                    "network": "\(networkMode)",
                    "driver": "\(network.driver)",
                    "needsNetworkNamespace": "\(tempNeedsNetworkNamespace)"
                ])
            } else {
                logger.warning("Network not found during namespace check", metadata: [
                    "docker_id": "\(dockerID)",
                    "network": "\(networkMode)"
                ])
            }
        }
        // Capture as immutable for @Sendable closure
        let needsNetworkNamespace = tempNeedsNetworkNamespace
        let effectiveNetworkMode = normalizedNetworkMode

        logger.info("Creating LinuxContainer with Containerization API", metadata: [
            "docker_id": "\(dockerID)",
            "hostname": "\(config.hostname)"
        ])

        // Get image config to properly handle entrypoint/cmd/workingDir overrides
        let systemPlatform = detectSystemPlatform()
        let imagePlatform = systemPlatform.ociPlatform()

        logger.debug("⏱️ Fetching image config", metadata: ["docker_id": "\(dockerID)"])
        let imageConfigStart = Date()
        let imageConfig = try await config.image.config(for: imagePlatform)
        let imageConfigDuration = Date().timeIntervalSince(imageConfigStart)
        logger.debug("⏱️ Image config fetched", metadata: [
            "docker_id": "\(dockerID)",
            "duration_seconds": "\(String(format: "%.2f", imageConfigDuration))"
        ])

        let imageEntrypoint = imageConfig.config?.entrypoint ?? []
        let imageCmd = imageConfig.config?.cmd ?? []
        let imageWorkingDir = imageConfig.config?.workingDir ?? "/"

        // Build capabilities before closure for @Sendable capture
        let capabilities = buildLinuxCapabilities(
            privileged: config.privileged,
            capAdd: config.capAdd,
            capDrop: config.capDrop
        )

        // Create container directory path (needed for both unpacking and temp rootfs)
        // Use default Apple containerization store path
        let appleStorePath = NSString(string: "~/Library/Application Support/com.apple.containerization").expandingTildeInPath
        let containerRoot = URL(fileURLWithPath: appleStorePath).appendingPathComponent("containers")
        let containerPath = containerRoot.appendingPathComponent(dockerID)

        // Ensure container directory exists (base manager expects this)
        try FileManager.default.createDirectory(at: containerPath, withIntermediateDirectories: true)

        // Unpack image layers with OverlayFS (if not already provided)
        let effectiveOverlayConfig: Containerization.OverlayFSConfig
        if let providedConfig = config.overlayConfig {
            // Config already provided (e.g., from recreateContainerFromState)
            effectiveOverlayConfig = providedConfig
            logger.debug("Using provided OverlayFS config", metadata: [
                "docker_id": "\(dockerID)",
                "layers": "\(providedConfig.lowerLayers.count)"
            ])
        } else {
            // Unpack image using OverlayFS layer cache
            logger.debug("⏱️ Unpacking image with OverlayFS", metadata: ["docker_id": "\(dockerID)"])
            let unpackStart = Date()

            guard let unpacker = overlayUnpacker else {
                throw ContainerManagerError.notInitialized
            }

            effectiveOverlayConfig = try await unpacker.unpack(
                config.image,
                for: imagePlatform,
                at: containerPath
            )

            let unpackDuration = Date().timeIntervalSince(unpackStart)
            logger.info("⏱️ Image unpacked with OverlayFS", metadata: [
                "docker_id": "\(dockerID)",
                "layers": "\(effectiveOverlayConfig.lowerLayers.count)",
                "duration_seconds": "\(String(format: "%.2f", unpackDuration))"
            ])
        }

        // Create writable filesystem for OverlayFS upper/work directories
        // This is a sparse EXT4 filesystem that will be mounted as /dev/vdc in the guest
        let writablePath = containerPath.appendingPathComponent("writable.ext4")
        let mounter = OverlayFSMounter(logger: logger)

        if !FileManager.default.fileExists(atPath: writablePath.path) {
            // 64 GB provides sufficient space for build caches and large workloads
            // Thin-provisioned (sparse file) so only actual data consumes disk space
            try mounter.createWritableFilesystem(at: writablePath.path, sizeMB: 65536)
            logger.info("Created writable filesystem", metadata: [
                "docker_id": "\(dockerID)",
                "path": "\(writablePath.path)"
            ])
        } else {
            logger.debug("Writable filesystem already exists", metadata: [
                "docker_id": "\(dockerID)",
                "path": "\(writablePath.path)"
            ])
        }

        // Build VZ mounts from OverlayFS configuration
        // This creates:
        // - Bind mount from `/` to container rootfs path (FIRST mount - critical!)
        // - Writable block device for upper/work directories (/dev/vdc)
        // - Block device mounts for each layer (read-only EXT4, /dev/vdd onwards)
        let overlayMounts = mounter.buildMounts(
            containerID: dockerID,
            overlayConfig: effectiveOverlayConfig,
            writablePath: writablePath.path,
            additionalMounts: []  // Will be added in configuration closure
        )
        logger.debug("Built OverlayFS mounts", metadata: [
            "docker_id": "\(dockerID)",
            "overlay_mounts": "\(overlayMounts.count)"
        ])

        // Log layer paths for debugging
        logger.info("OverlayFS layer paths:", metadata: [
            "docker_id": "\(dockerID)",
            "layer_count": "\(effectiveOverlayConfig.lowerLayers.count)",
            "first_layer": "\(effectiveOverlayConfig.lowerLayers.first?.path ?? "none")",
            "upper": "\(effectiveOverlayConfig.upperDir.path)",
            "work": "\(effectiveOverlayConfig.workDir.path)"
        ])

        // Verify first layer file exists
        if let firstLayer = effectiveOverlayConfig.lowerLayers.first {
            let exists = FileManager.default.fileExists(atPath: firstLayer.path)
            logger.info("First layer file check:", metadata: [
                "docker_id": "\(dockerID)",
                "path": "\(firstLayer.path)",
                "exists": "\(exists)"
            ])
        }

        // Extract rootfs mount (the bind mount) and remaining mounts from overlayMounts
        // The FIRST mount in overlayMounts is the bind mount from `/` to container rootfs path
        // This MUST be passed as the `rootfs` parameter to manager.create()
        guard let rootfsMount = overlayMounts.first else {
            throw ContainerManagerError.invalidConfiguration("No rootfs mount in overlayMounts")
        }
        let additionalMounts = Array(overlayMounts.dropFirst())

        logger.debug("⏱️ Calling manager.create() with bind mount rootfs", metadata: [
            "docker_id": "\(dockerID)",
            "rootfs_type": "\(rootfsMount.type)",
            "rootfs_source": "\(rootfsMount.source)",
            "rootfs_destination": "\(rootfsMount.destination)",
            "additional_mounts": "\(additionalMounts.count)"
        ])
        let managerCreateStart = Date()
        let container = try await manager.create(
            dockerID,
            image: config.image,
            rootfs: rootfsMount
        ) { @Sendable containerConfig in
            let closureStartTime = Date()
            configLogger.debug("⏱️ Configuration closure started", metadata: [
                "docker_id": "\(dockerID)"
            ])

            // Configure the container process (OCI-compliant)
            // Implement proper Docker entrypoint/cmd semantics:
            // - effectiveEntrypoint = request.entrypoint ?? image.entrypoint
            // - effectiveCmd = request.cmd ?? image.cmd
            // - process.arguments = effectiveEntrypoint + effectiveCmd

            let effectiveEntrypoint = config.entrypoint ?? imageEntrypoint
            let effectiveCmd = config.command ?? imageCmd
            containerConfig.process.arguments = effectiveEntrypoint + effectiveCmd

            configLogger.debug("Container command", metadata: [
                "docker_id": "\(dockerID)",
                "entrypoint": "\(effectiveEntrypoint.joined(separator: " "))",
                "cmd": "\(effectiveCmd.joined(separator: " "))",
                "full_command": "\(containerConfig.process.arguments.joined(separator: " "))"
            ])

            if let env = config.env {
                // Merge with existing env from image, Docker CLI behavior
                containerConfig.process.environmentVariables += env
            }

            // Add ARCA_CONTAINER_ID for embedded-dns to query helper VM for networks
            // Skip for:
            // 1. Containers with com.arca.skip-embedded-dns label (like BuildKit)
            // 2. Host network containers (vmnet-only, no WireGuard)
            // 3. None network containers (no networking at all)
            let shouldSkipEmbeddedDNS = skipEmbeddedDNS ||
                                        effectiveNetworkMode == "host" ||
                                        effectiveNetworkMode == "none"

            if !shouldSkipEmbeddedDNS {
                containerConfig.process.environmentVariables.append("ARCA_CONTAINER_ID=\(dockerID)")
                configLogger.debug("Embedded-DNS enabled for container", metadata: [
                    "docker_id": "\(dockerID)",
                    "networkMode": "\(effectiveNetworkMode ?? "bridge")"
                ])
            } else {
                configLogger.debug("Embedded-DNS skipped for container", metadata: [
                    "docker_id": "\(dockerID)",
                    "networkMode": "\(effectiveNetworkMode ?? "none")",
                    "reason": skipEmbeddedDNS ? "label" : "network_mode"
                ])
            }

            // Set working directory (user override or image default)
            // Docker behavior: request.workingDir ?? image.workingDir ?? "/"
            // Note: Docker Compose sends empty string "" when WorkingDir not specified, not nil
            let effectiveWorkingDir: String
            if let userWorkingDir = config.workingDir, !userWorkingDir.isEmpty {
                effectiveWorkingDir = userWorkingDir
            } else {
                effectiveWorkingDir = imageWorkingDir
            }
            containerConfig.process.workingDirectory = effectiveWorkingDir
            configLogger.debug("Container working directory", metadata: [
                "docker_id": "\(dockerID)",
                "workingDir": "\(effectiveWorkingDir)",
                "source": (config.workingDir != nil && !config.workingDir!.isEmpty) ? "user" : "image"
            ])

            // Set hostname (OCI spec field)
            containerConfig.hostname = config.hostname

            // Enable network namespace for WireGuard/bridge containers only
            // Host and none network containers stay in root namespace
            // - host network: vmnet-only interface, NO network namespace, NO WireGuard
            // - bridge network: WireGuard interface in network namespace
            // - none network: no interfaces at all
            containerConfig.useNetworkNamespace = needsNetworkNamespace

            // Set network namespace path for WireGuard networking
            // The namespace is created by arca-services during AddNetwork RPC
            // Path is deterministic: /run/netns/arca-{shortID}
            // vmexec will join this namespace instead of creating a new one
            if needsNetworkNamespace {
                let shortID = String(dockerID.prefix(12))
                containerConfig.networkNamespacePath = "/run/netns/arca-\(shortID)"
            }

            configLogger.debug("Network namespace configuration", metadata: [
                "docker_id": "\(dockerID)",
                "networkMode": "\(effectiveNetworkMode ?? "none")",
                "useNetworkNamespace": "\(needsNetworkNamespace)",
                "namespacePath": "\(containerConfig.networkNamespacePath ?? "none")"
            ])

            // Network interface configuration:
            // Apple's Containerization framework creates a vmnet eth0 interface for ALL containers
            // (via shared vmnet network set during initialize()). This happens automatically.
            //
            // What happens next depends on the network mode:
            // - host network (networkMode="host", useNetworkNamespace=false):
            //   * eth0 is the ONLY interface - provides direct NAT internet access
            //   * No WireGuard setup, no embedded-DNS, stays in root namespace
            //   * Simple vmnet-only networking
            //
            // - bridge network (networkMode="bridge", useNetworkNamespace=true):
            //   * eth0 stays in VM root namespace as underlay for WireGuard traffic
            //   * WireGuard interface (wg0) created in container's network namespace
            //   * Embedded-DNS provides name resolution
            //   * veth pairs connect container namespace to root namespace
            //
            // - none network (networkMode="none", useNetworkNamespace=false):
            //   * eth0 exists but is not used
            //   * No networking configured for container
            //
            // We do NOT override containerConfig.interfaces, allowing Apple's framework
            // to manage the vmnet eth0 interface automatically.
            configLogger.info("Container network configuration", metadata: [
                "container_id": "\(dockerID)",
                "networkMode": "\(effectiveNetworkMode ?? "none")",
                "embeddedDNS": "\(!shouldSkipEmbeddedDNS)",
                "networkNamespace": "\(needsNetworkNamespace)"
            ])

            // Configure TTY mode
            containerConfig.process.terminal = tty

            // Configure stdout (always needed)
            containerConfig.process.stdout = stdoutWriter

            // Configure stderr (only when NOT using TTY - TTY merges stderr into stdout)
            if !tty {
                containerConfig.process.stderr = stderrWriter
            }

            // Configure stdin if provided (for attached containers)
            if let stdin = stdinReader {
                containerConfig.process.stdin = stdin
            }

            // Configure OverlayFS mounts (block devices + VirtioFS shares)
            // These mounts provide the layer stack that will be mounted as overlay in guest
            // Add additional block device mounts (writable + layers)
            // The rootfs bind mount was already passed as the `rootfs` parameter
            containerConfig.mounts.append(contentsOf: additionalMounts)
            configLogger.info("Configured OverlayFS block device mounts", metadata: [
                "docker_id": "\(dockerID)",
                "block_device_count": "\(additionalMounts.count)"
            ])

            // Configure volume mounts (VirtioFS directory shares)
            // Append to existing mounts (don't replace default system mounts like /proc, /sys, etc.)
            if !config.mounts.isEmpty {
                containerConfig.mounts.append(contentsOf: config.mounts)
                configLogger.info("Configured volume mounts", metadata: [
                    "docker_id": "\(dockerID)",
                    "mount_count": "\(config.mounts.count)",
                    "total_mounts": "\(containerConfig.mounts.count)"
                ])
            }

            // Configure extra block device mount (for helper containers)
            // Share the writable.ext4 file via VirtioFS so the helper can loop-mount it
            // We share the parent directory to allow access to the ext4 file
            if let extraBlockDevice = config.extraBlockDevice {
                // Share the directory containing writable.ext4 via VirtioFS
                let extURL = URL(fileURLWithPath: extraBlockDevice)
                let parentDir = extURL.deletingLastPathComponent().path
                let fileName = extURL.lastPathComponent

                let shareMount = Containerization.Mount.share(
                    source: parentDir,
                    destination: "/mnt/target-host",
                    options: [],  // Read-write
                    runtimeOptions: []
                )
                containerConfig.mounts.append(shareMount)
                configLogger.info("Configured VirtioFS share for helper container block device", metadata: [
                    "docker_id": "\(dockerID)",
                    "source_dir": "\(parentDir)",
                    "file_name": "\(fileName)",
                    "destination": "/mnt/target-host"
                ])
            }

            // Configure Unix socket relays (k3d/kind support)
            // Uses Apple's UnixSocketConfiguration for vsock-based relay between host and guest
            if !config.socketConfigs.isEmpty {
                containerConfig.sockets.append(contentsOf: config.socketConfigs)
                configLogger.info("Configured Unix socket relays for k3d/kind support", metadata: [
                    "docker_id": "\(dockerID)",
                    "socket_relay_count": "\(config.socketConfigs.count)"
                ])
            }

            // Configure memory limits (Phase 5 - Task 5.1)
            // Wire Docker API memory parameters to Apple's Containerization framework
            // The framework uses cgroup v2 for enforcement via Cgroup2Manager
            // Apple requires minimum 512MB, use 4GB default if not specified
            // Memory ballooning means the VM only consumes physical memory as needed up to this limit
            let defaultMemory: Int64 = 4 * 1024 * 1024 * 1024  // 4GB
            let effectiveMemory: Int64
            if let memory = config.memory, memory > 0 {
                effectiveMemory = memory
            } else {
                effectiveMemory = defaultMemory
            }
            containerConfig.memoryInBytes = UInt64(effectiveMemory)

            if let memory = config.memory, memory > 0 {
                configLogger.info("Configured memory limit", metadata: [
                    "docker_id": "\(dockerID)",
                    "memory_bytes": "\(memory)",
                    "memory_mb": "\(memory / 1024 / 1024)"
                ])
            } else {
                configLogger.debug("Using default memory limit", metadata: [
                    "docker_id": "\(dockerID)",
                    "memory_mb": "4096"
                ])
            }

            // Configure memory reservation (soft limit) via OCI LinuxMemory
            if let reservation = config.memoryReservation {
                configLogger.info("Configured memory reservation", metadata: [
                    "docker_id": "\(dockerID)",
                    "reservation_bytes": "\(reservation)",
                    "reservation_mb": "\(reservation / 1024 / 1024)"
                ])
            }

            // Configure memory swap limit
            if let swap = config.memorySwap {
                configLogger.info("Configured memory swap", metadata: [
                    "docker_id": "\(dockerID)",
                    "swap": swap == -1 ? "unlimited" : "\(swap) bytes"
                ])
            }

            // Configure memory swappiness
            if let swappiness = config.memorySwappiness {
                configLogger.info("Configured memory swappiness", metadata: [
                    "docker_id": "\(dockerID)",
                    "swappiness": "\(swappiness)"
                ])
            }

            // Configure CPU limits (Phase 5 - Task 5.2)
            // Wire Docker API CPU parameters to Apple's Containerization framework
            if let nanoCpus = config.nanoCpus {
                // Convert nanocpus to number of CPUs
                // nanoCpus is in units of 1e-9 CPUs, so 1 CPU = 1_000_000_000 nanocpus
                let cpus = Int(nanoCpus / 1_000_000_000)
                if cpus > 0 {
                    containerConfig.cpus = cpus
                    configLogger.info("Configured CPU limit", metadata: [
                        "docker_id": "\(dockerID)",
                        "nano_cpus": "\(nanoCpus)",
                        "cpus": "\(cpus)"
                    ])
                }
            }

            // Log other CPU parameters (not directly supported by containerConfig.cpus)
            // These would require cgroup configuration via OCI runtime spec
            if let cpuShares = config.cpuShares {
                configLogger.info("CPU shares specified (requires cgroup support)", metadata: [
                    "docker_id": "\(dockerID)",
                    "cpu_shares": "\(cpuShares)"
                ])
            }

            if let cpuPeriod = config.cpuPeriod {
                configLogger.info("CPU period specified (requires cgroup support)", metadata: [
                    "docker_id": "\(dockerID)",
                    "cpu_period": "\(cpuPeriod)"
                ])
            }

            if let cpuQuota = config.cpuQuota {
                configLogger.info("CPU quota specified (requires cgroup support)", metadata: [
                    "docker_id": "\(dockerID)",
                    "cpu_quota": "\(cpuQuota)"
                ])
            }

            if let cpusetCpus = config.cpusetCpus {
                configLogger.info("CPUset CPUs specified (requires cgroup support)", metadata: [
                    "docker_id": "\(dockerID)",
                    "cpuset_cpus": "\(cpusetCpus)"
                ])
            }

            if let cpusetMems = config.cpusetMems {
                configLogger.info("CPUset MEMs specified (requires cgroup support)", metadata: [
                    "docker_id": "\(dockerID)",
                    "cpuset_mems": "\(cpusetMems)"
                ])
            }

            // Configure User/UID (Phase 5 - Task 5.3)
            // Pass user string to vminitd which will resolve username → UID/GID
            // using /etc/passwd and /etc/group from the container's filesystem
            if let user = config.user {
                // Set process.user.username to the Docker user string
                // vminitd will parse formats: "username", "uid", "uid:gid", "username:gid"
                // and resolve to actual UID/GID using ContainerizationOS.User.getExecUser()
                containerConfig.process.user.username = user
                configLogger.info("Configured user", metadata: [
                    "docker_id": "\(dockerID)",
                    "user": "\(user)"
                ])
            }

            // Configure additional groups (--group-add)
            // Pass group names/GIDs to vminitd via environment variable for resolution
            if let groupAdd = config.groupAdd, !groupAdd.isEmpty {
                // Pass groups to vminitd for resolution via environment variable
                // vminitd will resolve group names using /etc/group and add GIDs to additionalGids
                containerConfig.process.environmentVariables.append("ARCA_GROUP_ADD=\(groupAdd.joined(separator: ","))")
                configLogger.info("Configured additional groups", metadata: [
                    "docker_id": "\(dockerID)",
                    "groups": "\(groupAdd.joined(separator: ","))"
                ])
            }

            // Configure Security Capabilities (Phase 5 - Task 5.5)
            // Wire Docker capability parameters to OCI LinuxCapabilities
            containerConfig.process.capabilities = capabilities
            configLogger.info("Configured security capabilities", metadata: [
                "docker_id": "\(dockerID)",
                "privileged": "\(config.privileged)",
                "cap_count": "\(capabilities.bounding.count)"
            ])

            let closureDuration = Date().timeIntervalSince(closureStartTime)
            configLogger.debug("⏱️ Configuration closure completed", metadata: [
                "docker_id": "\(dockerID)",
                "duration_seconds": "\(String(format: "%.2f", closureDuration))"
            ])
        }

        let managerCreateDuration = Date().timeIntervalSince(managerCreateStart)
        logger.debug("⏱️ manager.create() completed", metadata: [
            "docker_id": "\(dockerID)",
            "duration_seconds": "\(String(format: "%.2f", managerCreateDuration))"
        ])

        // Call .create() to set up the VM
        logger.info("Setting up container VM and runtime environment", metadata: [
            "docker_id": "\(dockerID)"
        ])
        let containerCreateStart = Date()
        try await container.create()
        let containerCreateDuration = Date().timeIntervalSince(containerCreateStart)
        logger.info("Container VM created successfully", metadata: [
            "docker_id": "\(dockerID)",
            "duration_seconds": "\(String(format: "%.2f", containerCreateDuration))"
        ])

        // OverlayFS is automatically mounted by vminitd during boot if layer block devices are detected
        // No host-side intervention needed - vminitd handles its own filesystem setup

        return container
    }

    /// Create a new container
    public func createContainer(
        image: String,
        name: String?,
        hostname: String? = nil,  // Container hostname (--hostname flag)
        entrypoint: [String]?,
        command: [String]?,
        env: [String]?,
        workingDir: String?,
        labels: [String: String]?,
        attachStdin: Bool = false,
        attachStdout: Bool = false,
        attachStderr: Bool = false,
        tty: Bool = false,
        openStdin: Bool = false,
        networkMode: String? = nil,
        restartPolicy: RestartPolicy? = nil,
        binds: [String]? = nil,
        volumes: [String: Any]? = nil,  // Anonymous volumes: {"/container/path": {}}
        portBindings: [String: [PortBinding]]? = nil,  // Port mappings: {"80/tcp": [PortBinding(hostIp: "0.0.0.0", hostPort: "8080")]}
        initialNetworkUserIP: String? = nil,  // User-specified IP for initial network (from docker run --ip)
        initialNetworkAliases: [String] = [],  // Aliases for initial network (from Docker Compose service name)
        // Memory Limits (Phase 5 - Task 5.1)
        memory: Int64? = nil,
        memoryReservation: Int64? = nil,
        memorySwap: Int64? = nil,
        memorySwappiness: Int? = nil,
        // CPU Limits (Phase 5 - Task 5.2)
        nanoCpus: Int64? = nil,
        cpuShares: Int64? = nil,
        cpuPeriod: Int64? = nil,
        cpuQuota: Int64? = nil,
        cpusetCpus: String? = nil,
        cpusetMems: String? = nil,
        // User/UID Support (Phase 5 - Task 5.3)
        user: String? = nil,
        groupAdd: [String]? = nil,
        // Security Capabilities (Phase 5 - Task 5.5)
        privileged: Bool = false,
        capAdd: [String]? = nil,
        capDrop: [String]? = nil,
        securityOpt: [String]? = nil,
        // Health Check (Phase 6 - Task 6.2)
        healthcheck: HealthConfig? = nil,
        // Extra Hosts (Issue #34)
        extraHosts: [String]? = nil,
        // Extra block device for helper containers (stopped container filesystem access)
        extraBlockDevice: String? = nil,
        // Tmpfs mounts (k3d support)
        tmpfs: [String: String]? = nil
    ) async throws -> String {
        logger.info("Creating container", metadata: [
            "image": "\(image)",
            "name": "\(name ?? "auto")",
            "attach": "\(attachStdin || attachStdout || attachStderr)",
            "tty": "\(tty)",
            "mounts": "\(binds?.count ?? 0)",
            "networkMode_param": "\(networkMode ?? "nil")"
        ])

        // Generate Docker-compatible ID
        let dockerID = generateDockerID()

        // Generate container name if not provided
        let containerName = name ?? generateContainerName()

        // Check if container name is already in use
        if let existingID = resolveContainerID(containerName) {
            logger.warning("Container name already in use", metadata: [
                "name": "\(containerName)",
                "existing_id": "\(existingID)"
            ])
            throw ContainerManagerError.nameConflict(containerName, existingID)
        }

        // Use real Containerization API
        guard var _ = nativeManager else {
            logger.error("ContainerManager not initialized")
            throw ContainerManagerError.notInitialized
        }

        // Validate memory limits (Phase 5 - Task 5.1)
        // Only validate if memory is explicitly set (> 0), Docker CLI sends 0 for unspecified
        if let memory = memory, memory > 0 {
            // Validate memory-reservation <= memory
            if let reservation = memoryReservation, reservation > 0, reservation > memory {
                throw ContainerManagerError.invalidParameter("memory-reservation must be less than or equal to memory")
            }

            // Validate memory-swap >= memory (or -1 for unlimited, or 0 for "same as memory")
            // Docker behavior: 0 or unset = twice memory, -1 = unlimited, >0 = specific limit
            if let swap = memorySwap, swap != -1 && swap != 0 && swap < memory {
                throw ContainerManagerError.invalidParameter("memory-swap must be greater than or equal to memory (or -1 for unlimited)")
            }
        }

        // Validate memory-swappiness range (0-100, or -1 for system default)
        if let swappiness = memorySwappiness {
            if swappiness < -1 || swappiness > 100 {
                throw ContainerManagerError.invalidParameter("memory-swappiness must be between 0 and 100 (or -1 for system default)")
            }
        }

        // Validate CPU limits (Phase 5 - Task 5.2)
        // Docker CLI sends 0 for unspecified values, only validate non-zero cpuset-cpus format
        if let cpusetCpus = cpusetCpus, !cpusetCpus.isEmpty {
            // Validate cpuset-cpus format: "0-3,5" or "0,1,2"
            let validChars = CharacterSet(charactersIn: "0123456789,-")
            if !cpusetCpus.unicodeScalars.allSatisfy({ validChars.contains($0) }) {
                throw ContainerManagerError.invalidParameter("cpuset-cpus must be in format '0-3,5' or '0,1,2'")
            }
        }

        // Get the image from ImageStore (no auto-pull - let Docker CLI handle it)
        logger.debug("Retrieving image", metadata: ["image": "\(image)"])
        let containerImage = try await imageManager.getImage(nameOrId: image)

        // Get image details for metadata and default command
        let imageDetails = try await imageManager.inspectImage(nameOrId: image)
        let imageID = imageDetails?.id ?? "sha256:" + String(repeating: "0", count: 64)

        // Get image config to calculate effective command for ContainerInfo
        let systemPlatform = detectSystemPlatform()
        let imagePlatform = systemPlatform.ociPlatform()
        let imageConfig = try await containerImage.config(for: imagePlatform)
        let imageEntrypoint = imageConfig.config?.entrypoint ?? []
        let imageCmd = imageConfig.config?.cmd ?? []

        // Extract image-defined volumes (VOLUME directives in Dockerfile)
        // These become anonymous volumes unless overridden by user mounts
        let imageVolumes = imageConfig.config?.volumes?.keys.map { String($0) } ?? []
        if !imageVolumes.isEmpty {
            logger.debug("Image defines volumes", metadata: [
                "docker_id": "\(dockerID)",
                "image_volumes": "\(imageVolumes.joined(separator: ", "))"
            ])
        }

        // Calculate effective command (matches Docker behavior and what actually gets executed)
        let effectiveEntrypoint = entrypoint ?? imageEntrypoint
        let effectiveCmd = command ?? imageCmd
        let effectiveFullCommand = effectiveEntrypoint + effectiveCmd

        logger.debug("Effective container command", metadata: [
            "docker_id": "\(dockerID)",
            "entrypoint": "\(effectiveEntrypoint.joined(separator: " "))",
            "cmd": "\(effectiveCmd.joined(separator: " "))",
            "full_command": "\(effectiveFullCommand.joined(separator: " "))"
        ])

        // Create log writers for capturing stdout/stderr
        logger.debug("Creating log writers", metadata: ["docker_id": "\(dockerID)"])
        let (stdoutLogWriter, stderrLogWriter): (FileLogWriter, FileLogWriter)
        let (stdoutBroadcast, stderrBroadcast): (BroadcastWriter, BroadcastWriter)
        do {
            (stdoutLogWriter, stderrLogWriter) = try logManager.createLogWriters(dockerID: dockerID)
            logWriters[dockerID] = (stdoutLogWriter, stderrLogWriter)

            // Wrap log writers in broadcast writers to support dynamic attach
            stdoutBroadcast = BroadcastWriter(initialSubscribers: [stdoutLogWriter])
            stderrBroadcast = BroadcastWriter(initialSubscribers: [stderrLogWriter])
            broadcastWriters[dockerID] = (stdoutBroadcast, stderrBroadcast)
        } catch {
            logger.error("Failed to create log writers", metadata: [
                "docker_id": "\(dockerID)",
                "error": "\(error)"
            ])
            throw ContainerManagerError.logWriterCreationFailed(error.localizedDescription)
        }

        // Create anonymous volumes if specified
        // Merge user-specified volumes with image-defined volumes (from VOLUME directives)
        var anonymousVolumeNames: [String] = []
        var effectiveBinds = binds ?? []

        // Build set of paths already covered by user mounts
        var coveredPaths: Set<String> = []

        // Add paths from bind mounts (format: "source:target" or "source:target:ro")
        for bind in effectiveBinds {
            let parts = bind.split(separator: ":", maxSplits: 2)
            if parts.count >= 2 {
                coveredPaths.insert(String(parts[1]))
            }
        }

        // Add paths from user-specified volumes
        if let userVolumes = volumes {
            for path in userVolumes.keys {
                coveredPaths.insert(path)
            }
        }

        // Add paths from tmpfs mounts
        if let tmpfsMounts = tmpfs {
            for path in tmpfsMounts.keys {
                coveredPaths.insert(path)
            }
        }

        // Merge user volumes with image-defined volumes (image volumes only if not covered)
        var effectiveVolumes: [String: Any] = volumes ?? [:]
        for imagePath in imageVolumes {
            if !coveredPaths.contains(imagePath) {
                effectiveVolumes[imagePath] = [:]
                logger.debug("Adding image-defined volume", metadata: [
                    "docker_id": "\(dockerID)",
                    "path": "\(imagePath)"
                ])
            } else {
                logger.debug("Image-defined volume path already covered by user mount", metadata: [
                    "docker_id": "\(dockerID)",
                    "path": "\(imagePath)"
                ])
            }
        }

        if !effectiveVolumes.isEmpty {
            logger.info("Creating anonymous volumes", metadata: [
                "docker_id": "\(dockerID)",
                "volume_count": "\(effectiveVolumes.count)",
                "user_volumes": "\(volumes?.count ?? 0)",
                "image_volumes": "\(imageVolumes.count)"
            ])

            guard let volumeManager = volumeManager else {
                logger.error("Anonymous volumes requested but VolumeManager not available")
                throw ContainerManagerError.volumeManagerNotAvailable
            }

            for (containerPath, _) in effectiveVolumes {
                // Create anonymous volume with auto-generated name
                let volumeMetadata = try await volumeManager.createVolume(
                    name: nil,  // Auto-generate name
                    driver: "local",
                    driverOpts: nil,
                    labels: ["com.arca.anonymous": "true"]  // Mark as anonymous
                )

                anonymousVolumeNames.append(volumeMetadata.name)

                // Add to binds so it gets mounted
                effectiveBinds.append("\(volumeMetadata.name):\(containerPath)")

                logger.info("Created anonymous volume", metadata: [
                    "docker_id": "\(dockerID)",
                    "volume_name": "\(volumeMetadata.name)",
                    "container_path": "\(containerPath)"
                ])
            }
        }

        // Parse bind mounts and named volumes (includes file bind mount handling and socket detection)
        var (mounts, socketConfigs, directMounts) = try await parseVolumeMounts(effectiveBinds, dockerID: dockerID)
        if !mounts.isEmpty || !socketConfigs.isEmpty || !directMounts.isEmpty {
            logger.info("Container has volume mounts", metadata: [
                "docker_id": "\(dockerID)",
                "mount_count": "\(mounts.count)",
                "socket_relay_count": "\(socketConfigs.count)",
                "direct_mount_count": "\(directMounts.count)"
            ])
        }

        // Store pending direct mounts for post-start setup
        if !directMounts.isEmpty {
            pendingDirectMounts[dockerID] = directMounts
            logger.debug("Stored pending direct mounts", metadata: [
                "docker_id": "\(dockerID)",
                "count": "\(directMounts.count)"
            ])
        }

        // Process tmpfs mounts (k3d support)
        // Docker format: {"container_path": "options"} e.g., {"/run": "", "/var/run": "size=123"}
        if let tmpfsMounts = tmpfs {
            for (containerPath, options) in tmpfsMounts {
                // Parse options string into array (comma-separated)
                var mountOptions: [String] = ["noexec", "nosuid", "nodev"]  // Default tmpfs options
                if !options.isEmpty {
                    mountOptions = options.split(separator: ",").map { String($0) }
                }

                // Create tmpfs mount
                let tmpfsMount = Containerization.Mount.any(
                    type: "tmpfs",
                    source: "tmpfs",
                    destination: containerPath,
                    options: mountOptions
                )
                mounts.append(tmpfsMount)

                logger.info("Added tmpfs mount", metadata: [
                    "docker_id": "\(dockerID)",
                    "container_path": "\(containerPath)",
                    "options": "\(mountOptions)"
                ])
            }
        }

        // Create writable filesystem early (before deferring LinuxContainer creation)
        // This is needed for docker cp to work on never-started containers
        // The writable.ext4 must exist before docker cp tries to write to it
        let appleStorePath = NSString(string: "~/Library/Application Support/com.apple.containerization").expandingTildeInPath
        let containerRoot = URL(fileURLWithPath: appleStorePath).appendingPathComponent("containers")
        let containerPath = containerRoot.appendingPathComponent(dockerID)

        // Ensure container directory exists
        try FileManager.default.createDirectory(at: containerPath, withIntermediateDirectories: true)

        // Create writable filesystem if it doesn't exist
        let writablePath = containerPath.appendingPathComponent("writable.ext4")
        if !FileManager.default.fileExists(atPath: writablePath.path) {
            let mounter = OverlayFSMounter(logger: logger)
            // 64 GB provides sufficient space for build caches and large workloads
            // Thin-provisioned (sparse file) so only actual data consumes disk space
            try mounter.createWritableFilesystem(at: writablePath.path, sizeMB: 65536)
            logger.info("Created writable filesystem during docker create", metadata: [
                "docker_id": "\(dockerID)",
                "path": "\(writablePath.path)"
            ])
        }

        // Always defer LinuxContainer creation until docker start
        // This ensures docker cp changes made between docker create and docker start are visible
        // The writable.ext4 is already created above, so docker cp will work
        logger.info("Deferring LinuxContainer creation until docker start", metadata: [
            "docker_id": "\(dockerID)",
            "container_name": "\(containerName)"
        ])

        // Store deferred config for later use during start
        // Hostname priority: user-specified (non-empty) > first 12 chars of container ID (Docker default)
        // Note: Docker CLI sends empty string "" when hostname not specified, not nil
        let effectiveHostname = (hostname?.isEmpty == false) ? hostname! : String(dockerID.prefix(12))
        deferredConfigs[dockerID] = DeferredContainerConfig(
            image: containerImage,
            entrypoint: entrypoint,
            command: command,
            env: env,
            workingDir: workingDir,
            hostname: effectiveHostname,
            mounts: mounts,  // Store mounts for deferred creation
            // Memory Limits (Phase 5 - Task 5.1)
            memory: memory,
            memoryReservation: memoryReservation,
            memorySwap: memorySwap,
            memorySwappiness: memorySwappiness,
            // CPU Limits (Phase 5 - Task 5.2)
            nanoCpus: nanoCpus,
            cpuShares: cpuShares,
            cpuPeriod: cpuPeriod,
            cpuQuota: cpuQuota,
            cpusetCpus: cpusetCpus,
            cpusetMems: cpusetMems,
            // User/UID Support (Phase 5 - Task 5.3)
            user: user,
            groupAdd: groupAdd,
            // Security Capabilities (Phase 5 - Task 5.5)
            privileged: privileged,
            capAdd: capAdd,
            capDrop: capDrop,
            // Health Check (Phase 6 - Task 6.2)
            healthcheck: healthcheck,
            // Unix Socket Relays (k3d/kind support)
            socketConfigs: socketConfigs,
            // Extra block device for helper containers
            extraBlockDevice: extraBlockDevice
        )

        // Use Docker ID as native ID - the actual LinuxContainer will be created during start
        let nativeID = dockerID

        // Register ID mapping
        registerIDMapping(dockerID: dockerID, nativeID: nativeID)

        // Store container info for state tracking
        let now = Date()
        let containerInfo = ContainerInfo(
            nativeID: nativeID,
            name: containerName,
            image: image,
            imageID: imageID,
            created: now,
            state: "created",
            command: effectiveFullCommand,
            path: effectiveFullCommand.first ?? "",
            args: effectiveFullCommand.dropFirst().map { String($0) },
            env: env ?? [],
            workingDir: workingDir ?? "/",
            labels: labels ?? [:],
            ports: convertPortBindingsToMappings(portBindings ?? [:]),
            hostConfig: HostConfig(
                binds: binds ?? [],
                networkMode: networkMode ?? "default",
                portBindings: portBindings ?? [:],
                restartPolicy: restartPolicy ?? RestartPolicy(name: "no", maximumRetryCount: 0),
                privileged: privileged,
                memory: memory ?? 0,
                memoryReservation: memoryReservation ?? 0,
                memorySwap: memorySwap ?? 0,
                memorySwappiness: memorySwappiness ?? -1,
                nanoCpus: nanoCpus ?? 0,
                cpuShares: cpuShares ?? 0,
                cpuPeriod: cpuPeriod ?? 0,
                cpuQuota: cpuQuota ?? 0,
                cpusetCpus: cpusetCpus ?? "",
                cpusetMems: cpusetMems ?? "",
                groupAdd: groupAdd ?? [],
                capAdd: capAdd ?? [],
                capDrop: capDrop ?? [],
                securityOpt: securityOpt ?? [],
                extraHosts: extraHosts ?? []
            ),
            config: ContainerConfiguration(
                // Hostname priority: user-specified (non-empty) > first 12 chars of container ID (Docker default)
                // Note: Docker CLI sends empty string "" when hostname not specified, not nil
                hostname: (hostname?.isEmpty == false) ? hostname! : String(dockerID.prefix(12)),
                env: env ?? [],
                cmd: effectiveCmd,  // Use effective cmd (request.cmd ?? image.cmd)
                image: image,
                workingDir: workingDir ?? "",
                entrypoint: effectiveEntrypoint,  // Store effective entrypoint for container restart
                labels: labels ?? [:],
                healthcheck: healthcheck
            ),
            networkSettings: NetworkSettings(),
            pid: 0,
            exitCode: 0,
            startedAt: nil,
            finishedAt: nil,
            tty: tty,
            needsCreate: true,  // Always defer LinuxContainer creation to docker start
            networkAttachments: [:],  // Start with no network attachments
            anonymousVolumes: anonymousVolumeNames,  // Track anonymous volumes for cleanup
            initialNetworkUserIP: initialNetworkUserIP,  // User-specified IP for initial network
            initialNetworkAliases: initialNetworkAliases  // Aliases for initial network (from Docker Compose)
        )

        containers[dockerID] = containerInfo

        // Persist container state
        try await persistContainerState(dockerID: dockerID, info: containerInfo)

        // Track volume mounts in StateStore
        try await trackVolumeMounts(
            dockerID: dockerID,
            binds: effectiveBinds,
            anonymousVolumes: anonymousVolumeNames
        )

        logger.info("Container created successfully", metadata: [
            "docker_id": "\(dockerID)",
            "native_id": "\(nativeID)",
            "name": "\(containerName)"
        ])

        // Emit container create event
        if let eventEmitter = eventEmitter {
            var attributes: [String: String] = ["name": containerName, "image": image]
            if let labels = labels {
                for (key, value) in labels {
                    attributes[key] = value
                }
            }
            await eventEmitter.emitContainerEvent(
                action: "create",
                containerID: dockerID,
                attributes: attributes
            )
        }

        return dockerID
    }

    /// Resolve container name or ID to Docker ID
    /// Supports:
    /// - Full 64-char Docker IDs
    /// - Short IDs (minimum 4 chars, prefix matching)
    /// - Container names (with or without "/" prefix)
    public func resolveContainerID(_ nameOrID: String) -> String? {
        // First try direct ID lookup (full 64-char ID)
        if containers[nameOrID] != nil {
            return nameOrID
        }

        // Try short ID prefix matching (4-64 chars)
        if nameOrID.count >= 4 && nameOrID.count < 64 {
            // Check if it's a valid hex string
            let hexCharset = CharacterSet(charactersIn: "0123456789abcdefABCDEF")
            if nameOrID.unicodeScalars.allSatisfy({ hexCharset.contains($0) }) {
                // Find containers with IDs that start with this prefix
                let matches = containers.keys.filter { $0.hasPrefix(nameOrID.lowercased()) }

                if matches.count == 1 {
                    return matches.first
                } else if matches.count > 1 {
                    // Multiple matches - return first (Docker behavior)
                    logger.warning("Multiple containers match short ID", metadata: [
                        "short_id": "\(nameOrID)",
                        "matches": "\(matches.count)"
                    ])
                    return matches.sorted().first
                }
            }
        }

        // Then try name lookup
        for (id, info) in containers {
            if info.name == nameOrID || info.name == "/\(nameOrID)" {
                return id
            }
        }

        return nil
    }

    // MARK: - Container Attach Support

    /// Register attach handles for a container (called before container starts)
    /// Used for interactive containers (docker run -it)
    public func registerAttach(containerID: String, handles: AttachHandles, exitSignal: AsyncStream<Void>.Continuation) {
        logger.debug("Registering attach handles", metadata: ["container_id": "\(containerID)"])
        pendingAttaches[containerID] = (handles: handles, exitSignal: exitSignal)
    }

    /// Consume and remove pending attach handles for a container
    /// Returns nil if no attach handles are registered
    private func consumeAttachHandles(containerID: String) -> (handles: AttachHandles, exitSignal: AsyncStream<Void>.Continuation)? {
        return pendingAttaches.removeValue(forKey: containerID)
    }

    /// Subscribe attach handles to broadcast writers for a running/created container
    /// This allows dynamic attachment without recreating the container
    private func subscribeAttachToBroadcast(containerID: String, handles: AttachHandles) throws {
        guard let (stdoutBroadcast, stderrBroadcast) = broadcastWriters[containerID] else {
            logger.error("Broadcast writers not found for container", metadata: ["id": "\(containerID)"])
            throw ContainerManagerError.containerNotFound(containerID)
        }

        logger.info("Subscribing attach handles to broadcast writers", metadata: ["id": "\(containerID)"])
        stdoutBroadcast.addSubscriber(handles.stdout)
        stderrBroadcast.addSubscriber(handles.stderr)
    }

    // MARK: - Helper Container Support

    /// Create a helper container for filesystem operations on stopped containers
    /// Helper containers mount the target container's writable.ext4 and image layers to set up OverlayFS
    public func createHelperContainer(
        name: String,
        image: String,
        targetWritablePath: String,
        targetImageRef: String?,
        layerPaths: [String],  // Paths to image layer.ext4 files for OverlayFS lower layers
        isHelper: Bool
    ) async throws -> String {
        logger.info("Creating helper container", metadata: [
            "name": "\(name)",
            "image": "\(image)",
            "target_writable": "\(targetWritablePath)",
            "layer_count": "\(layerPaths.count)"
        ])

        // Helper containers have special labels to identify them and enable filtering
        var labels = [String: String]()
        labels["com.arca.internal"] = "helper"
        labels["com.arca.helper.target_writable"] = targetWritablePath
        if let targetImage = targetImageRef {
            labels["com.arca.helper.target_image"] = targetImage
        }

        // Build bind mounts for helper:
        // - Target container's directory (contains writable.ext4 with upper/work)
        // - Each image layer directory (contains layer.ext4)
        let targetDir = URL(fileURLWithPath: targetWritablePath).deletingLastPathComponent().path
        var binds = ["\(targetDir):/mnt/target-host"]

        // Add layer mounts - each layer directory contains layer.ext4
        // Mount at /mnt/layers/0, /mnt/layers/1, etc.
        for (index, layerPath) in layerPaths.enumerated() {
            let layerDir = URL(fileURLWithPath: layerPath).deletingLastPathComponent().path
            binds.append("\(layerDir):/mnt/layers/\(index):ro")
        }

        logger.debug("Helper container bind mounts", metadata: [
            "binds": "\(binds.joined(separator: ", "))"
        ])

        // Create container with helper labels
        // The helper runs a simple sleep command to keep it alive while we perform operations
        // Use networkMode: "none" - helpers don't need networking
        // Use privileged: true - helpers need losetup and mount for block device/overlayfs access
        let helperID = try await createContainer(
            image: image,
            name: name,
            entrypoint: ["/bin/sh", "-c"],
            command: ["sleep infinity"],
            env: nil,
            workingDir: nil,
            labels: labels,
            tty: false,
            networkMode: "none",
            binds: binds,
            privileged: true
        )

        logger.info("Helper container created", metadata: [
            "id": "\(helperID)",
            "name": "\(name)",
            "layer_count": "\(layerPaths.count)"
        ])

        return helperID
    }

    // MARK: - Container Lifecycle

    /// Start a container
    public func startContainer(id: String) async throws {
        logger.info("Starting container", metadata: ["id": "\(id)"])

        // Resolve name or ID to Docker ID
        guard let dockerID = resolveContainerID(id) else {
            throw ContainerManagerError.containerNotFound(id)
        }

        guard var info = containers[dockerID] else {
            throw ContainerManagerError.containerNotFound(id)
        }

        // Get manager
        guard var manager = nativeManager else {
            logger.error("ContainerManager not initialized")
            throw ContainerManagerError.notInitialized
        }

        // Check if this is a deferred container (needs creation)
        let nativeContainer: LinuxContainer
        let attachInfo: (handles: AttachHandles, exitSignal: AsyncStream<Void>.Continuation)?

        if info.needsCreate {
            // Container creation was deferred - create it now
            logger.info("Creating deferred container", metadata: ["id": "\(dockerID)"])

            // Get deferred config
            guard let config = deferredConfigs.removeValue(forKey: dockerID) else {
                logger.error("Deferred config not found", metadata: ["id": "\(dockerID)"])
                throw ContainerManagerError.containerNotFound(id)
            }

            // Check for attach handles
            attachInfo = consumeAttachHandles(containerID: dockerID)

            // Get broadcast writers (already created during container creation)
            guard let (stdoutBroadcast, stderrBroadcast) = broadcastWriters[dockerID] else {
                logger.error("Broadcast writers not found", metadata: ["id": "\(dockerID)"])
                throw ContainerManagerError.containerNotFound(id)
            }

            // If attach handles exist, add them to broadcast writers
            if let attach = attachInfo {
                logger.info("Adding attach handles to broadcast writers for deferred container", metadata: ["id": "\(dockerID)"])
                stdoutBroadcast.addSubscriber(attach.handles.stdout)
                stderrBroadcast.addSubscriber(attach.handles.stderr)
            }

            // Create the LinuxContainer using helper with broadcast writers
            let container = try await createNativeContainer(
                config: NativeContainerConfig(
                    dockerID: dockerID,
                    image: config.image,
                    entrypoint: config.entrypoint,
                    command: config.command,
                    env: config.env,
                    workingDir: config.workingDir,
                    hostname: config.hostname,
                    tty: info.tty,
                    stdoutWriter: stdoutBroadcast,
                    stderrWriter: stderrBroadcast,
                    stdinReader: attachInfo?.handles.stdin,  // Include stdin if attached
                    mounts: config.mounts,
                    overlayConfig: nil,  // Will be unpacked in createNativeContainer
                    networkMode: info.hostConfig.networkMode,
                    labels: info.config.labels,
                    // Memory Limits (Phase 5 - Task 5.1)
                    memory: config.memory,
                    memoryReservation: config.memoryReservation,
                    memorySwap: config.memorySwap,
                    memorySwappiness: config.memorySwappiness,
                    // CPU Limits (Phase 5 - Task 5.2)
                    nanoCpus: config.nanoCpus,
                    cpuShares: config.cpuShares,
                    cpuPeriod: config.cpuPeriod,
                    cpuQuota: config.cpuQuota,
                    cpusetCpus: config.cpusetCpus,
                    cpusetMems: config.cpusetMems,
                    // User/UID Support (Phase 5 - Task 5.3)
                    user: config.user,
                    groupAdd: config.groupAdd,
                    // Security Capabilities (Phase 5 - Task 5.5)
                    privileged: config.privileged,
                    capAdd: config.capAdd,
                    capDrop: config.capDrop,
                    // Unix Socket Relays (k3d/kind support)
                    socketConfigs: config.socketConfigs,
                    // Extra block device for helper containers
                    extraBlockDevice: config.extraBlockDevice
                )
            )

            // Store the container
            nativeContainers[dockerID] = container
            nativeContainer = container

            // Update needsCreate flag
            info.needsCreate = false

        } else {
            // Container should already be created - check if it exists in framework
            if let container = nativeContainers[dockerID] {
                // Container exists in framework - use it
                nativeContainer = container

                // Check for attach handles and subscribe them to broadcast writers
                // This allows dynamic attach without recreating the container
                if let attach = consumeAttachHandles(containerID: dockerID) {
                    try subscribeAttachToBroadcast(containerID: dockerID, handles: attach.handles)
                    attachInfo = attach
                } else {
                    attachInfo = nil
                }

                // Start the container using Containerization API
                // Containerization state machine: .stopped -> create() -> .created -> start() -> .started
                // After a container exits and we call stop(), it goes back to .stopped state
                // To restart, we must call create() again to transition .stopped -> .created
                if info.state == "exited" {
                    logger.info("Container is exited, calling create() before start()", metadata: [
                        "id": "\(dockerID)"
                    ])
                    try await nativeContainer.create()
                }
            } else {
                // Container NOT in framework - must recreate from persisted state
                // This happens after daemon restart: metadata persists but Container objects don't
                logger.info("Recreating container from persisted state", metadata: [
                    "id": "\(dockerID)",
                    "state": "\(info.state)"
                ])

                // Clean up orphaned container storage from previous daemon run
                // The Containerization framework leaves storage directories when the daemon exits
                // We need to remove these before recreating (Docker doesn't preserve writable layer for stopped containers)
                logger.debug("Cleaning up orphaned container storage", metadata: [
                    "id": "\(dockerID)"
                ])
                do {
                    try manager.delete(dockerID)
                    logger.debug("Cleaned up orphaned storage via manager.delete()", metadata: [
                        "id": "\(dockerID)"
                    ])
                } catch {
                    // Expected to fail if no orphaned storage exists - this is normal
                    logger.debug("No orphaned storage found (this is normal)", metadata: [
                        "id": "\(dockerID)"
                    ])
                }

                // Get the image from persisted config
                logger.debug("Retrieving image for recreation", metadata: [
                    "image": "\(info.image)",
                    "docker_id": "\(dockerID)"
                ])
                let containerImage = try await imageManager.getImage(nameOrId: info.image)

                // Get log writers (create if they don't exist yet)
                let (stdoutLogWriter, stderrLogWriter): (FileLogWriter, FileLogWriter)
                let (stdoutBroadcast, stderrBroadcast): (BroadcastWriter, BroadcastWriter)

                if let existing = logWriters[dockerID] {
                    (stdoutLogWriter, stderrLogWriter) = existing
                } else {
                    let writers = try logManager.createLogWriters(dockerID: dockerID)
                    logWriters[dockerID] = writers
                    (stdoutLogWriter, stderrLogWriter) = writers
                }

                // Get or create broadcast writers
                if let existing = broadcastWriters[dockerID] {
                    (stdoutBroadcast, stderrBroadcast) = existing
                } else {
                    stdoutBroadcast = BroadcastWriter(initialSubscribers: [stdoutLogWriter])
                    stderrBroadcast = BroadcastWriter(initialSubscribers: [stderrLogWriter])
                    broadcastWriters[dockerID] = (stdoutBroadcast, stderrBroadcast)
                }

                // Parse volume mounts from persisted binds (includes both bind mounts, named volumes, and socket relays)
                let (recreatedMounts, recreatedSocketConfigs, recreatedDirectMounts) = try await parseVolumeMounts(info.hostConfig.binds, dockerID: dockerID)

                // Store pending direct mounts for post-start setup
                if !recreatedDirectMounts.isEmpty {
                    pendingDirectMounts[dockerID] = recreatedDirectMounts
                    logger.debug("Stored pending direct mounts for recreated container", metadata: [
                        "docker_id": "\(dockerID)",
                        "count": "\(recreatedDirectMounts.count)"
                    ])
                }

                // Resolve command and entrypoint: use persisted if provided, otherwise use image defaults
                // Empty array means "no override, use image defaults" in Docker semantics
                let resolvedCommand: [String]? = info.command.isEmpty ? nil : info.command
                let resolvedEntrypoint: [String]? = info.config.entrypoint

                // Recreate the LinuxContainer with the persisted configuration using broadcast writers
                let container = try await createNativeContainer(
                    config: NativeContainerConfig(
                        dockerID: dockerID,
                        image: containerImage,
                        entrypoint: resolvedEntrypoint,
                        command: resolvedCommand,
                        env: info.env,
                        workingDir: info.workingDir,
                        hostname: info.config.hostname,
                        tty: info.tty,
                        stdoutWriter: stdoutBroadcast,
                        stderrWriter: stderrBroadcast,
                        stdinReader: nil,  // No stdin for recreated containers
                        mounts: recreatedMounts,
                        overlayConfig: nil,  // TODO: Wire up from OverlayFSUnpacker (Phase 1)
                        networkMode: info.hostConfig.networkMode,
                        labels: info.config.labels,
                        // Memory Limits (Phase 5 - Task 5.1)
                        memory: info.hostConfig.memory > 0 ? info.hostConfig.memory : nil,
                        memoryReservation: info.hostConfig.memoryReservation > 0 ? info.hostConfig.memoryReservation : nil,
                        memorySwap: info.hostConfig.memorySwap != 0 ? info.hostConfig.memorySwap : nil,
                        memorySwappiness: info.hostConfig.memorySwappiness != -1 ? info.hostConfig.memorySwappiness : nil,
                        // CPU Limits (Phase 5 - Task 5.2)
                        nanoCpus: info.hostConfig.nanoCpus > 0 ? info.hostConfig.nanoCpus : nil,
                        cpuShares: info.hostConfig.cpuShares > 0 ? info.hostConfig.cpuShares : nil,
                        cpuPeriod: info.hostConfig.cpuPeriod > 0 ? info.hostConfig.cpuPeriod : nil,
                        cpuQuota: info.hostConfig.cpuQuota != 0 ? info.hostConfig.cpuQuota : nil,
                        cpusetCpus: !info.hostConfig.cpusetCpus.isEmpty ? info.hostConfig.cpusetCpus : nil,
                        cpusetMems: !info.hostConfig.cpusetMems.isEmpty ? info.hostConfig.cpusetMems : nil,
                        // User/UID Support (Phase 5 - Task 5.3)
                        user: !info.config.user.isEmpty ? info.config.user : nil,
                        groupAdd: !info.hostConfig.groupAdd.isEmpty ? info.hostConfig.groupAdd : nil,
                        // Security Capabilities (Phase 5 - Task 5.5)
                        privileged: info.hostConfig.privileged,
                        capAdd: !info.hostConfig.capAdd.isEmpty ? info.hostConfig.capAdd : nil,
                        capDrop: !info.hostConfig.capDrop.isEmpty ? info.hostConfig.capDrop : nil,
                        // Unix Socket Relays (k3d/kind support)
                        socketConfigs: recreatedSocketConfigs,
                        // Extra block device - nil for recreated containers (helper containers are ephemeral)
                        extraBlockDevice: nil
                    )
                )

                // Store the recreated container
                nativeContainers[dockerID] = container
                nativeContainer = container
                attachInfo = nil

                logger.info("Container recreated successfully from persisted state", metadata: [
                    "id": "\(dockerID)"
                ])

                // Container is now in .created state (createNativeContainer calls .create())
                // Ready to be started
            }
        }

        logger.info("Starting container with Containerization API", metadata: [
            "id": "\(dockerID)",
            "current_state": "\(info.state)"
        ])

        // ===================================================================================
        // NETWORK SETUP BEFORE START
        // We must complete network setup BEFORE calling container.start() because:
        // 1. start() holds a lock that blocks dialVsock()
        // 2. AddNetwork (via dialVsock) creates the network namespace
        // 3. vmexec needs to join the namespace when start() is called
        // By doing network setup first, the namespace exists before vmexec runs.
        // ===================================================================================

        // Wait for arca-services to signal all services are ready (port 51819)
        // dialVsock works in .created state, so we can do this before start()
        try await waitForServicesReady(container: nativeContainer, dockerID: dockerID)

        // Create FilesystemClient for container filesystem operations (diff, archive)
        let filesystemClient = FilesystemClient(
            containerID: dockerID,
            container: nativeContainer,
            logger: logger
        )
        filesystemClients[dockerID] = filesystemClient
        logger.debug("Created FilesystemClient", metadata: ["container": "\(dockerID)"])

        // ===================================================================================
        // DIRECT EXT4 MOUNT SETUP - Create bind mounts for named volumes (local driver)
        // Direct EXT4 bind mounts are created on /dev/vdb (writable.ext4) and bind mounted
        // to the container path. This provides full POSIX compliance and allows nested overlays.
        // ===================================================================================
        if let directMounts = pendingDirectMounts.removeValue(forKey: dockerID) {
            logger.info("Setting up direct EXT4 mounts", metadata: [
                "container": "\(dockerID)",
                "count": "\(directMounts.count)"
            ])

            for mount in directMounts {
                do {
                    logger.debug("Creating direct mount", metadata: [
                        "container": "\(dockerID)",
                        "volumeName": "\(mount.volumeName)",
                        "targetPath": "\(mount.targetPath)"
                    ])

                    try await filesystemClient.createDirectMount(
                        volumeName: mount.volumeName,
                        target: mount.targetPath
                    )

                    logger.info("Direct mount created", metadata: [
                        "container": "\(dockerID)",
                        "targetPath": "\(mount.targetPath)"
                    ])
                } catch {
                    logger.error("Failed to create direct mount", metadata: [
                        "container": "\(dockerID)",
                        "targetPath": "\(mount.targetPath)",
                        "error": "\(error)"
                    ])
                    throw error
                }
            }
        }

        // Note: Archives are now written directly to stopped containers via HelperContainerManager
        // No staging mechanism needed - files are already in place before container starts

        // ===================================================================================
        // NETWORK SETUP - Creates namespace at /run/netns/arca-{shortID}
        // This MUST complete before start() so vmexec can join the namespace
        // ===================================================================================

        logger.debug("Beginning container network setup (before start)", metadata: [
            "container": "\(dockerID)"
        ])

        // Query database for persisted network attachments (source of truth)
        // This avoids in-memory sync issues where containers[dockerID] might have stale networkAttachments
        let persistedAttachments = try await stateStore.loadNetworkAttachments(containerID: dockerID)
        let hasPersistedAttachments = !persistedAttachments.isEmpty

        // DEBUG: Log network attachment state before attachment logic
        logger.debug("Network attachment state before attachment logic", metadata: [
            "container": "\(dockerID)",
            "persistedAttachments_count": "\(persistedAttachments.count)",
            "persistedAttachments_networks": "\(persistedAttachments.map { $0.networkID }.joined(separator: ", "))",
            "inMemory_networkAttachments_count": "\(info.networkAttachments.count)",
            "networkMode": "\(info.hostConfig.networkMode)"
        ])

        // Auto-attach to network based on networkMode if no networks are attached in database
        // Docker CLI sets networkMode in HostConfig and expects the daemon to handle attachment
        if let networkManager = networkManager,
           !hasPersistedAttachments {
            let networkMode = info.hostConfig.networkMode

            // Only auto-attach if networkMode is not "none" or "host"
            // "host" network (vmnet driver) interfaces are created during VM creation, not at start time
            if networkMode != "none" && networkMode != "host" {
                // Normalize networkMode: empty, "default", or "bridge" all mean the default bridge network
                let targetNetwork: String
                if networkMode.isEmpty || networkMode == "default" {
                    targetNetwork = "bridge"
                } else {
                    targetNetwork = networkMode
                }

                logger.info("Auto-attaching container to network", metadata: [
                    "container": "\(dockerID)",
                    "network": "\(targetNetwork)",
                    "networkMode": "\(networkMode)"
                ])

                do {
                    // Resolve network name/ID to actual network ID
                    if let resolvedNetworkID = await networkManager.resolveNetworkID(targetNetwork) {
                        let containerName = info.name ?? String(dockerID.prefix(12))
                        let attachment = try await networkManager.attachContainerToNetwork(
                            containerID: dockerID,
                            container: nativeContainer,
                            networkID: resolvedNetworkID,
                            containerName: containerName,
                            aliases: info.initialNetworkAliases,  // Pass aliases from Docker Compose
                            userSpecifiedIP: info.initialNetworkUserIP,  // Pass user-specified IP for validation
                            extraHosts: info.hostConfig.extraHosts  // Pass extra hosts for DNS resolution (Issue #34)
                        )

                        // Record the attachment in ContainerManager
                        try await self.attachContainerToNetwork(
                            dockerID: dockerID,
                            networkID: resolvedNetworkID,
                            ip: attachment.ip,
                            mac: attachment.mac,
                            aliases: attachment.aliases
                        )

                        logger.info("Container auto-attached to network successfully", metadata: [
                            "container": "\(dockerID)",
                            "network": "\(targetNetwork)",
                            "resolved_id": "\(resolvedNetworkID)",
                            "ip": "\(attachment.ip)"
                        ])
                    } else {
                        logger.warning("Failed to resolve network, container will start without network", metadata: [
                            "container": "\(dockerID)",
                            "network": "\(targetNetwork)"
                        ])
                    }
                } catch let error as NetworkManagerError {
                    // User validation errors should fail container start
                    switch error {
                    case .invalidIPAddress, .ipAlreadyInUse, .alreadyConnected, .ipAllocationFailed:
                        logger.error("Container start failed due to network validation error", metadata: [
                            "container": "\(dockerID)",
                            "network": "\(targetNetwork)",
                            "error": "\(error)"
                        ])
                        throw error
                    default:
                        // Infrastructure errors (network not found, backend not ready, etc.)
                        // Log warning but don't fail container start - networking is optional
                        logger.warning("Failed to auto-attach container to network", metadata: [
                            "container": "\(dockerID)",
                            "network": "\(targetNetwork)",
                            "error": "\(error)"
                        ])
                    }
                } catch {
                    // Unknown errors - log warning but don't fail
                    logger.warning("Failed to auto-attach container to network", metadata: [
                        "container": "\(dockerID)",
                        "network": "\(targetNetwork)",
                        "error": "\(error)"
                    ])
                }
            } else {
                logger.debug("Container networkMode is 'none' or 'host', skipping auto-attachment", metadata: [
                    "container": "\(dockerID)",
                    "networkMode": "\(networkMode)"
                ])
            }
        } else if let networkManager = networkManager,
                  hasPersistedAttachments {
            // Container has persisted network attachments in database - restore them
            logger.info("🔵 NETWORK RESTORATION: Restoring persisted network attachments from database", metadata: [
                "container": "\(dockerID)",
                "attachmentCount": "\(persistedAttachments.count)"
            ])

            let containerName = info.name ?? String(dockerID.prefix(12))

            for attachment in persistedAttachments {
                do {
                    logger.debug("Restoring network attachment", metadata: [
                        "container": "\(dockerID)",
                        "network": "\(attachment.networkID)",
                        "ip": "\(attachment.ipAddress)"
                    ])

                    // Reattach to the network with the persisted IP address
                    // This ensures we reuse the same IP and allows the backend to recognize this as a restoration
                    let newAttachment = try await networkManager.attachContainerToNetwork(
                        containerID: dockerID,
                        container: nativeContainer,
                        networkID: attachment.networkID,
                        containerName: containerName,
                        aliases: attachment.aliases,
                        userSpecifiedIP: attachment.ipAddress,  // Reuse persisted IP for restoration
                        extraHosts: info.hostConfig.extraHosts  // Pass extra hosts for DNS resolution (Issue #34)
                    )

                    logger.info("Network attachment restored successfully", metadata: [
                        "container": "\(dockerID)",
                        "network": "\(attachment.networkID)",
                        "ip": "\(newAttachment.ip)"
                    ])
                } catch {
                    // Log the error but continue with other attachments
                    logger.error("Failed to restore network attachment", metadata: [
                        "container": "\(dockerID)",
                        "network": "\(attachment.networkID)",
                        "error": "\(error)"
                    ])
                }
            }
        }

        // Push DNS topology to this container (for its own resolution)
        await pushDNSTopologyUpdate(to: dockerID)

        // Push DNS topology to all other containers on the same networks (to add this container)
        // Use persisted attachments from database as source of truth
        for attachment in persistedAttachments {
            await pushDNSTopologyToNetwork(networkID: attachment.networkID)
        }

        // Publish ports if configured (Phase 4.1)
        if let portMapManager = portMapManager,
           !info.hostConfig.portBindings.isEmpty,
           let networkManager = networkManager {
            // Re-fetch updated container info after network attachment
            guard let updatedInfo = containers[dockerID] else {
                logger.warning("Container disappeared during port publishing", metadata: ["container": "\(dockerID)"])
                return
            }

            // Get WireGuard client for this container
            if let wireguardClient = await networkManager.getWireGuardClient(containerID: dockerID) {
                // Ensure we disconnect when done
                defer {
                    Task {
                        try? await wireguardClient.disconnect()
                    }
                }

                do {
                    // Get vmnet IP from container
                    let vmnetEndpoint = try await wireguardClient.getVmnetEndpoint()
                    let vmnetIP = vmnetEndpoint.split(separator: ":").first.map(String.init) ?? vmnetEndpoint

                    // Get overlay IP from first network attachment
                    let overlayIP = updatedInfo.networkAttachments.values.first?.ip ?? ""

                    // Publish all port mappings
                    try await portMapManager.publishPorts(
                        containerID: dockerID,
                        vmnetIP: vmnetIP,
                        overlayIP: overlayIP,
                        portBindings: info.hostConfig.portBindings,
                        wireguardClient: wireguardClient
                    )

                    logger.info("Published port mappings for container", metadata: [
                        "container": "\(dockerID)",
                        "portCount": "\(info.hostConfig.portBindings.count)"
                    ])
                } catch {
                    logger.error("Failed to publish port mappings", metadata: [
                        "container": "\(dockerID)",
                        "error": "\(error)"
                    ])
                    // Don't fail container start on port mapping errors
                }
            }
        }

        // ===================================================================================
        // GENERATE /etc/hosts FILE - Docker generates this file; we need to do the same
        // Must happen before start() while we still have access to modify the rootfs
        // ===================================================================================
        do {
            // Re-fetch updated container info after network attachment (may have new IP)
            guard let updatedInfo = containers[dockerID] else {
                logger.warning("Container disappeared during /etc/hosts generation", metadata: ["container": "\(dockerID)"])
                return
            }

            // Get container's IP address from first network attachment
            let containerIP = updatedInfo.networkAttachments.values.first?.ip ?? ""

            // Get hostname: use configured hostname or short container ID
            let hostname = info.config.hostname.isEmpty ? String(dockerID.prefix(12)) : info.config.hostname

            // Get container name (without leading slash)
            let containerName = (info.name ?? String(dockerID.prefix(12))).trimmingCharacters(in: CharacterSet(charactersIn: "/"))

            // Get extra hosts from hostConfig
            let extraHosts = info.hostConfig.extraHosts

            logger.debug("Generating /etc/hosts file", metadata: [
                "container": "\(dockerID)",
                "hostname": "\(hostname)",
                "ip": "\(containerIP)",
                "name": "\(containerName)",
                "extraHostsCount": "\(extraHosts.count)"
            ])

            try await filesystemClient.generateHostsFile(
                hostname: hostname,
                ipAddress: containerIP,
                containerName: containerName,
                extraHosts: extraHosts
            )

            logger.info("/etc/hosts file generated", metadata: [
                "container": "\(dockerID)",
                "hostname": "\(hostname)",
                "ip": "\(containerIP)"
            ])
        } catch {
            // Log error but don't fail container start - /etc/hosts is nice to have but not critical
            logger.warning("Failed to generate /etc/hosts file", metadata: [
                "container": "\(dockerID)",
                "error": "\(error)"
            ])
        }

        // ===================================================================================
        // START CONTAINER - Network namespace already exists from AddNetwork above
        // vmexec will join the pre-existing namespace immediately, no waiting needed
        // ===================================================================================
        try await nativeContainer.start()

        // ===================================================================================
        // ALL SETUP COMPLETE - Now safe to mark container as "running"
        // ===================================================================================

        info.state = "running"
        info.startedAt = Date()
        info.pid = 1  // Containers run as PID 1 in their VM
        containers[dockerID] = info

        // Persist state change
        try await persistContainerState(dockerID: dockerID, info: info)

        logger.info("Container started successfully (all setup complete)", metadata: [
            "id": "\(dockerID)",
            "state": "running"
        ])

        // Start health checks if configured (Phase 6 - Task 6.2)
        if let deferred = deferredConfigs[dockerID],
           let healthConfig = deferred.healthcheck,
           let healthChecker = healthChecker {
            // Don't start health checks for NONE healthcheck
            if healthConfig.test != ["NONE"] {
                logger.info("Starting health checks for container", metadata: [
                    "container": "\(dockerID)",
                    "interval": "\(healthConfig.interval ?? 30_000_000_000)ns"
                ])

                await healthChecker.start(
                    containerID: dockerID,
                    config: healthConfig,
                    containerStartTime: info.startedAt ?? Date()
                )
            } else {
                logger.debug("Health checks disabled (NONE) for container", metadata: ["container": "\(dockerID)"])
            }
        } else if let hostConfigHealthcheck = info.config.healthcheck,
                  let healthChecker = healthChecker {
            // Health check from persisted config (after daemon restart)
            if hostConfigHealthcheck.test != ["NONE"] {
                logger.info("Starting health checks for restarted container", metadata: [
                    "container": "\(dockerID)",
                    "interval": "\(hostConfigHealthcheck.interval ?? 30_000_000_000)ns"
                ])

                await healthChecker.start(
                    containerID: dockerID,
                    config: hostConfigHealthcheck,
                    containerStartTime: info.startedAt ?? Date()
                )
            } else {
                logger.debug("Health checks disabled (NONE) for restarted container", metadata: ["container": "\(dockerID)"])
            }
        }

        // Spawn background monitoring task to detect when container exits
        // The task waits for the container to exit, then calls back into the actor to update state
        let monitoringTask = Task { [weak self, logger, attachInfo] in
            do {
                logger.debug("Background monitor: waiting for container to exit", metadata: ["id": "\(dockerID)"])
                let exitStatus = try await nativeContainer.wait(timeoutInSeconds: nil)

                logger.info("Background monitor: container exited", metadata: [
                    "id": "\(dockerID)",
                    "exit_code": "\(exitStatus.exitCode)"
                ])

                // Signal exit to attach connection if present
                if let attach = attachInfo {
                    logger.debug("Signaling exit to attach connection", metadata: ["id": "\(dockerID)"])

                    // Close stdout/stderr writers to finish the stream continuations
                    try? attach.handles.stdout.close()
                    try? attach.handles.stderr.close()

                    // Signal exit
                    attach.exitSignal.yield(())
                    attach.exitSignal.finish()
                }

                // After wait() completes, we MUST call stop() to clean up the VM
                // and transition the container from .started to .stopped state
                // Reference: containerization/examples/ctr-example/main.swift
                logger.debug("Background monitor: stopping container to clean up VM", metadata: ["id": "\(dockerID)"])
                try await nativeContainer.stop()

                // Update container state via actor-isolated method
                await self?.updateContainerStateAfterExit(
                    dockerID: dockerID,
                    exitCode: Int(exitStatus.exitCode)
                )
            } catch {
                // Error waiting for container - this typically means the VM crashed
                // (e.g., kernel panic) and the vsock connection dropped.
                // Treat this as an abnormal exit and trigger restart policy.
                logger.warning("Background monitor: VM appears to have crashed", metadata: [
                    "id": "\(dockerID)",
                    "error": "\(error)"
                ])

                // Signal exit to attach connection even on error
                if let attach = attachInfo {
                    // Close stdout/stderr writers to finish the stream continuations
                    try? attach.handles.stdout.close()
                    try? attach.handles.stderr.close()

                    // Signal exit
                    attach.exitSignal.yield(())
                    attach.exitSignal.finish()
                }

                // Try to clean up the crashed VM resources
                // This may fail if the VM is already gone, but that's fine
                do {
                    try await nativeContainer.stop()
                    logger.debug("Background monitor: cleaned up crashed VM", metadata: ["id": "\(dockerID)"])
                } catch {
                    logger.debug("Background monitor: VM cleanup failed (already gone?)", metadata: [
                        "id": "\(dockerID)",
                        "error": "\(error)"
                    ])
                }

                // Update state and trigger restart policy
                // Exit code 137 = killed by SIGKILL (appropriate for VM crash)
                await self?.updateContainerStateAfterExit(
                    dockerID: dockerID,
                    exitCode: 137
                )
            }
        }

        monitoringTasks[dockerID] = monitoringTask

        // Emit container start event (after all initialization is complete)
        if let eventEmitter = eventEmitter, let info = containers[dockerID] {
            var attributes: [String: String] = [
                "name": info.name ?? "",
                "image": info.config.image
            ]
            // Add labels
            for (key, value) in info.config.labels {
                attributes[key] = value
            }
            await eventEmitter.emitContainerEvent(
                action: "start",
                containerID: dockerID,
                attributes: attributes
            )
        }
    }

    /// Stop a container
    public func stopContainer(id: String, timeout: Int? = nil) async throws {
        logger.info("Stopping container", metadata: [
            "id": "\(id)",
            "timeout": "\(timeout ?? 10)"
        ])

        // Resolve name or ID to Docker ID
        guard let dockerID = resolveContainerID(id) else {
            throw ContainerManagerError.containerNotFound(id)
        }

        guard var info = containers[dockerID] else {
            throw ContainerManagerError.containerNotFound(id)
        }

        // If container is already stopped/exited, this is a no-op (idempotent stop)
        // This handles containers loaded from database after daemon restart (no native container object)
        if info.state == "exited" || info.state == "dead" || info.state == "created" {
            logger.info("Container already stopped", metadata: [
                "id": "\(dockerID)",
                "state": "\(info.state)"
            ])
            return
        }

        // Get the native container object (must exist for running containers)
        guard let nativeContainer = nativeContainers[dockerID] else {
            logger.error("Native container not found for running container", metadata: [
                "id": "\(dockerID)",
                "state": "\(info.state)"
            ])
            throw ContainerManagerError.containerNotFound(id)
        }

        // Cancel monitoring task if running
        if let task = monitoringTasks.removeValue(forKey: dockerID) {
            task.cancel()
        }

        // Stop health checks if running (Phase 6 - Task 6.2)
        if let healthChecker = healthChecker {
            await healthChecker.stop(containerID: dockerID)
            logger.debug("Stopped health checks for container", metadata: ["container": "\(dockerID)"])
        }

        // Stop the container using Containerization API
        logger.info("Stopping container with Containerization API", metadata: ["id": "\(dockerID)"])
        try await nativeContainer.stop()

        // Push DNS topology updates to remove this container from other containers' view
        for networkID in info.networkAttachments.keys {
            await pushDNSTopologyToNetwork(networkID: networkID)
        }

        // Unpublish ports if configured (Phase 4.1)
        // NOTE: We pass nil for wireguardClient because the VM is already stopped.
        // The nftables rules inside the container are gone with the VM, so there's
        // nothing to clean up via gRPC. We only need to stop the host-side proxies.
        if let portMapManager = portMapManager,
           !info.hostConfig.portBindings.isEmpty {
            do {
                try await portMapManager.unpublishPorts(
                    containerID: dockerID,
                    wireguardClient: nil  // VM is stopped, can't use vsock
                )
                logger.info("Unpublished port mappings for container", metadata: [
                    "container": "\(dockerID)"
                ])
            } catch {
                logger.warning("Failed to unpublish port mappings", metadata: [
                    "container": "\(dockerID)",
                    "error": "\(error)"
                ])
                // Don't fail container stop on port unpublishing errors
            }
        }

        // Clean up in-memory network state (TAP devices are auto-cleaned by VM shutdown)
        if let networkManager = networkManager {
            await networkManager.cleanupStoppedContainer(containerID: dockerID)
        }

        // Update state
        info.state = "exited"
        info.finishedAt = Date()
        info.exitCode = 0
        info.pid = 0
        containers[dockerID] = info

        // Persist state change (mark as stopped by user)
        try await persistContainerState(dockerID: dockerID, info: info, stoppedByUser: true)

        logger.info("Container stopped successfully", metadata: [
            "id": "\(dockerID)",
            "state": "exited"
        ])

        // Emit container stop event
        if let eventEmitter = eventEmitter {
            var attributes: [String: String] = [
                "name": info.name ?? "",
                "image": info.config.image,
                "exitCode": "\(info.exitCode)"
            ]
            // Add labels
            for (key, value) in info.config.labels {
                attributes[key] = value
            }
            await eventEmitter.emitContainerEvent(
                action: "stop",
                containerID: dockerID,
                attributes: attributes
            )
        }
    }

    /// Kill a container by sending a signal (Phase 5 - Task 5.4)
    public func killContainer(id: String, signal: String = "SIGKILL") async throws {
        logger.info("Killing container", metadata: [
            "id": "\(id)",
            "signal": "\(signal)"
        ])

        // Resolve name or ID to Docker ID
        guard let dockerID = resolveContainerID(id) else {
            throw ContainerManagerError.containerNotFound(id)
        }

        guard let info = containers[dockerID] else {
            throw ContainerManagerError.containerNotFound(id)
        }

        // Verify container is running
        guard info.state == "running" else {
            logger.error("Container is not running", metadata: [
                "id": "\(dockerID)",
                "state": "\(info.state)"
            ])
            throw ContainerManagerError.containerNotRunning(id)
        }

        // Get the native container object
        guard let nativeContainer = nativeContainers[dockerID] else {
            logger.error("Native container not found", metadata: ["id": "\(dockerID)"])
            throw ContainerManagerError.containerNotFound(id)
        }

        // Parse signal string to Int32
        let signalNumber = parseSignal(signal)

        logger.info("Sending signal to container", metadata: [
            "id": "\(dockerID)",
            "signal": "\(signal)",
            "signal_number": "\(signalNumber)"
        ])

        // Send signal to container using Containerization API
        try await nativeContainer.kill(signalNumber)

        logger.info("Signal sent to container successfully", metadata: [
            "id": "\(dockerID)",
            "signal": "\(signal)"
        ])
    }

    /// Parse signal string to Int32 signal number
    private func parseSignal(_ signal: String) -> Int32 {
        // Remove SIG prefix if present
        let normalizedSignal = signal.uppercased().hasPrefix("SIG")
            ? String(signal.uppercased().dropFirst(3))
            : signal.uppercased()

        // Try parsing as number first
        if let num = Int32(normalizedSignal) {
            return num
        }

        // Map common signal names to numbers
        switch normalizedSignal {
        case "HUP": return 1
        case "INT": return 2
        case "QUIT": return 3
        case "KILL": return 9
        case "TERM": return 15
        case "USR1": return 10
        case "USR2": return 12
        case "ALRM": return 14
        case "CONT": return 18
        case "STOP": return 19
        case "TSTP": return 20
        case "TTIN": return 21
        case "TTOU": return 22
        default:
            // Default to SIGKILL if unknown
            logger.warning("Unknown signal name, defaulting to SIGKILL", metadata: ["signal": "\(signal)"])
            return 9
        }
    }

    /// Pause a running container
    /// Note: pause/resume was removed from Apple's Containerization framework (PR #366)
    public func pauseContainer(id: String) async throws {
        logger.info("Pausing container", metadata: ["id": "\(id)"])

        // Resolve name or ID to Docker ID
        guard let dockerID = resolveContainerID(id) else {
            throw ContainerManagerError.containerNotFound(id)
        }

        guard containers[dockerID] != nil else {
            throw ContainerManagerError.containerNotFound(id)
        }

        // pause/resume was removed from Apple's Containerization framework
        // See: https://github.com/apple/containerization/pull/366
        throw ContainerManagerError.invalidConfiguration("Container pause is not supported by the underlying runtime")
    }

    /// Unpause a paused container
    /// Note: pause/resume was removed from Apple's Containerization framework (PR #366)
    public func unpauseContainer(id: String) async throws {
        logger.info("Unpausing container", metadata: ["id": "\(id)"])

        // Resolve name or ID to Docker ID
        guard let dockerID = resolveContainerID(id) else {
            throw ContainerManagerError.containerNotFound(id)
        }

        guard containers[dockerID] != nil else {
            throw ContainerManagerError.containerNotFound(id)
        }

        // pause/resume was removed from Apple's Containerization framework
        // See: https://github.com/apple/containerization/pull/366
        throw ContainerManagerError.invalidConfiguration("Container unpause is not supported by the underlying runtime")
    }

    /// Get container statistics
    public func getContainerStats(id: String) async throws -> Containerization.ContainerStatistics {
        logger.info("Getting container statistics", metadata: ["id": "\(id)"])

        // Resolve name or ID to Docker ID
        guard let dockerID = resolveContainerID(id) else {
            throw ContainerManagerError.containerNotFound(id)
        }

        guard let info = containers[dockerID] else {
            throw ContainerManagerError.containerNotFound(id)
        }

        // Verify container is running
        guard info.state == "running" else {
            throw ContainerManagerError.invalidConfiguration("Container is not running")
        }

        // Get native container
        guard let nativeContainer = nativeContainers[dockerID] else {
            throw ContainerManagerError.containerNotFound(dockerID)
        }

        // Get statistics from Containerization API
        let stats = try await nativeContainer.statistics()

        logger.debug("Container statistics retrieved", metadata: [
            "id": "\(dockerID)",
            "memory_usage": "\(stats.memory.usageBytes)",
            "cpu_usage": "\(stats.cpu.usageUsec)"
        ])

        return stats
    }

    /// Rename a container
    public func renameContainer(id: String, newName: String) async throws {
        logger.info("Renaming container", metadata: [
            "id": "\(id)",
            "newName": "\(newName)"
        ])

        // Resolve name or ID to Docker ID
        guard let dockerID = resolveContainerID(id) else {
            throw ContainerManagerError.containerNotFound(id)
        }

        guard let info = containers[dockerID] else {
            throw ContainerManagerError.containerNotFound(id)
        }

        // Update in-memory state
        var updatedInfo = info
        updatedInfo.name = newName
        containers[dockerID] = updatedInfo

        // Update database (will throw if name already exists due to UNIQUE constraint)
        do {
            try await stateStore.updateContainerName(id: dockerID, newName: newName)
        } catch {
            // Rollback in-memory change
            containers[dockerID] = info
            throw ContainerManagerError.invalidConfiguration("Name '\(newName)' is already in use")
        }

        logger.info("Container renamed successfully", metadata: [
            "id": "\(dockerID)",
            "oldName": "\(info.name ?? "none")",
            "newName": "\(newName)"
        ])
    }

    /// Remove a container
    public func removeContainer(id: String, force: Bool = false, removeVolumes: Bool = false) async throws {
        logger.info("Removing container", metadata: [
            "id": "\(id)",
            "force": "\(force)"
        ])

        // Resolve name or ID to Docker ID
        guard let dockerID = resolveContainerID(id) else {
            throw ContainerManagerError.containerNotFound(id)
        }

        guard let info = containers[dockerID] else {
            throw ContainerManagerError.containerNotFound(id)
        }

        // Check if container is running and force is not set
        if info.state == "running" && !force {
            throw ContainerManagerError.containerRunning(id)
        }

        // Check if the native container object exists
        // After daemon restart, this will be nil even though metadata persists
        if let nativeContainer = nativeContainers[dockerID] {
            // Container exists in framework - stop it before removal
            logger.debug("Native container exists, stopping before removal", metadata: ["id": "\(dockerID)"])

            // CRITICAL: Stop the container FIRST before waiting for monitoring task
            // This avoids deadlock where monitoring task is waiting for container to exit
            // and we're waiting for monitoring task to finish
            if info.state == "running" || info.state == "created" {
                if force || info.state == "created" {
                    logger.info("Stopping container before removal", metadata: [
                        "id": "\(dockerID)",
                        "state": "\(info.state)"
                    ])
                    try? await nativeContainer.stop()
                } else if !force && info.state == "running" {
                    // Already checked above, but being explicit
                    throw ContainerManagerError.containerRunning(id)
                }
            }

            // Cancel monitoring task if running and wait for it to complete
            // Safe to wait now since we've already stopped the container above
            if let task = monitoringTasks.removeValue(forKey: dockerID) {
                task.cancel()
                // Wait for the task to fully complete to avoid file descriptor races
                _ = await task.result
            }

            // For exited containers, still call stop() to ensure cleanup
            if info.state == "exited" {
                logger.debug("Calling stop() on exited container for cleanup", metadata: ["id": "\(dockerID)"])
                try? await nativeContainer.stop()
            }
        } else {
            // Container NOT in framework - only exists in database (persisted state)
            // This happens after daemon restart when container was never recreated
            logger.info("Removing database-only container (not in framework)", metadata: [
                "id": "\(dockerID)",
                "state": "\(info.state)"
            ])

            // No need to stop native container since it doesn't exist
            // Just clean up any monitoring tasks
            if let task = monitoringTasks.removeValue(forKey: dockerID) {
                task.cancel()
                _ = await task.result
            }
        }

        // Unpublish ports (cleans up host-side proxies and port allocations)
        // NOTE: We pass nil for wireguardClient because the VM is already stopped.
        // The nftables rules inside the container are gone with the VM, so there's
        // nothing to clean up via gRPC. We only need to stop the host-side proxies.
        if let portMapManager = portMapManager,
           !info.hostConfig.portBindings.isEmpty {
            do {
                try await portMapManager.unpublishPorts(
                    containerID: dockerID,
                    wireguardClient: nil  // VM is stopped, can't use vsock
                )
                logger.info("Unpublished port mappings before removal", metadata: [
                    "container": "\(dockerID)"
                ])
            } catch {
                logger.warning("Failed to unpublish port mappings during removal", metadata: [
                    "container": "\(dockerID)",
                    "error": "\(error)"
                ])
                // Don't fail container removal on port unpublishing errors
            }
        }

        // Detach from all networks before removal
        // This updates the network's container list and removes IP allocations
        if let networkManager = networkManager, !info.networkAttachments.isEmpty {
            // Only detach if we have a native container object
            // For database-only containers (after daemon restart), skip detachment since
            // the container's network interfaces don't exist anyway
            if let nativeContainer = nativeContainers[dockerID] {
                logger.info("Detaching container from networks", metadata: [
                    "container": "\(dockerID)",
                    "network_count": "\(info.networkAttachments.count)"
                ])

                for networkID in info.networkAttachments.keys {
                    do {
                        // Detach from network (this removes from network's container list)
                        try await networkManager.detachContainerFromNetwork(
                            containerID: dockerID,
                            container: nativeContainer,
                            networkID: networkID
                        )
                        logger.debug("Detached container from network", metadata: [
                            "container": "\(dockerID)",
                            "network": "\(networkID)"
                        ])
                    } catch {
                        // Log but don't fail - network might already be deleted
                        logger.warning("Failed to detach from network (may already be deleted)", metadata: [
                            "container": "\(dockerID)",
                            "network": "\(networkID)",
                            "error": "\(error)"
                        ])
                    }
                }
            } else {
                // Database-only container - just clean up in-memory state
                logger.info("Skipping network detachment for database-only container", metadata: [
                    "container": "\(dockerID)",
                    "network_count": "\(info.networkAttachments.count)"
                ])

                // Clean up in-memory state in NetworkManager
                await networkManager.cleanupStoppedContainer(containerID: dockerID)

                // Delete network attachment records from StateStore
                for networkID in info.networkAttachments.keys {
                    do {
                        try await stateStore.deleteNetworkAttachment(
                            containerID: dockerID,
                            networkID: networkID
                        )
                        logger.debug("Deleted network attachment record", metadata: [
                            "container": "\(dockerID)",
                            "network": "\(networkID)"
                        ])
                    } catch {
                        logger.warning("Failed to delete network attachment record", metadata: [
                            "container": "\(dockerID)",
                            "network": "\(networkID)",
                            "error": "\(error)"
                        ])
                    }
                }
            }
        }

        // Push DNS topology updates to remove this container from other containers' view
        for networkID in info.networkAttachments.keys {
            await pushDNSTopologyToNetwork(networkID: networkID)
        }

        logger.info("Removing container from tracking", metadata: ["id": "\(dockerID)"])

        // Clean up all state
        nativeContainers.removeValue(forKey: dockerID)
        if let nativeID = idMapping[dockerID] {
            reverseMapping.removeValue(forKey: nativeID)
        }
        idMapping.removeValue(forKey: dockerID)
        containers.removeValue(forKey: dockerID)

        // Clean up volumes before deleting container
        await cleanupVolumesForContainer(dockerID: dockerID)

        // Delete from persistent storage (CASCADE will delete volume mounts)
        try await stateStore.deleteContainer(id: dockerID)

        // Close and remove log files
        if let (stdoutWriter, stderrWriter) = logWriters.removeValue(forKey: dockerID) {
            try? stdoutWriter.close()
            try? stderrWriter.close()
        }
        try? logManager.removeLogs(dockerID: dockerID)

        logger.info("Container removed successfully", metadata: [
            "id": "\(dockerID)"
        ])

        // Emit container destroy event
        if let eventEmitter = eventEmitter {
            var attributes: [String: String] = [
                "name": info.name ?? "",
                "image": info.config.image
            ]
            // Add labels
            for (key, value) in info.config.labels {
                attributes[key] = value
            }
            await eventEmitter.emitContainerEvent(
                action: "destroy",
                containerID: dockerID,
                attributes: attributes
            )
        }
    }

    /// Wait for a container to exit
    public func waitContainer(id: String, timeout: Int64? = nil) async throws -> Int {
        logger.info("Waiting for container to exit", metadata: ["id": "\(id)"])

        // Resolve name or ID to Docker ID
        guard let dockerID = resolveContainerID(id) else {
            throw ContainerManagerError.containerNotFound(id)
        }

        guard var info = containers[dockerID] else {
            throw ContainerManagerError.containerNotFound(id)
        }

        // If container is already exited, return the exit code immediately
        if info.state == "exited" {
            logger.info("Container already exited", metadata: [
                "id": "\(dockerID)",
                "exit_code": "\(info.exitCode)"
            ])
            return info.exitCode
        }

        // If container is in created state, Docker CLI expects us to wait for it to finish
        // But the Containerization API wait() requires the container to be running
        // So we return 0 immediately for created containers (they haven't run yet)
        if info.state == "created" {
            logger.debug("Container in created state, returning 0", metadata: ["id": "\(dockerID)"])
            return 0
        }

        // Get the native container object
        guard let nativeContainer = nativeContainers[dockerID] else {
            logger.error("Native container not found", metadata: ["id": "\(dockerID)"])
            throw ContainerManagerError.containerNotFound(id)
        }

        // Wait for the container process to exit
        let exitStatus = try await nativeContainer.wait(timeoutInSeconds: timeout)

        // Update container state to exited
        info.state = "exited"
        info.exitCode = Int(exitStatus.exitCode)
        info.finishedAt = Date()
        info.pid = 0
        containers[dockerID] = info

        // Persist container state (not stopped by user - this was a natural exit from wait)
        try await persistContainerState(dockerID: dockerID, info: info, stoppedByUser: false)

        logger.info("Container exited", metadata: [
            "id": "\(dockerID)",
            "exit_code": "\(exitStatus.exitCode)"
        ])

        return Int(exitStatus.exitCode)
    }

    /// Update a container's resource configuration
    /// Phase 6 - Task 6.1: Container Update Endpoint
    ///
    /// Updates resource limits and restart policy. Returns warnings if some updates
    /// cannot be applied immediately (e.g., to running containers).
    public func updateContainer(
        id: String,
        memory: Int64? = nil,
        memoryReservation: Int64? = nil,
        memorySwap: Int64? = nil,
        memorySwappiness: Int? = nil,
        nanoCpus: Int64? = nil,
        cpuShares: Int64? = nil,
        cpuPeriod: Int64? = nil,
        cpuQuota: Int64? = nil,
        cpusetCpus: String? = nil,
        cpusetMems: String? = nil,
        pidsLimit: Int64? = nil,
        blkioWeight: Int? = nil,
        oomKillDisable: Bool? = nil,
        restartPolicyName: String? = nil,
        restartPolicyMaxRetryCount: Int? = nil
    ) async throws -> [String] {
        logger.info("Updating container", metadata: ["id": "\(id)"])

        // Resolve name or ID to Docker ID
        guard let dockerID = resolveContainerID(id) else {
            throw ContainerManagerError.containerNotFound(id)
        }

        guard var info = containers[dockerID] else {
            throw ContainerManagerError.containerNotFound(id)
        }

        logger.debug("Container hostConfig before update", metadata: [
            "memory": "\(info.hostConfig.memory)",
            "memoryReservation": "\(info.hostConfig.memoryReservation)",
            "memorySwap": "\(info.hostConfig.memorySwap)",
            "cpuShares": "\(info.hostConfig.cpuShares)",
            "nanoCpus": "\(info.hostConfig.nanoCpus)"
        ])

        var warnings: [String] = []

        // Determine effective memory and memory reservation values after update
        // Docker sends 0 for "don't change this value" in update requests
        // Only use new value if it's non-nil AND non-zero (except memorySwap where -1 = unlimited, 0 = don't change)
        let effectiveMemory = (memory != nil && memory! > 0) ? memory! : info.hostConfig.memory
        let effectiveMemoryReservation = (memoryReservation != nil && memoryReservation! > 0) ? memoryReservation! : info.hostConfig.memoryReservation
        let effectiveMemorySwap = (memorySwap != nil && memorySwap! != 0) ? memorySwap! : info.hostConfig.memorySwap

        logger.debug("Validating memory limits", metadata: [
            "effectiveMemory": "\(effectiveMemory)",
            "effectiveMemoryReservation": "\(effectiveMemoryReservation)",
            "requestMemory": "\(memory?.description ?? "nil")",
            "requestMemoryReservation": "\(memoryReservation?.description ?? "nil")"
        ])

        // Validate memory limits against effective values
        if effectiveMemory > 0 && effectiveMemoryReservation > 0 && effectiveMemoryReservation > effectiveMemory {
            logger.error("Memory reservation validation failed", metadata: [
                "effectiveMemory": "\(effectiveMemory)",
                "effectiveMemoryReservation": "\(effectiveMemoryReservation)"
            ])
            throw ContainerManagerError.invalidParameter("Memory reservation cannot be greater than memory limit")
        }

        if effectiveMemory > 0 && effectiveMemorySwap > 0 && effectiveMemorySwap < effectiveMemory {
            throw ContainerManagerError.invalidParameter("Memory swap must be greater than or equal to memory limit")
        }

        // Validate CPU limits if provided
        if let cpuQuota = cpuQuota, let cpuPeriod = cpuPeriod {
            if cpuPeriod > 0 && cpuQuota > 0 && cpuQuota > cpuPeriod {
                warnings.append("CPU quota should not exceed CPU period")
            }
        }

        // Create updated HostConfig with merged values
        let updatedRestartPolicy: RestartPolicy
        if let policyName = restartPolicyName {
            updatedRestartPolicy = RestartPolicy(
                name: policyName,
                maximumRetryCount: restartPolicyMaxRetryCount ?? 0
            )
        } else {
            updatedRestartPolicy = info.hostConfig.restartPolicy
        }

        let updatedHostConfig = HostConfig(
            binds: info.hostConfig.binds,
            networkMode: info.hostConfig.networkMode,
            portBindings: info.hostConfig.portBindings,
            restartPolicy: updatedRestartPolicy,
            autoRemove: info.hostConfig.autoRemove,
            volumeDriver: info.hostConfig.volumeDriver,
            privileged: info.hostConfig.privileged,
            // Use effectiveMemory values calculated above (treats 0 as "don't change")
            memory: effectiveMemory,
            memoryReservation: effectiveMemoryReservation,
            memorySwap: effectiveMemorySwap,
            memorySwappiness: (memorySwappiness != nil && memorySwappiness! >= -1) ? memorySwappiness! : info.hostConfig.memorySwappiness,
            nanoCpus: (nanoCpus != nil && nanoCpus! > 0) ? nanoCpus! : info.hostConfig.nanoCpus,
            cpuShares: (cpuShares != nil && cpuShares! > 0) ? cpuShares! : info.hostConfig.cpuShares,
            cpuPeriod: (cpuPeriod != nil && cpuPeriod! > 0) ? cpuPeriod! : info.hostConfig.cpuPeriod,
            cpuQuota: (cpuQuota != nil && cpuQuota! > 0) ? cpuQuota! : info.hostConfig.cpuQuota,
            cpusetCpus: (cpusetCpus != nil && !cpusetCpus!.isEmpty) ? cpusetCpus! : info.hostConfig.cpusetCpus,
            cpusetMems: (cpusetMems != nil && !cpusetMems!.isEmpty) ? cpusetMems! : info.hostConfig.cpusetMems,
            groupAdd: info.hostConfig.groupAdd,
            capAdd: info.hostConfig.capAdd,
            capDrop: info.hostConfig.capDrop,
            securityOpt: info.hostConfig.securityOpt,
            extraHosts: info.hostConfig.extraHosts
        )

        // Update container info with new HostConfig
        info.hostConfig = updatedHostConfig
        containers[dockerID] = info

        // Persist the updated configuration to database
        try await persistContainerState(dockerID: dockerID, info: info, stoppedByUser: false)

        // Add warning about runtime updates
        if info.state == "running" {
            // According to Docker, some updates can be applied hot to running containers
            // However, with Apple's Containerization framework, we may have limitations
            if memory != nil || memoryReservation != nil || memorySwap != nil ||
               nanoCpus != nil || cpuShares != nil || cpuPeriod != nil || cpuQuota != nil {
                warnings.append("Resource limit updates will take effect on next container restart")
            }
        }

        logger.info("Container updated successfully", metadata: [
            "id": "\(dockerID)",
            "warnings": "\(warnings.count)"
        ])

        return warnings
    }

    // MARK: - Background Monitoring Helpers

    /// Update container state after it exits (called by background monitoring task)
    private func updateContainerStateAfterExit(dockerID: String, exitCode: Int) async {
        guard var containerInfo = containers[dockerID] else {
            logger.warning("Container not found when updating exit state", metadata: ["id": "\(dockerID)"])
            return
        }

        containerInfo.state = "exited"
        containerInfo.exitCode = exitCode
        containerInfo.finishedAt = Date()
        containerInfo.pid = 0
        containers[dockerID] = containerInfo

        // Clean up in-memory network state (TAP devices are auto-cleaned by VM shutdown)
        if let networkManager = networkManager {
            await networkManager.cleanupStoppedContainer(containerID: dockerID)
        }

        // Clean up FilesystemClient
        filesystemClients.removeValue(forKey: dockerID)
        logger.debug("Cleaned up FilesystemClient", metadata: ["container": "\(dockerID)"])

        // Persist container state (not stopped by user - this was a natural exit)
        do {
            try await persistContainerState(dockerID: dockerID, info: containerInfo, stoppedByUser: false)
        } catch {
            logger.error("Failed to persist container exit state", metadata: [
                "id": "\(dockerID)",
                "error": "\(error)"
            ])
        }

        // Clean up monitoring task
        monitoringTasks.removeValue(forKey: dockerID)

        logger.debug("Container state updated after exit", metadata: [
            "id": "\(dockerID)",
            "exit_code": "\(exitCode)"
        ])

        // Emit container die event
        if let eventEmitter = eventEmitter {
            var attributes: [String: String] = [
                "name": containerInfo.name ?? "",
                "image": containerInfo.config.image,
                "exitCode": "\(exitCode)"
            ]
            // Add labels
            for (key, value) in containerInfo.config.labels {
                attributes[key] = value
            }
            await eventEmitter.emitContainerEvent(
                action: "die",
                containerID: dockerID,
                attributes: attributes
            )
        }

        // Check restart policy and restart if needed
        await handleRestartPolicy(dockerID: dockerID, exitCode: exitCode, stoppedByUser: false)
    }

    /// Handle restart policy for a container that has exited
    private func handleRestartPolicy(dockerID: String, exitCode: Int, stoppedByUser: Bool) async {
        guard let containerInfo = containers[dockerID] else {
            return
        }

        let policy = containerInfo.hostConfig.restartPolicy

        // Determine if container should restart based on policy
        let shouldRestart: Bool
        switch policy.name {
        case "always":
            shouldRestart = true
        case "unless-stopped":
            shouldRestart = !stoppedByUser
        case "on-failure":
            shouldRestart = exitCode != 0
        default:
            shouldRestart = false
        }

        if shouldRestart {
            logger.info("Container will be restarted per restart policy", metadata: [
                "id": "\(dockerID)",
                "name": "\(containerInfo.name ?? dockerID)",
                "policy": "\(policy.name)",
                "exit_code": "\(exitCode)",
                "stopped_by_user": "\(stoppedByUser)"
            ])

            // Add a small delay before restarting to avoid rapid restart loops
            try? await Task.sleep(for: .seconds(1))

            do {
                try await startContainer(id: dockerID)
                logger.info("Container restarted successfully", metadata: [
                    "id": "\(dockerID)",
                    "name": "\(containerInfo.name ?? dockerID)"
                ])
            } catch {
                logger.error("Failed to restart container", metadata: [
                    "id": "\(dockerID)",
                    "name": "\(containerInfo.name ?? dockerID)",
                    "error": "\(error)"
                ])
            }
        } else {
            logger.debug("Container will NOT be restarted", metadata: [
                "id": "\(dockerID)",
                "policy": "\(policy.name)",
                "exit_code": "\(exitCode)",
                "stopped_by_user": "\(stoppedByUser)"
            ])
        }
    }

    /// Clean up monitoring task (called when monitoring fails)
    private func cleanupMonitoringTask(dockerID: String) {
        monitoringTasks.removeValue(forKey: dockerID)
    }

    // MARK: - Log Management

    /// Get log paths for a container
    nonisolated public func getLogPaths(dockerID: String) -> ContainerLogManager.LogPaths? {
        return logManager.getLogPaths(dockerID: dockerID)
    }

    // MARK: - Network Operations

    /// Attach a container to a network
    /// This method is called by NetworkManager after allocating IP and creating the attachment
    /// If the container is running, it will be stopped, reconfigured, and restarted
    public func attachContainerToNetwork(
        dockerID: String,
        networkID: String,
        ip: String,
        mac: String,
        aliases: [String]
    ) async throws {
        guard var containerInfo = containers[dockerID] else {
            throw ContainerManagerError.containerNotFound(dockerID)
        }

        logger.info("Attaching container to network", metadata: [
            "container": "\(dockerID)",
            "network": "\(networkID)",
            "ip": "\(ip)",
            "mac": "\(mac)"
        ])

        // Store network attachment
        let attachment = NetworkAttachment(
            networkID: networkID,
            ip: ip,
            mac: mac,
            aliases: aliases
        )
        containerInfo.networkAttachments[networkID] = attachment
        containers[dockerID] = containerInfo

        // Persist network attachment
        try await stateStore.saveNetworkAttachment(
            containerID: dockerID,
            networkID: networkID,
            ipAddress: ip,
            macAddress: mac,
            aliases: aliases
        )

        // With TAP-over-vsock architecture, no container recreation needed
        // TAP devices are created dynamically via NetworkBridge.attachContainerToNetwork

        logger.info("Container attached to network", metadata: [
            "container": "\(dockerID)",
            "network": "\(networkID)"
        ])

        // Push DNS topology to this container (to add new network's peers)
        await pushDNSTopologyUpdate(to: dockerID)

        // Push DNS topology to all containers on this network (to add this container)
        await pushDNSTopologyToNetwork(networkID: networkID)
    }

    /// Detach a container from a network
    /// This method is called by NetworkManager before releasing the IP
    public func detachContainerFromNetwork(
        dockerID: String,
        networkID: String
    ) async throws {
        guard var containerInfo = containers[dockerID] else {
            throw ContainerManagerError.containerNotFound(dockerID)
        }

        logger.info("Detaching container from network", metadata: [
            "container": "\(dockerID)",
            "network": "\(networkID)"
        ])

        // Remove network attachment
        containerInfo.networkAttachments.removeValue(forKey: networkID)
        containers[dockerID] = containerInfo

        // Persist network detachment
        try await stateStore.deleteNetworkAttachment(
            containerID: dockerID,
            networkID: networkID
        )

        // If container is running, we would need to hot-unplug the network interface
        // For now, network changes require container restart
        // TODO: Implement hot-unplug if Apple Containerization supports it

        logger.info("Container detached from network", metadata: [
            "container": "\(dockerID)",
            "network": "\(networkID)"
        ])

        // Push DNS topology to this container (to remove detached network's peers)
        await pushDNSTopologyUpdate(to: dockerID)

        // Push DNS topology to all containers on this network (to remove this container)
        await pushDNSTopologyToNetwork(networkID: networkID)
    }

    /// Get network attachments for a container
    public func getNetworkAttachments(dockerID: String) async -> [String: NetworkAttachment] {
        return containers[dockerID]?.networkAttachments ?? [:]
    }

    /// Get container name by Docker ID
    public func getContainerName(dockerID: String) async -> String? {
        return containers[dockerID]?.name
    }

    /// Get container network mode by Docker ID
    public func getContainerNetworkMode(dockerID: String) async -> String? {
        return containers[dockerID]?.hostConfig.networkMode
    }

    // MARK: - Helpers for ExecManager

    /// Get container state by ID (for checking if container is running)
    public func getContainerState(id: String) async -> String? {
        guard let dockerID = resolveContainerID(id) else {
            return nil
        }
        return containers[dockerID]?.state
    }

    /// Get container TTY flag by ID (for attach/exec stream multiplexing)
    public func getContainerTTY(id: String) async -> Bool? {
        guard let dockerID = resolveContainerID(id) else {
            return nil
        }
        return containers[dockerID]?.tty
    }

    /// Check if container is running (for log streaming)
    public func isContainerRunning(dockerID: String) async -> Bool {
        return containers[dockerID]?.state == "running"
    }

    /// Get container's image reference (for HelperContainerManager to mount layers)
    public func getContainerImageRef(dockerID: String) async -> String? {
        return containers[dockerID]?.image
    }

    /// Get layer paths for a container's image (for HelperContainerManager OverlayFS setup)
    /// Returns array of layer.ext4 paths from the shared layer cache
    public func getImageLayerPaths(imageRef: String) async throws -> [String] {
        // Get image from ImageManager
        let image = try await imageManager.getImage(nameOrId: imageRef)

        // Get platform
        let systemPlatform = detectSystemPlatform()
        let imagePlatform = systemPlatform.ociPlatform()

        // Unpack to get layer config (uses cache, so fast if already unpacked)
        guard let unpacker = overlayUnpacker else {
            throw ContainerManagerError.notInitialized
        }

        // We need to get the layer paths from the cache
        // The OverlayFSUnpacker stores layers in ~/.arca/layers/{digest}/layer.ext4
        // We need to unpack to get the paths (uses cache so this is fast)
        // Create a temp directory for unpacking - we only need the layer paths
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let config = try await unpacker.unpack(image, for: imagePlatform, at: tempDir)

        // Extract layer paths from the config
        return config.lowerLayers.map { $0.path }
    }

    /// Get layer cache base path
    public func getLayerCachePath() -> String {
        return NSString(string: "~/.arca/layers").expandingTildeInPath
    }

    /// Check if container should continue streaming logs
    /// Returns true for non-terminal states (created, running, restarting, paused)
    /// Returns false for terminal states (exited, dead, removing) or if container doesn't exist
    public func shouldStreamLogs(dockerID: String) async -> Bool {
        guard let state = containers[dockerID]?.state else {
            return false  // Container doesn't exist
        }

        // Continue streaming for non-terminal states
        switch state {
        case "created", "running", "restarting", "paused":
            return true
        case "exited", "dead", "removing":
            return false
        default:
            // Unknown state - assume non-terminal to be safe
            return true
        }
    }

    /// Get native container instance by ID (for exec operations)
    public func getNativeContainer(id: String) async -> LinuxContainer? {
        guard let dockerID = resolveContainerID(id) else {
            return nil
        }
        return nativeContainers[dockerID]
    }

    /// Get LinuxContainer instance by Docker ID (for network operations)
    /// This is an alias for getNativeContainer but with a clearer name for networking context
    public func getLinuxContainer(dockerID: String) async throws -> LinuxContainer? {
        guard containers[dockerID] != nil else {
            throw ContainerManagerError.containerNotFound(dockerID)
        }
        return nativeContainers[dockerID]
    }

    /// Get the native (Apple Containerization) ID for a Docker ID
    /// Used by HelperContainerManager to locate container storage paths
    public func getNativeID(forDockerID dockerID: String) -> String? {
        return idMapping[dockerID]
    }

    // MARK: - Volume/Mount Helpers

    /// Parse Docker volume mount strings into Containerization.Mount objects
    /// Supports both bind mounts and named volumes:
    /// - Bind mounts: "/host/path:/container/path[:ro]" or "relative/path:/container/path[:ro]"
    /// - Named volumes: "volume-name:/container/path[:ro]"
    ///
    /// For file bind mounts, VirtioFS only supports directory shares, so:
    /// - Parent directory is mounted to unique location (/mnt/arca-file-mounts/<hash>/)
    /// - VirtioFS mounts are deduplicated (same parent dir = one VirtioFS mount)
    /// - VirtioFS mounts are collected first, then bind mounts are added after
    ///
    /// For Unix socket bind mounts (e.g., Docker socket for k3d/kind):
    /// - VirtioFS cannot relay socket connections
    /// - Uses Apple's UnixSocketConfiguration for vsock-based relay
    /// - Socket traffic is proxied through vsock between host and guest
    ///
    /// Returns: tuple of (mounts array, socket configurations array, direct mounts for local volumes)
    private func parseVolumeMounts(_ binds: [String]?, dockerID: String) async throws -> (mounts: [Containerization.Mount], socketConfigs: [Containerization.UnixSocketConfiguration], directMounts: [DirectMountConfig]) {
        guard let binds = binds else {
            return (mounts: [], socketConfigs: [], directMounts: [])
        }

        // Track direct mounts for local volumes (set up after container starts)
        // Uses EXT4 bind mounts instead of OverlayFS to allow nested overlays (e.g., containerd)
        var directMounts: [DirectMountConfig] = []

        // Track VirtioFS mounts separately to deduplicate and ensure they come before bind mounts
        var virtioFSMounts: [String: Containerization.Mount] = [:]  // parentDir -> mount
        var otherMounts: [Containerization.Mount] = []
        // Track file bind mounts that need VirtioFS mounts to be processed first
        var fileBindMounts: [(mount: Containerization.Mount, parentDir: String)] = []
        // Track volume bind mounts that need VirtioFS mounts to be processed first
        // This is used for local volumes to work around VirtioFS mount point permission issues
        var volumeBindMounts: [(mount: Containerization.Mount, volumeRoot: String)] = []
        // Track Unix socket configurations for vsock relay (k3d/kind support)
        var socketConfigs: [Containerization.UnixSocketConfiguration] = []

        for bind in binds {
            // Parse bind mount string properly, handling colons in paths (e.g., sha256:xxx)
            // Format: source:destination or source:destination:options
            // Options: ro, rw, z, Z, nocopy, consistent, delegated, cached, bind, etc.
            let (source, containerPath, isReadOnly) = parseBindMountString(bind)
            guard !source.isEmpty && !containerPath.isEmpty else {
                logger.warning("Invalid bind mount format, skipping", metadata: ["bind": "\(bind)"])
                continue
            }

            // Determine if this is a named volume or bind mount
            // Logic follows Docker's behavior:
            // 1. If source contains "/" or starts with "." or "~", it's a path (bind mount)
            // 2. Otherwise, check if it exists as a file/directory in current directory
            // 3. If not, treat it as a named volume
            let looksLikePath = source.contains("/") || source.hasPrefix(".") || source.hasPrefix("~")

            let expandedHostPath: String
            var isNamedVolume = false

            if looksLikePath {
                // It's a path - expand it (handles absolute, relative, and tilde paths)
                if source.hasPrefix("/") {
                    // Absolute path
                    expandedHostPath = source
                } else if source.hasPrefix("~") {
                    // Tilde path
                    expandedHostPath = NSString(string: source).expandingTildeInPath
                } else {
                    // Relative path - resolve to absolute
                    let currentDir = FileManager.default.currentDirectoryPath
                    expandedHostPath = NSString(string: currentDir).appendingPathComponent(source)
                }
            } else {
                // No path separators - could be a file in current directory or a named volume
                // Check if it exists as a file/directory in current directory
                let currentDir = FileManager.default.currentDirectoryPath
                let potentialPath = NSString(string: currentDir).appendingPathComponent(source)

                if FileManager.default.fileExists(atPath: potentialPath) {
                    // It's a file/directory in current directory - bind mount
                    expandedHostPath = potentialPath
                    logger.debug("Treating as bind mount to file in current directory", metadata: [
                        "source": "\(source)",
                        "resolvedPath": "\(expandedHostPath)"
                    ])
                } else {
                    // It doesn't exist - treat as named volume
                    guard let volumeManager = volumeManager else {
                        logger.error("Named volume requested but VolumeManager not available", metadata: [
                            "volume": "\(source)"
                        ])
                        throw ContainerManagerError.volumeManagerNotAvailable
                    }

                    // Try to get existing volume, or auto-create if it doesn't exist
                    // This matches Docker's behavior of creating volumes on first use
                    let volumeMetadata: VolumeManager.VolumeMetadata
                    do {
                        volumeMetadata = try await volumeManager.inspectVolume(name: source)
                        logger.info("Resolved existing named volume", metadata: [
                            "volume": "\(source)",
                            "mountpoint": "\(volumeMetadata.mountpoint)",
                            "format": "\(volumeMetadata.format)"
                        ])
                    } catch {
                        // Volume doesn't exist - auto-create it (Docker behavior)
                        logger.info("Auto-creating named volume", metadata: [
                            "volume": "\(source)"
                        ])
                        volumeMetadata = try await volumeManager.createVolume(
                            name: source,
                            driver: "local",
                            driverOpts: [:],
                            labels: [:]
                        )
                        logger.info("Created named volume", metadata: [
                            "volume": "\(source)",
                            "mountpoint": "\(volumeMetadata.mountpoint)",
                            "format": "\(volumeMetadata.format)"
                        ])
                    }
                    expandedHostPath = volumeMetadata.mountpoint
                    isNamedVolume = true
                }
            }

            // Create mount options
            var options: [String] = []
            if isReadOnly {
                options.append("ro")
            }

            // Create the appropriate mount type
            let mount: Containerization.Mount
            if isNamedVolume {
                // Named volumes: Branch on driver type
                guard let volumeManager = volumeManager else {
                    logger.error("Named volume requested but VolumeManager not available", metadata: [
                        "volume": "\(source)"
                    ])
                    throw ContainerManagerError.volumeManagerNotAvailable
                }

                let volumeMetadata = try await volumeManager.inspectVolume(name: source)

                // Validate exclusive access for block volumes
                try await volumeManager.validateVolumeAccess(volumeName: source, containerID: dockerID)

                switch volumeMetadata.driver {
                case "local":
                    // Local driver: Direct EXT4 mount for full POSIX compliance
                    // VirtioFS doesn't support chmod on Unix sockets (needed for k3d/kind)
                    // Solution: Use direct EXT4 bind mount from writable.ext4 (/dev/vdb)
                    // This provides:
                    // - Full POSIX compliance via EXT4
                    // - Unix socket support for k3s/kine database sockets
                    // - Allows nested OverlayFS (containerd can create its own overlays)
                    //
                    // Note: This means local volumes don't have host file access anymore.
                    // For host file access, use bind mounts (-v /host/path:/container/path)

                    // Track direct mount config for post-start EXT4 bind mount setup
                    // Go code creates directory on /dev/vdb at /mnt/writable/volumes/{volumeName}
                    // and bind mounts it to the container target path
                    directMounts.append(DirectMountConfig(
                        volumeName: source,
                        targetPath: containerPath
                    ))

                    logger.info("Local volume configured for direct EXT4 mount", metadata: [
                        "volume": "\(source)",
                        "targetPath": "\(containerPath)",
                        "readOnly": "\(isReadOnly)"
                    ])
                    continue  // Skip the otherMounts.append below - direct mounts are set up after start

                case "block":
                    // Block driver: Exclusive EXT4 block device
                    mount = Containerization.Mount.block(
                        format: "ext4",
                        source: volumeMetadata.mountpoint,  // volume.img path
                        destination: containerPath,
                        options: options
                    )
                    logger.debug("Created block device mount for block volume", metadata: [
                        "volume": "\(source)",
                        "blockDevice": "\(volumeMetadata.mountpoint)",
                        "destination": "\(containerPath)",
                        "readOnly": "\(isReadOnly)"
                    ])

                default:
                    throw ContainerManagerError.invalidConfiguration("Unsupported volume driver: \(volumeMetadata.driver)")
                }
            } else {
                // Bind mounts: Use VirtioFS share
                // Check if source is a file or directory (VirtioFS only supports directory shares)
                let fileManager = FileManager.default
                var isDirectory: ObjCBool = false
                let exists = fileManager.fileExists(atPath: expandedHostPath, isDirectory: &isDirectory)

                if !exists {
                    // Check if this looks like a socket path (common patterns)
                    // Don't try to auto-create sockets or paths in system directories
                    let isSystemPath = expandedHostPath.hasPrefix("/var/run/") ||
                                       expandedHostPath.hasPrefix("/run/") ||
                                       expandedHostPath.hasPrefix("/tmp/") && expandedHostPath.hasSuffix(".sock")
                    let looksLikeSocket = expandedHostPath.hasSuffix(".sock")

                    if isReadOnly || isSystemPath || looksLikeSocket {
                        logger.error("Bind mount source does not exist", metadata: [
                            "path": "\(expandedHostPath)",
                            "isReadOnly": "\(isReadOnly)",
                            "isSystemPath": "\(isSystemPath)",
                            "looksLikeSocket": "\(looksLikeSocket)"
                        ])
                        throw ContainerManagerError.volumeSourceNotFound(expandedHostPath)
                    } else {
                        // For read-write mounts to non-system paths, create directory if it doesn't exist
                        // (will create as directory, not file)
                        logger.info("Creating host directory for bind mount", metadata: [
                            "path": "\(expandedHostPath)"
                        ])
                        try fileManager.createDirectory(
                            atPath: expandedHostPath,
                            withIntermediateDirectories: true,
                            attributes: nil
                        )
                    }
                }

                // Check if this is a Unix socket (e.g., Docker socket for k3d/kind)
                // Unix sockets require vsock-based relay, not VirtioFS mounting
                var statInfo = stat()
                if stat(expandedHostPath, &statInfo) == 0 {
                    let fileType = statInfo.st_mode & S_IFMT
                    if fileType == S_IFSOCK {
                        // Unix socket: Use Apple's UnixSocketConfiguration for vsock relay
                        // This enables k3d, kind, and other tools that mount the Docker socket
                        let hostSocketURL = URL(fileURLWithPath: expandedHostPath)
                        let guestSocketURL = URL(fileURLWithPath: containerPath)

                        let socketConfig = Containerization.UnixSocketConfiguration(
                            source: hostSocketURL,
                            destination: guestSocketURL,
                            permissions: nil,
                            direction: .into
                        )
                        socketConfigs.append(socketConfig)

                        logger.info("Unix socket relay configured for k3d/kind support", metadata: [
                            "host_socket": "\(expandedHostPath)",
                            "guest_socket": "\(containerPath)"
                        ])
                        continue  // Socket relays are handled separately, skip mount creation
                    }
                }

                // Check if this is a file mount (VirtioFS limitation workaround)
                let isFile = exists && !isDirectory.boolValue
                if isFile {
                    // File bind mount: VirtioFS only supports directory shares
                    // Solution: Mount parent directory to unique location, then bind mount the file
                    let parentDir = (expandedHostPath as NSString).deletingLastPathComponent
                    let filename = (expandedHostPath as NSString).lastPathComponent

                    // Create unique mount point for parent directory using deterministic hash
                    // Must use hashMountSource() which is the same hash used for VirtioFS tags
                    // This ensures consistency between the VirtioFS mount and bind mount paths
                    let parentDirHash = try hashMountSource(source: parentDir)
                    let guestParentMount = "/mnt/arca-file-mounts/\(parentDirHash)"

                    // 1. Track VirtioFS mount for parent directory (deduplicated)
                    // Multiple files from the same parent dir share one VirtioFS mount
                    if virtioFSMounts[parentDir] == nil {
                        let virtiofsMount = Containerization.Mount.share(
                            source: parentDir,
                            destination: guestParentMount,
                            options: []  // Read-write at VirtioFS level
                        )
                        virtioFSMounts[parentDir] = virtiofsMount
                        logger.debug("Added VirtioFS mount for file bind mount parent", metadata: [
                            "parentDir": "\(parentDir)",
                            "guestParentMount": "\(guestParentMount)",
                            "hash": "\(parentDirHash)"
                        ])
                    }

                    // 2. Create bind mount from VirtioFS location to container path
                    // vmexec prefixes mount DESTINATIONS with rootfs path, but NOT sources
                    // So VirtioFS gets mounted at: /run/container/{id}/rootfs/mnt/arca-file-mounts/{hash}/
                    // We need the bind mount source to point there (with rootfs prefix)
                    let containerRootfs = "/run/container/\(dockerID)/rootfs"
                    let bindSource = "\(containerRootfs)\(guestParentMount)/\(filename)"

                    // For file bind mounts, we need to signal to vminitd that the target
                    // should be created as an empty file, not a directory
                    // ContainerizationOS.Mount.mountToTarget() uses mkdirAll which creates directories
                    var bindOptions = ["bind", "arca-file-bind"]
                    if isReadOnly {
                        bindOptions.append("ro")
                    }
                    mount = Containerization.Mount.any(
                        type: "",  // Bind mounts have no filesystem type
                        source: bindSource,
                        destination: containerPath,
                        options: bindOptions
                    )

                    // Track file bind mount to add after VirtioFS mounts
                    fileBindMounts.append((mount: mount, parentDir: parentDir))

                    logger.info("File bind mount: VirtioFS share + bind mount", metadata: [
                        "file": "\(expandedHostPath)",
                        "parentDir": "\(parentDir)",
                        "guestParentMount": "\(guestParentMount)",
                        "bindSource": "\(bindSource)",
                        "containerPath": "\(containerPath)",
                        "readOnly": "\(isReadOnly)"
                    ])
                    continue  // Skip the mounts.append below - file bind mounts are added later
                } else {
                    // Directory bind mount: Normal VirtioFS share
                    mount = Containerization.Mount.share(
                        source: expandedHostPath,
                        destination: containerPath,
                        options: options
                    )
                    logger.debug("Created VirtioFS share for directory bind mount", metadata: [
                        "source": "\(source)",
                        "resolvedPath": "\(expandedHostPath)",
                        "destination": "\(containerPath)",
                        "readOnly": "\(isReadOnly)"
                    ])
                }
            }

            otherMounts.append(mount)
        }

        // Build final mounts array with correct ordering:
        // 1. VirtioFS mounts for file/volume bind mount parent directories (must be mounted first)
        // 2. Other mounts (directory VirtioFS shares, block volumes)
        // 3. Volume bind mounts (depend on VirtioFS mounts being present)
        // 4. File bind mounts (depend on VirtioFS mounts being present)
        var mounts: [Containerization.Mount] = []

        // Add VirtioFS mounts first
        for (parentDir, virtiofsMount) in virtioFSMounts {
            mounts.append(virtiofsMount)
            logger.debug("Added VirtioFS mount to final mounts array", metadata: [
                "parentDir": "\(parentDir)",
                "destination": "\(virtiofsMount.destination)"
            ])
        }

        // Add other mounts (directory shares, block volumes)
        mounts.append(contentsOf: otherMounts)

        // Add volume bind mounts (they depend on VirtioFS mounts)
        for volumeBindMount in volumeBindMounts {
            mounts.append(volumeBindMount.mount)
            logger.debug("Added volume bind mount to final mounts array", metadata: [
                "source": "\(volumeBindMount.mount.source)",
                "destination": "\(volumeBindMount.mount.destination)",
                "volumeRoot": "\(volumeBindMount.volumeRoot)"
            ])
        }

        // Add file bind mounts last (they depend on VirtioFS mounts)
        for fileBindMount in fileBindMounts {
            mounts.append(fileBindMount.mount)
            logger.debug("Added file bind mount to final mounts array", metadata: [
                "source": "\(fileBindMount.mount.source)",
                "destination": "\(fileBindMount.mount.destination)",
                "parentDir": "\(fileBindMount.parentDir)"
            ])
        }

        logger.info("Parsed volume mounts", metadata: [
            "total_mounts": "\(mounts.count)",
            "virtiofs_mounts": "\(virtioFSMounts.count)",
            "volume_bind_mounts": "\(volumeBindMounts.count)",
            "file_bind_mounts": "\(fileBindMounts.count)",
            "other_mounts": "\(otherMounts.count)",
            "socket_relays": "\(socketConfigs.count)",
            "direct_mounts": "\(directMounts.count)"
        ])

        return (mounts: mounts, socketConfigs: socketConfigs, directMounts: directMounts)
    }

    /// Parse a bind mount string handling colons in paths (e.g., sha256:xxx)
    /// Format: source:destination or source:destination:options
    /// Returns: (source, destination, isReadOnly)
    private func parseBindMountString(_ bind: String) -> (source: String, destination: String, isReadOnly: Bool) {
        // Known mount options that can appear at the end
        let knownOptions = Set(["ro", "rw", "z", "Z", "nocopy", "consistent", "delegated", "cached",
                                "bind", "volume", "tmpfs", "shared", "slave", "private",
                                "rshared", "rslave", "rprivate"])

        // Split on colons
        let parts = bind.split(separator: ":", omittingEmptySubsequences: false).map { String($0) }

        // We need at least 2 parts for source:destination
        guard parts.count >= 2 else {
            return ("", "", false)
        }

        // Work backwards from the end to identify options and destination
        var options: [String] = []
        var destIndex = parts.count - 1

        // Check if the last part is an option
        if parts.count >= 3 && knownOptions.contains(parts[parts.count - 1].lowercased()) {
            options.append(parts[parts.count - 1])
            destIndex = parts.count - 2
        }

        // The destination should be a container path (starts with /)
        // Keep going backwards until we find a path starting with /
        while destIndex > 0 && !parts[destIndex].hasPrefix("/") {
            destIndex -= 1
        }

        // destIndex now points to the destination
        // Everything before is the source
        guard destIndex > 0 && parts[destIndex].hasPrefix("/") else {
            // Fallback: assume first part is source, second is destination
            let isReadOnly = parts.count >= 3 && parts[2].lowercased() == "ro"
            return (parts[0], parts[1], isReadOnly)
        }

        // Source is everything from index 0 to destIndex-1, joined by colons
        let source = parts[0..<destIndex].joined(separator: ":")
        let destination = parts[destIndex]
        let isReadOnly = options.contains { $0.lowercased() == "ro" }

        return (source, destination, isReadOnly)
    }

    /// Track volume mounts in StateStore for usage tracking
    private func trackVolumeMounts(
        dockerID: String,
        binds: [String],
        anonymousVolumes: [String]
    ) async throws {
        guard !binds.isEmpty else {
            return
        }

        // Parse binds to extract volume names (for named volumes)
        for bind in binds {
            let parts = bind.split(separator: ":")
            guard parts.count >= 2 else {
                continue  // Skip invalid binds
            }

            let source = String(parts[0])
            let containerPath = String(parts[1])

            // Determine if this is a named volume (vs bind mount)
            let looksLikePath = source.contains("/") || source.hasPrefix(".") || source.hasPrefix("~")

            if !looksLikePath {
                // This is a named volume - record it in StateStore
                let isAnonymous = anonymousVolumes.contains(source)

                do {
                    try await stateStore.saveVolumeMount(
                        containerID: dockerID,
                        volumeName: source,
                        containerPath: containerPath,
                        isAnonymous: isAnonymous
                    )

                    logger.debug("Tracked volume mount", metadata: [
                        "container": "\(dockerID)",
                        "volume": "\(source)",
                        "path": "\(containerPath)",
                        "anonymous": "\(isAnonymous)"
                    ])
                } catch {
                    logger.warning("Failed to track volume mount", metadata: [
                        "container": "\(dockerID)",
                        "volume": "\(source)",
                        "error": "\(error)"
                    ])
                }
            }
        }
    }

    /// Clean up volumes when a container is removed
    /// Deletes anonymous volumes and removes volume mount relationships
    private func cleanupVolumesForContainer(dockerID: String) async {
        guard let volumeManager = volumeManager else {
            return  // No volume manager, nothing to clean up
        }

        do {
            // Get all volume mounts for this container
            let mounts = try await stateStore.getVolumeMounts(containerID: dockerID)

            // Delete anonymous volumes
            for mount in mounts where mount.isAnonymous {
                logger.info("Cleaning up anonymous volume", metadata: [
                    "container": "\(dockerID)",
                    "volume": "\(mount.volumeName)"
                ])

                do {
                    try await volumeManager.deleteVolume(name: mount.volumeName, force: true)
                    logger.info("Deleted anonymous volume", metadata: [
                        "container": "\(dockerID)",
                        "volume": "\(mount.volumeName)"
                    ])
                } catch {
                    logger.warning("Failed to delete anonymous volume", metadata: [
                        "container": "\(dockerID)",
                        "volume": "\(mount.volumeName)",
                        "error": "\(error)"
                    ])
                }
            }

            // Volume mount relationships will be deleted automatically via CASCADE
            // when we delete the container from StateStore
        } catch {
            logger.warning("Failed to clean up volumes", metadata: [
                "container": "\(dockerID)",
                "error": "\(error)"
            ])
        }
    }

    // MARK: - Filesystem Operations

    /// Get the path to a container's rootfs.ext4 file
    /// This follows Apple's Containerization framework convention: {imageStore.path}/containers/{id}/rootfs.ext4
    private func getRootfsPath(dockerID: String) -> URL? {
        guard let manager = nativeManager else {
            return nil
        }
        // Apple's ContainerManager stores containers at: imageStore.path/containers/{id}/rootfs.ext4
        return manager.imageStore.path
            .appendingPathComponent("containers")
            .appendingPathComponent(dockerID)
            .appendingPathComponent("rootfs.ext4")
    }

    /// Get filesystem changes for a container using OverlayFS upperdir enumeration
    /// Much faster than full filesystem enumeration - only reads upperdir
    public func getContainerChanges(id: String) async throws -> [FilesystemChange] {
        // Resolve name or ID to Docker ID
        guard let dockerID = resolveContainerID(id) else {
            throw ContainerManagerError.containerNotFound(id)
        }

        logger.info("Getting filesystem changes via OverlayFS upperdir", metadata: ["container": "\(dockerID)"])

        // Check if container is running - get FilesystemClient
        guard let filesystemClient = filesystemClients[dockerID] else {
            // Container not running - can't enumerate upperdir
            throw ContainerManagerError.containerNotRunning(dockerID)
        }

        // Sync filesystem first to ensure accurate results
        do {
            try await filesystemClient.syncFilesystem()
            logger.debug("Filesystem buffers synced", metadata: ["container": "\(dockerID)"])
        } catch {
            // Log warning but continue - may work anyway
            logger.warning("Failed to sync filesystem", metadata: [
                "container": "\(dockerID)",
                "error": "\(error)"
            ])
        }

        // Enumerate upperdir entries
        let entries = try await filesystemClient.enumerateUpperdir()

        logger.debug("Enumerated upperdir", metadata: [
            "container": "\(dockerID)",
            "entries": "\(entries.count)"
        ])

        // Convert upperdir entries to FilesystemChange
        var changes: [FilesystemChange] = []

        for entry in entries.sorted(by: { $0.path < $1.path }) {
            switch entry.type {
            case "whiteout":
                // Whiteout = deleted file
                changes.append(FilesystemChange(
                    path: entry.path,
                    kind: .deleted
                ))
            case "file", "dir", "symlink":
                // Present in upperdir = added or modified
                // We can't distinguish without a baseline, so mark as modified
                // Docker behavior: upperdir presence = change (could be add or modify)
                changes.append(FilesystemChange(
                    path: entry.path,
                    kind: .modified
                ))
            default:
                // Unknown type - skip
                logger.warning("Unknown upperdir entry type", metadata: [
                    "path": "\(entry.path)",
                    "type": "\(entry.type)"
                ])
            }
        }

        logger.info("Filesystem changes calculated from upperdir", metadata: [
            "container": "\(dockerID)",
            "changes": "\(changes.count)"
        ])

        return changes
    }

    // MARK: - ID Mapping

    /// Generate a Docker-compatible 64-character hex ID
    private func generateDockerID() -> String {
        let uuid = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        // Docker IDs are 64 chars, so double the UUID
        return (uuid + uuid).prefix(64).lowercased()
    }

    /// Register bidirectional ID mapping
    private func registerIDMapping(dockerID: String, nativeID: String) {
        idMapping[dockerID] = nativeID
        reverseMapping[nativeID] = dockerID
    }

    /// Get Docker ID from native ID
    private func getDockerID(for nativeID: String) -> String {
        if let dockerID = reverseMapping[nativeID] {
            return dockerID
        }

        // Create new mapping if needed
        let dockerID = generateDockerID()
        registerIDMapping(dockerID: dockerID, nativeID: nativeID)
        return dockerID
    }

    /// Generate a random container name (Docker-style)
    private func generateContainerName() -> String {
        let adjectives = ["happy", "silly", "brave", "clever", "zen", "epic"]
        let nouns = ["cat", "dog", "bird", "fish", "lion", "tiger"]
        let adj = adjectives.randomElement() ?? "random"
        let noun = nouns.randomElement() ?? "container"
        return "\(adj)_\(noun)"
    }

    // MARK: - Service Readiness

    /// Wait for arca-services to signal all services are ready
    /// Connects to vsock port 51819 which only opens after wireguard, filesystem, and process services are initialized
    private func waitForServicesReady(container: LinuxContainer, dockerID: String) async throws {
        let readyPort: UInt32 = 51819
        let maxRetries = 100  // 100 * 50ms = 5 seconds max
        let retryDelay: Duration = .milliseconds(50)

        logger.debug("Waiting for container services to be ready", metadata: [
            "container": "\(dockerID)",
            "readyPort": "\(readyPort)"
        ])

        var lastError: Error?
        for attempt in 1...maxRetries {
            do {
                // Try to connect to the ready signal port
                let fileHandle = try await container.dialVsock(port: readyPort)
                // Connection successful - services are ready
                // Close immediately (ready port just accepts and closes)
                try? fileHandle.close()

                logger.info("Container services ready", metadata: [
                    "container": "\(dockerID)",
                    "attempts": "\(attempt)"
                ])
                return
            } catch {
                lastError = error
                if attempt < maxRetries {
                    try await Task.sleep(for: retryDelay)
                }
            }
        }

        // Log warning but don't fail - the retry logic in clients will handle it
        // This provides graceful degradation for containers without arca-services
        logger.warning("Timeout waiting for container services ready signal", metadata: [
            "container": "\(dockerID)",
            "attempts": "\(maxRetries)",
            "error": "\(lastError?.localizedDescription ?? "unknown")"
        ])
    }

    // MARK: - Helper Methods

    /// Format status string from container state
    private func formatStatusFromState(_ info: ContainerInfo) -> String {
        switch info.state {
        case "running":
            if let startedAt = info.startedAt {
                let duration = Date().timeIntervalSince(startedAt)
                return "Up \(formatDuration(duration))"
            }
            return "Up"
        case "exited":
            if let finishedAt = info.finishedAt {
                let duration = Date().timeIntervalSince(finishedAt)
                return "Exited (\(info.exitCode)) \(formatDuration(duration)) ago"
            }
            return "Exited (\(info.exitCode))"
        case "created":
            return "Created"
        default:
            return info.state.capitalized
        }
    }

    /// Format duration for status string
    private func formatDuration(_ seconds: TimeInterval) -> String {
        let secs = Int(seconds)
        if secs < 60 {
            return "\(secs) seconds"
        } else if secs < 3600 {
            return "\(secs / 60) minutes"
        } else if secs < 86400 {
            return "\(secs / 3600) hours"
        } else {
            return "\(secs / 86400) days"
        }
    }

    /// Persist container state to SQLite database
    /// This helper method serializes ContainerInfo and saves it to StateStore
    private func persistContainerState(
        dockerID: String,
        info: ContainerInfo,
        stoppedByUser: Bool = false
    ) async throws {
        // Encode configuration as JSON
        let configData = try JSONEncoder().encode(info.config)
        let configJSON = String(data: configData, encoding: .utf8) ?? "{}"

        let hostConfigData = try JSONEncoder().encode(info.hostConfig)
        let hostConfigJSON = String(data: hostConfigData, encoding: .utf8) ?? "{}"

        // Save container to database
        try await stateStore.saveContainer(
            id: dockerID,
            name: info.name ?? "unknown",
            image: info.image,
            imageID: info.imageID,
            createdAt: info.created,
            status: info.state,
            running: info.state == "running",
            paused: info.state == "paused",
            restarting: info.state == "restarting",
            pid: info.pid,
            exitCode: info.exitCode,
            startedAt: info.startedAt,
            finishedAt: info.finishedAt,
            stoppedByUser: stoppedByUser,
            entrypoint: info.config.entrypoint,
            configJSON: configJSON,
            hostConfigJSON: hostConfigJSON
        )

        // Save network attachments
        for (networkID, attachment) in info.networkAttachments {
            try await stateStore.saveNetworkAttachment(
                containerID: dockerID,
                networkID: networkID,
                ipAddress: attachment.ip,
                macAddress: attachment.mac,
                aliases: attachment.aliases
            )
        }

        logger.debug("Persisted container state", metadata: [
            "container": "\(dockerID)",
            "state": "\(info.state)",
            "networkCount": "\(info.networkAttachments.count)"
        ])
    }

    // MARK: - DNS Topology Publisher

    /// Push DNS topology update to a specific container
    /// Called when network topology changes (container start/stop/attach/detach)
    private func pushDNSTopologyUpdate(to dockerID: String) async {
        // TODO(Phase 3.1): Implement DNS push via WireGuard gRPC (UpdateDNSMappings RPC)
        // This will replace the tap-forwarder DNS push with a WireGuard-based implementation
        // See Documentation/WIREGUARD_IMPLEMENTATION_PLAN.md Phase 3.1 for details

        // For now, DNS resolution is not implemented - this will be added in Phase 3.1
        // when embedded-DNS is integrated into arca-wireguard-service
        return
    }

    /// Push DNS topology updates to all containers on a specific network
    /// Called when a container joins/leaves a network or starts/stops
    private func pushDNSTopologyToNetwork(networkID: String) async {
        // TODO(Phase 3.1): Implement DNS push via WireGuard gRPC (UpdateDNSMappings RPC)
        // This will push DNS topology updates to all containers on a network
        // See Documentation/WIREGUARD_IMPLEMENTATION_PLAN.md Phase 3.1 for details
        return
    }

    /// Helper to get all containers on a specific network
    private func getContainersOnNetwork(networkID: String) async -> [ContainerDNSPeer] {
        var peers: [ContainerDNSPeer] = []

        for (dockerID, containerInfo) in containers {
            // Only include running containers
            guard containerInfo.state == "running" else {
                continue
            }

            // Check if container is on this network
            guard let attachment = containerInfo.networkAttachments[networkID] else {
                continue
            }

            // Get container name (use short ID if no name)
            let containerName = containerInfo.name ?? String(dockerID.prefix(12))

            peers.append(ContainerDNSPeer(
                name: containerName,
                dockerID: dockerID,
                ipAddress: attachment.ip,
                aliases: attachment.aliases
            ))
        }

        return peers
    }

    /// Container DNS information for building topology snapshots
    private struct ContainerDNSPeer {
        let name: String
        let dockerID: String
        let ipAddress: String
        let aliases: [String]
    }

    // MARK: - Helper Types

    /// Internal container tracking info
    private struct ContainerInfo {
        let nativeID: String
        var name: String?
        let image: String
        let imageID: String
        let created: Date
        var state: String
        let command: [String]
        let path: String
        let args: [String]
        let env: [String]
        let workingDir: String
        let labels: [String: String]
        let ports: [PortMapping]
        var hostConfig: HostConfig  // Phase 6 - Task 6.1: Mutable for update endpoint
        let config: ContainerConfiguration
        let networkSettings: NetworkSettings
        var pid: Int
        var exitCode: Int
        var startedAt: Date?
        var finishedAt: Date?
        let tty: Bool  // Whether container was created with TTY
        var needsCreate: Bool  // Whether .create() was deferred (for attached containers)
        var networkAttachments: [String: NetworkAttachment]  // Network ID -> Attachment details
        var anonymousVolumes: [String]  // Names of anonymous volumes to delete on container removal
        let initialNetworkUserIP: String?  // User-specified IP for initial network (from docker run --ip)
        let initialNetworkAliases: [String]  // Aliases for initial network (from Docker Compose service name)
    }

    /// Network attachment details for a container
    public struct NetworkAttachment: Sendable {
        public let networkID: String
        public let ip: String
        public let mac: String
        public let aliases: [String]

        public init(networkID: String, ip: String, mac: String, aliases: [String]) {
            self.networkID = networkID
            self.ip = ip
            self.mac = mac
            self.aliases = aliases
        }
    }

}

// MARK: - Errors

public enum ContainerManagerError: Error, CustomStringConvertible {
    case notInitialized
    case notImplemented
    case missingKernel
    case kernelNotFound(String)
    case containerNotFound(String)
    case containerRunning(String)
    case containerNotRunning(String)  // Phase 5 - Task 5.4: For kill endpoint validation
    case nameConflict(String, String)  // (name, existingID) - Container name already in use
    case imageNotFound(String)
    case invalidConfiguration(String)
    case invalidParameter(String)  // Phase 5 - Task 5.1: For validating resource limits
    case volumeSourceNotFound(String)
    case volumeNotFound(String)
    case volumeManagerNotAvailable
    case logWriterCreationFailed(String)
    case fileBindMountFailed(String, String)  // (target path, error message)

    public var description: String {
        switch self {
        case .notInitialized:
            return "ContainerManager not initialized"
        case .notImplemented:
            return "Feature not yet implemented (Containerization API integration in progress)"
        case .missingKernel:
            return "Kernel path not specified"
        case .kernelNotFound(let path):
            return "Kernel file not found at: \(path)\nPlease run: arca setup"
        case .containerNotFound(let id):
            return "No such container: \(id)"
        case .containerRunning(let id):
            return "Container is running: \(id). Stop the container before removing it or use force."
        case .containerNotRunning(let id):
            return "Container is not running: \(id)"
        case .nameConflict(let name, let existingID):
            return "Conflict. The container name \"\(name)\" is already in use by container \"\(existingID)\". You have to remove (or rename) that container to be able to reuse that name."
        case .imageNotFound(let ref):
            return "No such image: \(ref)"
        case .invalidConfiguration(let msg):
            return "Invalid configuration: \(msg)"
        case .invalidParameter(let msg):
            return "Invalid parameter: \(msg)"
        case .volumeSourceNotFound(let path):
            return "Volume source path does not exist: \(path)"
        case .volumeNotFound(let name):
            return "No such volume: \(name)"
        case .volumeManagerNotAvailable:
            return "VolumeManager not available - named volumes are not supported"
        case .logWriterCreationFailed(let msg):
            return "Failed to create log writers: \(msg)"
        case .fileBindMountFailed(let target, let error):
            return "Failed to create file bind mount at \(target): \(error)"
        }
    }
}
