import ContainerBridge
import Foundation
import Logging
import XCTest

final class ContainerBridgePathsTests: XCTestCase {
    private func temporaryRoot() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("arca-paths-\(UUID().uuidString)")
    }

    /// The engine must not share Apple's containerization image store, because
    /// `initfs.ext4` is derived from it -- Containerization's ContainerManager
    /// builds `imageStore.path/initfs.ext4`. Sharing that store is what forces
    /// ArcaDaemon to delete the file on every start; a private root removes the
    /// need for any coordination.
    func testTheImageStoreRootIsTheOneItWasGiven() throws {
        let logger = Logger(label: "paths-tests")
        let root = temporaryRoot()
        let stateStore = try StateStore(
            path: root.appendingPathComponent("state.db").path,
            logger: logger
        )
        let imageStoreRoot = root.appendingPathComponent("images")
        let manager = ContainerManager(
            imageManager: try ImageManager(logger: logger, imageStorePath: imageStoreRoot),
            kernelPath: root.appendingPathComponent("vmlinux").path,
            imageStoreRoot: imageStoreRoot,
            layerCachePath: root.appendingPathComponent("layers"),
            stateStore: stateStore,
            logger: logger
        )

        // containerizationRoot() and not imageStoreRoot: the stored property is
        // beside the decision, not the decision. MEASURED: with initialize()
        // reverted to pass no `root:` at all, assertions on the property alone
        // reported "Executed 2 tests, with 0 failures". containerizationRoot()
        // is the value initialize() hands to Containerization, so reverting the
        // selection is red.
        XCTAssertEqual(manager.containerizationRoot(), imageStoreRoot)
        XCTAssertEqual(manager.imageStoreRoot, imageStoreRoot)
        XCTAssertFalse(
            manager.containerizationRoot().path.contains("com.apple.containerization"),
            "the engine's image store must not resolve into Apple's shared store"
        )
    }

    /// `~/.arca/layers` was hardcoded, so a dev.gascan-rooted engine would still
    /// write its layer cache into Arca's tree.
    func testTheLayerCacheIsTheOneItWasGiven() throws {
        let logger = Logger(label: "paths-tests")
        let root = temporaryRoot()
        let stateStore = try StateStore(
            path: root.appendingPathComponent("state.db").path,
            logger: logger
        )
        let layerCachePath = root.appendingPathComponent("layers")
        let manager = ContainerManager(
            imageManager: try ImageManager(
                logger: logger,
                imageStorePath: root.appendingPathComponent("images")
            ),
            kernelPath: root.appendingPathComponent("vmlinux").path,
            imageStoreRoot: root.appendingPathComponent("images"),
            layerCachePath: layerCachePath,
            stateStore: stateStore,
            logger: logger
        )

        XCTAssertEqual(manager.layerCachePath, layerCachePath)
        XCTAssertFalse(
            manager.layerCachePath.path.hasSuffix(".arca/layers"),
            "the engine's layer cache must not resolve into Arca's tree"
        )
    }
}
