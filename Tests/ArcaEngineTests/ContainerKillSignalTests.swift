import ContainerBridge
import Foundation
import Logging
import XCTest

/// `ContainerManager.parseSignal` refuses what it cannot map.
///
/// This is the **container kill** path -- `docker kill --signal X` ->
/// `handleKillContainer` -> `killContainer` -> `parseSignal` -- and not the exec
/// path that `ExecSignalTests` covers. They are separate suites because they are
/// separate translations: `signalExec` is handed an `Int32` that a client already
/// resolved, while this one is handed the raw string a user typed.
///
/// XCTest and not swift-testing, and in `ArcaEngineTests` rather than
/// `ArcaTests`, for the reasons recorded at length on `ExecSignalTests`: Gas
/// Can's release gate runs SwiftPM with `--disable-swift-testing` under the
/// filters `^ArcaEngineTests\.` and `^ArcaTests\.NetworkPruneGateTests/`, so a
/// `@Test` here, or a class under `ArcaTests`, is a test the gate never runs.
///
/// No VM and no daemon. `parseSignal` is `nonisolated package` so it can be
/// driven directly; going through `killContainer` instead would need a running
/// container and a resolved `LinuxContainer`, neither of which exists without a
/// booted sandbox, and a test that cannot run is worse than no test.
final class ContainerKillSignalTests: XCTestCase {
    private let logger = Logger(label: "arca-engine-tests")

    /// A manager over a throwaway state root. Nothing here boots a sandbox; the
    /// manager exists because `parseSignal` is a member of it.
    ///
    /// `StateStore` and `ImageManager` are `try`d rather than force-tried
    /// because a failure is a broken fixture, and the test should say so.
    private func makeManager() throws -> ContainerManager {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("arca-kill-signal-\(UUID().uuidString)")
        let imageStoreRoot = root.appendingPathComponent("images")
        return ContainerManager(
            imageManager: try ImageManager(logger: logger, imageStorePath: imageStoreRoot),
            kernelPath: root.appendingPathComponent("vmlinux").path,
            imageStoreRoot: imageStoreRoot,
            layerCachePath: root.appendingPathComponent("layers"),
            logRoot: root.appendingPathComponent("logs"),
            stateStore: try StateStore(
                path: root.appendingPathComponent("state.db").path,
                logger: logger
            ),
            logger: logger
        )
    }

    /// Refusal, and the identity of the refusal.
    ///
    /// `XCTAssertThrowsError` on its own passes on any error whatsoever,
    /// including one thrown by the fixture rather than by the code under test.
    /// The case and the associated value are what establish that the refusal came
    /// from `parseSignal` and that it names what the caller actually asked for --
    /// the original string, not the `SIG`-stripped one, since that is what the
    /// user typed and what the 400 will quote back.
    private func assertRefused(
        _ signal: String,
        by manager: ContainerManager,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try manager.parseSignal(signal), file: file, line: line) { error in
            guard case ContainerManagerError.invalidSignal(let refused) = error else {
                XCTFail("expected invalidSignal for \(signal), got \(error)", file: file, line: line)
                return
            }
            XCTAssertEqual(
                refused, signal,
                "the refusal must name the signal the caller asked for",
                file: file, line: line
            )
        }
    }

    func testAnUnrecognisedSignalNameIsRefusedRatherThanTreatedAsSIGKILL() throws {
        // The name is the point: a caller asking for something this engine does not
        // know must not have it silently promoted to the most destructive signal
        // in the table.
        let manager = try makeManager()
        assertRefused("BOGUS", by: manager)
        assertRefused("SIGBOGUS", by: manager)
    }

    /// The numbers are chosen rather than sampled, and 32 and 33 are the ones
    /// worth explaining: they are the gap between `SYS` and `RTMIN` in the Linux
    /// signal table, so they are what a check written as `1...64` would wrongly
    /// admit. `ExecSignalTests` refuses the same two on the exec path.
    func testASignalNumberOutsideTheValidRangeIsRefused() throws {
        let manager = try makeManager()
        assertRefused("999", by: manager)
        assertRefused("0", by: manager)
        assertRefused("-1", by: manager)
        assertRefused("32", by: manager)
        assertRefused("33", by: manager)
        assertRefused("65", by: manager)
    }

    /// The regression guard, and it is not padding: it is what stops the refusal
    /// being implemented by refusing everything, which is the obvious wrong fix
    /// for a defect whose failure mode is being too permissive.
    ///
    /// MEASURED against the unfixed code, with `parseSignal` still returning
    /// `9` for an unknown name and forwarding any `Int32` unchecked:
    /// `swift test --disable-swift-testing --filter ContainerKillSignalTests` ->
    /// `Executed 3 tests, with 5 failures`, all five in the two refusal tests
    /// above (`XCTAssertThrowsError failed: did not throw an error`), this one
    /// `passed`. Its value is that it passes on both sides of the fix.
    func testTheThirteenMappedNamesAndTheirNumbersStillResolve() throws {
        let manager = try makeManager()
        let expected: [String: Int32] = [
            "HUP": 1, "INT": 2, "QUIT": 3, "KILL": 9, "TERM": 15, "USR1": 10,
            "USR2": 12, "ALRM": 14, "CONT": 18, "STOP": 19, "TSTP": 20,
            "TTIN": 21, "TTOU": 22,
        ]
        for (name, number) in expected {
            XCTAssertEqual(try manager.parseSignal(name), number)
            XCTAssertEqual(try manager.parseSignal("SIG\(name)"), number)
            XCTAssertEqual(try manager.parseSignal(String(number)), number)
        }
    }

    /// A name outside the old thirteen resolves rather than being refused, and
    /// this is a deliberate consequence of the fix rather than an accident.
    ///
    /// The refusal is validated against `Containerization.Signal.linux` -- one
    /// table for names and numbers both. Keeping the hand-written thirteen
    /// instead would have left the engine self-contradictory: `--signal 6` would
    /// be accepted and `--signal ABRT` refused, for the same signal. These four
    /// span the shape of the widening: two ordinary names the old table missed,
    /// and both ends of the real-time range, which the guest accepts and a bound
    /// taken from the macOS host's `NSIG` would have rejected.
    ///
    /// Unlike the guard above, this test does NOT pass against the unfixed code:
    /// `ABRT` returned 9 there. It is the fix's own assertion, not a regression
    /// guard.
    func testNamesBeyondTheOldThirteenResolveThroughTheSameTable() throws {
        let manager = try makeManager()
        XCTAssertEqual(try manager.parseSignal("ABRT"), 6)
        XCTAssertEqual(try manager.parseSignal("SIGSEGV"), 11)
        XCTAssertEqual(try manager.parseSignal("RTMIN"), 34)
        XCTAssertEqual(try manager.parseSignal("SIGRTMAX"), 64)
    }
}
