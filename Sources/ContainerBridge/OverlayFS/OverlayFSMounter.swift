#if os(macOS)

import Foundation
import Logging
import Containerization
import ContainerizationEXT4
import SystemPackage

/// Helper for mounting OverlayFS in guest VMs
///
/// Encapsulates OverlayFS-specific logic to avoid modifying Apple's containerization framework.
/// Follows the WireGuard pattern: all Arca-specific logic stays in ContainerBridge.
public struct OverlayFSMounter: Sendable {
    private let logger: Logger?

    public init(logger: Logger? = nil) {
        self.logger = logger
    }

    /// Build mounts array for OverlayFS configuration
    ///
    /// Creates mount specifications for:
    /// - Bind mount from `/` to `/run/container/{id}/rootfs` (FIRST mount - becomes container rootfs)
    /// - Writable block device (for upper/work directories)
    /// - Layer block devices (read-only EXT4 filesystems)
    ///
    /// Device layout in guest:
    /// - /dev/vda: initfs (vminit image, read-only, created by VZVirtualMachineManager)
    /// - /dev/vdb: writable.ext4 (contains upper/ and work/ subdirectories, read-write)
    /// - /dev/vdc onwards: layer0.ext4, layer1.ext4, etc. (read-only layers)
    ///
    /// Mount order is critical:
    /// - First mount is used by LinuxContainer as the rootfs mount
    /// - We use a bind mount from `/` (where vminitd mounts OverlayFS) to container rootfs path
    ///
    /// - Parameters:
    ///   - containerID: Container ID for rootfs path
    ///   - overlayConfig: OverlayFS configuration with layer paths
    ///   - writablePath: Path to writable.ext4 filesystem for upper/work
    ///   - additionalMounts: Additional container mounts (proc, sys, etc.)
    /// - Returns: Array of Mount objects for VM configuration
    public func buildMounts(
        containerID: String,
        overlayConfig: Containerization.OverlayFSConfig,
        writablePath: String,
        additionalMounts: [Containerization.Mount]
    ) -> [Containerization.Mount] {
        var mounts: [Containerization.Mount] = []

        // 1. FIRST MOUNT: Bind mount from `/` to container rootfs path
        // This is CRITICAL - Apple's LinuxContainer.create() mounts the first mount to /run/container/{id}/rootfs
        // Since vminitd mounts OverlayFS at `/` during boot, this bind mount makes the container
        // chroot into the OverlayFS instead of an empty temp-rootfs
        // NOTE: Bind mounts are read-only by default in Linux - we must explicitly specify "rw"
        let rootfsBindMount = Containerization.Mount.any(
            type: "none",
            source: "/",
            destination: "/run/container/\(containerID)/rootfs",
            options: ["bind", "rw"]
        )
        mounts.append(rootfsBindMount)

        logger?.info("Added bind mount for container rootfs", metadata: [
            "source": "/",
            "destination": "/run/container/\(containerID)/rootfs"
        ])

        // 2. Attach writable block device (will be /dev/vdb)
        // Contains upper/ and work/ subdirectories for OverlayFS
        // vminitd will mount this at /mnt/writable during boot
        let writableMount = Containerization.Mount.block(
            format: "ext4",
            source: writablePath,
            destination: "",  // Empty to prevent auto-mount by framework
            options: [],  // No "ro" = writable
            runtimeOptions: []
        )
        mounts.append(writableMount)

        logger?.debug("Added writable block device", metadata: [
            "source": "\(writablePath)",
            "guest_device": "/dev/vdb",
            "readonly": "\(writableMount.options.contains("ro"))",
            "options": "\(writableMount.options)"
        ])

        // 3. Attach each layer.ext4 as a read-only block device
        // Guest will see these as /dev/vdc, /dev/vdd, /dev/vde, etc.
        // vminitd will mount these at /mnt/layer{index} during boot
        for (index, layerPath) in overlayConfig.lowerLayers.enumerated() {
            let layerMount = Containerization.Mount.block(
                format: "ext4",
                source: layerPath.path,
                destination: "",  // Empty to prevent auto-mount by framework
                options: ["ro"],  // Read-only
                runtimeOptions: []
            )
            mounts.append(layerMount)

            // Generate device name matching containerization framework's String.blockDeviceTagAllocator()
            // Layers start at index 2 (vdc): vda=rootfs, vdb=writable, vdc+=layers
            // Index 0-23 → c-z, 24+ → aa, ab, etc.
            let deviceIndex = index + 2  // +2 because vda/vdb are reserved
            let deviceTag: String
            if deviceIndex < 26 {
                deviceTag = String(Character(UnicodeScalar(97 + deviceIndex)!))  // 'a' = 97
            } else {
                let adjusted = deviceIndex - 26
                let first = Character(UnicodeScalar(97 + (adjusted / 26))!)
                let second = Character(UnicodeScalar(97 + (adjusted % 26))!)
                deviceTag = String(first) + String(second)
            }
            logger?.debug("Added layer block device mount", metadata: [
                "index": "\(index)",
                "source": "\(layerPath.path)",
                "guest_device": "/dev/vd\(deviceTag)"
            ])
        }

        // 4. Add additional container mounts (proc, sys, devtmpfs, etc.)
        // These are mounted by vminitd AFTER OverlayFS is mounted at /
        mounts.append(contentsOf: additionalMounts)

        logger?.info("Built OverlayFS mount configuration", metadata: [
            "bind_mount": "/",
            "writable_device": "/dev/vdb",
            "layers": "\(overlayConfig.lowerLayers.count)",
            "layer_devices_start": "/dev/vdc",
            "total_mounts": "\(mounts.count)"
        ])

        return mounts
    }

    /// Get the writable device path in guest
    ///
    /// - Returns: Block device path for writable filesystem (/dev/vdb)
    public static var writableDevicePath: String {
        return "/dev/vdb"
    }

    /// Get mount path for writable filesystem in guest
    ///
    /// - Returns: Path where writable device is mounted
    public static var writableMountPath: String {
        return "/mnt/writable"
    }

    /// Get the layer block device paths in guest
    ///
    /// Returns the device paths that the guest will see for each layer.
    /// Block devices start at /dev/vdc (after writable device at /dev/vdb).
    ///
    /// - Parameter layerCount: Number of layer block devices attached
    /// - Returns: Array of block device paths in guest (e.g., ["/dev/vdc", "/dev/vdd", ...])
    public func buildBlockDevicePaths(layerCount: Int) -> [String] {
        var blockDevices: [String] = []
        for i in 0..<layerCount {
            // Start at 'c' (99) since vdb is writable device
            let deviceChar = Character(UnicodeScalar(99 + i)!)  // 99 = 'c'
            blockDevices.append("/dev/vd\(deviceChar)")
        }
        return blockDevices
    }

    /// Create writable EXT4 filesystem for upper/work directories
    ///
    /// Creates an EXT4 filesystem file that will be mounted in the guest
    /// as /dev/vdc and used for OverlayFS upper and work directories.
    ///
    /// Uses Apple's ContainerizationEXT4 framework for filesystem creation.
    ///
    /// - Parameters:
    ///   - path: Path where to create writable.ext4
    ///   - sizeMB: Size in megabytes (default: 65536 MB = 64 GB, thin-provisioned)
    /// - Throws: If filesystem creation fails
    public func createWritableFilesystem(at path: String, sizeMB: Int = 65536) throws {
        logger?.info("Creating writable filesystem", metadata: [
            "path": "\(path)",
            "size_mb": "\(sizeMB)"
        ])

        // Create parent directory if needed
        let parentDir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: parentDir,
            withIntermediateDirectories: true
        )

        // Create EXT4 filesystem using Apple's ContainerizationEXT4 framework
        // This is the same method used for creating temp-rootfs.ext4
        let sizeBytes = UInt64(sizeMB) * 1024 * 1024  // Convert MB to bytes
        let formatter = try ContainerizationEXT4.EXT4.Formatter(
            FilePath(path),
            minDiskSize: sizeBytes
        )

        // Pre-create /upper and /work directories for OverlayFS
        // IMPORTANT: This is critical for docker cp to never-started containers.
        // When these directories are created through VirtioFS + loop device during
        // docker cp, the filesystem gets corrupted (directories become 60-byte stubs
        // with mode d---------). By pre-creating them here as real ext4 directories,
        // docker cp can write files directly without needing to create these dirs.
        try formatter.create(
            path: FilePath("/upper"),
            mode: EXT4.Inode.Mode(.S_IFDIR, 0o755)
        )
        try formatter.create(
            path: FilePath("/work"),
            mode: EXT4.Inode.Mode(.S_IFDIR, 0o755)
        )

        try formatter.close()

        logger?.info("Writable filesystem created successfully", metadata: [
            "path": "\(path)",
            "size_mb": "\(sizeMB)"
        ])
    }
}

/// Errors that can occur during OverlayFS mounting operations
public enum OverlayFSMounterError: Error, CustomStringConvertible {
    case filesystemCreationFailed(String)

    public var description: String {
        switch self {
        case .filesystemCreationFailed(let message):
            return "Failed to create writable filesystem: \(message)"
        }
    }
}

#endif
