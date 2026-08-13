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
    /// `payload` is the layer's bytes. Two layouts differing only in it get
    /// different layer digests, and so different manifest and image digests --
    /// which is how a test spells "the vminit changed".
    @discardableResult
    static func write(at directory: URL, reference: String, payload: String) throws -> URL {
        let blobs = directory.appendingPathComponent("blobs/sha256")
        try FileManager.default.createDirectory(at: blobs, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        let layer = try writeBlob(
            Data(payload.utf8), mediaType: MediaTypes.imageLayerGzip, into: blobs
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
