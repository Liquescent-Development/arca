import ContainerBridge
import Foundation
import Logging
import XCTest

@testable import ArcaEngine

/// The one-time reclaim of the per-layer ext4 cache the single-composed-rootfs revert
/// orphaned.
///
/// These tests are about **scoping**, not about deletion. `removeItem` works; what has to be
/// pinned is that the reclaim deletes the one directory it was written for and refuses
/// anything it does not recognise, because it is the only recursive delete the revert adds.
final class LayerCacheReclaimTests: XCTestCase {

    /// One directory per process, removed whole in `tearDown`.
    private static let scratchRoot = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("arca-layer-cache-reclaim-tests-\(UUID().uuidString)")

    override class func tearDown() {
        try? FileManager.default.removeItem(at: scratchRoot)
        super.tearDown()
    }

    /// A fresh root, created on disk. Named per test rather than shared, so one test's
    /// deletion can never be another's missing fixture.
    private static func temporaryRoot(_ name: String = #function) throws -> URL {
        let root = scratchRoot.appendingPathComponent("\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// A populated `layers` directory under `root`, as the fork left it.
    @discardableResult
    private static func plantLayers(under root: URL) throws -> URL {
        let layers = root.appendingPathComponent("layers")
        try FileManager.default.createDirectory(at: layers, withIntermediateDirectories: true)
        try Data("ext4".utf8).write(to: layers.appendingPathComponent("abc.ext4"))
        return layers
    }

    // MARK: - The engine's orphan, under its state root

    /// The orphaned per-layer cache is removed, and the state root that held it is not.
    func testReclaimRemovesTheLayersDirectoryUnderTheStateRoot() throws {
        let stateRoot = try Self.temporaryRoot()
        let layers = try Self.plantLayers(under: stateRoot)

        try LayerCacheReclaim.run(stateRoot: stateRoot)

        XCTAssertFalse(FileManager.default.fileExists(atPath: layers.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: stateRoot.path))
    }

    /// A `layers` path that is not a directory is a state root this code does not understand,
    /// and deleting anything under that assumption would be guessing.
    func testReclaimRefusesWhenLayersIsNotADirectory() throws {
        let stateRoot = try Self.temporaryRoot()
        let layers = stateRoot.appendingPathComponent("layers")
        try Data("not a directory".utf8).write(to: layers)

        XCTAssertThrowsError(try LayerCacheReclaim.run(stateRoot: stateRoot))
        XCTAssertTrue(FileManager.default.fileExists(atPath: layers.path))
    }

    /// Nothing to reclaim is success, not an error: this runs on every start, and every start
    /// after the first has nothing left to do.
    func testReclaimIsSilentWhenThereIsNothingToReclaim() throws {
        let stateRoot = try Self.temporaryRoot()

        XCTAssertNoThrow(try LayerCacheReclaim.run(stateRoot: stateRoot))
        XCTAssertNoThrow(try LayerCacheReclaim.run(stateRoot: stateRoot))
    }

    // MARK: - ArcaDaemon's orphan, under `~/.arca`

    /// ArcaDaemon wrote its own copy of the per-layer cache, and the rename of the live cache
    /// to `image-rootfs` is what put this directory out of every other code path's reach. It
    /// is reclaimed under the same rule as the engine's.
    func testReclaimRemovesTheLayersDirectoryUnderTheArcaRoot() throws {
        let arcaRoot = try Self.temporaryRoot()
        let layers = try Self.plantLayers(under: arcaRoot)

        try LayerCacheReclaim.run(arcaRoot: arcaRoot)

        XCTAssertFalse(FileManager.default.fileExists(atPath: layers.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: arcaRoot.path))
    }

    /// The refusal is a property of the reclaim, not of the engine's entry point, so it holds
    /// on ArcaDaemon's tree too.
    func testReclaimRefusesWhenTheArcaRootsLayersIsNotADirectory() throws {
        let arcaRoot = try Self.temporaryRoot()
        let layers = arcaRoot.appendingPathComponent("layers")
        try Data("not a directory".utf8).write(to: layers)

        XCTAssertThrowsError(try LayerCacheReclaim.run(arcaRoot: arcaRoot))
        XCTAssertTrue(FileManager.default.fileExists(atPath: layers.path))
    }

    /// ArcaDaemon's start has nothing to do on the second run either.
    func testReclaimIsSilentWhenTheArcaRootHasNothingToReclaim() throws {
        let arcaRoot = try Self.temporaryRoot()

        XCTAssertNoThrow(try LayerCacheReclaim.run(arcaRoot: arcaRoot))
    }

    // MARK: - Scoping

    /// A symbolic link at `layers` is refused rather than unlinked, and the tree it pointed at
    /// keeps its contents.
    ///
    /// **This is not the argument for `lstat` over `fileExists(atPath:isDirectory:)`**, which
    /// an earlier revision of this docstring claimed. `fileExists` would follow the link and
    /// report a directory, but the delete that followed would still only unlink the link --
    /// see `testRemovingASymbolicLinkUnlinksItWithoutFollowingIt`. What refusing buys is that
    /// an operator who moved the flagged cache somewhere else is told so, by path, instead of
    /// having the link silently removed. The argument for `lstat` is
    /// `testAnUnreadableLayersPathIsRefusedRatherThanReportedAbsent`.
    func testReclaimRefusesASymbolicLinkAtTheLayersPath() throws {
        let root = try Self.temporaryRoot()
        let elsewhere = root.appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let hostage = elsewhere.appendingPathComponent("keep-me")
        try Data("keep me".utf8).write(to: hostage)

        let layers = root.appendingPathComponent("layers")
        try FileManager.default.createSymbolicLink(at: layers, withDestinationURL: elsewhere)

        XCTAssertThrowsError(try LayerCacheReclaim.run(stateRoot: root))
        XCTAssertTrue(FileManager.default.fileExists(atPath: hostage.path))
    }

    /// Everything beside `layers` survives -- in particular `image-rootfs`, the live cache the
    /// revert renames into the same parent. A reclaim that recursed one level broader would
    /// delete the engine's working image store.
    func testReclaimLeavesEverySiblingOfTheLayersDirectory() throws {
        let stateRoot = try Self.temporaryRoot()
        try Self.plantLayers(under: stateRoot)

        let imageRootfs = stateRoot.appendingPathComponent("image-rootfs")
        try FileManager.default.createDirectory(
            at: imageRootfs, withIntermediateDirectories: true
        )
        let composed = imageRootfs.appendingPathComponent("sha256-abc.ext4")
        try Data("composed rootfs".utf8).write(to: composed)
        let database = stateRoot.appendingPathComponent("state.db")
        try Data("sqlite".utf8).write(to: database)

        try LayerCacheReclaim.run(stateRoot: stateRoot)

        XCTAssertTrue(FileManager.default.fileExists(atPath: composed.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: database.path))
    }

    /// The measured argument for `lstat` over `FileManager.fileExists(atPath:isDirectory:)`.
    ///
    /// `fileExists` collapses every failure into `false`, so a `layers` directory the process
    /// cannot reach reads as absent and the reclaim would report success over a directory it
    /// never saw -- silently leaving the disk claimed, which is the one outcome this task
    /// exists to prevent. `lstat` separates `ENOENT` from `EACCES`, and only `ENOENT` is
    /// silent. MEASURED alongside this test on 2026-08-22 with a standalone `swiftc` probe:
    /// with the parent at mode 000 and `geteuid() == 501`, `lstat` returned -1 / errno 13
    /// while `fileExists` returned `false` for the same path.
    ///
    /// Skipped rather than run as root, where the permission bits do not apply and the test
    /// would be asserting nothing.
    func testAnUnreadableLayersPathIsRefusedRatherThanReportedAbsent() throws {
        try XCTSkipIf(geteuid() == 0, "root bypasses the permission bits this test relies on")

        let root = try Self.temporaryRoot()
        let layers = try Self.plantLayers(under: root)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: root.path)
        addTeardownBlock {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: root.path
            )
        }

        // The precondition this test turns on: the check it replaced cannot tell this state
        // from an absent directory.
        XCTAssertFalse(FileManager.default.fileExists(atPath: layers.path))

        XCTAssertThrowsError(try LayerCacheReclaim.run(stateRoot: root))
    }

    /// **Half** of the `lstat`-then-`removeItem` race: a symbolic link swapped into the name
    /// costs the link and nothing else, because `removeItem` unlinks a link rather than
    /// descending it.
    ///
    /// Read this together with `testAPathRenamedOverByARealDirectoryIsRemovedInFull`, which is
    /// the other half and goes the other way. An earlier revision of this suite pinned only
    /// this case and the surrounding documentation generalised it into a bound on the whole
    /// race. It is not one.
    ///
    /// Drives `FileManager` directly, because the property is `FileManager`'s and not this
    /// module's -- the reclaim refuses a link before it ever reaches `removeItem`, so a test
    /// through `LayerCacheReclaim` could not establish it.
    func testRemovingASymbolicLinkUnlinksItWithoutFollowingIt() throws {
        let root = try Self.temporaryRoot()
        let victim = root.appendingPathComponent("victim")
        try FileManager.default.createDirectory(at: victim, withIntermediateDirectories: true)
        let hostage = victim.appendingPathComponent("keep-me")
        try Data("keep me".utf8).write(to: hostage)

        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: victim)

        try FileManager.default.removeItem(at: link)

        XCTAssertFalse(FileManager.default.fileExists(atPath: link.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: victim.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: hostage.path))
    }

    /// The other half of the race, and the counterexample to the bound this suite used to
    /// imply: a **real directory** `rename(2)`d into the name between the check and the
    /// removal is deleted in full.
    ///
    /// Nothing in `removeItem` can tell it from the directory `lstat` examined -- it looks the
    /// name up again -- so it recurses. MEASURED with a standalone probe on 2026-08-22 before
    /// this test was written: the check saw a directory, `rename` returned 0, and the file
    /// three levels inside the renamed-in tree was gone afterwards.
    ///
    /// This test asserts the *unsafe* behaviour on purpose. It exists so that the race note in
    /// `LayerCacheReclaim` cannot drift back to "the residue is bounded" without a test going
    /// red, and it will need rewriting rather than deleting if the reclaim ever moves to
    /// `openat`/`unlinkat`, which is what would actually close this.
    func testAPathRenamedOverByARealDirectoryIsRemovedInFull() throws {
        let base = try Self.temporaryRoot()
        let root = base.appendingPathComponent("root")
        let layers = root.appendingPathComponent("layers")
        try FileManager.default.createDirectory(at: layers, withIntermediateDirectories: true)

        let precious = base.appendingPathComponent("precious")
        let deep = precious.appendingPathComponent("deep")
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        let treasure = deep.appendingPathComponent("treasure")
        try Data("do not delete".utf8).write(to: treasure)

        // The check the reclaim makes, made here, so the ordering under test is the real one.
        var status = stat()
        XCTAssertEqual(lstat(layers.path, &status), 0)
        XCTAssertEqual(status.st_mode & S_IFMT, S_IFDIR)

        // The swap. `layers` is empty, which is what lets `rename` replace it.
        XCTAssertEqual(rename(precious.path, layers.path), 0, "rename failed: errno \(errno)")

        try FileManager.default.removeItem(at: layers)

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: treasure.path),
            "if this now survives, the reclaim gained a real bound and the race note in "
                + "LayerCacheReclaim should be rewritten to claim it"
        )
    }

    // MARK: - The root the reclaim is handed

    /// A root carrying a `..` component is refused, and nothing under the directory it would
    /// have resolved to is touched.
    ///
    /// `URL(fileURLWithPath:)` keeps `.` and `..` components verbatim -- MEASURED with a
    /// `swiftc` probe on 2026-08-22: `/tmp/a/sub/../c` stays `/tmp/a/sub/../c` -- so the
    /// filesystem resolves them at `lstat` time, after any check this code makes.
    func testReclaimRefusesANonCanonicalRootAndRemovesNothing() throws {
        let root = try Self.temporaryRoot()
        let layers = try Self.plantLayers(under: root)
        let sneaky = URL(fileURLWithPath: root.path + "/sub/..")
        XCTAssertTrue(sneaky.path.contains(".."), "the fixture must still carry the `..`")

        XCTAssertThrowsError(try LayerCacheReclaim.run(stateRoot: sneaky))
        XCTAssertTrue(FileManager.default.fileExists(atPath: layers.path))
    }

    /// The refusal is a property of the reclaim and not of one entry point, so ArcaDaemon's
    /// label refuses the same roots. ArcaDaemon never passes through `validateEngineInputs`,
    /// which is why this check lives in the reclaim as well as at the engine's boundary.
    func testReclaimRefusesANonCanonicalArcaRoot() throws {
        let root = try Self.temporaryRoot()
        let layers = try Self.plantLayers(under: root)

        XCTAssertThrowsError(
            try LayerCacheReclaim.run(arcaRoot: URL(fileURLWithPath: root.path + "/sub/.."))
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: layers.path))
    }

    /// The filesystem root is refused. `/layers` is not a state root's cache, and `/` is the
    /// single most destructive value this argument can carry.
    func testReclaimRefusesTheFilesystemRoot() throws {
        XCTAssertThrowsError(try LayerCacheReclaim.run(stateRoot: URL(fileURLWithPath: "/")))
        XCTAssertThrowsError(try LayerCacheReclaim.run(arcaRoot: URL(fileURLWithPath: "/")))
    }

    /// The rule itself, over the forms a `URL` can no longer express by the time the reclaim
    /// sees one. `validateEngineInputs` is the caller that still holds them, as raw option
    /// text; this pins the shared rule both callers read.
    func testTheRootRuleRefusesTheEmptyAndRelativeForms() {
        XCTAssertNotNil(LayerCacheReclaim.rootRefusal(for: ""))
        XCTAssertNotNil(LayerCacheReclaim.rootRefusal(for: "."))
        XCTAssertNotNil(LayerCacheReclaim.rootRefusal(for: ".."))
        XCTAssertNotNil(LayerCacheReclaim.rootRefusal(for: "relative/root"))
        XCTAssertNotNil(LayerCacheReclaim.rootRefusal(for: "/a/../b"))
        XCTAssertNotNil(LayerCacheReclaim.rootRefusal(for: "/a/./b"))
        XCTAssertNotNil(LayerCacheReclaim.rootRefusal(for: "/"))

        // Every all-slashes spelling of the filesystem root, not just the one-character one.
        // MEASURED on 2026-08-22: `URL(fileURLWithPath:)` maps `"//"` and `"///"` to `"/"`.
        // While this rule compared against `"/"` by string, `"//"` passed the boundary and was
        // stopped only by the reclaim's own copy of the check.
        XCTAssertNotNil(LayerCacheReclaim.rootRefusal(for: "//"))
        XCTAssertNotNil(LayerCacheReclaim.rootRefusal(for: "///"))
        XCTAssertNotNil(LayerCacheReclaim.rootRefusal(for: "/a//b"))

        // `~/...` is refused, and this is a narrowing: `URL` expands the tilde against `$HOME`
        // -- MEASURED on 2026-08-22, `URL(fileURLWithPath: "~/foo").path` is
        // `/Users/<user>/foo` -- so this form used to be accepted and to work.
        XCTAssertNotNil(LayerCacheReclaim.rootRefusal(for: "~/foo"))
        XCTAssertNotNil(LayerCacheReclaim.rootRefusal(for: "~"))

        XCTAssertNil(LayerCacheReclaim.rootRefusal(for: "/Users/someone/.arca"))
        XCTAssertNil(LayerCacheReclaim.rootRefusal(for: "/var/folders/x/arca-engine-1"))
        // A trailing slash names the same directory and stays accepted; the refusals above are
        // refusing forms that resolve to somewhere else, not cosmetics.
        XCTAssertNil(LayerCacheReclaim.rootRefusal(for: "/var/folders/x/arca-engine-1/"))
    }

    /// The reason a non-absolute value is refused has to be true of every non-absolute value,
    /// and the one this rule gave was true of relative paths only: it said such a value
    /// resolves against the working directory, which is wrong for `~/...`.
    func testTheNonAbsoluteReasonCoversBothWaysAValueWouldHaveResolved() {
        let reason = LayerCacheReclaim.rootRefusal(for: "~/foo")
        XCTAssertNotNil(reason)
        XCTAssertTrue(reason?.contains("working directory") == true, "got: \(reason ?? "nil")")
        XCTAssertTrue(reason?.contains("$HOME") == true, "got: \(reason ?? "nil")")
    }

    /// `rm -rf` reaches a path the same way this process did, so for the errnos that stopped
    /// `lstat` because of the path itself, offering it costs the operator a cycle before they
    /// start thinking. The remedy is branched on why.
    func testAnUnreadablePathIsNotOfferedARemovalThatCannotReachItEither() throws {
        try XCTSkipIf(geteuid() == 0, "root bypasses the permission bits this test relies on")

        let root = try Self.temporaryRoot()
        try Self.plantLayers(under: root)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: root.path)
        addTeardownBlock {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: root.path
            )
        }

        XCTAssertThrowsError(try LayerCacheReclaim.run(stateRoot: root)) { error in
            let message = "\(error)"
            XCTAssertTrue(
                message.contains("cannot reach it either"), "no limit stated in: \(message)"
            )
            XCTAssertTrue(message.contains("chmod u+rx"), "no usable remedy in: \(message)")
            XCTAssertFalse(
                message.contains("To clear it and let the next start proceed"),
                "offered the blanket remedy anyway: \(message)"
            )
        }
    }

    // MARK: - Refusals carry a remedy

    /// A refusal blocks the start of whichever binary asked, over a cache the design calls
    /// regenerable, so the message has to be enough to act on: the exact path, what was found
    /// there, and the command that clears it. The throw stays; what is tested here is that it
    /// is not a dead end.
    func testEveryRefusalNamesThePathAndTheCommandThatClearsIt() throws {
        let root = try Self.temporaryRoot()
        let layers = root.appendingPathComponent("layers")
        try Data("not a directory".utf8).write(to: layers)

        XCTAssertThrowsError(try LayerCacheReclaim.run(stateRoot: root)) { error in
            let message = "\(error)"
            XCTAssertTrue(message.contains(layers.path), "no path in: \(message)")
            XCTAssertTrue(message.contains("a regular file"), "no diagnosis in: \(message)")
            XCTAssertTrue(message.contains("rm -rf"), "no remedy in: \(message)")
        }
    }

    /// A symbolic link's remedy is `rm`, not `rm -rf`: the same unlink, but the message has to
    /// say that what it points at is left alone, because the operator this refusal reaches is
    /// the one who deliberately moved the cache there.
    func testTheSymbolicLinkRefusalOffersAnUnlinkAndSaysWhatSurvives() throws {
        let root = try Self.temporaryRoot()
        let elsewhere = root.appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let layers = root.appendingPathComponent("layers")
        try FileManager.default.createSymbolicLink(at: layers, withDestinationURL: elsewhere)

        XCTAssertThrowsError(try LayerCacheReclaim.run(stateRoot: root)) { error in
            let message = "\(error)"
            XCTAssertTrue(message.contains("a symbolic link"), "no diagnosis in: \(message)")
            XCTAssertTrue(message.contains("rm '\(layers.path)'"), "no remedy in: \(message)")
            XCTAssertTrue(
                message.contains("not what it points at"), "no survival note in: \(message)"
            )
        }
    }

    // MARK: - The engine's call site

    /// The engine reclaims on start, through the one factory `arca-engine` itself calls.
    ///
    /// Pinning `EngineManagers` rather than `ServeCommand.run()` for the reason `EngineManagers`
    /// exists at all: a test target cannot import an executable, so a wiring only the
    /// executable can reach is a wiring no test can assert on.
    func testBuildingTheEngineManagersReclaimsTheLayersDirectory() throws {
        let stateRoot = try Self.temporaryRoot()
        let layers = try Self.plantLayers(under: stateRoot)

        _ = try EngineManagers(
            stateRoot: stateRoot,
            kernelPath: URL(fileURLWithPath: "/opt/arca/vmlinux"),
            logLevel: "info",
            logger: Logger(label: "layer-cache-reclaim-tests")
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: layers.path))
    }
}
