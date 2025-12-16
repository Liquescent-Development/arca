// FilesystemClient.swift
// Swift client for Arca Filesystem Service gRPC API
//
// Provides filesystem operations for containers:
// - Filesystem sync (flush buffers)
// - OverlayFS upperdir enumeration (for docker diff)
// - Archive operations (tar creation/extraction for buildx)

import Foundation
import GRPC
import NIO
import NIOPosix
import Logging
import Containerization

/// Client for communicating with arca-filesystem-service running in container VM
/// Connects via vsock port 51821
public actor FilesystemClient {
    private let logger: Logger
    private let containerID: String
    private let container: Containerization.LinuxContainer
    private var channel: GRPCChannel?
    private var eventLoopGroup: EventLoopGroup?
    private var client: Arca_Filesystem_V1_FilesystemServiceAsyncClient?
    private var vsockFileHandle: FileHandle?  // Keep FileHandle alive for the connection

    public init(containerID: String, container: Containerization.LinuxContainer, logger: Logger) {
        self.containerID = containerID
        self.container = container
        self.logger = logger
    }

    /// Connect to the container's filesystem service via vsock
    /// Includes retry logic to handle race conditions during container startup
    private func connect() async throws {
        guard client == nil else { return }

        logger.debug("Connecting to container filesystem service via vsock", metadata: [
            "container": "\(containerID)",
            "vsockPort": "51821"
        ])

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.eventLoopGroup = group

        // Retry logic following waitForAgent() pattern to handle startup race conditions
        let maxRetries = 50
        let retryDelay: Duration = .milliseconds(50)
        var lastError: Error?

        for attempt in 1...maxRetries {
            do {
                logger.debug("Attempting vsock connection", metadata: [
                    "container": "\(containerID)",
                    "attempt": "\(attempt)",
                    "vsockPort": "51821"
                ])
                let fileHandle = try await container.dialVsock(port: 51821)

                // Store FileHandle to keep it alive for the lifetime of the connection
                self.vsockFileHandle = fileHandle

                // Create gRPC channel from the connected socket FileHandle
                let channel = ClientConnection(
                    configuration: .default(
                        target: .connectedSocket(NIOBSDSocket.Handle(fileHandle.fileDescriptor)),
                        eventLoopGroup: group
                    ))

                self.channel = channel
                self.client = Arca_Filesystem_V1_FilesystemServiceAsyncClient(channel: channel)

                logger.debug("Connected to container filesystem service via vsock", metadata: [
                    "container": "\(containerID)",
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

        logger.error("Failed to connect to filesystem service after \(maxRetries) attempts", metadata: [
            "container": "\(containerID)",
            "error": "\(lastError?.localizedDescription ?? "unknown")"
        ])
        throw lastError ?? FilesystemClientError.connectionFailed("Connection timed out after \(maxRetries) attempts")
    }

    /// Get or create gRPC client connection
    private func getClient() async throws -> Arca_Filesystem_V1_FilesystemServiceAsyncClient {
        if let existing = client {
            return existing
        }

        try await connect()

        guard let client = client else {
            throw FilesystemClientError.connectionFailed("Failed to create client after connect()")
        }

        return client
    }

    /// Disconnect from the container's filesystem service
    public func disconnect() async throws {
        guard let channel = channel else {
            return
        }

        logger.debug("Disconnecting from container filesystem service", metadata: [
            "container": "\(containerID)"
        ])

        try await channel.close().get()
        try await eventLoopGroup?.shutdownGracefully()

        // Close the vsock FileHandle
        if let fileHandle = vsockFileHandle {
            try? fileHandle.close()
        }

        self.channel = nil
        self.eventLoopGroup = nil
        self.client = nil
        self.vsockFileHandle = nil

        logger.debug("Disconnected from container filesystem service", metadata: [
            "container": "\(containerID)"
        ])
    }

    /// Sync filesystem - flush all cached writes to disk
    /// Calls sync() syscall to ensure accurate filesystem reads
    public func syncFilesystem() async throws {
        logger.debug("Syncing filesystem", metadata: ["container": "\(containerID)"])

        let client = try await getClient()
        let request = Arca_Filesystem_V1_SyncFilesystemRequest()

        let response = try await client.syncFilesystem(request)

        guard response.success else {
            logger.error("Filesystem sync failed", metadata: [
                "container": "\(containerID)",
                "error": "\(response.error)"
            ])
            throw FilesystemClientError.syncFailed(response.error)
        }

        logger.debug("Filesystem sync complete", metadata: ["container": "\(containerID)"])
    }

    /// Enumerate OverlayFS upperdir for container diff
    /// Returns all files in /mnt/vdb/upper (added/modified files and whiteouts)
    /// Much faster than full filesystem enumeration
    public func enumerateUpperdir() async throws -> [UpperdirEntry] {
        logger.debug("Enumerating upperdir", metadata: ["container": "\(containerID)"])

        let client = try await getClient()
        let request = Arca_Filesystem_V1_EnumerateUpperdirRequest()

        let response = try await client.enumerateUpperdir(request)

        guard response.success else {
            logger.error("Upperdir enumeration failed", metadata: [
                "container": "\(containerID)",
                "error": "\(response.error)"
            ])
            throw FilesystemClientError.enumerationFailed(response.error)
        }

        logger.debug("Upperdir enumeration complete", metadata: [
            "container": "\(containerID)",
            "entries": "\(response.entries.count)"
        ])

        return response.entries.map { entry in
            UpperdirEntry(
                path: entry.path,
                type: entry.type,
                size: entry.size,
                mtime: entry.mtime,
                mode: entry.mode
            )
        }
    }

    /// Read archive - create tar archive of filesystem path
    /// Works universally without requiring tar in container
    /// Used for GET /containers/{id}/archive endpoint (buildx)
    public func readArchive(path: String) async throws -> (tarData: Data, stat: PathStat) {
        logger.debug("Reading archive", metadata: [
            "container": "\(containerID)",
            "path": "\(path)"
        ])

        let client = try await getClient()
        var request = Arca_Filesystem_V1_ReadArchiveRequest()
        request.containerID = containerID
        request.path = path

        let response = try await client.readArchive(request)

        guard response.success else {
            logger.error("Read archive failed", metadata: [
                "container": "\(containerID)",
                "path": "\(path)",
                "error": "\(response.error)"
            ])
            throw FilesystemClientError.readArchiveFailed(response.error)
        }

        let stat = PathStat(
            name: response.stat.name,
            size: response.stat.size,
            mode: response.stat.mode,
            mtime: response.stat.mtime,
            linkTarget: response.stat.linkTarget
        )

        logger.debug("Read archive complete", metadata: [
            "container": "\(containerID)",
            "path": "\(path)",
            "size": "\(response.tarData.count)"
        ])

        return (tarData: response.tarData, stat: stat)
    }

    /// Write archive - extract tar archive to filesystem path
    /// Works universally without requiring tar in container
    /// Used for PUT /containers/{id}/archive endpoint (buildx)
    public func writeArchive(path: String, tarData: Data) async throws {
        logger.debug("Writing archive", metadata: [
            "container": "\(containerID)",
            "path": "\(path)",
            "size": "\(tarData.count)"
        ])

        let client = try await getClient()
        var request = Arca_Filesystem_V1_WriteArchiveRequest()
        request.containerID = containerID
        request.path = path
        request.tarData = tarData

        let response = try await client.writeArchive(request)

        guard response.success else {
            logger.error("Write archive failed", metadata: [
                "container": "\(containerID)",
                "path": "\(path)",
                "error": "\(response.error)"
            ])
            throw FilesystemClientError.writeArchiveFailed(response.error)
        }

        logger.debug("Write archive complete", metadata: [
            "container": "\(containerID)",
            "path": "\(path)"
        ])
    }

    /// Create bind mount - bind mount a file or directory inside the container
    /// Works like "mount --bind /source /target" inside the container
    /// Used for file bind mounts (VirtioFS only supports directory shares)
    public func createBindMount(source: String, target: String, readOnly: Bool) async throws {
        logger.debug("Creating bind mount", metadata: [
            "container": "\(containerID)",
            "source": "\(source)",
            "target": "\(target)",
            "readOnly": "\(readOnly)"
        ])

        let client = try await getClient()
        var request = Arca_Filesystem_V1_CreateBindMountRequest()
        request.containerID = containerID
        request.source = source
        request.target = target
        request.readOnly = readOnly

        let response = try await client.createBindMount(request)

        guard response.success else {
            logger.error("Create bind mount failed", metadata: [
                "container": "\(containerID)",
                "source": "\(source)",
                "target": "\(target)",
                "error": "\(response.error)"
            ])
            throw FilesystemClientError.createBindMountFailed(response.error)
        }

        logger.info("Bind mount created successfully", metadata: [
            "container": "\(containerID)",
            "source": "\(source)",
            "target": "\(target)",
            "readOnly": "\(readOnly)"
        ])
    }

    /// Create volume overlay - create OverlayFS mount for a volume
    /// This overlays an EXT4 upper layer on top of a VirtioFS lower layer
    /// Provides full POSIX compliance (Unix sockets, chmod) for volumes
    /// Used for k3d/kind support where volumes need Unix socket support
    public func createVolumeOverlay(lowerPath: String, upperDevice: String, target: String, virtiofsTag: String) async throws {
        logger.debug("Creating volume overlay", metadata: [
            "container": "\(containerID)",
            "lowerPath": "\(lowerPath)",
            "upperDevice": "\(upperDevice)",
            "target": "\(target)",
            "virtiofsTag": "\(virtiofsTag)"
        ])

        let client = try await getClient()
        var request = Arca_Filesystem_V1_CreateVolumeOverlayRequest()
        request.containerID = containerID
        request.lowerPath = lowerPath
        request.upperDevice = upperDevice
        request.target = target
        request.virtiofsTag = virtiofsTag

        let response = try await client.createVolumeOverlay(request)

        guard response.success else {
            logger.error("Create volume overlay failed", metadata: [
                "container": "\(containerID)",
                "lowerPath": "\(lowerPath)",
                "upperDevice": "\(upperDevice)",
                "target": "\(target)",
                "error": "\(response.error)"
            ])
            throw FilesystemClientError.createVolumeOverlayFailed(response.error)
        }

        logger.info("Volume overlay created successfully", metadata: [
            "container": "\(containerID)",
            "lowerPath": "\(lowerPath)",
            "upperDevice": "\(upperDevice)",
            "target": "\(target)"
        ])
    }

    /// Create direct mount - bind mount EXT4 directory to container path
    /// Creates a directory on the writable EXT4 filesystem and bind mounts it
    /// Provides full POSIX compliance without OverlayFS (allows nested overlays)
    /// Used for named volumes (local driver) that don't need host file access
    public func createDirectMount(volumeName: String, target: String) async throws {
        logger.debug("Creating direct mount", metadata: [
            "container": "\(containerID)",
            "volumeName": "\(volumeName)",
            "target": "\(target)"
        ])

        let client = try await getClient()
        var request = Arca_Filesystem_V1_CreateDirectMountRequest()
        request.containerID = containerID
        request.volumeName = volumeName
        request.target = target

        let response = try await client.createDirectMount(request)

        guard response.success else {
            logger.error("Create direct mount failed", metadata: [
                "container": "\(containerID)",
                "volumeName": "\(volumeName)",
                "target": "\(target)",
                "error": "\(response.error)"
            ])
            throw FilesystemClientError.createDirectMountFailed(response.error)
        }

        logger.info("Direct mount created successfully", metadata: [
            "container": "\(containerID)",
            "volumeName": "\(volumeName)",
            "target": "\(target)"
        ])
    }

    /// Stat a path (check if it exists and get metadata)
    /// Used for HEAD requests on archive endpoint
    public func statPath(path: String) async throws -> PathStat {
        logger.debug("Stating path", metadata: [
            "container": "\(containerID)",
            "path": "\(path)"
        ])

        let client = try await getClient()
        var request = Arca_Filesystem_V1_StatPathRequest()
        request.containerID = containerID
        request.path = path

        let response = try await client.statPath(request)

        guard response.success else {
            logger.error("Stat path failed", metadata: [
                "container": "\(containerID)",
                "path": "\(path)",
                "error": "\(response.error)"
            ])
            throw FilesystemClientError.statFailed(response.error)
        }

        return PathStat(
            name: response.stat.name,
            size: response.stat.size,
            mode: response.stat.mode,
            mtime: response.stat.mtime,
            linkTarget: response.stat.linkTarget
        )
    }

    /// Generate /etc/hosts file for container
    /// Creates the standard Docker hosts file with localhost entries and container hostname
    /// Docker generates this file; we need to do the same for compatibility
    public func generateHostsFile(hostname: String, ipAddress: String, containerName: String, extraHosts: [String]) async throws {
        logger.debug("Generating /etc/hosts file", metadata: [
            "container": "\(containerID)",
            "hostname": "\(hostname)",
            "ipAddress": "\(ipAddress)",
            "containerName": "\(containerName)"
        ])

        let client = try await getClient()
        var request = Arca_Filesystem_V1_GenerateHostsFileRequest()
        request.containerID = containerID
        request.hostname = hostname
        request.ipAddress = ipAddress
        request.containerName = containerName
        request.extraHosts = extraHosts

        let response = try await client.generateHostsFile(request)

        guard response.success else {
            logger.error("Generate hosts file failed", metadata: [
                "container": "\(containerID)",
                "error": "\(response.error)"
            ])
            throw FilesystemClientError.generateHostsFileFailed(response.error)
        }

        logger.info("/etc/hosts file generated successfully", metadata: [
            "container": "\(containerID)",
            "hostname": "\(hostname)",
            "ipAddress": "\(ipAddress)"
        ])
    }

}

/// Entry in the OverlayFS upperdir (for docker diff)
public struct UpperdirEntry: Sendable {
    public let path: String
    public let type: String  // "file", "dir", "symlink", "whiteout"
    public let size: Int64
    public let mtime: Int64
    public let mode: UInt32

    public init(path: String, type: String, size: Int64, mtime: Int64, mode: UInt32) {
        self.path = path
        self.type = type
        self.size = size
        self.mtime = mtime
        self.mode = mode
    }
}

/// File stat information for archived paths
public struct PathStat: Sendable {
    public let name: String
    public let size: Int64
    public let mode: UInt32
    public let mtime: String  // RFC3339 format
    public let linkTarget: String

    public init(name: String, size: Int64, mode: UInt32, mtime: String, linkTarget: String) {
        self.name = name
        self.size = size
        self.mode = mode
        self.mtime = mtime
        self.linkTarget = linkTarget
    }
}

/// Errors from FilesystemClient
public enum FilesystemClientError: Error, CustomStringConvertible {
    case connectionFailed(String)
    case syncFailed(String)
    case enumerationFailed(String)
    case readArchiveFailed(String)
    case writeArchiveFailed(String)
    case createBindMountFailed(String)
    case createVolumeOverlayFailed(String)
    case createDirectMountFailed(String)
    case statFailed(String)
    case generateHostsFileFailed(String)

    public var description: String {
        switch self {
        case .connectionFailed(let msg):
            return "Failed to connect to filesystem service: \(msg)"
        case .syncFailed(let msg):
            return "Filesystem sync failed: \(msg)"
        case .enumerationFailed(let msg):
            return "Upperdir enumeration failed: \(msg)"
        case .readArchiveFailed(let msg):
            return "Read archive failed: \(msg)"
        case .writeArchiveFailed(let msg):
            return "Write archive failed: \(msg)"
        case .createBindMountFailed(let msg):
            return "Create bind mount failed: \(msg)"
        case .createVolumeOverlayFailed(let msg):
            return "Create volume overlay failed: \(msg)"
        case .createDirectMountFailed(let msg):
            return "Create direct mount failed: \(msg)"
        case .statFailed(let msg):
            return "Stat path failed: \(msg)"
        case .generateHostsFileFailed(let msg):
            return "Generate hosts file failed: \(msg)"
        }
    }
}
