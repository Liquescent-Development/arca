import GRPC
import SandboxEngineProto
import XCTest
@testable import ArcaEngine

final class InspectTests: XCTestCase {
    /// gascan reassembles the canonical reference and asserts it is one, which
    /// is what lets the daemon compare one observation against another by exact
    /// string (crates/gascan-arca/src/translate.rs:333-336). A tag, or a digest
    /// in another form, breaks reconciliation rather than looking untidy.
    func testImageDigestSplitsRepositoryFromBareLowercaseHex() {
        let digest = imageDigest(
            fromReference: "ghcr.io/liquescent-development/gascan/workspace@sha256:"
                + String(repeating: "a", count: 64)
        )
        XCTAssertEqual(digest?.repository, "ghcr.io/liquescent-development/gascan/workspace")
        XCTAssertEqual(digest?.sha256Hex, String(repeating: "a", count: 64))
    }

    func testImageDigestRefusesAnythingThatIsNotAnExactDigestReference() {
        XCTAssertNil(imageDigest(fromReference: "ubuntu:latest"))
        XCTAssertNil(imageDigest(fromReference: "ubuntu"))
        XCTAssertNil(imageDigest(fromReference: "ubuntu@sha256:abc"))
        XCTAssertNil(imageDigest(fromReference: "ubuntu@sha512:" + String(repeating: "a", count: 64)))
        XCTAssertNil(imageDigest(fromReference: "ubuntu@sha256:" + String(repeating: "A", count: 64)))
    }

    /// A paused or restarting sandbox is neither running nor stopped.
    /// UNSPECIFIED reaches the consumer as a hard UnknownActualState error
    /// naming the state (crates/gascan-arca/src/translate.rs:399-409) rather
    /// than a guess that could have a reconciler destroy live work.
    func testSandboxStateIsUnspecifiedForPausedAndRestarting() {
        XCTAssertEqual(sandboxState(fromStatus: "paused"), .unspecified)
        XCTAssertEqual(sandboxState(fromStatus: "restarting"), .unspecified)
    }

    /// Three arms, not two. "It is not there" and "I could not tell" demand
    /// opposite behaviour from a reconciler (engine.proto:354-357).
    ///
    /// Calls the context-free `inspect(request:)` overload rather than the
    /// protocol-conforming `inspect(request:context:)`: grpc-swift's
    /// `GRPCAsyncServerCallContext` has no public initialiser, so a test
    /// target cannot construct one. See SandboxEngineService.swift.
    func testAnAbsentSandboxIsAnAnswerRatherThanAnError() async throws {
        let response = await SandboxEngineService.forTesting().inspect(
            request: Arca_Engine_V1_InspectRequest.with { $0.sandboxID = "absent-a1b2c3d4e5f6" }
        )
        guard case .absent = response.outcome else {
            return XCTFail("an unknown sandbox must be Absent, not an error: \(String(describing: response.outcome))")
        }
    }
}
