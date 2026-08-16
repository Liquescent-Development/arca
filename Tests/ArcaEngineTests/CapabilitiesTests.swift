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

    /// **This asserts the one remaining negative as hard as the positives, and
    /// that is the point.** A capability that is true before its code exists is
    /// how a consumer is induced to send a request the engine cannot honour, so
    /// the `offline` assertion below is not a leftover from an emptier build: it
    /// is `.unverified` because nothing has proven isolation. See the note on
    /// `capabilities(request:)` for what earned each of the six that are true.
    ///
    /// `namedVolumes` was one of the falses until vminitd stopped identifying
    /// its OverlayFS block devices by counting `/dev/vd` letters -- which
    /// swallowed the volume devices -- and started reading a role out of each
    /// image's ext4 volume label. `tty` and `signals` were the last two, and
    /// they moved when milestone 3's `Exec` landed. **Neither moved on the
    /// strength of the code existing:** each names a live test in gascan's tier
    /// that fails against a one-line mutation of this engine, and both mutations
    /// were run. An assertion flipping here is a deliberate part of such a
    /// change; it failing on its own would mean a flag moved without one.
    ///
    /// **This test cannot corroborate any of them.** It reads the same literals
    /// the source holds; what makes those literals honest is gascan's live
    /// tier, named in that note, and nothing here. It is a lock against a flag
    /// moving unnoticed, not evidence that a flag is right.
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
        XCTAssertTrue(capabilities.projectMount)
        XCTAssertTrue(capabilities.namedVolumes)
        XCTAssertTrue(capabilities.tty)
        XCTAssertTrue(capabilities.signals)
        XCTAssertTrue(capabilities.loopbackPublish)
        XCTAssertTrue(capabilities.resourceLimits)
        XCTAssertEqual(capabilities.offline, .unverified)
        XCTAssertEqual(capabilities.contractMinor, 0)
        XCTAssertEqual(capabilities.engineVersion.minor, 2)
    }
}
