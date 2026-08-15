import Containerization
import ContainerizationEXT4
import Foundation
import SystemPackage
import XCTest

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
    /// The cache-hit branch tests `== .overlayLayer` rather than "has some role", and this is
    /// what makes that specific. A writable image in a layer's cache slot is a wrong rootfs,
    /// not a usable layer.
    func testTheWritableRoleIsNotMistakenForALayer() throws {
        let writable = try image(
            named: "writable.ext4",
            label: ArcaBlockDeviceRole.overlayWritable.volumeLabel
        )

        XCTAssertEqual(ArcaBlockDeviceRole.role(ofImageAt: writable), .overlayWritable)
        XCTAssertNotEqual(
            ArcaBlockDeviceRole.role(ofImageAt: writable),
            .overlayLayer,
            "the cache-hit check accepts only .overlayLayer, and this is why it must"
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
