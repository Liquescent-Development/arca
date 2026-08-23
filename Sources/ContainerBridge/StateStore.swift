import Foundation
import SQLite
import Logging
import ArcaIP

/// StateStore manages persistent container and network state in SQLite
/// All operations are atomic and thread-safe via actor isolation
/// SQLite.swift Connection objects have internal serial queues for thread safety
public actor StateStore {
    private nonisolated(unsafe) let db: Connection
    private let logger: Logger

    // Table definitions (nonisolated - immutable and thread-safe)
    private nonisolated(unsafe) let containers = Table("containers")
    private nonisolated(unsafe) let networks = Table("networks")
    private nonisolated(unsafe) let networkAttachments = Table("network_attachments")
    private nonisolated(unsafe) let volumes = Table("volumes")
    private nonisolated(unsafe) let volumeMounts = Table("volume_mounts")
    private nonisolated(unsafe) let subnetAllocation = Table("subnet_allocation")
    private nonisolated(unsafe) let filesystemBaselines = Table("filesystem_baselines")
    private nonisolated(unsafe) let schemaVersion = Table("schema_version")

    // Container columns (nonisolated - immutable and thread-safe)
    private nonisolated(unsafe) let id = Expression<String>("id")
    private nonisolated(unsafe) let name = Expression<String>("name")
    private nonisolated(unsafe) let image = Expression<String>("image")
    private nonisolated(unsafe) let imageID = Expression<String>("image_id")
    private nonisolated(unsafe) let createdAt = Expression<String>("created_at")
    private nonisolated(unsafe) let status = Expression<String>("status")
    private nonisolated(unsafe) let running = Expression<Bool>("running")
    private nonisolated(unsafe) let paused = Expression<Bool>("paused")
    private nonisolated(unsafe) let restarting = Expression<Bool>("restarting")
    private nonisolated(unsafe) let pid = Expression<Int>("pid")
    private nonisolated(unsafe) let exitCode = Expression<Int>("exit_code")
    private nonisolated(unsafe) let startedAt = Expression<String?>("started_at")
    private nonisolated(unsafe) let finishedAt = Expression<String?>("finished_at")
    private nonisolated(unsafe) let stoppedByUser = Expression<Bool>("stopped_by_user")
    private nonisolated(unsafe) let entrypointJSON = Expression<String?>("entrypoint_json")
    private nonisolated(unsafe) let configJSON = Expression<String>("config_json")
    private nonisolated(unsafe) let hostConfigJSON = Expression<String>("host_config_json")

    // Network columns (nonisolated - immutable and thread-safe)
    private nonisolated(unsafe) let networkID = Expression<String>("id")
    private nonisolated(unsafe) let networkName = Expression<String>("name")
    private nonisolated(unsafe) let driver = Expression<String>("driver")
    private nonisolated(unsafe) let scope = Expression<String>("scope")
    private nonisolated(unsafe) let networkCreatedAt = Expression<String>("created_at")
    private nonisolated(unsafe) let subnet = Expression<String>("subnet")
    private nonisolated(unsafe) let gateway = Expression<String>("gateway")
    private nonisolated(unsafe) let ipRange = Expression<String?>("ip_range")
    private nonisolated(unsafe) let nextIPOctet = Expression<Int>("next_ip_octet")
    private nonisolated(unsafe) let optionsJSON = Expression<String?>("options_json")
    private nonisolated(unsafe) let labelsJSON = Expression<String?>("labels_json")
    private nonisolated(unsafe) let isDefault = Expression<Bool>("is_default")

    // Network attachment columns (nonisolated - immutable and thread-safe)
    private nonisolated(unsafe) let attachmentID = Expression<Int64>("id")
    private nonisolated(unsafe) let containerID = Expression<String>("container_id")
    private nonisolated(unsafe) let attachedNetworkID = Expression<String>("network_id")
    private nonisolated(unsafe) let ipAddress = Expression<String>("ip_address")
    private nonisolated(unsafe) let ipAddressInt = Expression<Int64>("ip_address_int")  // IPv4 as integer for efficient SQL
    private nonisolated(unsafe) let macAddress = Expression<String>("mac_address")
    private nonisolated(unsafe) let aliasesJSON = Expression<String?>("aliases_json")
    private nonisolated(unsafe) let attachedAt = Expression<String>("attached_at")

    // Volume columns (nonisolated - immutable and thread-safe)
    private nonisolated(unsafe) let volumeName = Expression<String>("name")
    private nonisolated(unsafe) let volumeDriver = Expression<String>("driver")
    private nonisolated(unsafe) let volumeFormat = Expression<String>("format")
    private nonisolated(unsafe) let volumeMountpoint = Expression<String>("mountpoint")
    private nonisolated(unsafe) let volumeCreatedAt = Expression<String>("created_at")
    private nonisolated(unsafe) let volumeLabelsJSON = Expression<String?>("labels_json")
    private nonisolated(unsafe) let volumeOptionsJSON = Expression<String?>("options_json")

    // Volume mount columns (nonisolated - immutable and thread-safe)
    private nonisolated(unsafe) let mountID = Expression<Int64>("id")
    private nonisolated(unsafe) let mountContainerID = Expression<String>("container_id")
    private nonisolated(unsafe) let mountVolumeName = Expression<String>("volume_name")
    private nonisolated(unsafe) let mountContainerPath = Expression<String>("container_path")
    private nonisolated(unsafe) let mountIsAnonymous = Expression<Bool>("is_anonymous")
    private nonisolated(unsafe) let mountedAt = Expression<String>("mounted_at")

    // Subnet allocation columns (nonisolated - immutable and thread-safe)
    private nonisolated(unsafe) let allocationID = Expression<Int>("id")
    private nonisolated(unsafe) let nextSubnetByte = Expression<Int>("next_subnet_byte")

    // Filesystem baseline columns (nonisolated - immutable and thread-safe)
    private nonisolated(unsafe) let baselineID = Expression<Int64>("id")
    private nonisolated(unsafe) let baselineContainerID = Expression<String>("container_id")
    private nonisolated(unsafe) let filePath = Expression<String>("file_path")
    private nonisolated(unsafe) let fileType = Expression<String>("file_type")
    private nonisolated(unsafe) let fileSize = Expression<Int64>("file_size")
    private nonisolated(unsafe) let fileMtime = Expression<Int64>("file_mtime")
    private nonisolated(unsafe) let capturedAt = Expression<String>("captured_at")

    // Schema version columns (nonisolated - immutable and thread-safe)
    private nonisolated(unsafe) let version = Expression<Int>("version")
    private nonisolated(unsafe) let appliedAt = Expression<String>("applied_at")

    public enum StateStoreError: Error, CustomStringConvertible {
        case databaseInitFailed(String)
        case containerNotFound(String)
        case networkNotFound(String)
        case volumeNotFound(String)
        case invalidJSON(String)
        case transactionFailed(String)

        public var description: String {
            switch self {
            case .databaseInitFailed(let reason):
                return "Database initialization failed: \(reason)"
            case .containerNotFound(let id):
                return "Container not found: \(id)"
            case .networkNotFound(let id):
                return "Network not found: \(id)"
            case .volumeNotFound(let name):
                return "Volume not found: \(name)"
            case .invalidJSON(let reason):
                return "Invalid JSON: \(reason)"
            case .transactionFailed(let reason):
                return "Transaction failed: \(reason)"
            }
        }
    }

    /// Initialize StateStore with database at specified path
    /// Creates database and schema if it doesn't exist
    public init(path: String, logger: Logger) throws {
        self.logger = logger

        // Expand tilde in path
        let expandedPath = NSString(string: path).expandingTildeInPath

        // Create parent directory if needed
        let parentDir = URL(fileURLWithPath: expandedPath).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)

        // Connect to database
        do {
            self.db = try Connection(expandedPath)

            // Enable foreign key constraints (CRITICAL for CASCADE DELETE)
            try self.db.execute("PRAGMA foreign_keys = ON")

            // Set busy timeout for concurrent access (5 seconds)
            // This prevents SQLITE_BUSY errors when multiple operations happen concurrently
            self.db.busyTimeout = 5.0

            logger.info("Connected to state database", metadata: ["path": "\(expandedPath)"])
        } catch {
            throw StateStoreError.databaseInitFailed("Failed to connect: \(error)")
        }

        // Initialize schema (synchronous because init can't be async)
        do {
            try initializeSchemaSynchronously()
        } catch {
            throw StateStoreError.databaseInitFailed("Failed to initialize schema: \(error)")
        }
    }

    // MARK: - Schema Initialization

    /// Synchronous schema initialization for use in init
    private nonisolated func initializeSchemaSynchronously() throws {
        // Check current schema version (returns nil if table doesn't exist)
        let versionResult = try? db.scalar(schemaVersion.select(version.max))
        let currentVersion = versionResult ?? 0

        if currentVersion == 0 {
            try createSchemaV1Synchronously()
        }

        // Migration to v2: Add unique index on (network_id, ip_address) to prevent IPAM race conditions
        if currentVersion < 2 {
            try migrateToV2Synchronously()
        }

        // Migration to v3: drop the layer cache the single-composed-rootfs revert orphaned
        if currentVersion < 3 {
            try migrateToV3Synchronously()
        }
    }

    /// Migration to v3: drop `layer_cache`.
    ///
    /// Removing the table's definition above stops a *new* database growing one; every
    /// database that already exists keeps its rows until something drops them, and after this
    /// revert nothing will ever read them again. `LayerCacheReclaim` reclaims the ext4 files
    /// those rows indexed; this reclaims the index.
    ///
    /// Raw SQL because SQLite.swift's `Table` API is reached through the table constants at
    /// the top of this type, and keeping one alive only to drop it would leave a live handle
    /// on a table nothing else may touch. `IF EXISTS` because the table is absent on a
    /// database created after this change and on one created before it and never started
    /// under the fork -- neither is an error. SQLite drops a table's indexes with the table.
    private nonisolated func migrateToV3Synchronously() throws {
        try db.transaction {
            try db.run("DROP TABLE IF EXISTS layer_cache")
            try db.run(schemaVersion.insert(or: .replace, version <- 3))
        }
    }

    /// Migration to v2: Add ip_address_int column and unique index for atomic IPAM
    /// This prevents the TOCTOU race condition where multiple containers could get the same IP
    /// (fixes #13)
    private nonisolated func migrateToV2Synchronously() throws {
        try db.transaction {
            // Add ip_address_int column for efficient SQL-based IP allocation
            try db.run("ALTER TABLE network_attachments ADD COLUMN ip_address_int INTEGER")

            // Populate ip_address_int from existing ip_address strings using swift-ip
            for row in try db.prepare(networkAttachments) {
                let ipStr = row[ipAddress]
                if let ip = IP.V4(ipStr) {
                    let attachment = networkAttachments.filter(attachmentID == row[attachmentID])
                    try db.run(attachment.update(ipAddressInt <- Int64(ip.value)))
                }
            }

            // Add unique index on (network_id, ip_address_int) to prevent duplicate IPs per network
            // This ensures atomic IP allocation at the database level
            try db.run(networkAttachments.createIndex(
                attachedNetworkID, ipAddressInt,
                unique: true,
                ifNotExists: true
            ))

            // Update schema version
            try db.run(schemaVersion.insert(or: .replace, version <- 2))
        }
    }

    private nonisolated func createSchemaV1Synchronously() throws {
        try db.transaction {
            // Schema version table
            try db.run(schemaVersion.create(ifNotExists: true) { t in
                t.column(version, primaryKey: true)
                t.column(appliedAt, defaultValue: Date().iso8601String)
            })

            // Containers table
            try db.run(containers.create(ifNotExists: true) { t in
                t.column(id, primaryKey: true)
                t.column(name, unique: true)
                t.column(image)
                t.column(imageID)
                t.column(createdAt)
                t.column(status, defaultValue: "created")
                t.column(running, defaultValue: false)
                t.column(paused, defaultValue: false)
                t.column(restarting, defaultValue: false)
                t.column(pid, defaultValue: 0)
                t.column(exitCode, defaultValue: 0)
                t.column(startedAt)
                t.column(finishedAt)
                t.column(stoppedByUser, defaultValue: false)
                t.column(entrypointJSON)
                t.column(configJSON)
                t.column(hostConfigJSON)

                // Note: SQLite.swift doesn't support .in() for check constraints
                // We'll enforce this in the application layer
            })

            // Container indexes
            try db.run(containers.createIndex(name, ifNotExists: true))
            try db.run(containers.createIndex(status, ifNotExists: true))
            try db.run(containers.createIndex(image, ifNotExists: true))
            try db.run(containers.createIndex(running, ifNotExists: true))

            // Networks table
            try db.run(networks.create(ifNotExists: true) { t in
                t.column(networkID, primaryKey: true)
                t.column(networkName, unique: true)
                t.column(driver)
                t.column(scope, defaultValue: "local")
                t.column(networkCreatedAt)
                t.column(subnet)
                t.column(gateway)
                t.column(ipRange)
                t.column(nextIPOctet, defaultValue: 2)  // Default to .2 (gateway is .1)
                t.column(optionsJSON)
                t.column(labelsJSON)
                t.column(isDefault, defaultValue: false)

                // Note: SQLite.swift doesn't support .in() for check constraints
                // We'll enforce this in the application layer
            })

            // Network indexes
            try db.run(networks.createIndex(networkName, ifNotExists: true))
            try db.run(networks.createIndex(driver, ifNotExists: true))

            // Network attachments table
            try db.run(networkAttachments.create(ifNotExists: true) { t in
                t.column(attachmentID, primaryKey: .autoincrement)
                t.column(containerID)
                t.column(attachedNetworkID)
                t.column(ipAddress)
                t.column(macAddress)
                t.column(aliasesJSON)
                t.column(attachedAt, defaultValue: Date().iso8601String)

                t.foreignKey(containerID, references: containers, id, delete: .cascade)
                t.foreignKey(attachedNetworkID, references: networks, networkID, delete: .cascade)
                t.unique(containerID, attachedNetworkID)
            })

            // Network attachment indexes
            try db.run(networkAttachments.createIndex(containerID, ifNotExists: true))
            try db.run(networkAttachments.createIndex(attachedNetworkID, ifNotExists: true))

            // Volumes table
            try db.run(volumes.create(ifNotExists: true) { t in
                t.column(volumeName, primaryKey: true)
                t.column(volumeDriver, defaultValue: "local")
                t.column(volumeFormat, defaultValue: "ext4")
                t.column(volumeMountpoint)
                t.column(volumeCreatedAt, defaultValue: Date().iso8601String)
                t.column(volumeLabelsJSON)
                t.column(volumeOptionsJSON)
            })

            // Volume indexes
            try db.run(volumes.createIndex(volumeName, ifNotExists: true))
            try db.run(volumes.createIndex(volumeDriver, ifNotExists: true))

            // Volume mounts table (tracks which containers use which volumes)
            try db.run(volumeMounts.create(ifNotExists: true) { t in
                t.column(mountID, primaryKey: .autoincrement)
                t.column(mountContainerID)
                t.column(mountVolumeName)
                t.column(mountContainerPath)
                t.column(mountIsAnonymous, defaultValue: false)
                t.column(mountedAt, defaultValue: Date().iso8601String)

                // Foreign key constraints
                t.foreignKey(mountContainerID, references: containers, id, delete: .cascade)
                t.foreignKey(mountVolumeName, references: volumes, volumeName, delete: .cascade)
            })

            // Volume mount indexes
            try db.run(volumeMounts.createIndex(mountContainerID, ifNotExists: true))
            try db.run(volumeMounts.createIndex(mountVolumeName, ifNotExists: true))

            // Subnet allocation table (singleton)
            try db.run(subnetAllocation.create(ifNotExists: true) { t in
                t.column(allocationID, primaryKey: true)
                t.column(nextSubnetByte, defaultValue: 18)

                t.check(allocationID == 1)
                t.check(nextSubnetByte >= 18 && nextSubnetByte <= 31)
            })

            // Insert initial subnet allocation state
            try db.run(subnetAllocation.insert(or: .ignore,
                allocationID <- 1,
                nextSubnetByte <- 18
            ))

            // Filesystem baselines table (for tracking container filesystem changes)
            try db.run(filesystemBaselines.create(ifNotExists: true) { t in
                t.column(baselineID, primaryKey: .autoincrement)
                t.column(baselineContainerID)
                t.column(filePath)
                t.column(fileType)  // 'f' = file, 'd' = directory, 'l' = symlink
                t.column(fileSize)
                t.column(fileMtime)  // Unix timestamp (seconds since epoch)
                t.column(capturedAt, defaultValue: Date().iso8601String)

                t.foreignKey(baselineContainerID, references: containers, id, delete: .cascade)
            })

            // Filesystem baseline indexes
            try db.run(filesystemBaselines.createIndex(baselineContainerID, ifNotExists: true))
            try db.run(filesystemBaselines.createIndex(filePath, baselineContainerID, unique: true, ifNotExists: true))

            // Mark schema as v1
            try db.run(schemaVersion.insert(version <- 1))
        }
    }

    // MARK: - Container Operations

    /// Save container state to database
    public func saveContainer(
        id: String,
        name: String,
        image: String,
        imageID: String,
        createdAt: Date,
        status: String,
        running: Bool,
        paused: Bool,
        restarting: Bool,
        pid: Int,
        exitCode: Int,
        startedAt: Date?,
        finishedAt: Date?,
        stoppedByUser: Bool,
        entrypoint: [String]?,
        configJSON: String,
        hostConfigJSON: String
    ) throws {
        // Serialize entrypoint to JSON if provided
        let entrypointString: String?
        if let entrypoint = entrypoint {
            let data = try JSONEncoder().encode(entrypoint)
            entrypointString = String(data: data, encoding: .utf8)
        } else {
            entrypointString = nil
        }

        // Check if container exists
        let existing = try db.scalar(containers.filter(self.id == id).count)

        if existing > 0 {
            // Update existing container (preserves CASCADE relationships like filesystem_baselines)
            let container = containers.filter(self.id == id)
            try db.run(container.update(
                self.name <- name,
                self.image <- image,
                self.imageID <- imageID,
                self.createdAt <- createdAt.iso8601String,
                self.status <- status,
                self.running <- running,
                self.paused <- paused,
                self.restarting <- restarting,
                self.pid <- pid,
                self.exitCode <- exitCode,
                self.startedAt <- startedAt?.iso8601String,
                self.finishedAt <- finishedAt?.iso8601String,
                self.stoppedByUser <- stoppedByUser,
                self.entrypointJSON <- entrypointString,
                self.configJSON <- configJSON,
                self.hostConfigJSON <- hostConfigJSON
            ))
        } else {
            // Insert new container
            try db.run(containers.insert(
                self.id <- id,
                self.name <- name,
                self.image <- image,
                self.imageID <- imageID,
                self.createdAt <- createdAt.iso8601String,
                self.status <- status,
                self.running <- running,
                self.paused <- paused,
                self.restarting <- restarting,
                self.pid <- pid,
                self.exitCode <- exitCode,
                self.startedAt <- startedAt?.iso8601String,
                self.finishedAt <- finishedAt?.iso8601String,
                self.stoppedByUser <- stoppedByUser,
                self.entrypointJSON <- entrypointString,
                self.configJSON <- configJSON,
                self.hostConfigJSON <- hostConfigJSON
            ))
        }

        logger.debug("Container state saved", metadata: [
            "id": "\(id)",
            "name": "\(name)",
            "status": "\(status)"
        ])
    }

    /// Update container status in database
    public func updateContainerStatus(id: String, status: String, exitCode: Int? = nil, finishedAt: Date? = nil) throws {
        let container = containers.filter(self.id == id)

        var setters: [SQLite.Setter] = [
            self.status <- status,
            self.running <- (status == "running")
        ]

        if let exitCode = exitCode {
            setters.append(self.exitCode <- exitCode)
        }

        if let finishedAt = finishedAt {
            setters.append(self.finishedAt <- finishedAt.iso8601String)
        }

        try db.run(container.update(setters))

        logger.debug("Container status updated", metadata: [
            "id": "\(id)",
            "status": "\(status)",
            "exitCode": "\(exitCode?.description ?? "unchanged")"
        ])
    }

    /// Update container name in the database
    /// Throws error if new name is already in use (UNIQUE constraint violation)
    public func updateContainerName(id: String, newName: String) throws {
        let container = containers.filter(self.id == id)

        try db.run(container.update(self.name <- newName))

        logger.debug("Container name updated", metadata: [
            "id": "\(id)",
            "newName": "\(newName)"
        ])
    }

    /// Load all containers from database
    public func loadAllContainers() throws -> [(
        id: String,
        name: String,
        image: String,
        imageID: String,
        createdAt: Date,
        status: String,
        running: Bool,
        paused: Bool,
        restarting: Bool,
        pid: Int,
        exitCode: Int,
        startedAt: Date?,
        finishedAt: Date?,
        stoppedByUser: Bool,
        entrypoint: [String]?,
        configJSON: String,
        hostConfigJSON: String
    )] {
        var result: [(
            id: String, name: String, image: String, imageID: String,
            createdAt: Date, status: String, running: Bool, paused: Bool,
            restarting: Bool, pid: Int, exitCode: Int, startedAt: Date?,
            finishedAt: Date?, stoppedByUser: Bool, entrypoint: [String]?,
            configJSON: String, hostConfigJSON: String
        )] = []

        for row in try db.prepare(containers) {
            let createdDate = Date(iso8601String: row[createdAt]) ?? Date()
            let startedDate = row[startedAt].flatMap { Date(iso8601String: $0) }
            let finishedDate = row[finishedAt].flatMap { Date(iso8601String: $0) }

            // Deserialize entrypoint from JSON
            let entrypoint: [String]?
            if let entrypointData = row[entrypointJSON]?.data(using: .utf8) {
                entrypoint = try? JSONDecoder().decode([String].self, from: entrypointData)
            } else {
                entrypoint = nil
            }

            result.append((
                id: row[id],
                name: row[name],
                image: row[image],
                imageID: row[imageID],
                createdAt: createdDate,
                status: row[status],
                running: row[running],
                paused: row[paused],
                restarting: row[restarting],
                pid: row[pid],
                exitCode: row[exitCode],
                startedAt: startedDate,
                finishedAt: finishedDate,
                stoppedByUser: row[stoppedByUser],
                entrypoint: entrypoint,
                configJSON: row[configJSON],
                hostConfigJSON: row[hostConfigJSON]
            ))
        }

        logger.info("Loaded containers from database", metadata: [
            "count": "\(result.count)"
        ])

        return result
    }

    /// Delete container from database
    public func deleteContainer(id: String) throws {
        let container = containers.filter(self.id == id)
        try db.run(container.delete())

        logger.debug("Container deleted from database", metadata: ["id": "\(id)"])
    }

    /// Get containers that need to be restarted based on restart policy
    public func getContainersToRestart() throws -> [(id: String, name: String, policy: String, exitCode: Int)] {
        var result: [(id: String, name: String, policy: String, exitCode: Int)] = []

        // Query containers that are exited and have a restart policy
        for row in try db.prepare(containers.filter(status == "exited")) {
            // Extract values for logging (avoid Sendable issues)
            let containerId = row[id]
            let containerName = row[name]
            let containerExitCode = row[exitCode]
            let containerStoppedByUser = row[stoppedByUser]
            let hostConfig = row[hostConfigJSON]

            logger.debug("Checking restart policy for container", metadata: [
                "id": "\(containerId)",
                "name": "\(containerName)",
                "exitCode": "\(containerExitCode)",
                "stoppedByUser": "\(containerStoppedByUser)"
            ])

            // Parse restart policy from JSON
            if let data = hostConfig.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let restartPolicy = json["restartPolicy"] as? [String: Any],
               let policyName = restartPolicy["name"] as? String {

                logger.debug("Found restart policy", metadata: [
                    "id": "\(containerId)",
                    "policy": "\(policyName)"
                ])

                let shouldRestart: Bool
                switch policyName {
                case "always":
                    shouldRestart = true
                    logger.debug("Policy 'always': will restart")
                case "unless-stopped":
                    shouldRestart = !containerStoppedByUser
                    logger.debug("Policy 'unless-stopped'", metadata: [
                        "stoppedByUser": "\(containerStoppedByUser)",
                        "shouldRestart": "\(shouldRestart)"
                    ])
                case "on-failure":
                    shouldRestart = containerExitCode != 0
                    logger.debug("Policy 'on-failure'", metadata: [
                        "exitCode": "\(containerExitCode)",
                        "shouldRestart": "\(shouldRestart)"
                    ])
                default:
                    shouldRestart = false
                    logger.debug("Unknown policy: will not restart", metadata: ["policy": "\(policyName)"])
                }

                if shouldRestart {
                    logger.info("Container will be restarted", metadata: [
                        "id": "\(containerId)",
                        "name": "\(containerName)",
                        "policy": "\(policyName)",
                        "exitCode": "\(containerExitCode)"
                    ])
                    result.append((
                        id: containerId,
                        name: containerName,
                        policy: policyName,
                        exitCode: containerExitCode
                    ))
                } else {
                    logger.debug("Container will NOT be restarted", metadata: [
                        "id": "\(containerId)",
                        "policy": "\(policyName)"
                    ])
                }
            } else {
                logger.debug("No restart policy found in hostConfig", metadata: [
                    "id": "\(containerId)",
                    "hostConfig": "\(hostConfig)"
                ])
            }
        }

        logger.info("Found containers to restart", metadata: ["count": "\(result.count)"])
        return result
    }

    // MARK: - Network Operations

    /// Save network state to database
    public func saveNetwork(
        id: String,
        name: String,
        driver: String,
        scope: String,
        createdAt: Date,
        subnet: String,
        gateway: String,
        ipRange: String?,
        optionsJSON: String?,
        labelsJSON: String?,
        isDefault: Bool
    ) throws {
        try db.run(networks.insert(or: .replace,
            self.networkID <- id,
            self.networkName <- name,
            self.driver <- driver,
            self.scope <- scope,
            self.networkCreatedAt <- createdAt.iso8601String,
            self.subnet <- subnet,
            self.gateway <- gateway,
            self.ipRange <- ipRange,
            self.nextIPOctet <- 2,  // Legacy column - no longer used, kept for schema compatibility
            self.optionsJSON <- optionsJSON,
            self.labelsJSON <- labelsJSON,
            self.isDefault <- isDefault
        ))

        logger.debug("Network saved", metadata: [
            "id": "\(id)",
            "name": "\(name)",
            "driver": "\(driver)"
        ])
    }

    /// One network as it is stored. Named so that the callers which map it to
    /// `NetworkMetadata` can say what they take without restating eleven fields.
    public typealias PersistedNetwork = (
        id: String,
        name: String,
        driver: String,
        scope: String,
        createdAt: Date,
        subnet: String,
        gateway: String,
        ipRange: String?,
        optionsJSON: String?,
        labelsJSON: String?,
        isDefault: Bool
    )

    /// Load all networks from database
    public func loadAllNetworks() throws -> [PersistedNetwork] {
        var result: [(
            id: String, name: String, driver: String, scope: String,
            createdAt: Date, subnet: String, gateway: String,
            ipRange: String?, optionsJSON: String?, labelsJSON: String?,
            isDefault: Bool
        )] = []

        for row in try db.prepare(networks) {
            let createdDate = Date(iso8601String: row[networkCreatedAt]) ?? Date()

            result.append((
                id: row[networkID],
                name: row[networkName],
                driver: row[driver],
                scope: row[scope],
                createdAt: createdDate,
                subnet: row[subnet],
                gateway: row[gateway],
                ipRange: row[ipRange],
                optionsJSON: row[optionsJSON],
                labelsJSON: row[labelsJSON],
                isDefault: row[isDefault]
            ))
        }

        logger.info("Loaded networks from database", metadata: [
            "count": "\(result.count)"
        ])

        return result
    }

    /// Delete network from database
    public func deleteNetwork(id: String) throws {
        let network = networks.filter(self.networkID == id)
        try db.run(network.delete())

        logger.debug("Network deleted from database", metadata: ["id": "\(id)"])
    }

    /// Get a single network by ID
    public func getNetwork(id: String) throws -> (
        id: String,
        name: String,
        driver: String,
        scope: String,
        createdAt: Date,
        subnet: String,
        gateway: String,
        ipRange: String?,
        optionsJSON: String?,
        labelsJSON: String?,
        isDefault: Bool
    )? {
        let query = networks.filter(self.networkID == id)
        guard let row = try db.pluck(query) else {
            return nil
        }

        let createdDate = Date(iso8601String: row[networkCreatedAt]) ?? Date()

        return (
            id: row[networkID],
            name: row[networkName],
            driver: row[driver],
            scope: row[scope],
            createdAt: createdDate,
            subnet: row[subnet],
            gateway: row[gateway],
            ipRange: row[ipRange],
            optionsJSON: row[optionsJSON],
            labelsJSON: row[labelsJSON],
            isDefault: row[isDefault]
        )
    }

    /// Get all container IDs attached to a network
    public func getNetworkContainers(networkID: String) throws -> Set<String> {
        let query = networkAttachments.filter(self.attachedNetworkID == networkID)
        var containerIDs = Set<String>()

        for row in try db.prepare(query) {
            containerIDs.insert(row[containerID])
        }

        return containerIDs
    }

    /// Get all network IDs a container is attached to
    public func getContainerNetworks(containerID: String) throws -> Set<String> {
        let query = networkAttachments.filter(self.containerID == containerID)
        var networkIDs = Set<String>()

        for row in try db.prepare(query) {
            networkIDs.insert(row[attachedNetworkID])
        }

        return networkIDs
    }

    // MARK: - Network Attachment Operations

    /// Save network attachment
    public func saveNetworkAttachment(
        containerID: String,
        networkID: String,
        ipAddress: String,
        macAddress: String,
        aliases: [String]
    ) throws {
        let aliasesData = try JSONEncoder().encode(aliases)
        let aliasesString = String(data: aliasesData, encoding: .utf8)

        // Convert IP string to integer using swift-ip
        let ipInt: Int64
        if let ip = IP.V4(ipAddress) {
            ipInt = Int64(ip.value)
        } else {
            ipInt = 0  // Fallback for invalid IPs
        }

        try db.run(networkAttachments.insert(or: .replace,
            self.containerID <- containerID,
            self.attachedNetworkID <- networkID,
            self.ipAddress <- ipAddress,
            self.ipAddressInt <- ipInt,
            self.macAddress <- macAddress,
            self.aliasesJSON <- aliasesString,
            self.attachedAt <- Date().iso8601String
        ))

        logger.debug("Network attachment saved", metadata: [
            "container": "\(containerID)",
            "network": "\(networkID)"
        ])
    }

    /// Load network attachments for a container
    public func loadNetworkAttachments(containerID: String) throws -> [(
        networkID: String,
        ipAddress: String,
        macAddress: String,
        aliases: [String]
    )] {
        var result: [(networkID: String, ipAddress: String, macAddress: String, aliases: [String])] = []

        let query = networkAttachments.filter(self.containerID == containerID)
        for row in try db.prepare(query) {
            let aliases: [String]
            if let aliasesData = row[aliasesJSON]?.data(using: .utf8) {
                aliases = (try? JSONDecoder().decode([String].self, from: aliasesData)) ?? []
            } else {
                aliases = []
            }

            result.append((
                networkID: row[attachedNetworkID],
                ipAddress: row[ipAddress],
                macAddress: row[macAddress],
                aliases: aliases
            ))
        }

        return result
    }

    /// Load container attachments for a network
    public func loadAttachmentsForNetwork(networkID: String) throws -> [(
        containerID: String,
        ipAddress: String,
        macAddress: String,
        aliases: [String]
    )] {
        var result: [(containerID: String, ipAddress: String, macAddress: String, aliases: [String])] = []

        let query = networkAttachments.filter(self.attachedNetworkID == networkID)
        for row in try db.prepare(query) {
            let aliases: [String]
            if let aliasesData = row[aliasesJSON]?.data(using: .utf8) {
                aliases = (try? JSONDecoder().decode([String].self, from: aliasesData)) ?? []
            } else {
                aliases = []
            }

            result.append((
                containerID: row[self.containerID],
                ipAddress: row[ipAddress],
                macAddress: row[macAddress],
                aliases: aliases
            ))
        }

        return result
    }

    /// Delete network attachment
    public func deleteNetworkAttachment(containerID: String, networkID: String) throws {
        let attachment = networkAttachments
            .filter(self.containerID == containerID && self.attachedNetworkID == networkID)
        try db.run(attachment.delete())

        logger.debug("Network attachment deleted", metadata: [
            "container": "\(containerID)",
            "network": "\(networkID)"
        ])
    }

    /// Get all allocated IP addresses for a network
    /// Returns IPs from network_attachments (actively used by containers)
    public func getAllocatedIPs(networkID: String) throws -> Set<String> {
        let query = networkAttachments
            .filter(self.attachedNetworkID == networkID)
            .select(ipAddress)

        var allocatedIPs = Set<String>()
        for row in try db.prepare(query) {
            allocatedIPs.insert(row[ipAddress])
        }

        return allocatedIPs
    }

    /// Check if an IP is already allocated in a network
    public func isIPAllocated(networkID: String, ip: String) throws -> Bool {
        let query = networkAttachments
            .filter(self.attachedNetworkID == networkID && ipAddress == ip)
        return try db.scalar(query.count) > 0
    }

    /// Atomically allocate and reserve an IP address for a container on a network
    /// Uses SQL to find the first available IP in range and inserts in a single transaction.
    /// The unique index on (network_id, ip_address_int) prevents race conditions. (fixes #13)
    ///
    /// - Parameters:
    ///   - containerID: The container to allocate IP for
    ///   - networkID: The network to allocate IP on
    ///   - rangeStart: First IP in allocation range as integer
    ///   - rangeEnd: Last IP in allocation range as integer. **Callers currently
    ///     pass the subnet's broadcast address, and this method treats the bound
    ///     as inclusive** — see `Vas-Solutus/arca#50`. This method does not
    ///     validate `rangeStart <= rangeEnd`, and the fallback scan below is
    ///     `for ip in rangeStart...rangeEnd`, a closed range: an inverted pair
    ///     traps and kills the daemon. That is reachable today via a `/31` or
    ///     `/32` subnet from `WireGuardNetworkBackend.attachContainer`.
    ///   - gatewayInt: Gateway IP as integer (to skip)
    ///   - macAddress: MAC address for the attachment
    ///   - aliases: DNS aliases for the attachment
    /// - Returns: The allocated IP address as string
    /// - Throws: StateStoreError.transactionFailed if no IPs available
    public func allocateAndReserveIP(
        containerID: String,
        networkID: String,
        rangeStart: Int64,
        rangeEnd: Int64,
        gatewayInt: Int64,
        macAddress: String,
        aliases: [String]
    ) throws -> String {
        var allocatedIP: String?

        try db.transaction {
            // Find the first available IP using SQL
            // Strategy: Find MIN(ip + 1) where (ip + 1) is not already allocated
            // Start from rangeStart - 1 so we can find rangeStart itself if available

            // First, check if rangeStart is available (most common case for new networks)
            let startAvailable = try db.scalar(
                networkAttachments
                    .filter(attachedNetworkID == networkID && ipAddressInt == rangeStart)
                    .count
            ) == 0

            let nextIP: Int64
            if startAvailable && rangeStart != gatewayInt {
                nextIP = rangeStart
            } else {
                // Find first gap: SELECT MIN(ip_address_int) + 1 WHERE (ip + 1) NOT IN allocated
                // This is complex in SQLite, so we use a simpler approach:
                // Get MAX allocated IP and use MAX + 1, or find first gap by iteration

                // Simple approach: use MAX + 1 (no gap reclamation, but fast)
                let maxIP = try db.scalar(
                    networkAttachments
                        .filter(attachedNetworkID == networkID)
                        .select(ipAddressInt.max)
                ) ?? (rangeStart - 1)

                var candidate = maxIP + 1
                // Skip gateway if needed
                if candidate == gatewayInt {
                    candidate += 1
                }

                if candidate > rangeEnd {
                    // Pool exhausted with simple approach, try finding gaps
                    // Iterate through range to find first available (fallback)
                    var found: Int64? = nil
                    for ip in rangeStart...rangeEnd {
                        if ip == gatewayInt { continue }
                        let taken = try db.scalar(
                            networkAttachments
                                .filter(attachedNetworkID == networkID && ipAddressInt == ip)
                                .count
                        ) ?? 0
                        if taken == 0 {
                            found = ip
                            break
                        }
                    }
                    guard let foundIP = found else {
                        throw StateStoreError.transactionFailed("IP pool exhausted for network \(networkID)")
                    }
                    candidate = foundIP
                }
                nextIP = candidate
            }

            // Convert to string using swift-ip
            let ipv4 = IP.V4(value: UInt32(nextIP))
            let ipStr = String(describing: ipv4)

            // Insert the reservation atomically
            let aliasesData = try JSONEncoder().encode(aliases)
            let aliasesString = String(data: aliasesData, encoding: .utf8)

            try db.run(networkAttachments.insert(
                self.containerID <- containerID,
                attachedNetworkID <- networkID,
                self.ipAddress <- ipStr,
                self.ipAddressInt <- nextIP,
                self.macAddress <- macAddress,
                aliasesJSON <- aliasesString,
                attachedAt <- Date().iso8601String
            ))

            allocatedIP = ipStr
        }

        guard let ip = allocatedIP else {
            throw StateStoreError.transactionFailed("IP allocation failed for network \(networkID)")
        }

        logger.debug("IP allocated and reserved atomically", metadata: [
            "container": "\(containerID)",
            "network": "\(networkID)",
            "ip": "\(ip)"
        ])

        return ip
    }

    /// Atomically reserve a specific IP address for a container on a network
    /// Used when user specifies an IP via --ip flag
    public func reserveSpecificIP(
        containerID: String,
        networkID: String,
        ip: String,
        macAddress: String,
        aliases: [String]
    ) throws {
        guard let ipv4 = IP.V4(ip) else {
            throw StateStoreError.transactionFailed("Invalid IP address: \(ip)")
        }

        let aliasesData = try JSONEncoder().encode(aliases)
        let aliasesString = String(data: aliasesData, encoding: .utf8)

        do {
            // The unique index on (network_id, ip_address_int) ensures this fails if IP is taken
            try db.run(networkAttachments.insert(
                self.containerID <- containerID,
                attachedNetworkID <- networkID,
                self.ipAddress <- ip,
                self.ipAddressInt <- Int64(ipv4.value),
                self.macAddress <- macAddress,
                aliasesJSON <- aliasesString,
                attachedAt <- Date().iso8601String
            ))

            logger.debug("Specific IP reserved", metadata: [
                "container": "\(containerID)",
                "network": "\(networkID)",
                "ip": "\(ip)"
            ])
        } catch {
            throw StateStoreError.transactionFailed("IP \(ip) is already allocated on network \(networkID)")
        }
    }

    // MARK: - Subnet Allocation Operations

    /// Get next available subnet byte for auto-allocation
    public func getNextSubnetByte() throws -> Int {
        guard let row = try db.pluck(subnetAllocation.filter(allocationID == 1)) else {
            // Initialize if not exists
            try db.run(subnetAllocation.insert(or: .replace,
                allocationID <- 1,
                nextSubnetByte <- 18
            ))
            return 18
        }

        return row[nextSubnetByte]
    }

    /// Update next available subnet byte
    public func updateNextSubnetByte(_ value: Int) throws {
        let allocation = subnetAllocation.filter(allocationID == 1)
        try db.run(allocation.update(nextSubnetByte <- value))

        logger.debug("Subnet allocation updated", metadata: ["nextSubnetByte": "\(value)"])
    }

    /// Get all allocated subnet bytes from existing networks
    /// Parses subnets like "172.18.0.0/16" to extract the second octet (18)
    /// Returns set of allocated subnet bytes (e.g., [18, 19, 20])
    public func getAllocatedSubnetBytes() throws -> Set<UInt8> {
        var allocatedBytes = Set<UInt8>()

        for row in try db.prepare(networks) {
            let subnetStr = row[subnet]

            // Parse subnet like "172.18.0.0/16" -> extract second octet (18)
            let components = subnetStr.split(separator: "/")
            guard let ipPart = components.first else { continue }

            let octets = ipPart.split(separator: ".")
            guard octets.count >= 2,
                  let secondOctet = UInt8(octets[1]) else {
                continue
            }

            allocatedBytes.insert(secondOctet)
        }

        logger.debug("Found allocated subnet bytes", metadata: [
            "subnets": "\(Array(allocatedBytes).sorted())"
        ])

        return allocatedBytes
    }

    // MARK: - Volume Operations

    /// Save a volume to the database
    public func saveVolume(
        name: String,
        driver: String,
        format: String,
        mountpoint: String,
        createdAt: Date,
        labelsJSON: String?,
        optionsJSON: String?
    ) throws {
        try db.run(volumes.insert(or: .replace,
            self.volumeName <- name,
            self.volumeDriver <- driver,
            self.volumeFormat <- format,
            self.volumeMountpoint <- mountpoint,
            self.volumeCreatedAt <- createdAt.iso8601String,
            self.volumeLabelsJSON <- labelsJSON,
            self.volumeOptionsJSON <- optionsJSON
        ))

        logger.debug("Volume saved", metadata: [
            "name": "\(name)",
            "driver": "\(driver)",
            "format": "\(format)"
        ])
    }

    /// Load all volumes from the database
    public func loadAllVolumes() throws -> [(
        name: String,
        driver: String,
        format: String,
        mountpoint: String,
        createdAt: Date,
        labelsJSON: String?,
        optionsJSON: String?
    )] {
        var result: [(
            name: String, driver: String, format: String, mountpoint: String,
            createdAt: Date, labelsJSON: String?, optionsJSON: String?
        )] = []

        for row in try db.prepare(volumes) {
            let createdDate = Date(iso8601String: row[volumeCreatedAt]) ?? Date()

            result.append((
                name: row[volumeName],
                driver: row[volumeDriver],
                format: row[volumeFormat],
                mountpoint: row[volumeMountpoint],
                createdAt: createdDate,
                labelsJSON: row[volumeLabelsJSON],
                optionsJSON: row[volumeOptionsJSON]
            ))
        }

        logger.debug("Loaded volumes from database", metadata: ["count": "\(result.count)"])
        return result
    }

    /// Delete a volume from the database
    public func deleteVolume(name: String) throws {
        let volume = volumes.filter(volumeName == name)
        let deleted = try db.run(volume.delete())

        if deleted == 0 {
            throw StateStoreError.volumeNotFound(name)
        }

        logger.debug("Volume deleted from database", metadata: ["name": "\(name)"])
    }

    // MARK: - Volume Mount Operations

    /// Save a volume mount relationship
    public func saveVolumeMount(
        containerID: String,
        volumeName: String,
        containerPath: String,
        isAnonymous: Bool
    ) throws {
        try db.run(volumeMounts.insert(
            mountContainerID <- containerID,
            mountVolumeName <- volumeName,
            mountContainerPath <- containerPath,
            mountIsAnonymous <- isAnonymous,
            mountedAt <- Date().iso8601String
        ))

        logger.debug("Volume mount saved", metadata: [
            "container": "\(containerID)",
            "volume": "\(volumeName)",
            "path": "\(containerPath)",
            "anonymous": "\(isAnonymous)"
        ])
    }

    /// Get all volume mounts for a container
    public func getVolumeMounts(containerID: String) throws -> [(volumeName: String, containerPath: String, isAnonymous: Bool)] {
        let query = volumeMounts
            .filter(mountContainerID == containerID)
            .order(mountedAt)

        return try db.prepare(query).map { row in
            (
                volumeName: row[mountVolumeName],
                containerPath: row[mountContainerPath],
                isAnonymous: row[mountIsAnonymous]
            )
        }
    }

    /// Get all containers using a volume
    /// - Parameters:
    ///   - volumeName: Name of the volume
    ///   - runningOnly: If true, only returns containers that are currently running
    public func getVolumeUsers(volumeName: String, runningOnly: Bool = false) throws -> [String] {
        if runningOnly {
            // Join with containers table to filter by running state
            // Must qualify containers[id] to avoid ambiguity with volumeMounts.id
            let query = volumeMounts
                .join(containers, on: mountContainerID == containers[id])
                .filter(mountVolumeName == volumeName)
                .filter(running == true)
                .select(distinct: mountContainerID)

            return try db.prepare(query).map { row in
                row[mountContainerID]
            }
        } else {
            let query = volumeMounts
                .filter(mountVolumeName == volumeName)
                .select(distinct: mountContainerID)

            return try db.prepare(query).map { row in
                row[mountContainerID]
            }
        }
    }

    /// Delete volume mounts for a container
    public func deleteVolumeMounts(containerID: String) throws {
        let mounts = volumeMounts.filter(mountContainerID == containerID)
        let deleted = try db.run(mounts.delete())

        logger.debug("Volume mounts deleted", metadata: [
            "container": "\(containerID)",
            "count": "\(deleted)"
        ])
    }

    /// Get all dangling volumes (not used by any container)
    public func getDanglingVolumes() throws -> [String] {
        // Find volumes that have no corresponding mounts
        let usedVolumes = volumeMounts.select(distinct: mountVolumeName)
        let allVolumes = volumes.select(volumeName)

        // SQLite doesn't support EXCEPT, so we do it manually
        let used = try Set(db.prepare(usedVolumes).map { $0[mountVolumeName] })
        let all = try db.prepare(allVolumes).map { $0[volumeName] }

        return all.filter { !used.contains($0) }
    }

    // MARK: - Transaction Support

    /// Execute operations in a transaction
    public func transaction<T>(_ block: () throws -> T) throws -> T {
        var result: T!
        try db.transaction {
            result = try block()
        }
        return result
    }

    // MARK: - Filesystem Baseline Operations

    /// Save filesystem baseline for a container
    /// This stores the initial filesystem state for diff comparison
    public func saveFilesystemBaseline(containerID: String, files: [(path: String, type: String, size: Int64, mtime: Int64)]) throws {
        logger.debug("Starting baseline save transaction", metadata: [
            "container": "\(containerID)",
            "files_to_save": "\(files.count)"
        ])

        try db.transaction {
            // Delete existing baseline for this container
            let existingBaseline = filesystemBaselines.filter(baselineContainerID == containerID)
            let deleted = try db.run(existingBaseline.delete())
            logger.debug("Deleted existing baseline entries", metadata: ["deleted": "\(deleted)"])

            // Insert new baseline entries
            var inserted = 0
            for file in files {
                try db.run(filesystemBaselines.insert(
                    baselineContainerID <- containerID,
                    filePath <- file.path,
                    fileType <- file.type,
                    fileSize <- file.size,
                    fileMtime <- file.mtime,
                    capturedAt <- Date().iso8601String
                ))
                inserted += 1
            }
            logger.debug("Inserted baseline entries", metadata: ["inserted": "\(inserted)"])
        }

        // Verify the data persisted
        let query = filesystemBaselines.filter(baselineContainerID == containerID)
        let count = try db.scalar(query.count)

        logger.debug("Filesystem baseline saved and verified", metadata: [
            "container": "\(containerID)",
            "files_saved": "\(files.count)",
            "files_in_db": "\(count)"
        ])
    }

    /// Load filesystem baseline for a container
    public func loadFilesystemBaseline(containerID: String) throws -> [(path: String, type: String, size: Int64, mtime: Int64)] {
        let query = filesystemBaselines
            .filter(baselineContainerID == containerID)
            .order(filePath)

        return try db.prepare(query).map { row in
            (
                path: row[filePath],
                type: row[fileType],
                size: row[fileSize],
                mtime: row[fileMtime]
            )
        }
    }

    /// Check if filesystem baseline exists for a container
    public func hasFilesystemBaseline(containerID: String) throws -> Bool {
        let query = filesystemBaselines.filter(baselineContainerID == containerID)
        return try db.scalar(query.count) > 0
    }

    /// Delete filesystem baseline for a container
    public func deleteFilesystemBaseline(containerID: String) throws {
        let baseline = filesystemBaselines.filter(baselineContainerID == containerID)
        let deleted = try db.run(baseline.delete())

        logger.debug("Filesystem baseline deleted", metadata: [
            "container": "\(containerID)",
            "entries": "\(deleted)"
        ])
    }
}

// MARK: - Helper Extensions

extension Date {
    var iso8601String: String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: self)
    }

    init?(iso8601String: String) {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: iso8601String) else {
            return nil
        }
        self = date
    }
}
