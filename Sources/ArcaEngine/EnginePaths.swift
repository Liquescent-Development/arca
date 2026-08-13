import Foundation

/// Every path the engine derives from its `--state-root`.
///
/// One derivation, in the library, called by `arca-engine` and by the tests
/// alike. Before this existed, `ArcaEngineCommand` and `TestSupport` each spelt
/// out `root.appendingPathComponent("images")` and its five siblings, so the
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

    /// OverlayFS layer cache. Under the state root rather than `~/.arca/layers`,
    /// which is Arca's tree.
    public let layerCache: URL

    /// SQLite database holding container, network and volume state.
    public let stateDatabase: URL

    /// Base directory for named volumes.
    public let volumesRoot: URL

    /// The Linux kernel image the engine boots containers with.
    public let kernel: URL

    /// The socket recorded in `ArcaConfig`. Note that the socket the process
    /// actually serves on comes from `--socket-path`; this is the configured
    /// value the managers are handed.
    public let socket: URL

    public init(stateRoot: URL) {
        self.stateRoot = stateRoot
        self.imageStoreRoot = stateRoot.appendingPathComponent("images")
        self.layerCache = stateRoot.appendingPathComponent("layers")
        self.stateDatabase = stateRoot.appendingPathComponent("state.db")
        self.volumesRoot = stateRoot.appendingPathComponent("volumes")
        self.kernel = stateRoot.appendingPathComponent("vmlinux")
        self.socket = stateRoot.appendingPathComponent("arca.sock")
    }
}
