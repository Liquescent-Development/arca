import GRPC
import SandboxEngineProto
import XCTest
@testable import ArcaEngine

final class CapabilitiesTests: XCTestCase {
    func testVersionParsesTheLeadingSemverAndIgnoresAPrerelease() {
        let version = engineVersion(from: "0.2.4-alpha")
        XCTAssertEqual(version?.major, 0)
        XCTAssertEqual(version?.minor, 2)
        XCTAssertEqual(version?.patch, 4)
    }

    func testVersionRejectsAnythingItCannotReadRatherThanGuessing() {
        XCTAssertNil(engineVersion(from: ""))
        XCTAssertNil(engineVersion(from: "0.2"))
        XCTAssertNil(engineVersion(from: "v0.2.4"))
        XCTAssertNil(engineVersion(from: "0.2.x"))
    }

    /// This build implements no create and no exec, so it claims nothing. A
    /// capability that is true before its code exists is how a consumer is
    /// induced to send a request the engine cannot honour.
    ///
    /// Calls the context-free `capabilities(request:)` overload rather than
    /// the protocol-conforming `capabilities(request:context:)`: grpc-swift's
    /// `GRPCAsyncServerCallContext` has no public initialiser, so a test
    /// target cannot construct one. See SandboxEngineService.swift.
    func testThisBuildClaimsOnlyWhatItImplements() async throws {
        let response = await SandboxEngineService.forTesting()
            .capabilities(request: .init())

        guard case .capabilities(let capabilities) = response.outcome else {
            return XCTFail("Capabilities must answer with capabilities")
        }
        XCTAssertFalse(capabilities.projectMount)
        XCTAssertFalse(capabilities.namedVolumes)
        XCTAssertFalse(capabilities.tty)
        XCTAssertFalse(capabilities.signals)
        XCTAssertFalse(capabilities.loopbackPublish)
        XCTAssertFalse(capabilities.resourceLimits)
        XCTAssertEqual(capabilities.offline, .unverified)
        XCTAssertEqual(capabilities.contractMinor, 0)
        XCTAssertEqual(capabilities.engineVersion.minor, 2)
    }
}
