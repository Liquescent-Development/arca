import GRPC
import SandboxEngineProto
import XCTest
@testable import ArcaEngine

final class ListResourcesTests: XCTestCase {
    /// On an empty engine this is an empty list, not an error. A reconciler
    /// reads "nothing exists" from this and must not see a failure instead.
    ///
    /// Calls the context-free `listResources(request:)` overload rather than
    /// the protocol-conforming `listResources(request:context:)`:
    /// grpc-swift's `GRPCAsyncServerCallContext` has no public initialiser,
    /// so a test target cannot construct one. See SandboxEngineService.swift.
    func testAnEmptyEngineListsNoResourcesRatherThanFailing() async throws {
        let response = await SandboxEngineService.forTesting()
            .listResources(request: .init())

        guard case .resources(let list) = response.outcome else {
            return XCTFail("ListResources must answer with a list: \(String(describing: response.outcome))")
        }
        XCTAssertTrue(list.resources.isEmpty)
    }

    /// Unlabelled resources are NOT filtered out. gascan's drift detection
    /// depends on seeing them, and hiding them engine-side would break it
    /// silently (engine.proto:389-391). Asserted here on the mapping helper,
    /// and again against a real engine in the live tier.
    func testAnUnlabelledResourceMapsToOneWithNoOwner() {
        let resource = resourceMessage(kind: .volume, name: "someone-elses-volume", labels: [:])
        XCTAssertEqual(resource.identity.name, "someone-elses-volume")
        XCTAssertEqual(resource.identity.kind, .volume)
        XCTAssertFalse(resource.hasOwner)
    }

    func testALabelledResourceCarriesItsOwnerBack() {
        let resource = resourceMessage(
            kind: .container,
            name: "web-a1b2c3d4e5f6",
            labels: [
                SandboxIdentity.managedByLabelKey: "gascan",
                SandboxIdentity.sandboxIdLabelKey: "web-a1b2c3d4e5f6",
            ]
        )
        XCTAssertTrue(resource.hasOwner)
        XCTAssertEqual(resource.owner.managedBy, "gascan")
        XCTAssertEqual(resource.owner.sandboxID, "web-a1b2c3d4e5f6")
    }

    /// ContainerBridge reports Docker-style names with a leading slash
    /// (Sources/ContainerBridge/ContainerManager.swift:725), but the consumer
    /// compares a container resource's name against the bare sandbox id
    /// (crates/gascan-core/src/runtime.rs:829-832). This is the highest-risk
    /// line in this task: an unstripped slash makes every owned container
    /// look unrelated to the sandbox that owns it.
    func testContainerResourceNameStripsTheLeadingSlash() {
        XCTAssertEqual(
            containerResourceName(names: ["/web-a1b2c3d4e5f6"], id: "abc"),
            "web-a1b2c3d4e5f6"
        )
    }

    func testContainerResourceNameLeavesAnAlreadyBareNameUnchanged() {
        XCTAssertEqual(
            containerResourceName(names: ["web-a1b2c3d4e5f6"], id: "abc"),
            "web-a1b2c3d4e5f6"
        )
    }

    func testContainerResourceNameFallsBackToTheIdWhenThereAreNoNames() {
        XCTAssertEqual(containerResourceName(names: [], id: "abc"), "abc")
    }

    func testContainerResourceNameFallsBackToTheIdWhenTheOnlyNameIsBareSlash() {
        XCTAssertEqual(containerResourceName(names: ["/"], id: "abc"), "abc")
    }

    func testContainerResourceNameStripsOnlyOneLeadingSlash() {
        XCTAssertEqual(containerResourceName(names: ["//x"], id: "abc"), "/x")
    }
}
