import Containerization
import ContainerBridge
import Foundation
import XCTest

/// That the number of layer devices the guest is told about is the number the host attached.
///
/// **The guest cannot derive this number and that is the point.** Inside the guest, an image
/// with no layers and an image whose layers all failed classification produce the same thing: a
/// writable overlay device with nothing under it. `ArcaBoot` refused both, which killed every
/// legitimate zero-layer container (`FROM scratch`, an OCI artifact) to catch the broken one.
/// The count is the only thing that separates them, so what it is counting matters as much as
/// that it travels.
///
/// It counts **attachments, not intentions about attachments**. `OverlayFSMounter.buildMounts`
/// returns it alongside the mounts it built, incremented in the loop that appends each layer
/// device, rather than leaving the caller to read `lowerLayers.count`. A count taken from the
/// input list agrees with the output only while nothing between them skips a layer -- and a
/// skipped layer is exactly the defect the guest's comparison exists to notice.
///
/// **It is deliberately NOT derived from the role labels the host wrote.** A count that
/// re-read `ArcaBlockDeviceRole` off each image would miss an unlabelled layer in precisely the
/// same way the guest does, the two would agree at N-1, and the container would boot on a
/// rootfs built from a subset of its own image with nothing to say so. See
/// `LayerCacheRoleTests` for the defect that produces an unlabelled layer.
final class AttachedLayerCountTests: XCTestCase {
    private func overlayConfig(layers: Int) -> Containerization.OverlayFSConfig {
        let root = URL(fileURLWithPath: "/tmp/attached-layer-count-tests")
        return Containerization.OverlayFSConfig(
            lowerLayers: (0..<layers).map { root.appendingPathComponent("layer\($0).ext4") },
            upperDir: root.appendingPathComponent("upper"),
            workDir: root.appendingPathComponent("work")
        )
    }

    private func plan(layers: Int) -> OverlayFSMountPlan {
        OverlayFSMounter().buildMounts(
            containerID: "attached-layer-count",
            overlayConfig: overlayConfig(layers: layers),
            writablePath: "/tmp/attached-layer-count-tests/writable.ext4",
            additionalMounts: []
        )
    }

    /// How many block devices in the plan are layers, counted from the plan itself.
    ///
    /// The rootfs bind mount is not a block device and the writable one is the only block
    /// device without `ro`, so what remains is the layers. This is the assertion's own
    /// arithmetic and is not the arithmetic under test -- `buildMounts` counts by incrementing
    /// as it appends, which is why disagreeing with this is meaningful.
    private func layerDevices(in plan: OverlayFSMountPlan) -> [Containerization.Mount] {
        plan.mounts.filter { $0.type == "ext4" && $0.options.contains("ro") }
    }

    func testTheReportedCountIsTheNumberOfLayerDevicesAttached() throws {
        for layers in [1, 2, 5] {
            let built = plan(layers: layers)
            XCTAssertEqual(built.attachedLayerCount, layers, "\(layers) layers in, \(layers) reported")
            XCTAssertEqual(
                layerDevices(in: built).count,
                built.attachedLayerCount,
                "the reported count must be the number of layer devices in the same plan"
            )
        }
    }

    /// An image with no layers reports zero, and zero is a number the guest acts on: it is
    /// what tells the guest its rootfs is legitimately empty rather than broken.
    func testAnImageWithNoLayersReportsZeroAttached() throws {
        let built = plan(layers: 0)

        XCTAssertEqual(built.attachedLayerCount, 0)
        XCTAssertEqual(layerDevices(in: built).count, 0)
        // The writable is still attached -- that is why zero layers is ambiguous in the guest
        // at all, and why the count has to travel separately.
        XCTAssertTrue(
            built.mounts.contains { $0.type == "ext4" && !$0.options.contains("ro") },
            "the writable device is attached for a zero-layer image too"
        )
    }

    /// The count is per-container configuration, and the framework carries it as such.
    ///
    /// It reaches the guest as a kernel command line argument built at VM creation, so a
    /// value set on one container's configuration must not be a value every VM gets: two
    /// containers of different images run in different VMs and are told different numbers.
    func testTheCountIsCarriedPerContainerConfiguration() throws {
        var four = LinuxContainer.Configuration()
        var one = LinuxContainer.Configuration()
        four.attachedOverlayLayers = plan(layers: 4).attachedLayerCount
        one.attachedOverlayLayers = plan(layers: 1).attachedLayerCount

        XCTAssertEqual(four.attachedOverlayLayers, 4)
        XCTAssertEqual(one.attachedOverlayLayers, 1)
        // Nothing sets it by default: a VM with no Arca overlay reports no count at all,
        // which the guest distinguishes from a report of zero.
        XCTAssertNil(LinuxContainer.Configuration().attachedOverlayLayers)
    }
}
