import SandboxEngineProto
import XCTest
@testable import ArcaEngine

final class SandboxIdentityTests: XCTestCase {
    /// The container's name IS the sandbox id. gascan builds the expected
    /// identity as request.id.to_string() and validates created resources
    /// against it (crates/gascan-core/src/runtime.rs:829-832), so any other
    /// name fails every create client-side.
    func testContainerNameIsTheSandboxIdVerbatim() {
        XCTAssertEqual(
            SandboxIdentity.containerName(forSandboxId: "web-a1b2c3d4e5f6"),
            "web-a1b2c3d4e5f6"
        )
    }

    /// Labels are stored verbatim and never interpreted (engine.proto:144-148).
    /// Round-tripping is the whole contract.
    func testOwnerLabelsRoundTripUnchanged() {
        var owner = Arca_Engine_V1_OwnerLabels()
        owner.managedBy = "gascan"
        owner.sandboxID = "web-a1b2c3d4e5f6"

        let recovered = SandboxIdentity.owner(from: SandboxIdentity.labels(from: owner))

        XCTAssertEqual(recovered?.managedBy, "gascan")
        XCTAssertEqual(recovered?.sandboxID, "web-a1b2c3d4e5f6")
    }

    /// A resource the engine holds no labels for is how a consumer sees one it
    /// does not own (engine.proto:169-173). Absent, not empty: an OwnerLabels
    /// with two empty strings would claim managed_by "" and defeat gascan's
    /// ownership classifier.
    func testUnlabelledResourcesHaveNoOwnerRatherThanAnEmptyOne() {
        XCTAssertNil(SandboxIdentity.owner(from: [:]))
        XCTAssertNil(SandboxIdentity.owner(from: ["com.example.other": "x"]))
    }

    /// A half-labelled resource is not ours and must not be reported as though
    /// it were partially ours.
    func testAPartiallyLabelledResourceHasNoOwner() {
        XCTAssertNil(SandboxIdentity.owner(from: [SandboxIdentity.managedByLabelKey: "gascan"]))
        XCTAssertNil(SandboxIdentity.owner(from: [SandboxIdentity.sandboxIdLabelKey: "web-a1b2c3d4e5f6"]))
    }
}
