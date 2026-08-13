import ContainerBridge
import Foundation
import Logging

/// Every ContainerBridge manager the engine serves over, built once.
///
/// `EnginePaths` unified where the paths come *from*; this unifies which derived
/// path reaches which constructor argument, which was the half still spelt out
/// twice -- once in `ArcaEngineCommand.run()` and once in the tests' own
/// `SandboxEngineService.forTesting`. Task 1's review measured that arrangement:
/// swapping `imageStoreRoot: paths.layerCache` in the command alone left all 34
/// tests of the day green, because the tests drove a parallel wiring over the
/// shared derivation rather than the wiring itself.
///
/// There is one wiring now, and the tests drive it. MEASURED here, with the same
/// swap applied to the `ContainerManager(...)` call below:
/// `swift test --filter ArcaEngineTests` reported `Executed 60 tests, with 1
/// failure`, that failure being
/// `ContainerBridgePathsTests.testTheInitfsIsInsideTheImageStoreTheEngineHandsContainerization`.
/// Restored, the same command reports `Executed 60 tests, with 0 failures`.
///
/// It lives in `ArcaEngine` rather than in the `arca-engine` executable for the
/// reason `EnginePaths` does: a test target cannot import an executable, so a
/// wiring only the executable can reach is a wiring no test can assert on.
///
/// Constructing this does not initialize anything. `initialize()` needs a live
/// `Containerization.VmnetNetwork` and boots nothing until the engine asks --
/// see the ordering note at `ArcaEngineCommand.run()`, which is the only caller
/// that may ask.
public struct EngineManagers: Sendable {
    /// The derivation every path below came from, exposed so a caller can name
    /// the same directories the managers were rooted in without re-deriving
    /// them.
    public let paths: EnginePaths

    public let stateStore: StateStore
    public let imageManager: ImageManager
    public let containerManager: ContainerManager
    public let volumeManager: VolumeManager
    public let networkManager: NetworkManager
    public let execManager: ExecManager

    private let logger: Logger

    /// Builds the managers for one state root.
    ///
    /// The kernel is a parameter rather than an `EnginePaths` member for the
    /// same reason it is a separate CLI option: it is a read-only input the
    /// engine is handed, not state the engine owns.
    ///
    /// `logLevel` reaches `ArcaConfig` only. It is a string here because that is
    /// what `ArcaConfig` takes; the command has already parsed its own
    /// `Logger.Level` from it.
    public init(stateRoot: URL, kernelPath: URL, logLevel: String, logger: Logger) throws {
        let paths = EnginePaths(stateRoot: stateRoot)
        self.paths = paths
        self.logger = logger

        self.stateStore = try StateStore(path: paths.stateDatabase.path, logger: logger)
        self.imageManager = try ImageManager(
            logger: logger, imageStorePath: paths.imageStoreRoot
        )
        self.containerManager = ContainerManager(
            imageManager: imageManager,
            kernelPath: kernelPath.path,
            imageStoreRoot: paths.imageStoreRoot,
            layerCachePath: paths.layerCache,
            stateStore: stateStore,
            logger: logger
        )
        self.volumeManager = VolumeManager(
            volumesBasePath: paths.volumesRoot.path,
            stateStore: stateStore,
            logger: logger
        )
        self.networkManager = NetworkManager(
            config: ArcaConfig(
                kernelPath: kernelPath.path,
                socketPath: paths.socket.path,
                logLevel: logLevel
            ),
            stateStore: stateStore,
            containerManager: containerManager,
            logger: logger
        )
        self.execManager = ExecManager(containerManager: containerManager, logger: logger)
    }

    /// The service over these managers.
    ///
    /// Here rather than at each call site for the reason the wiring above is:
    /// six arguments spelt out twice is six chances for the command and the
    /// tests to hand the service different managers.
    public func makeService() -> SandboxEngineService {
        SandboxEngineService(
            containerManager: containerManager,
            volumeManager: volumeManager,
            networkManager: networkManager,
            imageManager: imageManager,
            execManager: execManager,
            logger: logger
        )
    }
}
