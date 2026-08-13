import Foundation

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
    case unexpectedVminitReference(expected: String, actual: String)

    public var description: String {
        switch self {
        case .missingInput(let name, let path):
            return "\(name) names nothing that exists: \(path)"
        case .unreadableInput(let name, let path, let cause):
            return "\(name) is unusable at \(path): \(cause)"
        case .unexpectedVminitReference(let expected, let actual):
            return "the vminit layout holds \(actual), not \(expected)"
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
