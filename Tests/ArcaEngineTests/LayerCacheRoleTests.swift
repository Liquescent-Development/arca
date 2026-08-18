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
///
/// **Every test here was one-layer until `OCILayoutFixture.Layer` existed, and a one-layer
/// image cannot ask the cache which layer it returned.** With a single layer, "the slot holds
/// the image's layer", "the slot holds the layer it is keyed by", "the layers come back in the
/// image's order" and "each layer got its own cache decision" are all the same sentence, and
/// three of the four go untested while the first passes. The multi-layer tests at the bottom of
/// this file separate them; the design call and the mutations that show each one can fail are
/// recorded on those tests.
final class LayerCacheRoleTests: XCTestCase {
    /// The layers every multi-layer test here is driven over: distinct path AND distinct
    /// content, bottom to top.
    ///
    /// **The three contents are the same LENGTH (18 bytes each), deliberately.** A reading that
    /// compared only entry sizes -- which is what the one-layer tests above do, and all they
    /// need -- cannot tell these apart, so the byte comparisons below are load-bearing rather
    /// than a stricter spelling of a size check. The paths are distinct for the other half:
    /// a whole wrong layer in a slot shows up structurally, before any byte is read.
    private static let layers = [
        OCILayoutFixture.Layer(path: "bottom", content: "bottom layer bytes"),
        OCILayoutFixture.Layer(path: "middle", content: "middle layer bytes"),
        OCILayoutFixture.Layer(path: "top", content: "topmost layer byte")
    ]

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

    /// Each layer's cache slot holds THAT layer, not some layer.
    ///
    /// This is the question a one-layer fixture cannot ask. `unpackLayerToCache` keys the cache
    /// on `layer.digest` and fills it from `image.getContent(digest: layer.digest)`; with one
    /// layer those are the only digest in the image, so a cache that returned the first match
    /// regardless of which layer was asked for, or that filled every slot from one layer,
    /// passes every assertion the tests above make.
    ///
    /// It reads the slots BY DIGEST rather than through `config.lowerLayers`, which keeps it
    /// independent of the order the unpacker hands them back -- that is
    /// `testTheCachedLayersComeBackInTheImagesOwnOrder`'s subject, and the two are kept
    /// separable on purpose so that a mutation to one mechanism does not fail both tests.
    ///
    /// The path and the content are both asserted because neither covers the other: a slot
    /// filled from the wrong layer shows a wrong path, and a slot filled with the right
    /// filename over the wrong or absent bytes shows only in the bytes. The fixture's three
    /// contents are the same length so that the byte comparison is doing the work.
    ///
    /// **MEASURED, and the measurement is the reason this test exists rather than a claim
    /// about it.** Making every slot's content come from layer 0 -- in
    /// `OverlayFSUnpacker.unpackLayerToCache`, replacing `image.getContent(digest: layer.digest)`
    /// with a fetch of `image.manifest(for: SystemPlatform.linuxArm.ociPlatform()).layers[0].digest`,
    /// which is the cache returning the first match whichever layer was asked for -- fails this
    /// test and `testAStaleLayerIsRebuiltWhileItsLabelledSiblingIsReused`, and **nothing else in
    /// the file or the suite**: 243 tests, 2 failures, both of them multi-layer. Every one of
    /// the eight one-layer tests above stayed green, which is the blindness this task closes
    /// stated as a reading rather than as an argument.
    ///
    /// **The 243 is the suite the run was taken over, one test short of the commit that landed
    /// it.** `823201e` also added
    /// `OCILayoutFixtureTests.testAMultiLayerLayoutRefusesLayersItCouldNotTellApart`, so a
    /// reader reproducing this mutation at `823201e` sees 244 tests and the same 2 failures --
    /// not a test that went missing. The failing set is the claim; the total is only the run it
    /// came from.
    func testEachLayerIsCachedUnderItsOwnDigestHoldingItsOwnContent() async throws {
        let image = try await loadedImage(
            reference: "multi-layer-probe:latest", layers: Self.layers
        )
        let platform = SystemPlatform.linuxArm.ociPlatform()
        let descriptors = try await image.manifest(for: platform).layers

        XCTAssertEqual(
            descriptors.count, Self.layers.count,
            "the layout must carry one layer per fixture layer, or the per-layer assertions "
                + "below run over fewer slots than they name"
        )
        XCTAssertEqual(
            Set(descriptors.map(\.digest)).count, Self.layers.count,
            "the layers must carry DISTINCT digests: the cache is keyed by digest, so layers "
                + "sharing one cannot be asked for separately and this test would be vacuous"
        )

        let cache = scratch.appendingPathComponent("layers")
        let unpacker = OverlayFSUnpacker(layerCachePath: cache)
        _ = try await unpacker.unpack(
            image, for: platform, at: scratch.appendingPathComponent("container")
        )

        for (index, layer) in Self.layers.enumerated() {
            let slot = cacheSlot(in: cache, digest: descriptors[index].digest)
            XCTAssertEqual(
                try pathsIn(imageAt: slot), ["/", "/lost+found", "/\(layer.path)"].sorted(),
                """
                the slot keyed by layer \(index)'s digest holds a different layer's entries. A \
                cache that answers with some layer rather than the one it was asked for builds \
                a rootfs out of the wrong image content, with Start succeeding.
                """
            )
            XCTAssertEqual(
                try contentOfEntry(named: "/\(layer.path)", inImageAt: slot),
                Data(layer.content.utf8),
                """
                the slot keyed by layer \(index)'s digest carries that layer's filename over \
                bytes that are not that layer's. All three fixture layers are the same length, \
                so no size or structural reading can see this one.
                """
            )
        }
    }

    /// The layers come back bottom-to-top in the image's own order.
    ///
    /// `unpack` unpacks layers concurrently and re-sorts by index before returning, so the
    /// order in `lowerLayers` is a decision the code makes rather than a consequence of how it
    /// iterates -- and with one layer that decision is unobservable. The order is what the
    /// guest stacks the overlay in: reversed, every file that a higher layer overrides comes
    /// back as the version the image replaced, which is not an error anywhere.
    ///
    /// It asserts on the PATHS only, deliberately, and reads none of the slots' contents. That
    /// is what keeps it separable from `testEachLayerIsCachedUnderItsOwnDigestHoldingItsOwnContent`:
    /// the two mechanisms -- which content fills a slot, and which order the slots come back in
    /// -- are independent, and MEASURED to be. Reversing the sort in `OverlayFSUnpacker.unpack`
    /// (`collected.sorted { $0.0 < $1.0 }` to `{ $0.0 > $1.0 }`) leaves the suite at 243 tests
    /// with exactly one failure, this one; the content mutation recorded on that test fails two
    /// tests and leaves this one green. Neither test rides on the other's fix.
    ///
    /// The 243 is the suite that run was taken over, one test short of `823201e`, which landed
    /// this alongside `OCILayoutFixtureTests.testAMultiLayerLayoutRefusesLayersItCouldNotTellApart`;
    /// reproducing the mutation at `823201e` gives 244 tests and the same single failure.
    func testTheCachedLayersComeBackInTheImagesOwnOrder() async throws {
        let image = try await loadedImage(
            reference: "layer-order-probe:latest", layers: Self.layers
        )
        let platform = SystemPlatform.linuxArm.ociPlatform()
        let descriptors = try await image.manifest(for: platform).layers

        let cache = scratch.appendingPathComponent("layers")
        let unpacker = OverlayFSUnpacker(layerCachePath: cache)
        let config = try await unpacker.unpack(
            image, for: platform, at: scratch.appendingPathComponent("container")
        )

        XCTAssertEqual(
            config.lowerLayers,
            descriptors.map { cacheSlot(in: cache, digest: $0.digest) },
            """
            the unpacked layers are handed to the guest in an order that is not the manifest's. \
            The overlay stacks them in this order, so a wrong one silently serves the version of \
            every overridden file that the image replaced.
            """
        )
    }

    /// The cache decides per layer, not once per image.
    ///
    /// Three slots, three different starting states in ONE unpack: layer 0 seeded labelled (a
    /// hit), layer 1 seeded unlabelled (a stale entry, which must be discarded and rebuilt),
    /// layer 2 not seeded at all (a plain miss). The tests above establish what each of those
    /// answers means for an image of one layer; nothing in them says the answer is taken again
    /// for the next layer, and a check hoisted out of the loop -- or a result cached across
    /// layers -- would leave a partially stale cache either wholly reused or wholly rebuilt.
    ///
    /// Wholly reused is the milestone's own defect for the layers that were stale; wholly
    /// rebuilt is merely slow, which is why the reuse readings here are the ones that would go
    /// quiet, and why the reused slot is asserted to keep its inode, its size and its emptiness
    /// rather than just to exist.
    ///
    /// The rebuilt and missed slots are asserted to hold THEIR OWN layers, which is the per-layer
    /// identity question again in the state where it is easiest to get wrong: the unpacker is
    /// mid-loop with another layer's content already in hand.
    ///
    /// **MEASURED against two mutations, and it is the second that says this is not a longer
    /// spelling of the test above.** The maintainer's `if true || Self.cachedLayerIsReusable(…)`
    /// -- the pre-fix behaviour exactly -- fails this test and
    /// `testUnpackingOverAStaleCacheEntryRelabelsItRatherThanReusingIt` and nothing else (243
    /// tests, 2 failures), which
    /// `testEachLayerIsCachedUnderItsOwnDigestHoldingItsOwnContent` survives because it seeds no
    /// cache entry at all. The wrong-layer-content mutation recorded on that test fails this one
    /// too: the two share the content-identity mechanism, and no mutation was found that this
    /// test survives and that one catches.
    ///
    /// The 243 is the suite that run was taken over, one test short of `823201e`, which landed
    /// this alongside `OCILayoutFixtureTests.testAMultiLayerLayoutRefusesLayersItCouldNotTellApart`;
    /// reproducing the mutation at `823201e` gives 244 tests and the same 2 failures.
    func testAStaleLayerIsRebuiltWhileItsLabelledSiblingIsReused() async throws {
        let image = try await loadedImage(
            reference: "partial-reuse-probe:latest", layers: Self.layers
        )
        let platform = SystemPlatform.linuxArm.ociPlatform()
        let descriptors = try await image.manifest(for: platform).layers
        let cache = scratch.appendingPathComponent("layers")

        let reused = try cachedLayer(
            in: cache,
            digest: descriptors[0].digest,
            label: ArcaBlockDeviceRole.overlayLayer.volumeLabel
        )
        let stale = try cachedLayer(in: cache, digest: descriptors[1].digest, label: nil)
        let missed = cacheSlot(in: cache, digest: descriptors[2].digest)
        XCTAssertFalse(
            OverlayFSUnpacker.cachedLayerExists(at: missed),
            "layer 2 must start with no cache entry at all, or it is not the miss this names"
        )
        let reusedInode = try inodeOfFile(at: reused)
        let reusedSize = try sizeOfFile(at: reused)
        let staleInode = try inodeOfFile(at: stale)

        let unpacker = OverlayFSUnpacker(layerCachePath: cache)
        _ = try await unpacker.unpack(
            image, for: platform, at: scratch.appendingPathComponent("container")
        )

        XCTAssertEqual(
            try inodeOfFile(at: reused), reusedInode,
            "the labelled sibling must be REUSED: a rebuild here would mean the cache took one "
                + "decision for the whole image rather than one per layer"
        )
        XCTAssertEqual(try sizeOfFile(at: reused), reusedSize)
        XCTAssertEqual(
            try pathsIn(imageAt: reused), ["/", "/lost+found"],
            "a reused slot must not gain its layer, or the readings above cannot tell reuse "
                + "from a rebuild that happened to land on the same inode"
        )

        XCTAssertNotEqual(
            try inodeOfFile(at: stale), staleInode,
            "the stale sibling must be discarded and rebuilt even though the layer before it "
                + "was a hit; left alone it reaches the guest unlabelled and is dropped silently"
        )
        XCTAssertEqual(
            try pathsIn(imageAt: stale), ["/", "/lost+found", "/middle"].sorted(),
            "the rebuilt slot must hold ITS OWN layer -- the unpacker is mid-loop with another "
                + "layer's content in hand, which is where this is easiest to get wrong"
        )
        XCTAssertEqual(
            try contentOfEntry(named: "/middle", inImageAt: stale),
            Data(Self.layers[1].content.utf8),
            "the rebuilt slot carries its layer's filename over another layer's bytes"
        )

        XCTAssertEqual(
            try pathsIn(imageAt: missed), ["/", "/lost+found", "/top"].sorted(),
            "the unseeded slot must be filled from its own layer, which is the plain miss path "
                + "running beside a hit and a discard in the same unpack"
        )
        XCTAssertEqual(
            try contentOfEntry(named: "/top", inImageAt: missed),
            Data(Self.layers[2].content.utf8)
        )
    }

    /// A layer the unpacker REFUSES must leave nothing behind that the next create reuses.
    ///
    /// **This is the one state no test in this file constructed, and it is the one that turns a
    /// loud refusal into a silent wrong rootfs from the second attempt onward.** Every test above
    /// drives an unpack that succeeds; the refusal Task 6 added
    /// (`ContainerizationEXT4/Formatter+Unpack.swift:110-120`) throws with the formatter already
    /// created AT the final cache path and carrying the layer volume label, and `close()` is what
    /// writes the superblock and that label
    /// (`ContainerizationEXT4/EXT4+Formatter.swift:645, 970-972`). So a formatter closed on the
    /// failure path leaves a valid, correctly labelled, EMPTY `layer.ext4` in the slot -- which is
    /// byte-for-byte what `cachedLayer(in:digest:label:)` above seeds, and
    /// `testAStaleLayerIsRebuiltWhileItsLabelledSiblingIsReused` proves that is a cache HIT.
    ///
    /// The create fails loudly ONCE. Every create afterwards gets an empty layer and succeeds:
    /// the poisoned slot is a real ext4, carries `.overlayLayer`, is attached, is counted, and
    /// `ArcaLayerAttachment.resolve` sees `attached == identified` and resolves `.complete`. Task
    /// 7's count guard cannot see it, because there is nothing about it to see. That is this
    /// milestone's own defect signature reached through the FAILURE path -- a rootfs built from
    /// none of its image, with `Start` succeeding.
    ///
    /// **MEASURED against the unfixed unpacker before the fix existed**, which is why the second
    /// assertion is the load-bearing one rather than the first: at submodule `fb2b2f2` the first
    /// unpack threw as it should and the retry took the cache HIT branch and SUCCEEDED. The exact
    /// output is quoted in `Documentation/EVIDENCE-layer-cache-poisoning.md`, in this repository
    /// and in git -- a committed test citing a file that is not committed leaves its evidence
    /// with no durable home, which is where this record spent Landing 1.
    ///
    /// It asserts the retry THROWS rather than asserting on the cache predicate alone, because
    /// the predicate is a reading and the retry is the behaviour: an implementation that left a
    /// slot the predicate rejected but that some other branch accepted would satisfy the reading
    /// and not the behaviour.
    func testAnUnpackThatRefusesALayerLeavesNoCacheEntryForTheNextCreateToReuse() async throws {
        let image = try await loadedImage(
            reference: "refused-layer-probe:latest",
            layers: [
                OCILayoutFixture.Layer(
                    path: "payload",
                    content: "these bytes are not a tar",
                    blob: .bytesThatAreNotTheDeclaredArchive
                )
            ]
        )
        let platform = SystemPlatform.linuxArm.ociPlatform()
        let descriptors = try await image.manifest(for: platform).layers
        let digest = try XCTUnwrap(
            descriptors.first?.digest, "the fixture image must carry the layer under test"
        )

        let cache = scratch.appendingPathComponent("layers")
        let slot = cacheSlot(in: cache, digest: digest)
        let unpacker = OverlayFSUnpacker(layerCachePath: cache)

        let first = await errorFrom {
            _ = try await unpacker.unpack(
                image, for: platform, at: self.scratch.appendingPathComponent("container-1")
            )
        }
        let firstFailure = try XCTUnwrap(
            first,
            "the unpack of a blob that is not the archive its media type declares must FAIL; "
                + "without that this test is not about a failure path at all"
        )
        XCTAssertTrue(
            "\(firstFailure)".contains("is not a paxRestricted archive with filter none"),
            "the failure must be Task 6's refusal and not some other error, or what it leaves "
                + "behind is not the state under test. Got: \(firstFailure)"
        )
        // The refusal must NAME the layer. `UnpackError.sourceIsNotDeclaredArchive` carries the
        // declaration it refused against and nothing that identifies which of an image's layers
        // carried it -- and the layers are unpacked concurrently, so the log order does not say
        // either. Without the digest an operator cannot find the layer, and the media type is
        // what tells them whether the blob or the declaration is the wrong half.
        XCTAssertTrue(
            "\(firstFailure)".contains(digest),
            "a refused layer must be named by its DIGEST: it is the only handle the operator has "
                + "on which layer of the image refused. Got: \(firstFailure)"
        )
        XCTAssertTrue(
            "\(firstFailure)".contains(try XCTUnwrap(descriptors.first?.mediaType)),
            "a refused layer must name the media type it was declared under, which is the half "
                + "that says whether the blob or the declaration is wrong. Got: \(firstFailure)"
        )

        XCTAssertFalse(
            OverlayFSUnpacker.cachedLayerIsReusable(at: slot),
            """
            the refused layer left a REUSABLE cache slot. It is a valid ext4 carrying \
            .overlayLayer over none of the image, so the guest classifies it, Task 7's count \
            counts it, and the container boots on a rootfs missing that layer entirely.
            """
        )
        XCTAssertFalse(
            OverlayFSUnpacker.cachedLayerExists(at: slot),
            "a cache slot must not exist at all unless the unpack that would fill it succeeded: "
                + "a slot whose existence is not conditional on success is one predicate change "
                + "away from being reused again"
        )

        let second = await errorFrom {
            _ = try await unpacker.unpack(
                image, for: platform, at: self.scratch.appendingPathComponent("container-2")
            )
        }
        let secondFailure = try XCTUnwrap(
            second,
            """
            the retry SUCCEEDED over a layer the first attempt refused. The refusal was converted \
            into a silent acceptance by the cache, which is the whole defect: it fails loudly \
            once and then hands every later create an empty layer.
            """
        )
        XCTAssertTrue(
            "\(secondFailure)".contains("is not a paxRestricted archive with filter none"),
            "the retry must reach the same refusal, not a different failure over the wreckage of "
                + "the first. Got: \(secondFailure)"
        )
    }

    /// One refused layer must not leave its SIBLINGS' slots reusable-but-incomplete.
    ///
    /// `unpack` runs the layers in a `withThrowingTaskGroup`
    /// (`Containerization/Image/Unpacker/OverlayFSUnpacker.swift:84-115`), which cancels the
    /// siblings when one child throws, and `unpackEntries` checks cancellation each iteration
    /// (`ContainerizationEXT4/Formatter+Unpack.swift:132`). So a refusal on one layer can stop the
    /// others mid-unpack -- and a formatter closed there writes a correctly labelled, PARTIALLY
    /// populated slot. Those are cache hits too, and cache slots are keyed by digest alone, so
    /// they are shared with every other image carrying the same layer.
    ///
    /// The sibling assertion is conditional -- a slot that survives must be COMPLETE -- rather
    /// than "no slot survives", and deliberately: a sibling that finished before the cancellation
    /// arrived has a legitimate, complete entry, and refusing that would be asserting a race
    /// rather than a property. The fixture's layers are one entry each, so they usually do
    /// finish; the property that must hold either way is that nothing reusable is partial.
    ///
    /// The retry assertion is what makes this test more than a longer spelling of the one above:
    /// it drives a THREE-layer image, where the poisoned slot is one of several and the create
    /// that reuses it succeeds with two good layers and one empty one. That is the wrong-rootfs
    /// outcome in the shape a real image has.
    func testARefusedLayerLeavesNoPartialSlotForItsSiblings() async throws {
        let layers = [
            OCILayoutFixture.Layer(path: "bottom", content: "bottom layer bytes"),
            OCILayoutFixture.Layer(path: "middle", content: "middle layer bytes"),
            OCILayoutFixture.Layer(
                path: "top",
                content: "these bytes are not a tar",
                blob: .bytesThatAreNotTheDeclaredArchive
            )
        ]
        let image = try await loadedImage(reference: "refused-sibling-probe:latest", layers: layers)
        let platform = SystemPlatform.linuxArm.ociPlatform()
        let descriptors = try await image.manifest(for: platform).layers
        XCTAssertEqual(
            Set(descriptors.map(\.digest)).count, layers.count,
            "the three layers must carry distinct digests, or they share one slot and the "
                + "sibling assertions below run over fewer slots than they name"
        )

        let cache = scratch.appendingPathComponent("layers")
        let unpacker = OverlayFSUnpacker(layerCachePath: cache)

        let first = await errorFrom {
            _ = try await unpacker.unpack(
                image, for: platform, at: self.scratch.appendingPathComponent("container-1")
            )
        }
        XCTAssertNotNil(first, "the image carries a layer the unpacker must refuse")

        let refused = cacheSlot(in: cache, digest: descriptors[2].digest)
        XCTAssertFalse(
            OverlayFSUnpacker.cachedLayerIsReusable(at: refused),
            "the refused layer's own slot must not be reusable"
        )

        for index in 0..<2 {
            let sibling = cacheSlot(in: cache, digest: descriptors[index].digest)
            guard OverlayFSUnpacker.cachedLayerIsReusable(at: sibling) else { continue }
            XCTAssertEqual(
                try pathsIn(imageAt: sibling), ["/", "/lost+found", "/\(layers[index].path)"].sorted(),
                """
                layer \(index)'s slot survived the sibling refusal as a REUSABLE but incomplete \
                entry. It carries .overlayLayer over part of its layer, and every later create \
                over this digest -- in any image -- takes it as a hit.
                """
            )
            XCTAssertEqual(
                try contentOfEntry(named: "/\(layers[index].path)", inImageAt: sibling),
                Data(layers[index].content.utf8),
                "a reusable sibling slot must hold its layer's BYTES, not merely an entry "
                    + "bearing its name: a truncated file is the same absence one level down"
            )
        }

        let second = await errorFrom {
            _ = try await unpacker.unpack(
                image, for: platform, at: self.scratch.appendingPathComponent("container-2")
            )
        }
        XCTAssertNotNil(
            second,
            """
            the retry of a three-layer image SUCCEEDED over a layer the first attempt refused: \
            two good layers and one empty one, labelled, counted, and resolved .complete by Task \
            7's guard. The container boots on a rootfs missing its top layer, and Start succeeds.
            """
        )
    }

    /// A refused unpack must not leave scratch in the cache directory either.
    ///
    /// The slot's existence being conditional on success means the unpack has somewhere ELSE to
    /// write while it is still in doubt, and that somewhere must not survive the failure. An
    /// operator clearing a poisoned cache clears slots; a directory that accumulates one 2GB file
    /// per refused attempt fills the state root with files nothing will ever look at or name.
    ///
    /// It is a separate test from the two above rather than one more assertion on them because it
    /// is a separate mechanism: the promotion is what stops the reuse, and the cleanup is what
    /// stops the accumulation. The mutation matrix in
    /// `Documentation/EVIDENCE-layer-cache-poisoning.md` shows each one failing this test alone
    /// or those two alone, never both.
    func testARefusedUnpackLeavesNoScratchBesideTheCacheSlot() async throws {
        let image = try await loadedImage(
            reference: "refused-scratch-probe:latest",
            layers: [
                OCILayoutFixture.Layer(
                    path: "payload",
                    content: "these bytes are not a tar",
                    blob: .bytesThatAreNotTheDeclaredArchive
                )
            ]
        )
        let platform = SystemPlatform.linuxArm.ociPlatform()
        let descriptors = try await image.manifest(for: platform).layers
        let digest = try XCTUnwrap(descriptors.first?.digest)

        let cache = scratch.appendingPathComponent("layers")
        let unpacker = OverlayFSUnpacker(layerCachePath: cache)
        let first = await errorFrom {
            _ = try await unpacker.unpack(
                image, for: platform, at: self.scratch.appendingPathComponent("container")
            )
        }
        XCTAssertNotNil(first, "the image carries a layer the unpacker must refuse")

        let slot = cacheSlot(in: cache, digest: digest)
        let directory = slot.deletingLastPathComponent()
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: directory.path),
            "the unpacker creates the layer's directory before it formats anything, so this "
                + "test's reading below is over a directory that exists"
        )
        // Anything OTHER than the cache slot itself is scratch the failure did not clean up.
        // The slot is excluded so that this test says nothing about whether the slot survives --
        // that is the subject of the two tests above, and keeping the two readings apart is what
        // makes a mutation to either mechanism fail one test and not the other.
        let leftovers = try FileManager.default
            .contentsOfDirectory(atPath: directory.path)
            .filter { $0 != slot.lastPathComponent }
            .sorted()
        XCTAssertEqual(
            leftovers, [],
            """
            a refused unpack left \(leftovers) in the layer's cache directory. Every refused \
            attempt adds another, none of them is named by anything, and the layer cache grows \
            without bound in a state root nothing prunes.
            """
        )
    }

    /// Runs `work` and returns the error it threw, or `nil` if it did not throw.
    ///
    /// `XCTAssertThrowsError` takes an autoclosure, which cannot carry an `await`, so an async
    /// throw has to be caught by hand. Here rather than in each test so the three above read as
    /// the assertions they make rather than as the plumbing that reaches them.
    private func errorFrom(_ work: () async throws -> Void) async -> Error? {
        do {
            try await work()
            return nil
        } catch {
            return error
        }
    }

    /// A real `Image`, loaded from a real OCI layout through the engine's own store.
    ///
    /// The load is `ImageManager.loadFromOCILayout`, which is what `arca-engine image load`
    /// reaches (`EngineImageLoad.swift:82`); `loadWorkspaceImages` wraps that same call but
    /// reports only references, and an `Image` is what the unpacker takes. The digest under test
    /// is therefore Containerization's, not one this test invented.
    private func loadedImage(reference: String, payload: String) async throws -> Image {
        try await loadImage(
            fromLayoutAt: try OCILayoutFixture.write(
                at: scratch.appendingPathComponent("layout"),
                reference: reference,
                payload: payload
            )
        )
    }

    /// The same load, over a layout of more than one layer.
    ///
    /// It reaches the frozen one-layer entry point's sibling rather than passing a one-element
    /// array through it, so the one-layer tests above keep exercising the call shape their
    /// pinned bytes were measured for (`OCILayoutFixtureTests.pinnedIndexDigest`).
    private func loadedImage(
        reference: String, layers: [OCILayoutFixture.Layer]
    ) async throws -> Image {
        try await loadImage(
            fromLayoutAt: try OCILayoutFixture.write(
                at: scratch.appendingPathComponent("layout"),
                reference: reference,
                layers: layers
            )
        )
    }

    private func loadImage(fromLayoutAt layout: URL) async throws -> Image {
        let manager = try EngineManagers.makeImageManager(
            paths: EnginePaths(stateRoot: scratch.appendingPathComponent("state")),
            logger: Logger(label: "layer-cache-role-tests")
        )
        let loaded = try await manager.loadFromOCILayout(directory: layout)
        return try XCTUnwrap(
            loaded.first, "the layout must load exactly the image the unpack is driven over"
        )
    }

    /// The cache slot `unpackLayerToCache` keys `digest` to, whether or not anything is there.
    private func cacheSlot(in cache: URL, digest: String) -> URL {
        cache.appendingPathComponent(digest).appendingPathComponent("layer.ext4")
    }

    /// `{cache}/{digest}/layer.ext4`, which is the layout `unpackLayerToCache` builds.
    private func cachedLayer(in cache: URL, digest: String, label: String?) throws -> URL {
        let path = cacheSlot(in: cache, digest: digest)
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(), withIntermediateDirectories: true
        )
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

    /// The bytes one named entry holds, read out of the ext4 image.
    ///
    /// One level below `sizeOfEntry`, and the multi-layer tests need it there. The fixture's
    /// layers are all the same length by construction, so a size reading cannot tell one
    /// layer's content from another's -- and "the slot holds 18 bytes" is exactly the reading a
    /// cache that returned the wrong layer would satisfy.
    private func contentOfEntry(named name: String, inImageAt path: URL) throws -> Data {
        let reader = try EXT4.EXT4Reader(blockDevice: FilePath(path.path))
        return try reader.readFile(at: FilePath(name))
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
