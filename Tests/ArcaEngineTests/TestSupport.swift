import ContainerBridge
import Foundation
import Logging
@testable import ArcaEngine

extension SandboxEngineService {
    /// A service over real ContainerBridge managers against a throwaway state
    /// root. Nothing in Tasks 1-6's tests starts a VM; these managers exist
    /// because the service holds them, not because the tests drive them.
    ///
    /// `StateStore` and `ImageManager` construction is force-tried: a failure
    /// here means the on-disk test fixture (a fresh temp directory) could not
    /// be created, which should fail the test run loudly rather than surface
    /// as an ordinary assertion failure.
    static func forTesting() -> SandboxEngineService {
        forTesting(
            stateRoot: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("arca-engine-tests-\(UUID().uuidString)")
        )
    }

    /// The same service against a state root the caller names, so a test can
    /// assert on where the managers were actually rooted.
    ///
    /// Paths come from `EnginePaths` -- the derivation `arca-engine` itself
    /// calls -- and not from a copy of its `appendingPathComponent` lines. The
    /// copy is what made this helper a replica of the wiring rather than the
    /// wiring: while it stood, changing the engine's real image-store root left
    /// the whole suite green.
    ///
    /// No default for `stateRoot`, in keeping with the rule the path parameters
    /// on `ContainerManager` follow: the no-argument overload above states the
    /// throwaway root it wants.
    static func forTesting(stateRoot: URL) -> SandboxEngineService {
        let logger = Logger(label: "arca-engine-tests")
        let paths = EnginePaths(stateRoot: stateRoot)

        let stateStore = try! StateStore(
            path: paths.stateDatabase.path,
            logger: logger
        )
        let imageManager = try! ImageManager(
            logger: logger,
            imageStorePath: paths.imageStoreRoot
        )
        let containerManager = ContainerManager(
            imageManager: imageManager,
            kernelPath: paths.kernel.path,
            imageStoreRoot: paths.imageStoreRoot,
            layerCachePath: paths.layerCache,
            stateStore: stateStore,
            logger: logger
        )
        let config = ArcaConfig(
            kernelPath: paths.kernel.path,
            socketPath: paths.socket.path,
            logLevel: "info"
        )

        return SandboxEngineService(
            containerManager: containerManager,
            volumeManager: VolumeManager(
                volumesBasePath: paths.volumesRoot.path,
                stateStore: stateStore,
                logger: logger
            ),
            networkManager: NetworkManager(
                config: config,
                stateStore: stateStore,
                containerManager: containerManager,
                logger: logger
            ),
            imageManager: imageManager,
            execManager: ExecManager(containerManager: containerManager, logger: logger),
            logger: logger
        )
    }
}
