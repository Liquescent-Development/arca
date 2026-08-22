import ContainerizationError
import Foundation
import Logging

/// Removes the per-layer ext4 cache that the single-composed-rootfs revert orphaned.
///
/// The fork's OverlayFS unpacker kept one ext4 block per image layer under a `layers`
/// directory, and the revert to a single composed rootfs leaves those files with no reader.
/// They are a cache and regenerable by definition, so they are deleted rather than migrated.
///
/// **Two trees, two owners.** The fork wrote a `layers` directory into each of the two roots
/// that ran an unpacker: `<state-root>/layers` under `arca-engine` and `~/.arca/layers` under
/// `ArcaDaemon`. Neither process can reclaim the other's -- the engine's state root is
/// private to the engine by design, and `~/.arca` is Arca's tree (see the note on
/// `EnginePaths.imageRootfs`) -- so each start reclaims its own. Renaming the live cache to
/// `image-rootfs` is what made the old directory unreachable, and therefore what would have
/// made it permanent.
///
/// **The two entry points differ only in what they name, and that is the point.** They share
/// one implementation, so there is one deletion rule; the argument labels are what make a
/// call site state which tree it is deleting out of, rather than passing an unlabelled root
/// into the most destructive operation in the revert.
///
/// Scoping is the correctness property here, not the deletion. The reclaim touches the single
/// `layers` child of the root it is handed and nothing above, beside or beyond it, and it
/// refuses rather than guesses when that child is anything other than a real directory.
public enum LayerCacheReclaim {
    /// The one directory name both orphans share.
    private static let layersDirectoryName = "layers"

    /// Reclaims `arca-engine`'s orphan, under the state root the engine owns.
    public static func run(stateRoot: URL, logger: Logger? = nil) throws {
        try reclaimLayersDirectory(under: stateRoot, logger: logger)
    }

    /// Reclaims `ArcaDaemon`'s orphan, under `~/.arca`.
    public static func run(arcaRoot: URL, logger: Logger? = nil) throws {
        try reclaimLayersDirectory(under: arcaRoot, logger: logger)
    }

    /// Deletes `<root>/layers` if -- and only if -- that path is a directory.
    ///
    /// `lstat` rather than `FileManager.fileExists(atPath:isDirectory:)`, for two reasons that
    /// both matter to a recursive delete: `fileExists` follows symbolic links, so a `layers`
    /// symlink pointing at a live tree would be reported as a directory; and it collapses
    /// every failure into `false`, so an unreadable path would be indistinguishable from an
    /// absent one and the reclaim would report success over a directory it never saw.
    /// Absence -- `ENOENT` -- is the one condition that is not an error: this runs on every
    /// start, and the second start has nothing left to reclaim.
    private static func reclaimLayersDirectory(under root: URL, logger: Logger?) throws {
        let layers = root.appendingPathComponent(layersDirectoryName)

        var status = stat()
        guard lstat(layers.path, &status) == 0 else {
            let failure = errno
            guard failure == ENOENT else {
                throw ContainerizationError(
                    .invalidState,
                    message: "could not inspect \(layers.path) (errno \(failure): "
                        + "\(String(cString: strerror(failure)))); refusing to reclaim a tree "
                        + "this version cannot see"
                )
            }
            return
        }

        guard status.st_mode & S_IFMT == S_IFDIR else {
            throw ContainerizationError(
                .invalidState,
                message: "\(layers.path) exists and is not a directory; refusing to reclaim a "
                    + "tree this version does not understand"
            )
        }

        try FileManager.default.removeItem(at: layers)
        logger?.info(
            "reclaimed the orphaned per-layer cache", metadata: ["path": "\(layers.path)"]
        )
    }
}
