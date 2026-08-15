#if os(macOS)

import Foundation
import Logging
import Containerization
import ContainerizationOCI

/// Arca-specific OverlayFS unpacker with layer caching and database integration
///
/// This wrapper extends Apple's Containerization framework with:
/// - Layer caching at {layerCachePath}/{digest}/layer.ext4 -- the path is this
///   type's own init parameter, and it is `<state-root>/layers` under
///   `arca-engine`, `~/.arca/layers` only under `ArcaDaemon`
/// - Database integration for cache tracking
/// - Parallel layer unpacking for performance
///
/// Follows the WireGuard pattern: all Arca-specific logic stays in ContainerBridge.
public actor OverlayFSUnpacker {
    private let logger: Logger
    private let baseUnpacker: Containerization.OverlayFSUnpacker
    private let layerCachePath: URL
    private let stateStore: StateStore

    public init(layerCachePath: URL, stateStore: StateStore, logger: Logger) {
        self.logger = logger
        self.layerCachePath = layerCachePath
        self.stateStore = stateStore

        // Initialize base unpacker from containerization framework
        self.baseUnpacker = Containerization.OverlayFSUnpacker(
            layerCachePath: layerCachePath,
            recorder: stateStore  // StateStore implements LayerCacheRecorder
        )
    }

    /// Unpack image layers with caching
    ///
    /// This is the main entry point for OverlayFS-based container creation.
    /// It unpacks all layers in parallel (where possible) and returns an OverlayFSConfig.
    ///
    /// - Parameters:
    ///   - image: The OCI image to unpack
    ///   - platform: The target platform (e.g., linux/arm64)
    ///   - containerPath: Path to container directory (for upper/work dirs)
    /// - Returns: OverlayFSConfig with layer paths and upper/work directories
    public func unpack(
        _ image: Containerization.Image,
        for platform: ContainerizationOCI.Platform,
        at containerPath: URL
    ) async throws -> Containerization.OverlayFSConfig {
        logger.info("Starting OverlayFS unpack", metadata: [
            "image": "\(image.reference)",
            "container_path": "\(containerPath.path)",
            "platform": "\(platform.os)/\(platform.architecture)"
        ])

        // Delegate to base unpacker - it handles parallel unpacking and caching
        let config = try await baseUnpacker.unpack(
            image,
            for: platform,
            at: containerPath,
            progress: nil
        )

        logger.info("OverlayFS unpack complete", metadata: [
            "layers": "\(config.lowerLayers.count)",
            "upper": "\(config.upperDir.path)",
            "work": "\(config.workDir.path)"
        ])

        return config
    }
}

#endif