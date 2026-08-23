import ContainerizationArchive
import ContainerizationOCI
import CryptoKit
import Foundation

/// Writes a real OCI image layout to disk: `oci-layout`, `index.json`, and the
/// `blobs/sha256/<hex>` files the loader reads by digest.
///
/// A real layout rather than a stub image manager, because the whole decision
/// under test is keyed on the digest `loadFromOCILayout` returns. A test that
/// hands `loadVminit` a digest of its own invention proves the invention.
///
/// The structure is the one `~/.arca/vminit` carries -- VERIFIED against it:
/// `head -c 400 ~/.arca/vminit/index.json` shows a single
/// `application/vnd.oci.image.manifest.v1+json` descriptor annotated
/// `org.opencontainers.image.ref.name: arca-vminit:latest`, and
/// `find ~/.arca/vminit` shows `oci-layout`, `index.json` and three blobs under
/// `blobs/sha256`. The JSON is encoded from the same `ContainerizationOCI`
/// types Containerization decodes it with, so the bytes cannot drift from what
/// the loader expects.
///
/// It is around a kilobyte rather than the real image's ~178MB because nothing
/// in the load path unpacks a layer: `ImageStore.ImportOperation` copies layer
/// blobs by digest and decodes only the index, the manifest and the config.
enum OCILayoutFixture {
    /// One layer of a layout: the path its single entry lands at in the unpacked
    /// filesystem, and the bytes the file there holds.
    ///
    /// **Both halves are per-layer on purpose, and neither subsumes the other.**
    /// A cache keyed by digest can only be shown to have returned the layer it
    /// was ASKED FOR by layers that differ, and the two readings differ in what
    /// they can see: the path is what a whole wrong layer in a slot shows
    /// structurally, and the content is what a right filename over wrong or
    /// absent bytes shows.
    ///
    /// **No test in the tree reads either half back out of an unpacked
    /// filesystem today.** The per-layer suite that
    /// did -- `LayerCacheRoleTests`, which recorded that finding twice for the
    /// one-layer case, one level down each time -- was deleted in `2d1f8db`
    /// along with the per-layer cache it covered, and the unpack tests that
    /// survive it (`ImageRootfsUnpackerTests`) assert at image granularity
    /// without ever opening the filesystem. Both fields are kept anyway,
    /// because the sentence above is a claim about what the two readings can
    /// SEE, which is a property of the fixture rather than of any one suite: a
    /// per-layer assertion added back with only one of them would be blind to
    /// exactly one of the two failures, and silently.
    struct Layer {
        /// How the blob under the layer's media type is written.
        ///
        /// **The dishonest case is a fixture for a REFUSAL, and it exists because
        /// nothing else in the tree can produce one.** Every layer this fixture
        /// writes is otherwise a real tar (see `layerArchive(at:containing:)`), so
        /// the input class Task 6 taught `EXT4.Formatter.unpack` to reject --
        /// bytes that are not the archive their media type declares -- had no
        /// in-tree producer, and what the unpacker's CALLER does with that
        /// refusal could not be tested at all. It is the caller, not the refusal,
        /// that its one consumer uses this for:
        /// `ImageRootfsUnpackerTests.fixtureRefusingItsLayer`, which drives
        /// exactly TWO tests -- `testARefusedUnpackLeavesNoCacheSlot` and
        /// `testARefusedUnpackLeavesNoScratchBesideTheSlot`.
        ///
        /// **The layer-granularity suite drove a third, and it has no
        /// successor.**
        /// `LayerCacheRoleTests.testARefusedLayerLeavesNoPartialSlotForItsSiblings`
        /// -- deleted with the rest of that file in `2d1f8db` -- pinned that one
        /// refused layer leaves no SIBLING slot reusable-but-incomplete. The
        /// per-layer `unpack` ran its layers in a throwing task group, so a
        /// refusal cancelled the siblings mid-unpack, a formatter closed there
        /// wrote a correctly labelled but partially populated slot, and slots
        /// keyed by digest alone were shared with every other image carrying
        /// that layer.
        ///
        /// **That property cannot be expressed at image granularity**, which is
        /// why nothing replaced it: there is one slot per image and platform, so
        /// there are no siblings to leave partial and no digest-keyed sharing
        /// between images for a partial artefact to travel through. What carries
        /// over is narrower -- that a partial or unreadable artefact is not
        /// promoted into the image's OWN slot, which is Mechanism 3 in
        /// `ImageRootfsUnpackerTests`. Read the difference as coverage that went
        /// away with the thing it covered, not as coverage retained.
        enum Blob {
            /// A real uncompressed pax tar holding `content` at `path`.
            case archive
            /// `content`'s bytes laid down raw under the same archive media type:
            /// a truncated fetch or a hand-built layout, whose digest is still
            /// correct so nothing upstream of the unpack objects.
            case bytesThatAreNotTheDeclaredArchive
        }

        /// Relative, which is the shape a real OCI layer tar has; see
        /// `layerArchive(at:containing:)`. Unused by
        /// `.bytesThatAreNotTheDeclaredArchive`, which never becomes an entry.
        let path: String
        let content: String
        let blob: Blob

        init(path: String, content: String, blob: Blob = .archive) {
            self.path = path
            self.content = content
            self.blob = blob
        }
    }

    /// Refusals, rather than a layout a later test would fail vacuously over.
    enum Failure: Error {
        /// Two layers with the same path AND content produce the same tar bytes,
        /// so they hash to one blob digest and share one cache slot. A test over
        /// them cannot tell a cache that returned the layer it was asked for from
        /// one that returned either -- which is the whole property a multi-layer
        /// fixture exists to make observable.
        case indistinguishableLayers(String)
        /// A manifest with no layers unpacks to nothing, so every per-layer
        /// assertion over it holds by vacuity.
        case noLayers
    }

    /// Builds a layout at `directory` holding one image under `reference`.
    ///
    /// `payload` is the layer's content, and the whole layout is a function of
    /// it: two layouts differing only in `payload` get different layer digests
    /// and so different manifest and image digests, and two written from the
    /// same `payload` are byte-identical. Both halves are load-bearing -- the
    /// first is how a test spells "the vminit changed", the second is what makes
    /// the first mean anything.
    ///
    /// **This one-layer shape is frozen, which is why it is a wrapper rather
    /// than the implementation.** 12 call sites across 8 test files reach it
    /// (`grep -rn "OCILayoutFixture.write" Tests/`, 12 hits in 8 files at
    /// `ea9bcbc`), and `OCILayoutFixtureTests` pins the exact `index.json`
    /// digest it produces for `payload: "one"`. It delegates below with the
    /// entry path `payload`, which is the value that keeps those bytes what they
    /// were: the pin is the check on that, and it is not a claim made here.
    @discardableResult
    static func write(at directory: URL, reference: String, payload: String) throws -> URL {
        try write(
            at: directory,
            reference: reference,
            layers: [Layer(path: "payload", content: payload)]
        )
    }

    /// Builds a layout at `directory` holding one image of `layers` under
    /// `reference`, bottom layer first -- the order a manifest lists them in and
    /// the order an overlay stacks them in.
    ///
    /// **The suite was one-layer everywhere until this existed, so a whole class
    /// of defect could not be seen from a test at all**: which layer a cache slot
    /// holds, whether a cache consulted per layer answers per layer, and whether
    /// the layers come back in the order the image lists them are all questions
    /// that need at least two layers to be different questions from "did the
    /// unpack succeed".
    ///
    /// The layers are refused rather than deduplicated when two of them are
    /// identical: see `Failure.indistinguishableLayers`.
    @discardableResult
    static func write(at directory: URL, reference: String, layers: [Layer]) throws -> URL {
        guard !layers.isEmpty else { throw Failure.noLayers }
        // The blob mode is part of the identity because it is part of the BYTES:
        // an honest and a dishonest layer over the same path and content hash
        // differently and so occupy different cache slots, and refusing them as
        // indistinguishable would refuse a layout that is not.
        let identities = layers.map { "\($0.path)=\($0.content)@\($0.blob)" }
        guard Set(identities).count == identities.count else {
            throw Failure.indistinguishableLayers(identities.joined(separator: ", "))
        }

        let blobs = directory.appendingPathComponent("blobs/sha256")
        try FileManager.default.createDirectory(at: blobs, withIntermediateDirectories: true)

        // Without `.sortedKeys` `JSONEncoder` emits the config's keys in a
        // different order on every encode, so the config blob, the manifest and
        // the image digest all differ between two writes of the SAME payload.
        // That made `EngineStartupTests.swift:288` -- "a different vminit must
        // load to a different digest" -- vacuous: it passed for two layouts
        // holding identical payloads, so it could not tell "the vminit changed"
        // from "the fixture was written twice".
        // `OCILayoutFixtureTests` is the guard, and it holds this two ways: by
        // sampling 32 writes, and by pinning the resulting `index.json` digest.
        // The pin is the half that does not depend on how the encoder happens to
        // order keys in the running process -- which two 500-write runs of the
        // deletion measured differently, 13 distinct layouts with one at 57%
        // against 8 in a strict period-8 rotation. See that file; no miss
        // probability is quoted from either run.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let layerBlobs = try layers.map {
            try writeBlob(
                try layerBlob(for: $0),
                mediaType: MediaTypes.imageLayer,
                into: blobs
            )
        }

        // architecture and os are read back by the loader, which refuses an
        // image that names no platform or more than one.
        //
        // The diffIDs are the blob digests in the same order, which is exact
        // rather than a shortcut: the layers are uncompressed, and an
        // uncompressed layer's blob digest IS its diffID.
        let config = ContainerizationOCI.Image(
            architecture: "arm64",
            os: "linux",
            config: ImageConfig(),
            rootfs: Rootfs(type: "layers", diffIDs: layerBlobs.map(\.digest))
        )
        let configBlob = try writeBlob(
            try encoder.encode(config), mediaType: MediaTypes.imageConfig, into: blobs
        )

        let manifest = Manifest(config: configBlob, layers: layerBlobs)
        var manifestBlob = try writeBlob(
            try encoder.encode(manifest), mediaType: MediaTypes.imageManifest, into: blobs
        )
        // The annotation, not the blob, is what names the image: the reference
        // is carried by the index, exactly as the exported vminit layout does.
        manifestBlob.annotations = ["org.opencontainers.image.ref.name": reference]

        try encoder.encode(Index(manifests: [manifestBlob]))
            .write(to: directory.appendingPathComponent("index.json"))
        try Data(#"{"imageLayoutVersion":"1.0.0"}"#.utf8)
            .write(to: directory.appendingPathComponent("oci-layout"))
        return directory
    }

    /// The bytes written under a layer's media type, honest or not.
    ///
    /// One place, so that `MediaTypes.imageLayer` below is written once for both
    /// modes: the whole point of the dishonest mode is that the DECLARATION is
    /// identical and only the bytes differ, and a fixture that spelled the media
    /// type twice could drift into declaring the two differently -- which would
    /// make the refusal under test a media-type mismatch rather than a blob one.
    private static func layerBlob(for layer: Layer) throws -> Data {
        switch layer.blob {
        case .archive:
            return try layerArchive(at: layer.path, containing: layer.content)
        case .bytesThatAreNotTheDeclaredArchive:
            return Data(layer.content.utf8)
        }
    }

    /// The layer blob: a real tar holding `payload` as the content of one file
    /// at `path`, rather than `payload`'s bytes laid down raw.
    ///
    /// **Raw bytes were enough for every test that only loads, and are not
    /// enough for one that unpacks -- and when this was written, NOT because they
    /// failed.** `ImportOperation` copies layer blobs by digest and never opens
    /// one, so nothing before then noticed the fixture's "layer" was not an
    /// archive. `EXT4.Formatter.unpack` does open it, and against the unpacker at
    /// submodule `3f68806` it accepted one silently: MEASURED there, reverting
    /// this line to `Data(payload.utf8)` under `MediaTypes.imageLayerGzip` logged
    /// `Layer cached … size_mb=2048` with no error and left an ext4 image
    /// enumerating as `["/", "/lost+found"]`. An empty filesystem, correctly
    /// labelled.
    ///
    /// That is why a real tar is required rather than merely tidier: a test
    /// asserting only on the label cannot tell that apart from a layer that
    /// holds its image, and a labelled empty layer is this milestone's own
    /// defect signature -- a rootfs built from none of its image, with `Start`
    /// succeeding. The test that revert turned red was
    /// `LayerCacheRoleTests.testUnpackingOverAStaleCacheEntryRelabelsItRatherThanReusingIt`,
    /// which asserted on `/payload`; it is history, deleted in `2d1f8db` with
    /// the per-layer cache, so the measurement above is a record of what was
    /// observed then and not a check a reader can re-run at HEAD.
    ///
    /// **No test at HEAD reads a file back out of the unpacked filesystem** --
    /// production's `verifyReadable` opens one only far enough to construct an
    /// `EXT4.EXT4Reader` (`ImageRootfsUnpacker.verifyReadable`) and never looks
    /// up a path. That makes the requirement to write a real tar rest on the
    /// refusal path
    /// below rather than on a content assertion. That is enough to keep it:
    /// the requirement is restated on its own terms below, under **That fix
    /// does not weaken the requirement to write a real tar**, against the
    /// unpacker this fixture actually runs against.
    ///
    /// **The unpacker defect that measurement exposed is CLOSED at submodule
    /// `6ede1d5`, so the paragraph above describes `3f68806` and not the code
    /// this fixture runs against.** `unpack` refuses a source that is not the
    /// archive its declared media type says it is, rather than turning it into a
    /// valid, correctly labelled, empty `layer.ext4`. MEASURED after that commit,
    /// the same revert -- `Data($0.content.utf8)` in place of `layerArchive`,
    /// under this fixture's `MediaTypes.imageLayer` -- fails the same test
    /// through production, the then-current `OverlayFSUnpacker` reporting `the source is
    /// not a paxRestricted archive with filter none: … reading the next archive
    /// header failed with code -30: Truncated tar archive`. (That type is deleted at the
    /// `a5803b6` pointer this repository now carries; `EXT4Unpacker` is the unpacker in its
    /// place, and it raises the same `UnpackError.sourceIsNotDeclaredArchive` from the same
    /// `EXT4.Formatter.unpack` call. An earlier version of this paragraph cited
    /// `OverlayFSUnpacker.swift:84` for the report. At `6ede1d5` that offset lands on the
    /// `let layerPaths = try await withThrowingTaskGroup(...)` binding that fans the layer
    /// walk out -- not on a throw site and nowhere near the refusal. It is dropped rather
    /// than replaced with a second number: naming the type is what survives the next edit.)
    ///
    /// **The quoted text is what `6ede1d5` reported and is no longer what a
    /// reader at HEAD sees**, because the refusal is now wrapped with the layer's
    /// identity where the caller knows it (`LayerUnpackFailure`): the same
    /// failure arrives as `layer 1 of 1, sha256:… (application/vnd.oci.image.layer.v1.tar),
    /// could not be unpacked into …` carrying the sentence above as its cause.
    /// The revert is also no longer the way to produce one --
    /// `Layer.Blob.bytesThatAreNotTheDeclaredArchive` is, and
    /// `ImageRootfsUnpackerTests.assertIsTheLayerRefusal` asserts on both
    /// halves of the message -- the `could not be unpacked into` wrapper and
    /// the `is not a paxRestricted archive with filter none` cause -- rather
    /// than quoting it here. (The per-layer test that used to hold that
    /// assertion,
    /// `LayerCacheRoleTests.testAnUnpackThatRefusesALayerLeavesNoCacheEntryForTheNextCreateToReuse`,
    /// was deleted in `2d1f8db`; the property survives at image granularity.)
    ///
    /// **That fix does not weaken the requirement to write a real tar.** A
    /// fixture handing the unpacker a blob it refuses tests the refusal, and
    /// every test that reaches this line is asking a question about a layer that
    /// unpacked.
    ///
    /// Uncompressed, with every entry field fixed, so the bytes are a function
    /// of `path` and `payload` alone. libarchive's gzip filter stamps the
    /// current time into its header. MEASURED against the entry exactly as built
    /// below, two writes a second apart: under `filter: .gzip` they hash to
    /// `8982bec5474d…` and `1bd8b529ffa4…`, under `filter: .none` both to
    /// `331693e76444…` -- which is reproducible from here, being the layer
    /// blob's own filename in a layout written by the one-layer wrapper with
    /// `payload: "the layer this test unpacks"`, whose `path` is `payload`.
    /// (Re-derived 2026-08-17 after `path` became a parameter, by listing
    /// `blobs/sha256` of such a layout: still `331693e76444…`.)
    ///
    /// **The stamp has one-second resolution**: two gzip writes inside the same
    /// second hash identically (measured, `282a67e774c6…` twice). So HAD this
    /// fixture ever written gzip, the flake would have been intermittent rather
    /// than constant -- a counterfactual, and stated as one. **It never did**:
    /// before `36e0fc7` the blob was `Data(payload.utf8)` under a gzip *media
    /// type* with no libarchive involved, and `ArchiveWriterConfiguration` first
    /// enters this file in `36e0fc7` already at `filter: .none` (`git log -S`
    /// over this path confirms both). The reason both nondeterminism sources
    /// went unnoticed is simpler and covers them together: **no test compared
    /// two same-payload layouts until `OCILayoutFixtureTests` existed.**
    ///
    /// **It was one of two nondeterminism sources and closing it alone was not
    /// enough** -- see the `.sortedKeys` note in `write(at:reference:payload:)`
    /// for the other, which left the layout nondeterministic until the same
    /// round that added `OCILayoutFixtureTests`.
    ///
    /// `MediaTypes.imageLayer` is then honest twice over: the unpacker reads the
    /// media type to pick its decompressor, and an uncompressed layer's digest
    /// really is the `diffID` that `Rootfs` below claims it is.
    ///
    /// `path` is relative, which is the shape a real OCI layer tar has;
    /// `/usr/bin/tar -tvf` prints `Removing leading '/' from member names` for
    /// an absolute one. It lands at `/<path>` in the unpacked filesystem either
    /// way -- `/payload` for the one-layer wrapper, and one path per layer for a
    /// multi-layer layout, where telling the slots apart is the point. The suite
    /// that asserted on those paths was `LayerCacheRoleTests`, deleted in
    /// `2d1f8db`. The relative shape stays regardless: it is the shape a real
    /// OCI layer tar has, which is a fact about this fixture's fidelity to the
    /// format rather than about any test that reads it.
    private static func layerArchive(at path: String, containing payload: String) throws -> Data {
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("arca-oci-layer-\(UUID().uuidString).tar")
        defer { try? FileManager.default.removeItem(at: scratch) }

        let content = Data(payload.utf8)
        let entry = WriteEntry()
        entry.path = path
        entry.fileType = .regular
        entry.permissions = 0o644
        entry.owner = 0
        entry.group = 0
        entry.size = Int64(content.count)
        entry.modificationDate = Date(timeIntervalSince1970: 0)

        let writer = try ArchiveWriter(
            configuration: ArchiveWriterConfiguration(format: .paxRestricted, filter: .none)
        )
        try writer.open(file: scratch)
        try writer.writeEntry(entry: entry, data: content)
        try writer.finishEncoding()
        return try Data(contentsOf: scratch)
    }

    /// Writes one blob under its own digest and describes it.
    ///
    /// The loader verifies every blob it copies against the digest the
    /// descriptor claims, so the descriptor is derived from the bytes rather
    /// than stated beside them.
    private static func writeBlob(
        _ data: Data, mediaType: String, into blobs: URL
    ) throws -> Descriptor {
        let hex = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        try data.write(to: blobs.appendingPathComponent(hex))
        return Descriptor(mediaType: mediaType, digest: "sha256:\(hex)", size: Int64(data.count))
    }
}
