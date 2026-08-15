import GRPC
import SandboxEngineProto
import XCTest
@testable import ArcaEngine

final class SandboxEngineServiceTests: XCTestCase {
    /// The one unary method this build does not implement must still ANSWER.
    ///
    /// Returning a gRPC status instead would be a transport fault by the
    /// contract's reading (engine.proto:52-58), and the consumer would report an
    /// unreachable engine rather than an unsupported operation. The code and the
    /// RPC name are what a consumer reads, so they are what this asserts; an
    /// earlier version asserted only `XCTAssertNotNil(outcome)`, which is true
    /// whenever *any* arm is set and so would have passed had the method answered
    /// `ok`.
    ///
    /// Calls the context-free `createContainer(request:)` overload rather than
    /// the protocol-conforming one: grpc-swift's `GRPCAsyncServerCallContext` has
    /// no public initialiser, so a test target cannot construct one. See
    /// SandboxEngineService.swift.
    ///
    /// **`CreateContainer` is the last unary method on this list, and it is the
    /// one worth watching.** `Inspect` left it when Task 7 implemented it,
    /// `ListResources` when Task 8 did, `PrepareImage` when Task 10 did, `Create`
    /// when Task 11 did, and `Start`, `Stop` and `Remove` when Task 12 did. None
    /// is an omission: an implemented method belongs to the tests that assert
    /// what it reports (`InspectTests`, `ListResourcesTests`,
    /// `PrepareImageTests`, `CreateTests`, `LifecycleTests`), and leaving it here
    /// would have this test fail for the correct behaviour. `CreateContainer`
    /// shares `CreateRequest` with `Create` and is a create in every respect
    /// except that its resources already exist, so it is the method most likely
    /// to be quietly satisfied by a change aimed at its neighbour. It is not
    /// implemented, and this is what says so.
    ///
    /// `Exec` and `Logs` are the other two unimplemented methods and are not
    /// here: both send their error inside a stream frame, and
    /// `GRPCAsyncResponseStreamWriter` has no initialiser a test target can
    /// reach. gascan's live tier drives both against a real engine over a real
    /// socket.
    func testCreateContainerAnswersUnsupportedCapabilityNamingTheRpc() async throws {
        let service = SandboxEngineService.forTesting()
        let outcome = await service.createContainer(
            request: Arca_Engine_V1_CreateContainerRequest()
        ).outcome

        guard case .failed(let failed) = outcome else {
            return XCTFail("an unimplemented method must answer with an error outcome, got "
                + String(describing: outcome))
        }
        XCTAssertEqual(failed.error.code, "unsupported_capability")
        XCTAssertTrue(
            failed.error.message.contains("CreateContainer"),
            "must name the RPC: \(failed.error.message)"
        )
    }
}
