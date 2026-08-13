import Foundation

/// Every path the engine derives from its `--state-root`.
///
/// Only mutable state the engine owns is derived here. Read-only inputs are
/// not: the kernel image arrives as `--kernel-path` and the vminit OCI layout
/// as `--vminit-layout`, because a file two processes read is safe to share and
/// a state root is not. See `EngineInputs`.
///
/// One derivation, in the library, called by `arca-engine` and by the tests
/// alike. Before this existed, `ServeCommand` and `TestSupport` each spelt
/// out `root.appendingPathComponent("images")` and its siblings, so the
/// suite exercised a hand-copy of the wiring rather than the wiring: changing
/// the engine's real image-store root left every test green.
///
/// It lives in `ArcaEngine` rather than in the `arca-engine` executable because
/// a test target cannot import an executable, and a derivation only the
/// executable can reach is a derivation no test can assert on.
///
/// A struct with a single initializer rather than a free `enginePaths(_:)`
/// function: the members are one cohesive value, and the type is what later
/// tasks add paths to.
public struct EnginePaths: Sendable, Equatable {
    /// The root the engine was told to own. Everything below is under it, and
    /// that is the property tests assert -- not the individual spellings.
    public let stateRoot: URL

    /// Root of the Containerization ImageStore, and so the directory
    /// `initfs.ext4` is built in. Shared by `ImageManager` and
    /// `ContainerManager`: they must name the same directory or the vminit
    /// image one loads is not the one the other resolves the initfs from.
    public let imageStoreRoot: URL

    /// The init filesystem Containerization unpacks the vminit image into.
    ///
    /// Derived from `imageStoreRoot` and not spelt out from the state root,
    /// because that is where Containerization puts it -- `ContainerManager`
    /// appends `initfs.ext4` to the image store's own path
    /// (containerization/Sources/Containerization/ContainerManager.swift:146).
    /// Restating it from the state root would be a second derivation of the
    /// image store root, free to drift from the first.
    ///
    /// It is the engine's because the store is: ArcaDaemon deletes the copy in
    /// Apple's shared store on every start, and this one is not that file.
    public let initfs: URL

    /// OverlayFS layer cache. Under the state root rather than `~/.arca/layers`,
    /// which is Arca's tree.
    public let layerCache: URL

    /// Digest of the vminit image `initfs` was built from, so that a start can
    /// tell an unchanged vminit from a new one. Beside the state root's other
    /// records and never beside Apple's shared `initfs.ext4`, which belongs to
    /// whichever ArcaDaemon is running.
    public let vminitDigest: URL

    /// SQLite database holding container, network and volume state.
    public let stateDatabase: URL

    /// Base directory for named volumes.
    public let volumesRoot: URL

    /// The socket recorded in `ArcaConfig`. Note that the socket the process
    /// actually serves on comes from `--socket-path`; this is the configured
    /// value the managers are handed.
    public let socket: URL

    public init(stateRoot: URL) {
        self.stateRoot = stateRoot
        self.imageStoreRoot = stateRoot.appendingPathComponent("images")
        self.initfs = self.imageStoreRoot.appendingPathComponent("initfs.ext4")
        self.vminitDigest = stateRoot.appendingPathComponent("vminit-digest")
        self.layerCache = stateRoot.appendingPathComponent("layers")
        self.stateDatabase = stateRoot.appendingPathComponent("state.db")
        self.volumesRoot = stateRoot.appendingPathComponent("volumes")
        self.socket = stateRoot.appendingPathComponent("arca.sock")
    }
}
