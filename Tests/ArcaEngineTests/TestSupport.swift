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
        let logger = Logger(label: "arca-engine-tests")
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("arca-engine-tests-\(UUID().uuidString)")

        let stateStore = try! StateStore(
            path: root.appendingPathComponent("state.db").path,
            logger: logger
        )
        let imageManager = try! ImageManager(
            logger: logger,
            imageStorePath: root.appendingPathComponent("images")
        )
        let containerManager = ContainerManager(
            imageManager: imageManager,
            kernelPath: root.appendingPathComponent("vmlinux").path,
            imageStoreRoot: root.appendingPathComponent("images"),
            layerCachePath: root.appendingPathComponent("layers"),
            stateStore: stateStore,
            logger: logger
        )
        let config = ArcaConfig(
            kernelPath: root.appendingPathComponent("vmlinux").path,
            socketPath: root.appendingPathComponent("arca.sock").path,
            logLevel: "info"
        )

        return SandboxEngineService(
            containerManager: containerManager,
            volumeManager: VolumeManager(
                volumesBasePath: root.appendingPathComponent("volumes").path,
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
