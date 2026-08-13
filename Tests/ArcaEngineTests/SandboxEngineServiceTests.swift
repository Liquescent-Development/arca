import GRPC
import SandboxEngineProto
import XCTest
@testable import ArcaEngine

final class SandboxEngineServiceTests: XCTestCase {
    /// An unimplemented method must still ANSWER. Returning a gRPC status
    /// instead would be a transport fault by the contract's reading, and the
    /// consumer would report an unreachable engine rather than an unsupported
    /// operation.
    ///
    /// Calls the context-free `start(request:)` overload rather than the
    /// protocol-conforming `start(request:context:)`: grpc-swift's
    /// `GRPCAsyncServerCallContext` has no public initialiser, so a test
    /// target cannot construct one. See SandboxEngineService.swift.
    func testUnimplementedMethodsAnswerWithUnsupportedCapabilityNamingTheRpc() async throws {
        let service = SandboxEngineService.forTesting()
        let response = await service.start(
            request: Arca_Engine_V1_StartRequest.with { $0.sandboxID = "web-a1b2c3d4e5f6" }
        )
        guard case .error(let error) = response.outcome else {
            return XCTFail("an unimplemented method must answer with an error outcome")
        }
        XCTAssertEqual(error.code, "unsupported_capability")
        XCTAssertTrue(error.message.contains("Start"), "must name the RPC: \(error.message)")
    }

    /// Every unimplemented response carries an `unsupported_capability` error
    /// naming its RPC.
    ///
    /// This replaces a version that asserted only `XCTAssertNotNil(outcome)`.
    /// An outcome is non-nil whenever *any* arm is set, so that test passed if
    /// every one of these methods had answered `ok` -- the precise inversion of
    /// what its name claimed. The code and the RPC name are what a consumer
    /// reads, so they are what this asserts.
    ///
    /// The four unary ones among them. `Exec` and `Logs` send their error
    /// inside a stream frame, and `GRPCAsyncResponseStreamWriter` has no
    /// initialiser a test target can reach; gascan's live tier drives both
    /// against a real engine over a real socket.
    ///
    /// `Inspect` left this table when Task 7 implemented it, `ListResources`
    /// when Task 8 did, `PrepareImage` when Task 10 did, and `Create` when Task
    /// 11 did. None is an omission: an implemented method belongs to the tests
    /// that assert what it reports (`InspectTests`, `ListResourcesTests`,
    /// `PrepareImageTests`, `CreateTests`), and leaving it here would have this
    /// test fail for the correct behaviour.
    ///
    /// `CreateContainer` stays, and it is the one worth watching. It shares
    /// `CreateRequest` with `Create` and is a create in every respect except
    /// that its resources already exist, so it is the method most likely to be
    /// quietly satisfied by a change aimed at its neighbour. It is not
    /// implemented, and this is what says so.
    func testEveryUnimplementedUnaryMethodAnswersUnsupportedCapability() async throws {
        let service = SandboxEngineService.forTesting()

        let answers: [(rpc: String, error: Arca_Engine_V1_EngineError?)] = [
            ("CreateContainer", engineError(await service.createContainer(request: .init()).outcome)),
            ("Start", engineError(await service.start(request: .init()).outcome)),
            ("Stop", engineError(await service.stop(request: .init()).outcome)),
            ("Remove", engineError(await service.remove(request: .init()).outcome)),
        ]

        XCTAssertEqual(
            answers.count, 4,
            "six of the eleven contract methods are unimplemented, and Exec and Logs "
                + "are the two that stream"
        )
        for (rpc, error) in answers {
            guard let error else {
                XCTFail("\(rpc) must answer with an error outcome, and did not")
                continue
            }
            XCTAssertEqual(error.code, "unsupported_capability", "\(rpc) answered \(error.code)")
            XCTAssertTrue(
                error.message.contains(rpc),
                "\(rpc)'s message must name the RPC: \(error.message)"
            )
        }
    }
}

// Reads the `EngineError` out of whichever arm a response type puts it in, so
// the table above can be one list rather than six near-copies. `nil` means
// the response did not answer with an error, which for an unimplemented method
// is itself the failure -- hence optional rather than a trap.

private func engineError(
    _ outcome: Arca_Engine_V1_AckResponse.OneOf_Outcome?
) -> Arca_Engine_V1_EngineError? {
    if case .error(let error) = outcome { return error }
    return nil
}

/// Create is the one shape that nests: its failure arm is a `CreateFailed`,
/// which carries the error alongside the resources a partial create made.
private func engineError(
    _ outcome: Arca_Engine_V1_CreateResponse.OneOf_Outcome?
) -> Arca_Engine_V1_EngineError? {
    if case .failed(let failed) = outcome { return failed.error }
    return nil
}
