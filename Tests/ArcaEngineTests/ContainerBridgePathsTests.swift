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
            selected.path.hasPrefix(root.path + "/"),
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
            cache.path.hasPrefix(root.path + "/"),
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

        for (name, path) in Self.derivedPaths(under: root) {
            XCTAssertTrue(
                path.path.hasPrefix(root.path + "/"),
                "\(name) must live under the state root, got \(path.path)"
            )
        }
    }

    /// Under the state root is not enough: they must also be different places.
    ///
    /// The containment test above, and the two through the wiring, are each
    /// satisfied by every path collapsing onto one directory. MEASURED with
    /// `EnginePaths.layerCache` set to `stateRoot/"images"`:
    /// `swift test --filter ArcaEngineTests` reported `Executed 60 tests, with 1
    /// failure`, and that one failure was this test -- the other six in this
    /// file, and every other test in the target, passed over an engine whose
    /// OverlayFS layer cache would be unpacking layers directly into the
    /// Containerization content store, beside the blobs and the 512MB
    /// initfs.ext4 (that size MEASURED on a real start; see Task 6's report).
    ///
    /// Pairwise on the derived values rather than a restatement of the
    /// derivation: spelling `stateRoot/"layers"` out here again is the tautology
    /// Task 1's review removed, and it would pass over a collapse it had itself
    /// copied.
    func testNoTwoEnginePathsNameTheSamePlace() {
        let root = temporaryRoot()
        let derived = Self.derivedPaths(under: root)

        for (offset, first) in derived.enumerated() {
            XCTAssertNotEqual(
                first.path, root,
                "\(first.name) must not be the state root itself, got \(first.path.path)"
            )
            for second in derived[(offset + 1)...] {
                XCTAssertNotEqual(
                    first.path, second.path,
                    "\(first.name) and \(second.name) must not be the same path, "
                        + "both are \(first.path.path)"
                )
            }
        }
    }

    /// Every path `EnginePaths` derives, named. A listing of its members, which
    /// is why it is not a second derivation: adding a member without adding it
    /// here leaves that member unchecked by both tests above, and adding it here
    /// with the wrong spelling does not compile.
    private static func derivedPaths(under root: URL) -> [(name: String, path: URL)] {
        let paths = EnginePaths(stateRoot: root)
        return [
            ("imageStoreRoot", paths.imageStoreRoot),
            ("initfs", paths.initfs),
            ("vminitDigest", paths.vminitDigest),
            ("layerCache", paths.layerCache),
            ("stateDatabase", paths.stateDatabase),
            ("volumesRoot", paths.volumesRoot),
            ("socket", paths.socket),
        ]
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

    // MARK: - Source-text guards on the create path
    //
    // READ THIS BEFORE TRUSTING THE TWO TESTS BELOW.
    //
    // They read `Sources/ContainerBridge/ContainerManager.swift` as text. They
    // execute none of it, and they prove nothing about what
    // `createNativeContainer` does at runtime.
    //
    // They are text because the runtime is out of reach, not because text was
    // preferred. `createNativeContainer` opens with
    // `guard var manager = nativeManager`, and `nativeManager` is assigned only
    // by `initialize()`, which builds a `Kernel` and a
    // `Containerization.VmnetNetwork` -- so the call site needs a kernel image
    // and a VM, and this target has neither. Extracting the derivation into
    // something a test could call instead would prove the derivation and still
    // not prove the call site used it, which is the shape this project has
    // shipped repeatedly: a well-formed test over a function, and nothing
    // asserting that the caller called it.
    //
    // The honest call-site instrument is Gas Can's live `Create` test, which is
    // Task 13's and does not exist yet. These two are a tripwire under the
    // revert, not a substitute for it.

    /// This file must never name Apple's shared containerization store.
    ///
    /// `createNativeContainer` used to build the container directory under a
    /// hardcoded `~/Library/Application Support/com.apple.containerization`
    /// while `getRootfsPath` derived the same directory from
    /// `manager.imageStore.path`. For ArcaDaemon the two agreed, because
    /// `ArcaDaemon.swift:178` passes `imageStoreRoot: ImageStore.default.path`
    /// and that *is* Apple's store. For an engine given any other state root
    /// they did not: Containerization opens
    /// `imageStore.path/containers/<id>/bootlog.log`
    /// (containerization/Sources/Containerization/ContainerManager.swift:317,
    /// :35-37, :139-140), so the bridge created a directory Containerization
    /// never looked in.
    ///
    /// WHAT THIS PROVES: the literal is gone from this file.
    ///
    /// WHAT IT DOES NOT PROVE, and what can satisfy it while the bug is back:
    /// a file that hardcodes a *different* wrong root (`~/.arca/containers`,
    /// say); a file where `containerDirectory(in:dockerID:)` is correct but
    /// `createNativeContainer` no longer calls it; any change at all to the
    /// runtime behaviour of the create path. It also forbids the string in
    /// comments, deliberately -- a comment asserting the wrong store is how the
    /// old derivation stayed plausible for as long as it did.
    func testTheContainerBridgeCreatePathNeverNamesApplesSharedStore() throws {
        let source = try Self.containerManagerSource()

        XCTAssertFalse(
            source.contains("com.apple.containerization"),
            "Sources/ContainerBridge/ContainerManager.swift must not name Apple's "
                + "shared containerization store: the store a container's directory "
                + "goes in is whichever root initialize() handed Containerization, "
                + "and naming Apple's agrees with that only for ArcaDaemon"
        )
    }

    /// `<store>/containers/<id>` must be derived in one place in this file.
    ///
    /// Two spellings drifting apart is the defect itself, not a stylistic
    /// concern: the create path and `getRootfsPath` each derived this directory
    /// and only one of them was moved when `ContainerManager` gained an image
    /// store root.
    ///
    /// Exactly one, not at most one: `at most` passes vacuously over a file
    /// where the derivation was respelt (`appending(path:)`) and duplicated
    /// again in the new spelling.
    ///
    /// WHAT THIS PROVES: the token `appendingPathComponent("containers")` occurs
    /// once in this file.
    ///
    /// WHAT IT DOES NOT PROVE: that the one occurrence is rooted at the
    /// manager's store, that either caller reaches it, or anything about
    /// runtime. A single occurrence rooted at a hardcoded path satisfies it --
    /// that is what the test above is for, and neither test covers the other's
    /// gap at runtime.
    func testTheContainersDirectoryIsDerivedInExactlyOnePlace() throws {
        let source = try Self.containerManagerSource()

        XCTAssertEqual(
            source.components(separatedBy: #".appendingPathComponent("containers")"#).count - 1,
            1,
            "the <store>/containers/<id> join must be derived once, in "
                + "containerDirectory(in:dockerID:), and reached by every caller "
                + "that needs it"
        )
    }

    /// The ContainerBridge source both tests above read.
    ///
    /// Located from `#filePath` rather than from the test bundle, because the
    /// bundle holds no sources. A missing or unreadable file fails the test and
    /// is never skipped: a guard that quietly passes when it cannot find what it
    /// guards is worse than no guard, and these two are already the weaker half
    /// of this task's evidence.
    private static func containerManagerSource(
        testFile: StaticString = #filePath
    ) throws -> String {
        let repoRoot = URL(fileURLWithPath: "\(testFile)")
            .deletingLastPathComponent()  // ArcaEngineTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
        let source = repoRoot
            .appendingPathComponent("Sources/ContainerBridge/ContainerManager.swift")
        return try String(contentsOf: source, encoding: .utf8)
    }
}
