import ContainerBridge
import Foundation
import Logging

/// The engine's inputs, split by mutability.
///
/// `stateRoot` is mutable and private to this engine: state.db, images/,
/// volumes/, layers/. Sharing it with a live ArcaDaemon is the hazard the C1
/// review finding named -- ContainerManager's restore loop marks persisted
/// "running" containers exited 137 and writes that back.
///
/// `kernelPath` and `vminitLayout` are read-only inputs. A file two processes
/// read is safe to share; a state root is not. They are separate options so
/// that the CLI cannot express the confusion, and it is why the kernel is no
/// longer one of `EnginePaths`' derivations: deriving it from the state root
/// forced a read-only file to live inside the one directory the engine owns.
public struct EngineInputs: Sendable {
    public let stateRoot: URL
    public let kernelPath: URL
    public let vminitLayout: URL

    public init(stateRoot: URL, kernelPath: URL, vminitLayout: URL) {
        self.stateRoot = stateRoot
        self.kernelPath = kernelPath
        self.vminitLayout = vminitLayout
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

    public var description: String {
        switch self {
        case .missingInput(let name, let path):
            return "\(name) names nothing that exists: \(path)"
        case .unreadableInput(let name, let path, let cause):
            return "\(name) is unusable at \(path): \(cause)"
        case .unexpectedVminitReference(let name, let path, let expected, let actual):
            return "\(name) at \(path) holds \(actual), not \(expected)"
        }
    }
}

/// Refuses before any manager is constructed, so a bad input costs a clear
/// error rather than a partially-initialised engine.
public func validateEngineInputs(_ inputs: EngineInputs) throws {
    let fileManager = FileManager.default

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

    isDirectory = false
    guard fileManager.fileExists(atPath: inputs.vminitLayout.path, isDirectory: &isDirectory) else {
        throw EngineStartupError.missingInput(
            name: "--vminit-layout", path: inputs.vminitLayout.path
        )
    }
    guard isDirectory.boolValue else {
        throw EngineStartupError.unreadableInput(
            name: "--vminit-layout", path: inputs.vminitLayout.path,
            cause: "is a file, not an OCI layout directory"
        )
    }

    // An OCI layout is identified by these two files. Checking only that the
    // directory exists would accept an empty directory and fail later, inside
    // ImageManager, with a message about the wrong thing.
    for marker in ["oci-layout", "index.json"] {
        let path = inputs.vminitLayout.appendingPathComponent(marker).path
        guard fileManager.fileExists(atPath: path) else {
            throw EngineStartupError.unreadableInput(
                name: "--vminit-layout", path: inputs.vminitLayout.path,
                cause: "is not an OCI layout: no \(marker)"
            )
        }
    }
}

/// The option `loadVminit` refuses on behalf of, so a refusal names the thing
/// the user would change.
private let vminitLayoutOption = "--vminit-layout"

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
