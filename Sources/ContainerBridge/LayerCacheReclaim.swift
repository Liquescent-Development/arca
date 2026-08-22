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
/// `layers` child of the root it is handed and nothing above, beside or beyond it; it refuses
/// a root that could not be a state root at all (`rootRefusal(for:)`); and it refuses rather
/// than guesses when that child is anything other than a real directory.
///
/// **Every refusal carries its remedy.** What is being refused is a regenerable cache, and a
/// refusal blocks the start of whichever binary asked -- so an error that only says "no" turns
/// a stale directory into a process that will not run. Each message names the exact path, what
/// was found there, and the one command that clears it. That is what makes the throw
/// actionable; it is not a reason to soften the throw. Nothing here swallows a failure, retries
/// one, or continues past one: the single `catch` below rethrows with the remedy attached and
/// keeps the original error as `cause`.
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

    /// Why `path` may not be a root this code deletes a `layers` child out of, or nil if it
    /// may be one.
    ///
    /// One rule, two callers, because they hold different halves of the evidence and neither
    /// half is sufficient:
    ///
    ///   - `ArcaEngine.validateEngineInputs` applies it to the **raw `--state-root` option
    ///     string**, which is the last point at which the empty and relative forms are still
    ///     distinguishable from a root the operator meant. MEASURED with a `swiftc` probe on
    ///     2026-08-22: `URL(fileURLWithPath:)` resolves `""`, `"."`, `".."` and
    ///     `"relative/root"` against the working directory, so all four reach a `URL` as
    ///     ordinary absolute paths. MEASURED in this task's review round: with no rule here,
    ///     `arca-engine serve --state-root ""` recursively removed `$CWD/layers`.
    ///   - `reclaimLayersDirectory` applies it to the root it was actually handed, because
    ///     `ArcaDaemon` never passes through `validateEngineInputs` and because a future
    ///     caller should not have to know that it must. What survives into a `URL` is the
    ///     non-canonical and filesystem-root forms; this catches those, and it cannot catch
    ///     the four above, which is why the boundary check is not redundant.
    ///
    /// Returns a reason rather than throwing, so each caller can raise it in its own error
    /// type -- `EngineStartupError`, which names the CLI option, or `ContainerizationError`
    /// here -- without either owning the other's vocabulary.
    public static func rootRefusal(for path: String) -> String? {
        if path.isEmpty {
            return "is empty"
        }
        guard path.hasPrefix("/") else {
            return "is not an absolute path (it must begin with `/`); a relative root resolves "
                + "against whatever working directory the process happened to start in"
        }
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            if component == "." || component == ".." {
                return "is not canonical: it contains a `\(component)` component, which the "
                    + "filesystem resolves after this check rather than before it"
            }
        }
        guard path != "/" else {
            return "is the filesystem root"
        }
        return nil
    }

    /// Deletes `<root>/layers` if -- and only if -- that path is a directory.
    ///
    /// `lstat` rather than `FileManager.fileExists(atPath:isDirectory:)`. The reason that
    /// carries the most weight is **failure**: `fileExists` collapses every error into
    /// `false`, so a `layers` directory whose parent has become unreadable would be reported
    /// as absent and the reclaim would report success over a directory it never saw. `lstat`
    /// separates `ENOENT` from every other errno, and only `ENOENT` is silent. It also does
    /// not follow symbolic links, which `fileExists` does -- that difference is what lets the
    /// refusal below name a link at all, but it is not what bounds the blast radius; see the
    /// race note.
    ///
    /// **The `lstat`-then-`removeItem` pair is not atomic, and the residue is bounded.** The
    /// name can be repointed between the two calls, so the check passing is not a guarantee
    /// about what `removeItem` opens. What keeps that from reaching outside the scope is
    /// `removeItem`'s own behaviour: handed a symbolic link, it unlinks the link and does not
    /// descend through it, so a name repointed at a live tree costs the link and nothing else.
    /// `LayerCacheReclaimTests.testRemovingASymbolicLinkUnlinksItWithoutFollowingIt` pins that
    /// property rather than leaving this paragraph to assert it.
    ///
    /// Absence -- `ENOENT` -- is the one condition that is not an error: this runs on every
    /// start, and the second start has nothing left to reclaim.
    private static func reclaimLayersDirectory(under root: URL, logger: Logger?) throws {
        if let reason = rootRefusal(for: root.path) {
            throw ContainerizationError(
                .invalidState,
                message: "refusing to reclaim the orphaned per-layer cache: the root "
                    + "\(quoted(root.path)) \(reason). Pass a canonical absolute directory."
            )
        }

        let layers = root.appendingPathComponent(layersDirectoryName)

        var status = stat()
        guard lstat(layers.path, &status) == 0 else {
            let failure = errno
            guard failure == ENOENT else {
                throw ContainerizationError(
                    .invalidState,
                    message: "could not inspect \(quoted(layers.path)): "
                        + "\(String(cString: strerror(failure))) (errno \(failure)). That path "
                        + "holds the orphaned per-layer cache and no other code path reads or "
                        + "removes it. To clear it and let the next start proceed: "
                        + "rm -rf \(quoted(layers.path))"
                )
            }
            return
        }

        guard status.st_mode & S_IFMT == S_IFDIR else {
            throw ContainerizationError(
                .invalidState,
                message: "\(quoted(layers.path)) is \(describe(status.st_mode)), not a "
                    + "directory, so it is not the orphaned per-layer cache this reclaims and "
                    + "removing it would be a guess. No other code path reads or removes it. "
                    + "To clear it and let the next start proceed: "
                    + "\(removalCommand(for: status.st_mode, path: layers.path))"
            )
        }

        do {
            try FileManager.default.removeItem(at: layers)
        } catch {
            throw ContainerizationError(
                .invalidState,
                message: "could not remove the orphaned per-layer cache at "
                    + "\(quoted(layers.path)): \(error). Some of it may still be there, and "
                    + "every later start refuses here until it is gone. To clear it: "
                    + "rm -rf \(quoted(layers.path)) -- and if that reports `Operation not "
                    + "permitted`, a file under it carries a `uchg` or `schg` flag, so run "
                    + "chflags -R nouchg,noschg \(quoted(layers.path)) first",
                cause: error
            )
        }

        logger?.info(
            "reclaimed the orphaned per-layer cache", metadata: ["path": "\(layers.path)"]
        )
    }

    /// The file type as an operator would recognise it, so a refusal says what is actually
    /// there rather than only what it is not.
    private static func describe(_ mode: mode_t) -> String {
        switch mode & S_IFMT {
        case S_IFLNK: return "a symbolic link"
        case S_IFREG: return "a regular file"
        case S_IFIFO: return "a FIFO"
        case S_IFSOCK: return "a socket"
        case S_IFBLK: return "a block device"
        case S_IFCHR: return "a character device"
        default: return "not a directory"
        }
    }

    /// A symbolic link is cleared by `rm`, which removes the link itself and leaves whatever
    /// it points at alone -- the distinction an operator who deliberately moved the cache
    /// elsewhere needs stated, since `rm -rf` on the same path is the same unlink but reads as
    /// though it recurses through the link.
    private static func removalCommand(for mode: mode_t, path: String) -> String {
        mode & S_IFMT == S_IFLNK
            ? "rm \(quoted(path)) -- that removes the link, not what it points at"
            : "rm -rf \(quoted(path))"
    }

    /// Single-quoted for pasting into a shell, with any embedded quote closed and reopened.
    private static func quoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
