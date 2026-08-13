import ContainerBridge
import Foundation
import Logging
import XCTest
@testable import ArcaEngine

final class ContainerBridgePathsTests: XCTestCase {
    private func temporaryRoot() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("arca-paths-\(UUID().uuidString)")
    }

    /// A kernel deliberately outside any state root, because that is the shape
    /// `--kernel-path` exists to allow: one read-only image shared by however
    /// many engines, each owning its own state root.
    private static let externalKernel = URL(fileURLWithPath: "/opt/arca/vmlinux")

    /// The engine must not share Apple's containerization image store, because
    /// `initfs.ext4` is derived from it -- Containerization's ContainerManager
    /// builds `imageStore.path/initfs.ext4`. Sharing that store is what forces
    /// ArcaDaemon to delete the file on every start; a private root removes the
    /// need for any coordination.
    ///
    /// This drives `SandboxEngineService.forTesting(stateRoot:kernelPath:)`,
    /// which derives its paths from `EnginePaths` exactly as `arca-engine`
    /// does, and reads `containerizationRoot()`, the value `initialize()` hands
    /// to Containerization. Both ends are the production ones: nothing here
    /// restates the derivation, so a derivation that changed would be caught
    /// rather than followed.
    ///
    /// The kernel is passed in from outside the root, as `--kernel-path` allows
    /// and the assertions below require: nothing the engine *derives* may
    /// escape the state root, and the kernel is no longer derived.
    func testTheEngineImageStoreIsUnderItsStateRootAndNotApples() {
        let root = temporaryRoot()
        let service = SandboxEngineService.forTesting(
            stateRoot: root, kernelPath: Self.externalKernel
        )

        let selected = service.containerManager.containerizationRoot()
        XCTAssertTrue(
            selected.path.hasPrefix(root.path),
            "the engine's image store must live under the state root it was given, got \(selected.path)"
        )
        XCTAssertFalse(
            selected.path.contains("com.apple.containerization"),
            "the engine's image store must not resolve into Apple's shared store"
        )
    }

    /// `~/.arca/layers` was hardcoded, so a dev.gascan-rooted engine would still
    /// write its layer cache into Arca's tree.
    func testTheEngineLayerCacheIsUnderItsStateRootAndNotArcas() {
        let root = temporaryRoot()
        let service = SandboxEngineService.forTesting(
            stateRoot: root, kernelPath: Self.externalKernel
        )

        let cache = service.containerManager.layerCachePath
        XCTAssertTrue(
            cache.path.hasPrefix(root.path),
            "the engine's layer cache must live under the state root it was given, got \(cache.path)"
        )
        XCTAssertFalse(
            cache.path.hasSuffix(".arca/layers"),
            "the engine's layer cache must not resolve into Arca's tree"
        )
    }

    /// Nothing the engine derives escapes the state root. The two tests above
    /// cover the image store and the layer cache through the wiring; this
    /// covers the rest of `EnginePaths` -- the state database, the volumes
    /// directory and the configured socket -- which are handed to managers this
    /// suite does not otherwise read back.
    ///
    /// The kernel is absent because it is no longer derived: it arrives as
    /// `--kernel-path`, a read-only input the engine may share, and validating
    /// it is `validateEngineInputs`' job rather than this one's.
    func testNoEnginePathEscapesTheStateRoot() {
        let root = temporaryRoot()
        let paths = EnginePaths(stateRoot: root)

        for (name, path) in [
            ("imageStoreRoot", paths.imageStoreRoot),
            ("initfs", paths.initfs),
            ("vminitDigest", paths.vminitDigest),
            ("layerCache", paths.layerCache),
            ("stateDatabase", paths.stateDatabase),
            ("volumesRoot", paths.volumesRoot),
            ("socket", paths.socket),
        ] {
            XCTAssertTrue(
                path.path.hasPrefix(root.path + "/"),
                "\(name) must live under the state root, got \(path.path)"
            )
        }
    }

    /// ContainerBridge's own contract, independent of the engine: a
    /// `ContainerManager` uses the roots it was handed. ArcaDaemon depends on
    /// this too, and it is constructed by neither `EnginePaths` nor
    /// `forTesting`.
    func testAContainerManagerUsesTheRootsItWasGiven() throws {
        let logger = Logger(label: "paths-tests")
        let root = temporaryRoot()
        let stateStore = try StateStore(
            path: root.appendingPathComponent("state.db").path,
            logger: logger
        )
        let imageStoreRoot = root.appendingPathComponent("images")
        let layerCachePath = root.appendingPathComponent("layers")
        let manager = ContainerManager(
            imageManager: try ImageManager(logger: logger, imageStorePath: imageStoreRoot),
            kernelPath: root.appendingPathComponent("vmlinux").path,
            imageStoreRoot: imageStoreRoot,
            layerCachePath: layerCachePath,
            stateStore: stateStore,
            logger: logger
        )

        // containerizationRoot() and not imageStoreRoot: the stored property is
        // beside the decision, not the decision. MEASURED: with initialize()
        // reverted to pass no `root:` at all, assertions on the property alone
        // reported "Executed 2 tests, with 0 failures".
        XCTAssertEqual(manager.containerizationRoot(), imageStoreRoot)
        XCTAssertEqual(manager.layerCachePath, layerCachePath)
    }

    /// `initfs.ext4` is not a path the engine picks, it is a path
    /// Containerization derives from whichever image store it is handed
    /// (containerization/Sources/Containerization/ContainerManager.swift:146).
    /// `EnginePaths.initfs` must therefore be that derivation and not a second
    /// route to the same string -- the test above proves it stays under the
    /// state root, this proves it stays inside the store.
    func testTheInitfsIsInsideTheImageStoreTheEngineHandsContainerization() {
        let root = temporaryRoot()
        let paths = EnginePaths(stateRoot: root)
        let service = SandboxEngineService.forTesting(
            stateRoot: root, kernelPath: Self.externalKernel
        )

        XCTAssertEqual(
            paths.initfs,
            service.containerManager.containerizationRoot()
                .appendingPathComponent("initfs.ext4"),
            "the initfs the engine deletes must be the one Containerization builds"
        )
    }

    /// An `ImageManager` reports the store it was actually given, which is what
    /// lets ArcaDaemon name its initfs relative to its store instead of
    /// re-deriving Application Support by hand -- the re-derivation that sat 70
    /// lines from the comment saying the file avoids it.
    ///
    /// A store path is passed in rather than defaulted, because asserting on
    /// the default would mean touching the real
    /// `~/Library/Application Support/com.apple.containerization` from a test.
    func testAnImageManagerReportsTheStoreRootItWasGiven() throws {
        let root = temporaryRoot()
        let storePath = root.appendingPathComponent("images")
        let manager = try ImageManager(
            logger: Logger(label: "paths-tests"), imageStorePath: storePath
        )

        XCTAssertEqual(manager.storeRoot, storePath)
    }
}
