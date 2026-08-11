import XCTest
@testable import ArcaEngine

final class EngineErrorsTests: XCTestCase {
    /// The consumer accepts exactly these twelve and maps anything else to
    /// invalid_output, so the engine's vocabulary is not the engine's to widen.
    /// See gascan crates/gascan-arca/src/error.rs:20-55.
    func testCodeVocabularyIsExactlyTheTwelveTheConsumerAccepts() {
        XCTAssertEqual(
            Set(EngineErrorCode.allCases.map(\.rawValue)),
            [
                "command_io", "command_failed", "invalid_output", "helper_error",
                "unsupported_capability", "ownership_mismatch", "foreign_resource_refused",
                "invalid_resource_identity", "resource_conflict", "not_found",
                "invalid_state", "unknown_actual_state",
            ]
        )
    }

    /// gascan asserts the exact rendered string per code because a
    /// resource<->message transposition is invisible to a code check
    /// (crates/gascan-arca/src/error.rs:137-207). Placement is the assertion.
    func testResourceAndMessageLandInTheirOwnFields() {
        let error = engineError(.invalidState, resource: "code-a1b2c3d4e5f6", message: "not running")
        XCTAssertEqual(error.code, "invalid_state")
        XCTAssertEqual(error.resource, "code-a1b2c3d4e5f6")
        XCTAssertEqual(error.message, "not running")
    }

    func testCatchingConvertsAThrownErrorRatherThanLettingItEscape() async {
        struct Boom: Error {}
        let result = await engineErrorCatching(.commandIo, resource: "vol-a") {
            throw Boom()
        }
        guard case .failure(let error) = result else {
            return XCTFail("a thrown error must become an EngineError, not a success")
        }
        XCTAssertEqual(error.code, "command_io")
        XCTAssertEqual(error.resource, "vol-a")
        XCTAssertTrue(error.message.contains("Boom"), "must name the underlying error: \(error.message)")
    }

    func testCatchingPassesSuccessThrough() async {
        let result = await engineErrorCatching(.commandIo, resource: "") { 41 + 1 }
        guard case .success(let value) = result else {
            return XCTFail("a non-throwing body must succeed")
        }
        XCTAssertEqual(value, 42)
    }
}
