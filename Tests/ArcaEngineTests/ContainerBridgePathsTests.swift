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

    /// The cache path was hardcoded under `~/.arca`, so a dev.gascan-rooted engine
    /// would still write its image rootfs cache into Arca's tree. ArcaDaemon still
    /// names that tree (`~/.arca/image-rootfs`); the engine must not.
    func testTheEngineImageRootfsCacheIsUnderItsStateRootAndNotArcas() {
        let root = temporaryRoot()
        let service = SandboxEngineService.forTesting(
            stateRoot: root, kernelPath: Self.externalKernel
        )

        let cache = service.containerManager.imageRootfsCachePath
        XCTAssertTrue(
            cache.path.hasPrefix(root.path + "/"),
            "the engine's image rootfs cache must live under the state root it was "
                + "given, got \(cache.path)"
        )
        XCTAssertFalse(
            cache.path.hasSuffix(".arca/image-rootfs"),
            "the engine's image rootfs cache must not resolve into Arca's tree"
        )
    }

    /// `ContainerLogManager` derived `~/Library/Application Support/
    /// com.apple.arca/logs` for itself and took no root at all, so every
    /// engine -- whatever state root it was given -- wrote its containers'
    /// stdout and stderr into ArcaDaemon's one shared directory, and deleted
    /// out of it on remove.
    ///
    /// Read through `service.containerManager.logManager`, the same object the
    /// create path, the reload path and `removeLogs` use, so this is the
    /// engine's real wiring and not a restatement of `EnginePaths`.
    func testTheEngineContainerLogsAreUnderItsStateRootAndNotTheSharedOne() {
        let root = temporaryRoot()
        let service = SandboxEngineService.forTesting(
            stateRoot: root, kernelPath: Self.externalKernel
        )

        let logDir = service.containerManager.logManager.containerLogDir(dockerID: "c0ffee")
        XCTAssertTrue(
            logDir.path.hasPrefix(root.path + "/"),
            "the engine's container logs must live under the state root it was "
                + "given, got \(logDir.path)"
        )
        XCTAssertFalse(
            logDir.path.contains("com.apple.arca"),
            "the engine's container logs must not resolve into ArcaDaemon's "
                + "shared log store, got \(logDir.path)"
        )
        // Under the state root is not enough. The log root is a sibling of the
        // image store, not a child of it: the engine must not write its own
        // files into the directory Containerization owns, and passing
        // `imageStoreRoot` where `logsRoot` belongs satisfies the containment
        // check above on its own.
        XCTAssertFalse(
            logDir.path.hasPrefix(
                service.containerManager.containerizationRoot().path + "/"
            ),
            "the engine's container logs must not be written inside the image "
                + "store it hands Containerization, got \(logDir.path)"
        )
    }

    /// The image rootfs cache must not live inside the directory the layer reclaim
    /// deletes, and this is the one assertion in this file about a literal value rather
    /// than a relationship.
    ///
    /// **It is here because the value has a consequence outside this type.** Task 10 adds a
    /// reclaim that deletes `<state-root>/layers` on every engine start, to clear the
    /// per-layer OverlayFS cache the revert to a single composed rootfs orphans. If this
    /// member ever names that directory again, that reclaim deletes the LIVE per-image
    /// cache on every start: each `gascan up` silently pays a full 35-layer unpack, and
    /// nothing else in the suite goes red.
    ///
    /// MEASURED, which is why this test exists at all: with `EnginePaths.swift:90` reverted
    /// to `stateRoot.appendingPathComponent("layers")` and a clean `.build`,
    /// `swift test --filter ArcaEngineTests` reported `Executed 260 tests, with 0
    /// failures`. Neither of the two tests through the wiring can see it -- `<root>/layers`
    /// is under the state root, does not end in `.arca/image-rootfs`, and is as distinct
    /// from `images`/`volumes`/`logs` as `image-rootfs` is.
    ///
    /// Written as a negative keyed to the hazard rather than
    /// `XCTAssertEqual(paths.imageRootfs, root.appendingPathComponent("image-rootfs"))`,
    /// which would be the restatement of the derivation this file's other tests were
    /// rewritten to remove -- it would pass over any rename and fail over a harmless one.
    /// What must never happen is this one containment, so that is what is asserted.
    ///
    /// **Containment and not `lastPathComponent != "layers"`, which is what this test
    /// checked when it was first written.** The reclaim is a recursive `removeItem(at:)` on
    /// the directory, so `<state-root>/layers/v2` -- a plausible shape for a later cache
    /// revision -- is deleted on every engine start just as surely as `<state-root>/layers`
    /// is, and passed the narrower check. The directory named here is Task 10's delete
    /// target, not a second derivation of `EnginePaths.imageRootfs`: it is the hazard, and
    /// naming it is the point.
    func testTheImageRootfsCacheIsNotInsideTheDirectoryTheLayerReclaimDeletes() {
        let root = temporaryRoot()
        let paths = EnginePaths(stateRoot: root)

        // Task 10's delete target. Both sides are built from the same `root`, so comparing
        // the paths as text needs no symlink resolution.
        let reclaimed = root.appendingPathComponent("layers")
        let cache = paths.imageRootfs.path

        XCTAssertFalse(
            cache == reclaimed.path || cache.hasPrefix(reclaimed.path + "/"),
            "the image rootfs cache must not be \(reclaimed.path) nor anything inside it: "
                + "the layer reclaim removes that directory recursively on every engine "
                + "start, so a live per-image cache under it is destroyed on each start and "
                + "re-unpacked in full. Got \(cache)"
        )
    }

    /// Nothing the engine derives escapes the state root. The two tests above
    /// cover the image store and the image rootfs cache through the wiring; this
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
    /// satisfied by every path collapsing onto one directory. MEASURED with this
    /// member -- then spelt `EnginePaths.layerCache` -- set to `stateRoot/"images"`:
    /// `swift test --filter ArcaEngineTests` reported `Executed 60 tests, with 1
    /// failure`, and that one failure was this test -- the other six in this
    /// file, and every other test in the target, passed over an engine whose
    /// image cache would be unpacking straight into the Containerization content
    /// store, beside the blobs and the 512MB initfs.ext4 (that size MEASURED on a
    /// real start; see Task 6's report).
    ///
    /// Pairwise on the derived values rather than a restatement of the
    /// derivation: spelling `stateRoot/"image-rootfs"` out here again is the
    /// tautology Task 1's review removed, and it would pass over a collapse it had
    /// itself copied.
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
            ("imageRootfs", paths.imageRootfs),
            ("stateDatabase", paths.stateDatabase),
            ("volumesRoot", paths.volumesRoot),
            ("logsRoot", paths.logsRoot),
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
        let imageRootfsCachePath = root.appendingPathComponent("image-rootfs")
        let logRoot = root.appendingPathComponent("logs")
        let manager = ContainerManager(
            imageManager: try ImageManager(logger: logger, imageStorePath: imageStoreRoot),
            kernelPath: root.appendingPathComponent("vmlinux").path,
            imageStoreRoot: imageStoreRoot,
            imageRootfsCachePath: imageRootfsCachePath,
            logRoot: logRoot,
            stateStore: stateStore,
            logger: logger
        )

        // containerizationRoot() and not imageStoreRoot: the stored property is
        // beside the decision, not the decision. MEASURED: with initialize()
        // reverted to pass no `root:` at all, assertions on the property alone
        // reported "Executed 2 tests, with 0 failures".
        XCTAssertEqual(manager.containerizationRoot(), imageStoreRoot)
        XCTAssertEqual(manager.imageRootfsCachePath, imageRootfsCachePath)

        // The log root through `logManager.containerLogDir(dockerID:)` -- the
        // resolution the create path (`createLogWriters`), the reload path and
        // `removeLogs` all go through -- rather than through a stored property
        // on either type. This is the call-site assertion for the log root:
        // `ContainerManager` takes a root and builds the `ContainerLogManager`
        // itself, so a manager that ignored `logRoot:` and rebuilt Application
        // Support here would fail this line. Handing a ready-made
        // `ContainerLogManager` in would have made this true by construction.
        XCTAssertEqual(
            manager.logManager.containerLogDir(dockerID: "c0ffee"),
            logRoot.appendingPathComponent("c0ffee")
        )
    }

    /// A `ContainerLogManager` writes and deletes under the root it was given,
    /// and nowhere else.
    ///
    /// The assertion above reads the resolved path; this one drives the two
    /// operations that use it, because the defect had both halves. Container
    /// output went into `~/Library/Application Support/com.apple.arca/logs`
    /// whatever root the engine owned, and `removeContainer` -- via
    /// `ContainerManager.swift`'s `removeLogs` call -- deleted out of that same
    /// shared directory, so a throwaway engine removing a sandbox deleted under
    /// the operator's real log store.
    ///
    /// WHAT THIS PROVES: `createLogWriters` creates the container's log files
    /// under the supplied root, and `removeLogs` removes that directory. Both
    /// against a temporary root, so a regression to the shared derivation both
    /// leaves this root empty and fails to delete from it.
    ///
    /// WHAT IT DOES NOT PROVE: that `createContainer` or `startContainer` reach
    /// `createLogWriters` at all. Both guard on `nativeManager`, which only
    /// `initialize()` sets and which needs a kernel and a VM, so those call
    /// sites are unreachable from this target. The test above covers the root
    /// `ContainerManager` hands down; what remains unproven here is the hop
    /// from the hot paths into these two methods, and that is Gas Can's live
    /// tier to settle.
    func testALogManagerWritesAndDeletesOnlyUnderTheRootItWasGiven() throws {
        let logRoot = temporaryRoot().appendingPathComponent("logs")
        let manager = ContainerLogManager(
            logRoot: logRoot, logger: Logger(label: "paths-tests")
        )
        let containerDir = logRoot.appendingPathComponent("c0ffee")

        _ = try manager.createLogWriters(dockerID: "c0ffee")
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: containerDir.appendingPathComponent("stdout.log").path
            ),
            "createLogWriters must create the container's log files under the "
                + "root it was given, nothing appeared at \(containerDir.path)"
        )

        try manager.removeLogs(dockerID: "c0ffee")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: containerDir.path),
            "removeLogs must delete the container's directory under the root it "
                + "was given, \(containerDir.path) survived"
        )
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
    // The honest call-site instrument is Gas Can's live `Create` test. It is
    // Task 13's to land, and the behaviour it proves has already been MEASURED
    // by the controller against this commit: a real engine on a real socket
    // creates a container, the directory appears under the engine's OWN
    // `<state-root>/images/containers/`, and Apple's shared store is unchanged
    // across the run. These two tests are a tripwire under the revert, not a
    // substitute for that.

    /// This file must carry no literal path to Apple's shared containerization
    /// store.
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
    /// WHAT THIS PROVES: the literal is gone from this file. Nothing more. The
    /// name says *carries no literal* rather than *never reaches*, and the
    /// difference is the whole of what follows.
    ///
    /// WHAT IT DOES NOT PROVE, and what can satisfy it while the bug is back.
    /// The first two were MEASURED against this suite rather than reasoned
    /// about, and each left `Executed 149 tests, with 0 failures`:
    ///
    /// - **Apple's store reached by name instead of by literal.** Replace
    ///   `manager.imageStore.path` in `containerDirectory(in:dockerID:)` with
    ///   `ImageStore.default.path` and the original defect is back exactly,
    ///   because `ImageStore.defaultRoot()` returns that same directory. This is
    ///   the likeliest regression shape rather than a contrived one: that
    ///   spelling is already in the tree twice, at `ImageManager.swift:23` and
    ///   `ArcaDaemon.swift:178`.
    /// - **The literal split across a concatenation or an intermediate
    ///   constant.** `"com.apple." + "containerization"` re-inlined at the
    ///   create site defeats `contains` while restoring the behaviour.
    /// - A file hardcoding a *different* wrong root (`~/.arca/containers`, say);
    ///   a file where `containerDirectory(in:dockerID:)` is correct but
    ///   `createNativeContainer` no longer calls it; any change at all to the
    ///   runtime behaviour of the create path.
    ///
    /// **THE INSTRUMENT THAT CATCHES ALL OF THESE IS GAS CAN'S LIVE `Create`
    /// TEST, AND IT LIVES IN THE OTHER REPOSITORY.** Under the first mutation
    /// above, MEASURED: it fails with `NSPOSIXErrorDomain Code=2`, finds the
    /// engine's own `<state-root>/images/containers/` empty, and catches Apple's
    /// shared store growing by one directory (253 -> 254). These two tests are a
    /// tripwire for the textual defect and not coverage of the behavioural one.
    ///
    /// It also forbids the string in comments, deliberately -- a comment
    /// asserting the wrong store is how the old derivation stayed plausible for
    /// as long as it did.
    func testTheContainerBridgeCreatePathCarriesNoLiteralPathToApplesSharedStore() throws {
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
    /// concern: the create path and the since-deleted `getRootfsPath` each
    /// derived this directory and only one of them was moved when
    /// `ContainerManager` gained an image-store root. **Only the create path's
    /// copy ever executed** -- `getRootfsPath` had no callers, which is why the
    /// drift survived unnoticed and why it is gone rather than corrected.
    ///
    /// Exactly one, not at most one: `at most` passes vacuously over a file
    /// where the derivation was respelt (`appending(path:)`) and duplicated
    /// again in the new spelling.
    ///
    /// WHAT THIS PROVES: the token `appendingPathComponent("containers")` occurs
    /// once in this file.
    ///
    /// WHAT IT DOES NOT PROVE: that the one occurrence is rooted at the
    /// manager's store, that any caller reaches it, or anything about runtime. A
    /// single occurrence rooted at a hardcoded path satisfies it -- that is what
    /// the test above is for, and neither test covers the other's gap at
    /// runtime.
    ///
    /// It counts over the whole file, comments included, so a doc comment that
    /// *quotes* this token fails the suite. That is why the comment on
    /// `containerDirectory(in:dockerID:)` describes the join instead of spelling
    /// it, and a future reader who does not know that will be puzzled by a red
    /// suite after writing prose. Left as-is rather than narrowed to code: a
    /// counter that skipped comments would stop forbidding the wrong store in a
    /// comment, which is the other half of what these two tests are for.
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
    /// The derivation lives in `BridgeSources` because `CreatePathSeamTests` reads the same
    /// file, and two spellings of it would be free to drift -- which for a text guard shows
    /// up as the guard silently passing over a file it never opened. A missing or
    /// unreadable file throws and fails the test and is never skipped; these two are
    /// already the weaker half of this task's evidence.
    private static func containerManagerSource() throws -> String {
        try BridgeSources.containerManager()
    }
}
