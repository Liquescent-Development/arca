// HelperContainerManager.swift
// Manages ephemeral helper containers for filesystem operations on stopped containers
//
// When docker cp or archive operations target a stopped container, we can't access
// the filesystem directly because Arca uses VMs. This manager spins up a hidden
// helper container that mounts the target container's block device, performs the
// operation using exec, and tears down.
//
// This provides full Docker compatibility for:
// - docker cp to/from stopped containers
// - GET/HEAD/PUT /containers/{id}/archive endpoints

import Foundation
import Logging
import Containerization
import ContainerizationOCI

/// Manages ephemeral helper containers for stopped container filesystem access
public actor HelperContainerManager {
    private let logger: Logger
    private weak var containerManager: ContainerManager?
    private weak var imageManager: ImageManager?
    private weak var execManager: ExecManager?

    /// Helper container prefix - used to identify and filter helpers
    public static let helperNamePrefix = "_arca_helper_"

    /// Base image for helper containers (minimal Alpine with tar, losetup, mount)
    private static let helperImage = "alpine:latest"

    /// Track active helper containers for cleanup
    private var activeHelpers: [String: HelperContainer] = [:]  // Target container ID -> Helper

    /// Represents an active helper container with mounted filesystem
    public struct HelperContainer: Sendable {
        public let helperID: String           // Helper container's Docker ID
        public let targetID: String           // Target container's Docker ID
        public let targetWritablePath: String // Path to target's writable.ext4
        public let loopDevice: String?        // Loop device (e.g., /dev/loop0) - nil if not mounted
        public let mountPoint: String         // Mount point inside helper (/mnt/target)
        public let created: Date
    }

    public init(logger: Logger) {
        self.logger = logger
    }

    /// Set references to managers (called after initialization)
    public func setManagers(containerManager: ContainerManager, imageManager: ImageManager, execManager: ExecManager) {
        self.containerManager = containerManager
        self.imageManager = imageManager
        self.execManager = execManager
    }

    // MARK: - Public API

    /// Write archive to a stopped container's filesystem
    /// Creates a helper container, mounts the target's block device, writes files via exec, and tears down
    public func writeArchive(targetID: String, path: String, tarData: Data) async throws {
        logger.info("Writing archive to stopped container via helper", metadata: [
            "target": "\(targetID)",
            "path": "\(path)",
            "size": "\(tarData.count)"
        ])

        // Get or create helper container with mounted filesystem
        let helper = try await getOrCreateMountedHelper(targetID: targetID, readOnly: false)

        // IMPORTANT: Remove from activeHelpers IMMEDIATELY (synchronously) to prevent
        // race conditions where another request tries to reuse a helper being destroyed
        activeHelpers.removeValue(forKey: targetID)

        // Helper function to ensure cleanup happens and is awaited
        // This is critical for docker cp to never-started containers - the writes must
        // be fully flushed to the host filesystem before we return success
        @Sendable func cleanupAndReturn() async {
            await self.cleanupHelper(helper)
        }

        // Use do-catch to ensure cleanup is awaited on all paths
        do {
            // /mnt/target is bound to /mnt/writable/upper (the container's upper layer)
            // We create directories directly in the upper layer - when the container starts,
            // OverlayFS will merge this with the image layers
            let targetPath = helper.mountPoint + (path.hasPrefix("/") ? path : "/\(path)")

            // Ensure target directory exists in upper layer
            let mkdirResult = try await execInHelper(helperID: helper.helperID, command: ["mkdir", "-p", targetPath])
            logger.debug("Created target directory", metadata: [
                "path": "\(targetPath)",
                "exit_code": "\(mkdirResult.exitCode)",
                "stderr": "\(mkdirResult.stderr)"
            ])

            // Write tar data via exec
            // We'll base64 encode the data and decode it inside the container
            let base64Data = tarData.base64EncodedString()

            // Debug: list what's in targetPath before tar
            let beforeTar = try await execInHelper(helperID: helper.helperID, command: ["ls", "-la", targetPath])
            logger.debug("Before tar extract", metadata: [
                "path": "\(targetPath)",
                "contents": "\(beforeTar.stdout)"
            ])

            // Use a shell command to decode base64 and extract tar
            // Use printf instead of echo for more reliable handling of special chars
            let extractCommand = ["sh", "-c", "printf '%s' '\(base64Data)' | base64 -d | tar -xvf - -C '\(targetPath)' 2>&1"]
            let result = try await execInHelper(helperID: helper.helperID, command: extractCommand)

            logger.debug("Tar extract result", metadata: [
                "exit_code": "\(result.exitCode)",
                "stdout": "\(result.stdout)",
                "stderr": "\(result.stderr)"
            ])

            // Debug: list what's in targetPath after tar
            let afterTar = try await execInHelper(helperID: helper.helperID, command: ["ls", "-la", targetPath])
            logger.debug("After tar extract", metadata: [
                "path": "\(targetPath)",
                "contents": "\(afterTar.stdout)"
            ])

            if result.exitCode != 0 {
                // Cleanup before throwing
                await cleanupAndReturn()
                throw HelperContainerError.operationFailed("tar extract failed: \(result.stderr)")
            }

            // Sync to ensure writes are flushed to the underlying filesystem
            _ = try await execInHelper(helperID: helper.helperID, command: ["sync"])

            logger.info("Archive written to stopped container", metadata: [
                "target": "\(targetID)",
                "path": "\(path)"
            ])

            // CRITICAL: Await cleanup before returning success
            // This ensures sync/umount/losetup-detach complete and VirtioFS flushes to host
            await cleanupAndReturn()

        } catch {
            // Cleanup on error path too
            await cleanupAndReturn()
            throw error
        }
    }

    /// Read archive from a stopped container's filesystem
    /// Creates a helper container with mounted filesystem, reads files via exec, and tears down
    /// Searches upper layer first, then image layers
    public func readArchive(targetID: String, path: String) async throws -> (tarData: Data, stat: PathStat) {
        logger.info("Reading archive from stopped container via helper", metadata: [
            "target": "\(targetID)",
            "path": "\(path)"
        ])

        // Get or create helper with mounted filesystem (read-only is sufficient)
        let helper = try await getOrCreateMountedHelper(targetID: targetID, readOnly: true)

        // IMPORTANT: Remove from activeHelpers IMMEDIATELY to prevent race conditions
        defer {
            activeHelpers.removeValue(forKey: targetID)
            Task {
                await self.cleanupHelper(helper)
            }
        }

        let relativePath = path.hasPrefix("/") ? path : "/\(path)"

        // Find the path in upper layer or layers
        var foundPath: String?
        var stat: PathStat?

        // First check upper layer
        let upperPath = helper.mountPoint + relativePath
        if let s = try? await statPathInHelper(helperID: helper.helperID, path: upperPath) {
            foundPath = upperPath
            stat = s
            logger.debug("Path found in upper layer for read", metadata: ["path": "\(path)"])
        }

        // If not in upper, search layers
        if foundPath == nil {
            for i in 0..<10 {
                let layerPath = "/mnt/layer\(i)" + relativePath
                if let s = try? await statPathInHelper(helperID: helper.helperID, path: layerPath) {
                    foundPath = layerPath
                    stat = s
                    logger.debug("Path found in layer for read", metadata: ["path": "\(path)", "layer": "\(i)"])
                    break
                }
            }
        }

        guard let targetPath = foundPath, let pathStat = stat else {
            throw HelperContainerError.operationFailed("Path not found: \(path)")
        }

        // Create tar archive and base64 encode it for transport
        // Use -w 0 on base64 to disable line wrapping (Alpine/BusyBox compatible)
        let tarCommand = ["sh", "-c", "tar -cf - -C '\((targetPath as NSString).deletingLastPathComponent)' '\((targetPath as NSString).lastPathComponent)' 2>/dev/null | base64 -w 0"]
        let result = try await execInHelper(helperID: helper.helperID, command: tarCommand)

        logger.debug("tar+base64 result", metadata: [
            "exit_code": "\(result.exitCode)",
            "stdout_length": "\(result.stdout.count)",
            "stderr": "\(result.stderr)",
            "stdout_preview": "\(String(result.stdout.prefix(100)))"
        ])

        if result.exitCode != 0 {
            throw HelperContainerError.operationFailed("tar create failed: \(result.stderr)")
        }

        // Decode base64 output (remove all whitespace just in case)
        let base64String = result.stdout.components(separatedBy: .whitespacesAndNewlines).joined()
        guard !base64String.isEmpty, let tarData = Data(base64Encoded: base64String) else {
            throw HelperContainerError.operationFailed("Failed to decode tar data (stdout_len=\(result.stdout.count))")
        }

        logger.info("Archive read from stopped container", metadata: [
            "target": "\(targetID)",
            "path": "\(path)",
            "size": "\(tarData.count)"
        ])

        return (tarData: tarData, stat: pathStat)
    }

    /// Check if a path exists in a stopped container
    /// Used for HEAD requests on archive endpoint
    /// Searches upper layer first, then image layers
    public func pathExists(targetID: String, path: String) async throws -> PathStat {
        logger.debug("Checking path in stopped container via helper", metadata: [
            "target": "\(targetID)",
            "path": "\(path)"
        ])

        // Get or create helper with mounted filesystem
        let helper = try await getOrCreateMountedHelper(targetID: targetID, readOnly: true)

        // IMPORTANT: Remove from activeHelpers IMMEDIATELY to prevent race conditions
        defer {
            activeHelpers.removeValue(forKey: targetID)
            Task {
                await self.cleanupHelper(helper)
            }
        }

        let relativePath = path.hasPrefix("/") ? path : "/\(path)"

        // First check upper layer (/mnt/target is bound to upper)
        let upperPath = helper.mountPoint + relativePath
        if let stat = try? await statPathInHelper(helperID: helper.helperID, path: upperPath) {
            logger.debug("Path found in upper layer", metadata: ["path": "\(path)"])
            return stat
        }

        // Search through mounted layers
        // Check up to 10 layers (typical images have 1-5 layers)
        for i in 0..<10 {
            let layerPath = "/mnt/layer\(i)" + relativePath
            if let stat = try? await statPathInHelper(helperID: helper.helperID, path: layerPath) {
                logger.debug("Path found in layer", metadata: ["path": "\(path)", "layer": "\(i)"])
                return stat
            }
        }

        throw HelperContainerError.operationFailed("Path not found: \(path)")
    }

    /// Check if a container ID is a helper container
    public static func isHelperContainer(name: String) -> Bool {
        return name.hasPrefix(helperNamePrefix)
    }

    /// Clean up any orphaned helper containers on daemon startup
    public func cleanupOrphanedHelpers() async {
        logger.info("Cleaning up orphaned helper containers")

        guard let containerManager = containerManager else { return }

        do {
            // List all containers including stopped ones
            // Use internal label filter to include helper containers
            let filters = ["label": ["com.arca.internal=helper"]]
            let containers = try await containerManager.listContainers(all: true, filters: filters)

            for container in containers {
                logger.info("Removing orphaned helper container", metadata: [
                    "id": "\(container.id)",
                    "name": "\(container.names.first ?? "unknown")"
                ])

                try? await containerManager.removeContainer(id: container.id, force: true)
            }
        } catch {
            logger.warning("Failed to cleanup orphaned helpers", metadata: [
                "error": "\(error)"
            ])
        }
    }

    // MARK: - Helper Container Lifecycle

    /// Create a fresh helper for filesystem operations
    /// Always creates a new helper - reuse is disabled to avoid race conditions
    private func getOrCreateMountedHelper(targetID: String, readOnly: Bool) async throws -> HelperContainer {
        // Clean up any stale helper first (shouldn't exist due to immediate removal, but just in case)
        if let stale = activeHelpers.removeValue(forKey: targetID) {
            logger.debug("Cleaning up stale helper before creating new one", metadata: [
                "target": "\(targetID)",
                "stale_helper": "\(stale.helperID)"
            ])
            Task {
                await self.cleanupHelper(stale)
            }
        }

        // Always create a fresh helper
        return try await createAndMountHelper(targetID: targetID, readOnly: readOnly)
    }

    /// Create a new helper container and mount the target's filesystem
    /// Sets up full OverlayFS with image layers + writable upper/work directories
    private func createAndMountHelper(targetID: String, readOnly: Bool) async throws -> HelperContainer {
        guard let containerManager = containerManager else {
            throw HelperContainerError.managerNotAvailable
        }

        // Get target container info (to verify it exists and get image ref)
        guard let targetInfo = try? await containerManager.getContainer(id: targetID) else {
            throw HelperContainerError.targetNotFound(targetID)
        }

        // Get target's writable block device path
        let writablePath = try await getTargetWritablePath(targetID: targetID)

        // Verify writable.ext4 exists
        guard FileManager.default.fileExists(atPath: writablePath) else {
            throw HelperContainerError.writableNotFound(writablePath)
        }

        // Get the target container's image reference and layer paths
        let imageRef = targetInfo.config.image
        var layerPaths: [String] = []
        do {
            layerPaths = try await containerManager.getImageLayerPaths(imageRef: imageRef)
            logger.info("Got image layer paths for OverlayFS", metadata: [
                "target": "\(targetID)",
                "image": "\(imageRef)",
                "layer_count": "\(layerPaths.count)"
            ])
        } catch {
            logger.warning("Could not get image layer paths, will use upper-only mode", metadata: [
                "target": "\(targetID)",
                "image": "\(imageRef)",
                "error": "\(error)"
            ])
        }

        // Generate helper name
        let helperName = Self.helperNamePrefix + UUID().uuidString.lowercased().prefix(8)

        logger.info("Creating helper container", metadata: [
            "target": "\(targetID)",
            "helper_name": "\(String(helperName))",
            "writable_path": "\(writablePath)",
            "layer_count": "\(layerPaths.count)",
            "read_only": "\(readOnly)"
        ])

        // Ensure helper image is available
        try await ensureHelperImage()

        // Create helper container with target's block device and layers mounted
        // Helper needs to be privileged to use losetup, mount, and overlayfs
        let helperID = try await containerManager.createHelperContainer(
            name: String(helperName),
            image: Self.helperImage,
            targetWritablePath: writablePath,
            targetImageRef: imageRef,
            layerPaths: layerPaths,
            isHelper: true
        )

        // Start the helper
        try await containerManager.startContainer(id: helperID)

        // Wait for helper to be ready (just check it's running)
        try await waitForHelperReady(helperID: helperID)

        // Mount the target's filesystem inside the helper with proper OverlayFS
        let mountPoint = "/mnt/target"
        let loopDevice = try await mountTargetFilesystemWithOverlayFS(
            helperID: helperID,
            layerCount: layerPaths.count,
            mountPoint: mountPoint,
            readOnly: readOnly
        )

        let helper = HelperContainer(
            helperID: helperID,
            targetID: targetID,
            targetWritablePath: writablePath,
            loopDevice: loopDevice,
            mountPoint: mountPoint,
            created: Date()
        )

        activeHelpers[targetID] = helper

        logger.info("Helper container created and OverlayFS mounted", metadata: [
            "helper_id": "\(helperID)",
            "target": "\(targetID)",
            "loop_device": "\(loopDevice)",
            "layer_count": "\(layerPaths.count)"
        ])

        return helper
    }

    /// Mount the target container's writable.ext4 filesystem inside the helper
    private func mountTargetFilesystem(helperID: String, deviceFile: String, mountPoint: String, readOnly: Bool) async throws -> String {
        // Set up loop device (BusyBox-compatible approach)
        // 1. First get the next free loop device with `losetup -f`
        let findResult = try await execInHelper(helperID: helperID, command: ["losetup", "-f"])

        if findResult.exitCode != 0 {
            throw HelperContainerError.operationFailed("losetup -f failed: \(findResult.stderr)")
        }

        let loopDevice = findResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !loopDevice.isEmpty else {
            throw HelperContainerError.operationFailed("losetup -f returned empty device")
        }

        // 2. Attach the file to the loop device
        let attachResult = try await execInHelper(helperID: helperID, command: ["losetup", loopDevice, deviceFile])

        if attachResult.exitCode != 0 {
            throw HelperContainerError.operationFailed("losetup attach failed: \(attachResult.stderr)")
        }

        logger.debug("Loop device created", metadata: [
            "helper_id": "\(helperID)",
            "loop_device": "\(loopDevice)"
        ])

        // Create mount point
        let mkdirResult = try await execInHelper(helperID: helperID, command: ["mkdir", "-p", mountPoint])
        if mkdirResult.exitCode != 0 {
            // Clean up loop device
            _ = try? await execInHelper(helperID: helperID, command: ["losetup", "-d", loopDevice])
            throw HelperContainerError.operationFailed("mkdir failed: \(mkdirResult.stderr)")
        }

        // Mount the loop device
        var mountCommand = ["mount"]
        if readOnly {
            mountCommand.append("-o")
            mountCommand.append("ro")
        }
        mountCommand.append(loopDevice)
        mountCommand.append(mountPoint)

        let mountResult = try await execInHelper(helperID: helperID, command: mountCommand)
        if mountResult.exitCode != 0 {
            // Clean up loop device
            _ = try? await execInHelper(helperID: helperID, command: ["losetup", "-d", loopDevice])
            throw HelperContainerError.operationFailed("mount failed: \(mountResult.stderr)")
        }

        logger.debug("Filesystem mounted", metadata: [
            "helper_id": "\(helperID)",
            "mount_point": "\(mountPoint)",
            "read_only": "\(readOnly)"
        ])

        return loopDevice
    }

    /// Mount the target container's filesystem for reading (merged view) or writing (upper layer only)
    /// Note: Nested OverlayFS doesn't work in Apple's VMs, so we use a different strategy:
    /// - For writes: Mount upper layer directly, create directories as needed
    /// - For reads: Mount layers individually and search through them
    private func mountTargetFilesystemWithOverlayFS(
        helperID: String,
        layerCount: Int,
        mountPoint: String,
        readOnly: Bool
    ) async throws -> String {
        // Step 1: Set up loop device for writable.ext4 (upper layer)
        let findResult = try await execInHelper(helperID: helperID, command: ["losetup", "-f"])
        if findResult.exitCode != 0 {
            throw HelperContainerError.operationFailed("losetup -f failed: \(findResult.stderr)")
        }
        let upperLoopDevice = findResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !upperLoopDevice.isEmpty else {
            throw HelperContainerError.operationFailed("losetup -f returned empty device")
        }

        let attachResult = try await execInHelper(helperID: helperID, command: ["losetup", upperLoopDevice, "/mnt/target-host/writable.ext4"])
        if attachResult.exitCode != 0 {
            throw HelperContainerError.operationFailed("losetup attach writable.ext4 failed: \(attachResult.stderr)")
        }

        // Mount writable.ext4
        _ = try await execInHelper(helperID: helperID, command: ["mkdir", "-p", "/mnt/writable"])
        let mountWritableResult = try await execInHelper(helperID: helperID, command: ["mount", upperLoopDevice, "/mnt/writable"])
        if mountWritableResult.exitCode != 0 {
            _ = try? await execInHelper(helperID: helperID, command: ["losetup", "-d", upperLoopDevice])
            throw HelperContainerError.operationFailed("mount writable failed: \(mountWritableResult.stderr)")
        }

        // Verify upper directory exists (should be pre-created in writable.ext4)
        // The /upper and /work directories are now created when writable.ext4 is formatted
        // (see OverlayFSMounter.createWritableFilesystem). This is a safety check for
        // containers created before this fix was applied.
        let writableContentsResult = try await execInHelper(helperID: helperID, command: ["ls", "-la", "/mnt/writable/"])
        logger.debug("Writable filesystem contents", metadata: [
            "helper_id": "\(helperID)",
            "contents": "\(writableContentsResult.stdout)"
        ])

        logger.debug("Upper layer mounted", metadata: [
            "helper_id": "\(helperID)",
            "loop_device": "\(upperLoopDevice)"
        ])

        // Step 2: Set up loop devices and mount each layer (for reading)
        for i in 0..<layerCount {
            let layerFile = "/mnt/layers/\(i)/layer.ext4"

            // Get next free loop device
            let findLayerResult = try await execInHelper(helperID: helperID, command: ["losetup", "-f"])
            if findLayerResult.exitCode != 0 {
                continue
            }
            let layerLoopDevice = findLayerResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)

            // Attach layer file to loop device (read-only)
            let attachLayerResult = try await execInHelper(helperID: helperID, command: ["losetup", "-r", layerLoopDevice, layerFile])
            if attachLayerResult.exitCode != 0 {
                continue
            }

            // Mount layer read-only
            let layerMountPoint = "/mnt/layer\(i)"
            _ = try await execInHelper(helperID: helperID, command: ["mkdir", "-p", layerMountPoint])
            let mountLayerResult = try await execInHelper(helperID: helperID, command: ["mount", "-o", "ro", layerLoopDevice, layerMountPoint])
            if mountLayerResult.exitCode != 0 {
                _ = try? await execInHelper(helperID: helperID, command: ["losetup", "-d", layerLoopDevice])
                continue
            }

            logger.debug("Layer mounted", metadata: [
                "layer": "\(i)",
                "mount_point": "\(layerMountPoint)"
            ])
        }

        // Step 3: Use symlink to make /mnt/target point to /mnt/writable/upper
        // Note: bind mount doesn't work in nested OverlayFS environments
        // Symlink is a simple and reliable alternative
        let symlinkResult = try await execInHelper(helperID: helperID, command: [
            "ln", "-sf", "/mnt/writable/upper", mountPoint
        ])

        if symlinkResult.exitCode != 0 {
            logger.warning("Symlink creation failed", metadata: [
                "stderr": "\(symlinkResult.stderr)"
            ])
        }

        // Verify the symlink works
        let verifyResult = try await execInHelper(helperID: helperID, command: [
            "sh", "-c", "ls -la \(mountPoint) && touch \(mountPoint)/write_test && rm \(mountPoint)/write_test && echo OK"
        ])
        logger.debug("Symlink verification", metadata: [
            "helper_id": "\(helperID)",
            "result": "\(verifyResult.stdout)",
            "stderr": "\(verifyResult.stderr)",
            "exit_code": "\(verifyResult.exitCode)"
        ])

        logger.info("Filesystem mounted for docker cp", metadata: [
            "helper_id": "\(helperID)",
            "mount_point": "\(mountPoint)",
            "layer_count": "\(layerCount)",
            "read_only": "\(readOnly)",
            "mode": "symlink-to-upper"
        ])

        return upperLoopDevice
    }

    /// Unmount and clean up the target filesystem in the helper
    private func unmountTargetFilesystem(helperID: String, helper: HelperContainer) async {
        guard let loopDevice = helper.loopDevice else { return }

        // Sync filesystem to ensure all writes are flushed before unmount
        _ = try? await execInHelper(helperID: helperID, command: ["sync"])

        // Unmount the writable filesystem (not /mnt/target which is a symlink)
        // The actual EXT4 filesystem from writable.ext4 is mounted at /mnt/writable
        _ = try? await execInHelper(helperID: helperID, command: ["umount", "/mnt/writable"])

        // Sync again to flush VirtioFS cache to host
        _ = try? await execInHelper(helperID: helperID, command: ["sync"])

        // Detach loop device
        _ = try? await execInHelper(helperID: helperID, command: ["losetup", "-d", loopDevice])

        logger.debug("Filesystem unmounted", metadata: [
            "helper_id": "\(helperID)",
            "loop_device": "\(loopDevice)"
        ])
    }

    /// Destroy helper container for a target
    public func destroyHelper(targetID: String) async throws {
        guard let helper = activeHelpers.removeValue(forKey: targetID) else {
            return
        }

        await cleanupHelper(helper)
    }

    /// Clean up a helper container (unmount and remove)
    /// Called after helper is already removed from activeHelpers to avoid race conditions
    private func cleanupHelper(_ helper: HelperContainer) async {
        logger.info("Cleaning up helper container", metadata: [
            "helper_id": "\(helper.helperID)",
            "target": "\(helper.targetID)"
        ])

        // Try to cleanly unmount before destroying
        await unmountTargetFilesystem(helperID: helper.helperID, helper: helper)

        guard let containerManager = containerManager else { return }

        // Force remove the helper
        try? await containerManager.removeContainer(id: helper.helperID, force: true)

        logger.debug("Helper container destroyed", metadata: [
            "helper_id": "\(helper.helperID)"
        ])
    }

    // MARK: - Exec Helpers

    /// Result of executing a command in the helper
    private struct ExecResult {
        let exitCode: Int32
        let stdout: String
        let stderr: String
    }

    /// Execute a command in the helper container and capture output
    private func execInHelper(helperID: String, command: [String]) async throws -> ExecResult {
        guard let containerManager = containerManager,
              let nativeContainer = await containerManager.getNativeContainer(id: helperID) else {
            throw HelperContainerError.helperNotRunning(helperID)
        }

        // Create process configuration
        var processConfig = LinuxProcessConfiguration()
        processConfig.arguments = command
        processConfig.workingDirectory = "/"
        processConfig.terminal = false

        // Create output collectors
        let stdoutCollector = OutputCollector()
        let stderrCollector = OutputCollector()

        processConfig.stdout = stdoutCollector
        processConfig.stderr = stderrCollector

        // Execute the command
        let execID = UUID().uuidString
        let process = try await nativeContainer.exec(execID, configuration: processConfig)
        try await process.start()

        // Wait for completion
        let exitStatus = try await process.wait()

        // Clean up process
        try await process.delete()

        return ExecResult(
            exitCode: exitStatus.exitCode,
            stdout: stdoutCollector.output,
            stderr: stderrCollector.output
        )
    }

    /// Stat a path inside the helper container
    private func statPathInHelper(helperID: String, path: String) async throws -> PathStat {
        // Use stat command to get file info
        // Format: %n (name) %s (size) %f (mode hex) %Y (mtime unix) %N (link target if symlink)
        let statResult = try await execInHelper(
            helperID: helperID,
            command: ["stat", "-c", "%n|%s|%f|%Y", path]
        )

        if statResult.exitCode != 0 {
            throw HelperContainerError.operationFailed("stat failed: \(statResult.stderr)")
        }

        let parts = statResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "|")
        guard parts.count >= 4 else {
            throw HelperContainerError.operationFailed("Invalid stat output")
        }

        let name = (path as NSString).lastPathComponent
        let size = Int64(parts[1]) ?? 0
        let modeHex = String(parts[2])
        let mode = UInt32(modeHex, radix: 16) ?? 0
        let mtime = Int64(parts[3]) ?? 0

        // Convert unix timestamp to RFC3339
        let date = Date(timeIntervalSince1970: TimeInterval(mtime))
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let mtimeStr = formatter.string(from: date)

        // Check if it's a symlink and get target
        var linkTarget = ""
        if (mode & 0xF000) == 0xA000 {  // S_IFLNK
            let readlinkResult = try? await execInHelper(helperID: helperID, command: ["readlink", path])
            if let result = readlinkResult, result.exitCode == 0 {
                linkTarget = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        return PathStat(
            name: name,
            size: size,
            mode: mode,
            mtime: mtimeStr,
            linkTarget: linkTarget
        )
    }

    // MARK: - Helper Methods

    /// Get the path to a container's writable.ext4 block device
    private func getTargetWritablePath(targetID: String) async throws -> String {
        // Containers are stored at:
        // ~/Library/Application Support/com.apple.containerization/containers/{uuid}/writable.ext4
        // We need to get the native UUID for this Docker ID

        guard let containerManager = containerManager else {
            throw HelperContainerError.managerNotAvailable
        }

        // Get the native container ID from the mapping
        guard let nativeID = await containerManager.getNativeID(forDockerID: targetID) else {
            throw HelperContainerError.targetNotFound(targetID)
        }

        // The containerization framework stores containers in a specific location
        let containerizationPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.apple.containerization/containers")

        let writablePath = containerizationPath
            .appendingPathComponent(nativeID)
            .appendingPathComponent("writable.ext4")
            .path

        return writablePath
    }

    /// Ensure the helper base image is available
    private func ensureHelperImage() async throws {
        guard let imageManager = imageManager else {
            throw HelperContainerError.managerNotAvailable
        }

        // Check if image exists
        do {
            _ = try await imageManager.getImage(nameOrId: Self.helperImage)
            logger.debug("Helper image already available", metadata: ["image": "\(Self.helperImage)"])
        } catch {
            // Pull the image
            logger.info("Pulling helper image", metadata: ["image": "\(Self.helperImage)"])

            _ = try await imageManager.pullImage(
                reference: Self.helperImage,
                auth: nil,
                progress: nil
            )

            logger.info("Helper image pulled successfully", metadata: ["image": "\(Self.helperImage)"])
        }
    }

    /// Wait for helper container to be ready
    private func waitForHelperReady(helperID: String) async throws {
        guard let containerManager = containerManager else {
            throw HelperContainerError.managerNotAvailable
        }

        let maxAttempts = 50
        let retryDelay: Duration = .milliseconds(100)

        for attempt in 1...maxAttempts {
            guard let info = try? await containerManager.getContainer(id: helperID) else {
                if attempt == maxAttempts {
                    throw HelperContainerError.helperNotRunning(helperID)
                }
                try await Task.sleep(for: retryDelay)
                continue
            }

            if info.state.running {
                logger.debug("Helper container ready", metadata: [
                    "helper_id": "\(helperID)",
                    "attempts": "\(attempt)"
                ])
                return
            }

            try await Task.sleep(for: retryDelay)
        }

        throw HelperContainerError.helperNotRunning(helperID)
    }
}

// MARK: - Output Collector

/// Simple writer that collects output into a string
private final class OutputCollector: Writer, @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()

    var output: String {
        lock.lock()
        defer { lock.unlock() }
        return String(data: data, encoding: .utf8) ?? ""
    }

    func write(_ newData: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        data.append(newData)
    }

    func close() throws {
        // Nothing to close
    }
}

// MARK: - Errors

public enum HelperContainerError: Error, CustomStringConvertible {
    case managerNotAvailable
    case targetNotFound(String)
    case writableNotFound(String)
    case helperCreationFailed(String)
    case helperNotRunning(String)
    case operationFailed(String)

    public var description: String {
        switch self {
        case .managerNotAvailable:
            return "Container manager not available"
        case .targetNotFound(let id):
            return "Target container not found: \(id)"
        case .writableNotFound(let path):
            return "Target container's writable filesystem not found: \(path)"
        case .helperCreationFailed(let msg):
            return "Failed to create helper container: \(msg)"
        case .helperNotRunning(let id):
            return "Helper container not running: \(id)"
        case .operationFailed(let msg):
            return "Filesystem operation failed: \(msg)"
        }
    }
}
