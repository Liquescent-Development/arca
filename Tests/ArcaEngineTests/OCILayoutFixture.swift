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
    /// absent bytes shows -- which is the finding `LayerCacheRoleTests` already
    /// records twice for the one-layer case, one level down each time.
    struct Layer {
        /// Relative, which is the shape a real OCI layer tar has; see
        /// `layerArchive(at:containing:)`.
        let path: String
        let content: String
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
        let identities = layers.map { "\($0.path)=\($0.content)" }
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
                try layerArchive(at: $0.path, containing: $0.content),
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

    /// The layer blob: a real tar holding `payload` as the content of one file
    /// at `path`, rather than `payload`'s bytes laid down raw.
    ///
    /// **Raw bytes were enough for every test that only loads, and are not
    /// enough for one that unpacks -- but NOT because they fail.** `ImportOperation`
    /// copies layer blobs by digest and never opens one, so nothing before now
    /// noticed the fixture's "layer" was not an archive. `EXT4.Formatter.unpack`
    /// does open it, and MEASURED, it accepts it silently: reverting this line to
    /// `Data(payload.utf8)` under `MediaTypes.imageLayerGzip` logs `Layer cached
    /// … size_mb=2048` with no error and leaves an ext4 image enumerating as
    /// `["/", "/lost+found"]`. An empty filesystem, correctly labelled.
    ///
    /// That is why a real tar is required rather than merely tidier: a test
    /// asserting only on the label cannot tell that apart from a layer that
    /// holds its image, and a labelled empty layer is this milestone's own
    /// defect signature -- a rootfs built from none of its image, with `Start`
    /// succeeding. `testUnpackingOverAStaleCacheEntryRelabelsItRatherThanReusingIt`
    /// asserts on `/payload`, and the revert above is what makes it fail.
    ///
    /// **A defect in the unpacker is visible from here and is NOT this
    /// fixture's to fix**: production turns a mis-typed or corrupt layer blob
    /// into a valid, correctly labelled, empty `layer.ext4` rather than refusing
    /// it. It is upstream, in the frozen submodule, and recorded for a follow-up.
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
    /// way, which is what `LayerCacheRoleTests` asserts on -- `/payload` for the
    /// one-layer wrapper, and one path per layer for a multi-layer layout, where
    /// telling the slots apart is the point.
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
