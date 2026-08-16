import Containerization
import ContainerizationEXT4
import Foundation
import Logging
import SystemPackage
import XCTest
@testable import ArcaEngine

/// That an ext4 image formatted before roles existed is not mistaken for one that carries a
/// role.
///
/// **This is the shape of a defect that shipped, and the reason it is worth a test of its
/// own.** `ca47c87` made the guest classify virtio-blk devices by the role in their ext4
/// volume label, and `OverlayFSUnpacker` writes that label only where it FORMATS a layer --
/// which happens only on a cache miss. Every `layer.ext4` written before the label existed
/// therefore came back from the cache-hit branch unlabelled, reached the guest, and was
/// dropped by the classifier with `is not an Arca role, leaving it alone`: a rootfs built from
/// a subset of its own image, or from none of it, with no error on either side.
///
/// **What makes it silent is that a stale image is not broken.** It is a valid ext4
/// filesystem, so nothing throws, nothing is corrupt, and no existing check has any reason to
/// object. The only thing wrong with it is an absence, and an absence is exactly what a
/// classifier that trusts the cache never looks for.
///
/// So the fix is a positive test for the role on every cache hit
/// (`OverlayFSUnpacker.unpackLayerToCache`), and these are the two answers that decision rests
/// on, driven against real formatted images rather than against a fixture that stands in for
/// one.
final class LayerCacheRoleTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("arca-layer-cache-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
        try super.tearDownWithError()
    }

    /// Formats an ext4 image, with `label` or without one, and returns its path.
    ///
    /// `volumeLabel: nil` is the **exact** pre-change call, not an imitation of it: the
    /// parameter was added by the same commit that introduced roles, so omitting it reproduces
    /// what every cached layer on disk before that commit actually is.
    private func image(named name: String, label: String?) throws -> FilePath {
        let path = FilePath(scratch.appendingPathComponent(name).path)
        let formatter = try EXT4.Formatter(path, minDiskSize: 2 * 1024 * 1024, volumeLabel: label)
        try formatter.close()
        return path
    }

    /// The load-bearing half: an unlabelled image must not answer with a role.
    ///
    /// It is asserted through `role(ofImageAt:)` rather than through the raw label because
    /// that is the function the cache-hit branch calls, and a test of the label alone would
    /// leave the mapping from "no label" to "not a layer" unpinned -- which is where the
    /// silence came from.
    func testAnImageFormattedWithoutALabelHasNoRole() throws {
        let stale = try image(named: "stale.ext4", label: nil)

        XCTAssertNil(
            try EXT4.volumeLabel(ofBlockDevice: stale),
            "an image formatted with no volumeLabel must carry no label"
        )
        XCTAssertNil(
            ArcaBlockDeviceRole.role(ofImageAt: stale),
            "an unlabelled layer image must not be accepted as a role-carrying one; "
                + "accepting it is what let the guest drop a layer silently"
        )
    }

    /// The control, and it is not optional.
    ///
    /// Without it `role(ofImageAt:)` returning `nil` for everything would pass the assertion
    /// above -- the one-sided-assertion shape this project has shipped before. This pins that
    /// the function can say yes, and to the right role.
    func testAnImageFormattedForALayerReportsThatRole() throws {
        let fresh = try image(
            named: "fresh.ext4",
            label: ArcaBlockDeviceRole.overlayLayer.volumeLabel
        )

        XCTAssertEqual(
            ArcaBlockDeviceRole.role(ofImageAt: fresh),
            .overlayLayer,
            "an image formatted for the layer role must report it"
        )
    }

    /// A role the caller did not ask about must not be mistaken for the one it did.
    ///
    /// The cache-hit branch tests `== .overlayLayer` rather than "has some role". **Until a
    /// reviewer measured it, this test asserted that only of `role(ofImageAt:)` and never of
    /// `cachedLayerIsReusable`, so the sentence above described a property nothing held:
    /// weakening the predicate to `!= nil` left `swift test --filter ArcaEngineTests` at 171
    /// passing.** The last assertion is the one that makes the claim true, and it is driven
    /// over the cache layout rather than a bare temp file because that is where the predicate
    /// meets a writable image: in a layer's slot it is a wrong rootfs, not a missing one, and
    /// the guest would mount it without complaint.
    func testTheWritableRoleIsNotMistakenForALayer() throws {
        let writable = try image(
            named: "writable.ext4",
            label: ArcaBlockDeviceRole.overlayWritable.volumeLabel
        )
        let inCache = try cachedLayer(
            in: scratch.appendingPathComponent("layers"),
            digest: "sha256:writable",
            label: ArcaBlockDeviceRole.overlayWritable.volumeLabel
        )

        XCTAssertEqual(ArcaBlockDeviceRole.role(ofImageAt: writable), .overlayWritable)
        XCTAssertNotEqual(
            ArcaBlockDeviceRole.role(ofImageAt: writable),
            .overlayLayer,
            "the cache-hit check accepts only .overlayLayer, and this is why it must"
        )
        XCTAssertFalse(
            OverlayFSUnpacker.cachedLayerIsReusable(at: inCache),
            "a writable image in a layer's cache slot must not be reused as a layer; without "
                + "this the predicate could accept any role at all and nothing would object"
        )
    }

    /// The decision the cache actually makes, over a real cache layout.
    ///
    /// **The three tests above pin the PREDICATE, and a reviewer showed that is not the same
    /// thing.** Bypassing the check at its call site -- `if true || cachedRole == .overlayLayer`,
    /// which is the pre-fix behaviour exactly -- left `swift test --filter ArcaEngineTests` at
    /// 155 passing. `OverlayFSUnpacker.cachedLayerIsReusable` exists so that the decision has a
    /// name a test can reach; this drives it over `{cache}/{digest}/layer.ext4` rather than over
    /// a bare temp file, so the fixture is the shape the unpacker meets.
    func testAStaleCacheEntryIsNotReusableAndAFreshOneIs() throws {
        let cache = scratch.appendingPathComponent("layers")
        let stale = try cachedLayer(in: cache, digest: "sha256:stale", label: nil)
        let fresh = try cachedLayer(
            in: cache,
            digest: "sha256:fresh",
            label: ArcaBlockDeviceRole.overlayLayer.volumeLabel
        )

        XCTAssertTrue(OverlayFSUnpacker.cachedLayerExists(at: stale))
        XCTAssertFalse(
            OverlayFSUnpacker.cachedLayerIsReusable(at: stale),
            "a cache entry written before role labels existed must be reformatted, not reused"
        )
        XCTAssertTrue(
            OverlayFSUnpacker.cachedLayerIsReusable(at: fresh),
            "a labelled entry must still be a hit; without this the check would reformat forever"
        )
    }

    /// Discarding an entry twice is not an error, and a failure that is not "already gone" is.
    ///
    /// The unpacker is re-entrant across `await` and two `Create`s can share a layer digest, so
    /// both can reach the discard. The loser must not fail the RPC over work the winner already
    /// did -- but nothing else may be swallowed, because an entry that survives is handed to the
    /// guest unlabelled, which is the defect this whole change exists to prevent.
    func testDiscardingAnAlreadyDiscardedEntryIsNotAnError() throws {
        let cache = scratch.appendingPathComponent("layers")
        let entry = try cachedLayer(in: cache, digest: "sha256:raced", label: nil)

        XCTAssertNoThrow(try OverlayFSUnpacker.discardCachedLayer(at: entry))
        XCTAssertFalse(OverlayFSUnpacker.cachedLayerExists(at: entry))
        XCTAssertNoThrow(
            try OverlayFSUnpacker.discardCachedLayer(at: entry),
            "a second discard races the first and must be the outcome it wanted, not a failure"
        )
    }

    /// That `unpackLayerToCache` CONSULTS the reusability check, which nothing above proves.
    ///
    /// **The three predicate tests pin what the answer is and the two decision tests pin what
    /// each answer means; none of them pins the CALL.** That is the gap milestone 2's re-review
    /// recorded and deliberately left, because closing it needs a real `Image` rather than a
    /// bare path: `unpackLayerToCache` is `private`
    /// (`containerization/Sources/Containerization/Image/Unpacker/OverlayFSUnpacker.swift:217`),
    /// so `unpack` is the only way in.
    ///
    /// The assertions are on the entry's LABEL, its CONTENT and its INODE afterwards, not on a
    /// call count. A stale entry is a perfectly valid ext4 filesystem and the only thing wrong
    /// with it is an absence, so "the label is now there" is the same statement as "the check
    /// ran and the reformat followed" -- and it is the statement the guest's classifier acts on.
    ///
    /// **The label alone is not enough, and a reviewer measured why.** It is written where the
    /// entry is FORMATTED, so it says nothing about what was unpacked into it afterwards:
    /// replacing the unpack call in `unpackLayerToCache` with a no-op left the whole engine
    /// suite green. A correctly labelled, valid, EMPTY layer is the milestone's own defect
    /// signature reached through the miss path instead of the hit path -- a container booting on
    /// a rootfs built from none of its image, with `Start` succeeding. So the content is
    /// asserted too, which the fixture's real tar is what makes cheap.
    ///
    /// The inode pins the other half of the branch: `discardCachedLayer`'s CALL. Removing it
    /// leaves the reformat to happen in place over the surviving file, and the label lands
    /// either way, so nothing but the file's identity separates discard-and-rebuild from
    /// reformat-in-place.
    ///
    /// The content is asserted as BYTES and not as filenames, which is the same finding a third
    /// time and one level further down. MEASURED by a reviewer: emptying the fixture entry while
    /// leaving the entry itself in place -- a layer with the label, the right filenames, a fresh
    /// inode, 2GB of size and none of the image's data -- left this file at 8 tests, 0 failures.
    ///
    /// **The CONTENT and the INODE are each measured against their opposite by
    /// `testUnpackingOverALabelledCacheEntryLeavesItAlone`, which takes the same readings over
    /// an entry that is reused and gets the other answer to both** -- on unmutated code, in the
    /// same run. That is what says those two readings can distinguish anything. **The LABEL is
    /// not among them**: a reused entry keeps `.overlayLayer`, so there is no opposite answer to
    /// get, and the label is pinned absolutely rather than differentially. Its receipt is the
    /// maintainer's `if true || …` mutation instead, which fails this test and only this test.
    func testUnpackingOverAStaleCacheEntryRelabelsItRatherThanReusingIt() async throws {
        let payload = "the layer this test unpacks"
        let image = try await loadedImage(reference: "stale-cache-probe:latest", payload: payload)
        let platform = SystemPlatform.linuxArm.ociPlatform()
        // Awaited into a local first: `XCTUnwrap` takes an autoclosure, which
        // cannot carry the `await`.
        let layers = try await image.manifest(for: platform).layers
        let digest = try XCTUnwrap(
            layers.first?.digest,
            "the fixture image must carry a layer for the unpacker to cache"
        )

        // Seeded the way a pre-label engine left it: correct layout, correct
        // filename, valid ext4, no role label.
        let cache = scratch.appendingPathComponent("layers")
        let seeded = try cachedLayer(in: cache, digest: digest, label: nil)
        XCTAssertNil(
            ArcaBlockDeviceRole.role(ofImageAt: FilePath(seeded.path)),
            "the seeded entry must start unlabelled or this test asserts nothing"
        )
        XCTAssertEqual(
            try pathsIn(imageAt: seeded), ["/", "/lost+found"],
            "the seeded entry must start without the payload or the content assertion below "
                + "would hold before the unpack ran"
        )
        let seededInode = try inodeOfFile(at: seeded)

        let unpacker = OverlayFSUnpacker(layerCachePath: cache)
        let config = try await unpacker.unpack(
            image, for: platform, at: scratch.appendingPathComponent("container")
        )

        XCTAssertEqual(
            config.lowerLayers, [seeded],
            "the reformatted entry must be the one handed to the guest, or this asserts on a "
                + "file the container never mounts"
        )
        XCTAssertEqual(
            ArcaBlockDeviceRole.role(ofImageAt: FilePath(seeded.path)),
            .overlayLayer,
            """
            the unpacker reused a stale cache entry unexamined. The guest's classifier drops an \
            unlabelled device with 'is not an Arca role, leaving it alone', so the rootfs is \
            built from a subset of its image -- or from none of it, with Start still succeeding.
            """
        )
        XCTAssertEqual(
            try pathsIn(imageAt: seeded), ["/", "/lost+found", "/payload"],
            """
            the rebuilt entry carries the role label over none of the image's layer. That is the \
            same silent wrong rootfs the label exists to prevent, reached by relabelling an \
            empty filesystem instead of by reusing a stale one.
            """
        )
        XCTAssertEqual(
            try sizeOfEntry(named: "/payload", inImageAt: seeded), Int64(payload.utf8.count),
            "the rebuilt entry must hold the image's layer BYTES, not merely a file bearing its "
                + "name: an entry present and empty is the same absence one level down"
        )
        XCTAssertNotEqual(
            try inodeOfFile(at: seeded), seededInode,
            "the stale entry must be DISCARDED and rebuilt, not reformatted in place: the label "
                + "lands either way, so nothing else separates the two"
        )
    }

    /// The control for the test above, and it is not optional.
    ///
    /// Without it an unpacker that ignored the cache entirely -- never calling the check,
    /// reformatting on every pass -- would satisfy every assertion above, which is the
    /// one-sided-assertion shape `testAnImageFormattedForALayerReportsThatRole` exists to close
    /// for the predicate. This closes it for the call.
    ///
    /// It reads the entry's SIZE because that is what separates "reused" from "rebuilt" without
    /// reaching into the unpacker: `cachedLayer` seeds with `minDiskSize: 2 * 1024 * 1024` and
    /// `unpackLayerToCache` formats with `2 * 1024 * 1024 * 1024`
    /// (`containerization/Sources/Containerization/Image/Unpacker/OverlayFSUnpacker.swift:311`).
    /// The two are not the requested numbers -- the formatter floors the seed at 128MB -- but
    /// they are far apart, and that is all this needs. MEASURED: seeding this test unlabelled,
    /// so the rebuild it is the control for actually happens, fails it with 2147483648 against
    /// 134217728. A reviewer then measured the same thing from the production side: making the
    /// cache-hit branch unreachable fails this test and only this test.
    ///
    /// **It also reads the content and the inode, and that is the half that is not about this
    /// test at all.** The test above asserts a rebuilt entry gains `/payload` holding the
    /// image's bytes, and changes inode; this one asserts a reused entry does neither. Two
    /// readings, two opposite answers, one run, no mutation -- which is what makes those
    /// assertions demonstrably able to tell the two outcomes apart rather than merely able to
    /// pass. The LABEL is deliberately not among them: a reused entry keeps `.overlayLayer`, so
    /// there is no opposite answer for this test to get.
    func testUnpackingOverALabelledCacheEntryLeavesItAlone() async throws {
        let image = try await loadedImage(
            reference: "fresh-cache-probe:latest", payload: "the layer this test does not unpack"
        )
        let platform = SystemPlatform.linuxArm.ociPlatform()
        let layers = try await image.manifest(for: platform).layers
        let digest = try XCTUnwrap(
            layers.first?.digest,
            "the fixture image must carry a layer for the unpacker to cache"
        )

        let cache = scratch.appendingPathComponent("layers")
        let seeded = try cachedLayer(
            in: cache, digest: digest, label: ArcaBlockDeviceRole.overlayLayer.volumeLabel
        )
        let seededSize = try sizeOfFile(at: seeded)
        let seededInode = try inodeOfFile(at: seeded)

        let unpacker = OverlayFSUnpacker(layerCachePath: cache)
        let config = try await unpacker.unpack(
            image, for: platform, at: scratch.appendingPathComponent("container")
        )

        XCTAssertEqual(config.lowerLayers, [seeded])
        XCTAssertEqual(
            try sizeOfFile(at: seeded), seededSize,
            "a labelled entry must be a cache HIT; rebuilding it would make the test above pass "
                + "for an unpacker that never consults the check at all"
        )
        XCTAssertEqual(
            try pathsIn(imageAt: seeded), ["/", "/lost+found"],
            "a reused entry must not gain the image's layer -- and the test above must not pass "
                + "for a reading that reports '/payload' whatever it is handed"
        )
        XCTAssertEqual(
            try inodeOfFile(at: seeded), seededInode,
            "a reused entry must keep its identity -- and the test above must not pass for a "
                + "reading that reports a fresh inode whatever it is handed"
        )
    }

    /// A real `Image`, loaded from a real OCI layout through the engine's own store.
    ///
    /// The load is `ImageManager.loadFromOCILayout`, which is what `arca-engine image load`
    /// reaches (`EngineImageLoad.swift:82`); `loadWorkspaceImages` wraps that same call but
    /// reports only references, and an `Image` is what the unpacker takes. The digest under test
    /// is therefore Containerization's, not one this test invented.
    private func loadedImage(reference: String, payload: String) async throws -> Image {
        let layout = try OCILayoutFixture.write(
            at: scratch.appendingPathComponent("layout"), reference: reference, payload: payload
        )
        let manager = try EngineManagers.makeImageManager(
            paths: EnginePaths(stateRoot: scratch.appendingPathComponent("state")),
            logger: Logger(label: "layer-cache-role-tests")
        )
        let loaded = try await manager.loadFromOCILayout(directory: layout)
        return try XCTUnwrap(
            loaded.first, "the layout must load exactly the image the unpack is driven over"
        )
    }

    /// `{cache}/{digest}/layer.ext4`, which is the layout `unpackLayerToCache` builds.
    private func cachedLayer(in cache: URL, digest: String, label: String?) throws -> URL {
        let directory = cache.appendingPathComponent(digest)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("layer.ext4")
        let formatter = try EXT4.Formatter(
            FilePath(path.path),
            minDiskSize: 2 * 1024 * 1024,
            volumeLabel: label
        )
        try formatter.close()
        return path
    }

    /// The on-disk size of `path`, which is how a reused cache entry is told from a rebuilt one.
    private func sizeOfFile(at path: URL) throws -> Int64 {
        try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: path.path)[.size] as? Int64,
            "the cache entry must exist and report a size"
        )
    }

    /// The file's identity, which is how a discarded-and-rebuilt entry is told from one
    /// reformatted in place. Both leave a 2GB labelled file at the same path; only one leaves a
    /// different file there.
    private func inodeOfFile(at path: URL) throws -> UInt64 {
        try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: path.path)[.systemFileNumber] as? UInt64,
            "the cache entry must exist and report a file number"
        )
    }

    /// Every entry inside the ext4 image at `path`.
    ///
    /// This is what separates a layer that holds its image from one that merely carries its
    /// label. The two are indistinguishable to every other reading here -- same path, same
    /// label, same size on disk -- and the second is a container booting on a rootfs built from
    /// none of its image, with `Start` succeeding.
    private func entriesIn(imageAt path: URL) throws -> [EXT4.FilesystemEnumerator.FileInfo] {
        let reader = try EXT4.EXT4Reader(blockDevice: FilePath(path.path))
        return try EXT4.FilesystemEnumerator(reader: reader).enumerateFilesystem()
    }

    /// The image's structure: which entries exist, sorted.
    private func pathsIn(imageAt path: URL) throws -> [String] {
        try entriesIn(imageAt: path).map(\.path).sorted()
    }

    /// The image's content: how many bytes one named entry actually holds.
    ///
    /// Asked separately from `pathsIn` because they are separate properties, and a reviewer
    /// measured that the difference matters: an entry that exists and holds nothing satisfies
    /// every structural reading while carrying none of the image.
    private func sizeOfEntry(named name: String, inImageAt path: URL) throws -> Int64 {
        try XCTUnwrap(
            try entriesIn(imageAt: path).first { $0.path == name }?.size,
            "the image must hold an entry at \(name)"
        )
    }

    /// A path holding no filesystem at all answers `nil` rather than throwing.
    ///
    /// The caller is classifying, not validating: it has to reach "reformat this" from a
    /// truncated or garbage file the same way it reaches it from an unlabelled one. A throw
    /// here would propagate out of an image unpack instead.
    func testAPathThatIsNotAFilesystemHasNoRole() throws {
        let garbage = scratch.appendingPathComponent("garbage.ext4")
        try Data(repeating: 0x5A, count: 8192).write(to: garbage)

        XCTAssertNil(ArcaBlockDeviceRole.role(ofImageAt: FilePath(garbage.path)))
    }
}
