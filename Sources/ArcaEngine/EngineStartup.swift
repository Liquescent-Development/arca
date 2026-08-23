import ContainerBridge
import Foundation
import Logging

/// The engine's inputs, split by mutability.
///
/// `stateRoot` is mutable and private to this engine: state.db, images/,
/// image-rootfs/, volumes/, logs/. (`layers/` was in this list until the
/// single-composed-rootfs revert; `image-rootfs/` replaced it, and `volumes/`
/// was dropped from the sentence by mistake in the same edit --
/// `EnginePaths.volumesRoot` never went anywhere. The list names the children
/// this sentence is about and is not an inventory of `EnginePaths.init`, which
/// also assigns `vminit-digest` and `arca.sock`.) Sharing it with a live
/// ArcaDaemon is the hazard the C1 review finding named -- ContainerManager's
/// restore loop marks persisted "running" containers exited 137 and writes that
/// back.
///
/// `kernelPath` and `vminitLayout` are read-only inputs. A file two processes
/// read is safe to share; a state root is not. They are separate options so
/// that the CLI cannot express the confusion, and it is why the kernel is no
/// longer one of `EnginePaths`' derivations: deriving it from the state root
/// forced a read-only file to live inside the one directory the engine owns.
///
/// **Constructed from the raw option strings, not from `URL`s, and that is load
/// bearing.** `URL(fileURLWithPath:)` resolves a relative path against the
/// working directory, so `""`, `"."`, `".."` and `"a/b"` all become ordinary
/// absolute paths at the moment of the parse -- MEASURED with a `swiftc` probe
/// on 2026-08-22. Taking `URL`s here would destroy, before any validation ran,
/// the only evidence that distinguishes those four from a state root the
/// operator meant. `--state-root ""` recursively removed `$CWD/layers` while
/// this type took a `URL`. The raw text is kept so `validateEngineInputs` can
/// refuse them; see `LayerCacheReclaim.rootRefusal(for:)`.
public struct EngineInputs: Sendable {
    /// Exactly what `--state-root` carried, before any resolution.
    public let stateRootOption: String

    public let stateRoot: URL
    public let kernelPath: URL
    public let vminitLayout: URL

    public init(stateRoot: String, kernelPath: String, vminitLayout: String) {
        self.stateRootOption = stateRoot
        self.stateRoot = URL(fileURLWithPath: stateRoot)
        self.kernelPath = URL(fileURLWithPath: kernelPath)
        self.vminitLayout = URL(fileURLWithPath: vminitLayout)
    }
}

public enum EngineStartupError: Error, CustomStringConvertible {
    case missingInput(name: String, path: String)
    case unreadableInput(name: String, path: String, cause: String)
    /// Carries the option and the path for the same reason the two cases above
    /// do: this is the one refusal a user meets after the paths validated, and
    /// "the vminit layout holds X, not Y" names neither the option to change
    /// nor the layout that was read. A refusal that does not say what to fix is
    /// a worse failure than a crash.
    case unexpectedVminitReference(name: String, path: String, expected: String, actual: String)
    /// An option whose *text* is wrong, as distinct from an option naming a path
    /// that is wrong. It carries the raw value rather than a resolved path
    /// because for `--state-root` the two differ: the empty and relative forms
    /// are gone by the time a `URL` exists. See `EngineInputs`.
    case unusableOptionValue(name: String, value: String, cause: String)

    public var description: String {
        switch self {
        case .missingInput(let name, let path):
            return "\(name) names nothing that exists: \(path)"
        case .unreadableInput(let name, let path, let cause):
            return "\(name) is unusable at \(path): \(cause)"
        case .unexpectedVminitReference(let name, let path, let expected, let actual):
            return "\(name) at \(path) holds \(actual), not \(expected)"
        case .unusableOptionValue(let name, let value, let cause):
            return "\(name) \(cause): \(value.isEmpty ? "\"\"" : value). Pass a canonical "
                + "absolute directory."
        }
    }
}

/// Refuses before any manager is constructed, so a bad input costs a clear
/// error rather than a partially-initialised engine.
public func validateEngineInputs(_ inputs: EngineInputs) throws {
    let fileManager = FileManager.default

    // `--state-root` first, and ahead of every check that touches the
    // filesystem, because it is the one option this engine *deletes* out of:
    // `EngineManagers.init` reclaims `<state-root>/layers` on every start. The
    // rule is `LayerCacheReclaim`'s own, applied here to the raw option text
    // because this is the last point at which the empty and relative forms are
    // still distinguishable -- the reclaim's copy of the same check sees a path
    // `URL` has already resolved. Neither check subsumes the other; the doc
    // comment on `rootRefusal(for:)` says which catches what.
    //
    // Unlike the two below, this refusal reads no filesystem at all, so it
    // cannot itself be the thing that creates or touches a wrong directory.
    if let reason = LayerCacheReclaim.rootRefusal(for: inputs.stateRootOption) {
        throw EngineStartupError.unusableOptionValue(
            name: stateRootOption, value: inputs.stateRootOption, cause: reason
        )
    }

    var isDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: inputs.kernelPath.path, isDirectory: &isDirectory) else {
        throw EngineStartupError.missingInput(
            name: "--kernel-path", path: inputs.kernelPath.path
        )
    }
    guard !isDirectory.boolValue else {
        throw EngineStartupError.unreadableInput(
            name: "--kernel-path", path: inputs.kernelPath.path,
            cause: "is a directory, not a kernel image"
        )
    }

    try validateOCILayoutDirectory(inputs.vminitLayout, option: vminitLayoutOption)
}

/// Refuses a directory that is not an OCI image layout, naming the option the
/// caller would change and the path it tried.
///
/// Parameterised by option name rather than fixed to `--vminit-layout` because
/// two options now point at OCI layouts: `--vminit-layout`, the startup input,
/// and `--oci-layout` on `arca-engine image load`, the workspace image a
/// consumer pushes afterwards. They are separate options over separate
/// mechanisms on purpose (a startup input is not pushed content), but "what
/// makes a directory an OCI layout" is one question, and answering it twice is
/// two answers free to drift -- the defect Task 1's duplicated wiring already
/// cost this milestone in another form.
///
/// The marker check is EXISTENCE-ONLY, which is deliberate and bounded: it
/// rejects an empty directory, a file, and a half-written layout, but a layout
/// whose `oci-layout` and `index.json` are both zero bytes passes here and
/// fails inside `ImageStore.load`. That residue is why `loadWorkspaceImages`
/// wraps the load itself rather than trusting this check to be the only
/// refusal.
package func validateOCILayoutDirectory(_ directory: URL, option: String) throws {
    let fileManager = FileManager.default

    var isDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory) else {
        throw EngineStartupError.missingInput(name: option, path: directory.path)
    }
    guard isDirectory.boolValue else {
        throw EngineStartupError.unreadableInput(
            name: option, path: directory.path,
            cause: "is a file, not an OCI layout directory"
        )
    }

    // An OCI layout is identified by these two files. Checking only that the
    // directory exists would accept an empty directory and fail later, inside
    // ImageManager, with a message about the wrong thing.
    for marker in ["oci-layout", "index.json"] {
        let path = directory.appendingPathComponent(marker).path
        guard fileManager.fileExists(atPath: path) else {
            throw EngineStartupError.unreadableInput(
                name: option, path: directory.path,
                cause: "is not an OCI layout: no \(marker)"
            )
        }
    }
}

/// The option `validateEngineInputs` and `loadVminit` refuse on behalf of, so a
/// refusal names the thing the user would change.
private let vminitLayoutOption = "--vminit-layout"

/// The option whose value becomes the directory the engine owns -- and the one
/// the per-layer cache reclaim deletes a child out of.
private let stateRootOption = "--state-root"

/// The reference the exported layout carries. VERIFIED against the real one:
/// `head -c 400 ~/.arca/vminit/index.json` shows its single manifest annotated
/// `"org.opencontainers.image.ref.name": "arca-vminit:latest"`. It is also the
/// reference `ContainerManager.initialize()` resolves the initfs from
/// (ContainerBridge/ContainerManager.swift:275), so the two must agree.
private let expectedVminitReference = "arca-vminit:latest"

/// The digest of the vminit the initfs in this state root was built from, or
/// nil if nothing has been recorded yet.
///
/// Absent reads as nil rather than as an error: the first start against a fresh
/// state root has no record, and that is not a fault. An unreadable or corrupt
/// record reads as nil too, and costs one regeneration rather than a refusal to
/// start -- the right price for what is a cache key, not an input.
public func recordedVminitDigest(stateRoot: URL) -> String? {
    try? String(
        contentsOf: EnginePaths(stateRoot: stateRoot).vminitDigest, encoding: .utf8
    ).trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Records the digest of the vminit the initfs was built from.
public func recordVminitDigest(_ digest: String, stateRoot: URL) throws {
    let paths = EnginePaths(stateRoot: stateRoot)
    try FileManager.default.createDirectory(
        at: paths.stateRoot, withIntermediateDirectories: true
    )
    try digest.write(to: paths.vminitDigest, atomically: true, encoding: .utf8)
}

/// Loads the vminit layout into the engine's OWN image store, regenerating the
/// initfs if and only if the image changed, and returns the loaded digest.
///
/// The store is the engine's because `imageManager` is rooted at
/// `EnginePaths.imageStoreRoot`, and `initfs.ext4` follows the store:
/// Containerization builds it inside whichever image store it is handed. So
/// this engine never touches the file ArcaDaemon deletes on every start, and
/// the two need no coordination.
///
/// Regeneration is keyed on the digest rather than unconditional. Deleting the
/// initfs on every start would rebuild a ~178MB image for no correctness gain,
/// since Containerization reuses an existing file
/// (containerization/Sources/Containerization/ContainerManager.swift:148-162).
///
/// An unexpected reference is a refusal. ArcaDaemon logs and continues in the
/// same place (ArcaDaemon.swift:131-133); booting sandboxes on an unknown init
/// image is not a warning-level condition.
public func loadVminit(
    from layout: URL,
    into imageManager: ImageManager,
    stateRoot: URL,
    logger: Logger
) async throws -> String {
    let loaded = try await imageManager.loadFromOCILayout(directory: layout)
    guard let image = loaded.first(where: { $0.reference == expectedVminitReference }) else {
        throw EngineStartupError.unexpectedVminitReference(
            name: vminitLayoutOption,
            path: layout.path,
            expected: expectedVminitReference,
            actual: loaded.map(\.reference).joined(separator: ", ")
        )
    }

    let digest = image.digest
    guard recordedVminitDigest(stateRoot: stateRoot) != digest else {
        logger.debug("vminit unchanged; keeping the existing initfs", metadata: [
            "digest": "\(digest)"
        ])
        return digest
    }

    // Removed before the record is written and never after: a record written
    // over a failed removal claims the initfs was built from an image it was
    // not, and every later start believes it. Which is also why the removal is
    // `try` and not `try?` -- a file that cannot be removed is a stale init
    // image the engine would go on to boot.
    let initfs = EnginePaths(stateRoot: stateRoot).initfs
    if FileManager.default.fileExists(atPath: initfs.path) {
        try FileManager.default.removeItem(at: initfs)
    }
    logger.info("vminit changed; initfs will be regenerated", metadata: [
        "digest": "\(digest)",
        "initfs": "\(initfs.path)",
    ])
    try recordVminitDigest(digest, stateRoot: stateRoot)
    return digest
}
