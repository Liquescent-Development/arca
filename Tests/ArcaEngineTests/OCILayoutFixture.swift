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
    /// Builds a layout at `directory` holding one image under `reference`.
    ///
    /// `payload` is the layer's content. Two layouts differing only in it get
    /// different layer digests, and so different manifest and image digests --
    /// which is how a test spells "the vminit changed".
    @discardableResult
    static func write(at directory: URL, reference: String, payload: String) throws -> URL {
        let blobs = directory.appendingPathComponent("blobs/sha256")
        try FileManager.default.createDirectory(at: blobs, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        let layer = try writeBlob(
            try layerArchive(containing: payload), mediaType: MediaTypes.imageLayer, into: blobs
        )

        // architecture and os are read back by the loader, which refuses an
        // image that names no platform or more than one.
        let config = ContainerizationOCI.Image(
            architecture: "arm64",
            os: "linux",
            config: ImageConfig(),
            rootfs: Rootfs(type: "layers", diffIDs: [layer.digest])
        )
        let configBlob = try writeBlob(
            try encoder.encode(config), mediaType: MediaTypes.imageConfig, into: blobs
        )

        let manifest = Manifest(config: configBlob, layers: [layer])
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

    /// The layer blob: a real tar holding `payload` as one file's content,
    /// rather than `payload`'s bytes laid down raw.
    ///
    /// **Raw bytes were enough for every test that only loads, and are not
    /// enough for one that unpacks.** `ImportOperation` copies layer blobs by
    /// digest and never opens one, so nothing before now noticed that the
    /// fixture's "layer" was not an archive; `OverlayFSUnpacker` hands the blob
    /// to `EXT4.Formatter.unpack`, which opens it, and a blob that is not an
    /// archive fails there for a reason that has nothing to do with what such a
    /// test asserts.
    ///
    /// Uncompressed, with every entry field fixed, so the bytes are a function
    /// of `payload` alone. libarchive's gzip filter stamps the current time into
    /// its header, which would make two layouts written from the same payload
    /// carry different digests -- and `MediaTypes.imageLayer` is then honest
    /// twice over: the unpacker reads the media type to pick its decompressor,
    /// and an uncompressed layer's digest really is the `diffID` that `Rootfs`
    /// below claims it is.
    private static func layerArchive(containing payload: String) throws -> Data {
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("arca-oci-layer-\(UUID().uuidString).tar")
        defer { try? FileManager.default.removeItem(at: scratch) }

        let content = Data(payload.utf8)
        let entry = WriteEntry()
        entry.path = "/payload"
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
