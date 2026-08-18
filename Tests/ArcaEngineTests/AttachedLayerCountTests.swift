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

    /// That the count is a per-container property with no default, and nothing more.
    ///
    /// **Read what this asserts, not what its subject suggests.** Setting a `var` on two
    /// independent structs and reading it back is true of any `var` on any struct, and this
    /// would pass if nothing downstream ever read the property. What it does pin is the one
    /// part that is a decision rather than a language guarantee: the default is `nil` and not
    /// `0`, so a VM nobody reported a count for tells the guest "no report" and never "no
    /// layers". Those are different claims and only one of them describes an empty image.
    ///
    /// **What no test in either repository pins, and what happens when it breaks.** The value
    /// reaches the guest through three plain assignments after this one: `LinuxContainer.create`
    /// into `VMConfiguration`, and each VMM manager's `create` into its instance configuration.
    /// MEASURED: deleting `attachedOverlayLayers: self.config.attachedOverlayLayers` from
    /// `LinuxContainer.create` compiles and leaves all 247 tests here and all 613 in the
    /// submodule passing. What it would then do to a guest is not measured but follows from
    /// one branch: the guest receives no count, resolves `.unreported`, and refuses the boot --
    /// the same refusal path that WAS measured live for a mismatched count, whose only trace
    /// is a line in `bootlog.log`. The hop after that cannot be driven from a macOS test:
    /// `VZVirtualMachineInstance.toVZ` ends in `VZVirtualMachineConfiguration.validate()`,
    /// which needs the virtualization entitlement. Those hops are covered by the live tier and
    /// by nothing else.
    func testTheCountIsNilByDefaultAndSettablePerConfiguration() throws {
        // Not zero. A VM with no Arca overlay must reach the guest saying nothing at all.
        XCTAssertNil(LinuxContainer.Configuration().attachedOverlayLayers)

        var four = LinuxContainer.Configuration()
        var one = LinuxContainer.Configuration()
        four.attachedOverlayLayers = 4
        one.attachedOverlayLayers = 1

        XCTAssertEqual(four.attachedOverlayLayers, 4)
        XCTAssertEqual(one.attachedOverlayLayers, 1, "the count is per container, not per process")
    }
}
