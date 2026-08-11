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

    /// Every response type sets its oneof. An unset outcome is representable in
    /// proto3 and reaches the consumer as invalid_output
    /// (crates/gascan-arca/src/translate.rs:291-293).
    func testEveryUnimplementedResponseSetsItsOutcome() async throws {
        let service = SandboxEngineService.forTesting()
        let stopOutcome = await service.stop(request: .init()).outcome
        let removeOutcome = await service.remove(request: .init()).outcome
        let createOutcome = await service.create(request: .init()).outcome
        let createContainerOutcome = await service.createContainer(request: .init()).outcome
        let prepareImageOutcome = await service.prepareImage(request: .init()).outcome
        XCTAssertNotNil(stopOutcome)
        XCTAssertNotNil(removeOutcome)
        XCTAssertNotNil(createOutcome)
        XCTAssertNotNil(createContainerOutcome)
        XCTAssertNotNil(prepareImageOutcome)
    }
}
