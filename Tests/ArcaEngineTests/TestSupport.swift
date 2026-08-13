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
                .appendingPathComponent("arca-engine-tests-\(UUID().uuidString)"),
            // Outside the state root on purpose. Nothing here boots a sandbox,
            // so it is never read, and putting it under the root would quietly
            // restate the derivation `--kernel-path` replaced.
            kernelPath: URL(fileURLWithPath: "/opt/arca/vmlinux")
        )
    }

    /// The same service against a state root and kernel the caller names, so a
    /// test can assert on where the managers were actually rooted.
    ///
    /// State-root paths come from `EnginePaths` -- the derivation `arca-engine`
    /// itself calls -- and not from a copy of its `appendingPathComponent`
    /// lines. The copy is what made this helper a replica of the wiring rather
    /// than the wiring: while it stood, changing the engine's real image-store
    /// root left the whole suite green.
    ///
    /// The kernel is a parameter rather than an `EnginePaths` member for the
    /// same reason it is a separate CLI option: it is a read-only input the
    /// engine is handed, not state the engine owns. Deriving it here while
    /// `arca-engine` took it from `--kernel-path` would put the drift back.
    ///
    /// No defaults on either, in keeping with the rule the path parameters on
    /// `ContainerManager` follow: the no-argument overload above states the
    /// throwaway values it wants.
    static func forTesting(stateRoot: URL, kernelPath: URL) -> SandboxEngineService {
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
            kernelPath: kernelPath.path,
            imageStoreRoot: paths.imageStoreRoot,
            layerCachePath: paths.layerCache,
            stateStore: stateStore,
            logger: logger
        )
        let config = ArcaConfig(
            kernelPath: kernelPath.path,
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
