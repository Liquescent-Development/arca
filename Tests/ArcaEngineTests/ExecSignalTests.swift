import Containerization
import ContainerBridge
import Foundation
import Logging
import XCTest

/// `ExecManager.signalExec` refuses, out loud, every case it cannot carry out.
///
/// The one property these tests cannot establish is the one the feature is for:
/// that a signal reaches a process inside the guest. That needs a running VM and
/// belongs to the live tier, and nothing below should be read as coverage of it.
/// What is covered is every way `signalExec` can fail to send one -- an exec id
/// that names nothing, an exec whose process was never started, and a signal
/// number the guest has no meaning for -- because each of those is a way for a
/// signal to be dropped, and a dropped signal that the caller is not told about
/// is the defect this method was written to avoid.
///
/// XCTest and not swift-testing, for the reason recorded on
/// `NetworkPruneGateTests`: Gas Can's release gate runs SwiftPM with
/// `--disable-swift-testing`, so a `@Test` here is a test nothing executes.
///
/// **In `ArcaEngineTests` and not `ArcaTests`, and that placement is the
/// difference between this suite gating a release and merely existing.** Gas
/// Can's gate (`scripts/build-arca-engine.sh`) runs exactly two filters,
/// `^ArcaEngineTests\.` and `^ArcaTests\.NetworkPruneGateTests/`, so a new class
/// under `ArcaTests` is run by nobody but a developer typing `swift test`.
///
/// MEASURED at the time this suite was written, when it sat in `ArcaTests` and
/// `ArcaEngineTests` stood at 172: `swift test --disable-swift-testing` under
/// those two filters reported `Executed 175 tests` -- 172 + 3, and none of these
/// four. Moving the file here was the whole of the fix; on the current tree the
/// same command reports `Executed 180 tests`. The acceptance property below --
/// that a silently dropped signal cannot ship -- is only true in this target.
///
/// (`swift test list --filter` cannot be used to check that: it ignores the
/// filter and prints the full listing, which the gate script documents and which
/// reproduced here. The counts above come from real runs.)
///
/// No VM, no daemon, no state on disk: `ExecManager` reaches a `ContainerManager`
/// only through `ExecContainerSource`, and these tests supply their own.
final class ExecSignalTests: XCTestCase {
    private let containerID = String(repeating: "c", count: 64)

    private func makeExecManager() -> ExecManager {
        ExecManager(
            containerManager: RunningContainerSource(containerID: containerID),
            logger: Logger(label: "arca-exec-signal-tests")
        )
    }

    /// A created-but-never-started exec, plus the assertion that it really is in
    /// that state. Without the second half the tests below could pass on an exec
    /// that does not exist, which is a different refusal entirely.
    private func makeCreatedExec(
        in manager: ExecManager,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> String {
        let execID = try await manager.createExec(
            containerID: containerID,
            cmd: ["/bin/sh"],
            env: nil,
            workingDir: nil,
            user: nil,
            tty: false,
            attachStdin: false,
            attachStdout: true,
            attachStderr: true
        )
        let info = await manager.getExecInfo(execID: execID)
        XCTAssertNotNil(info, "createExec did not record the exec instance", file: file, line: line)
        XCTAssertNil(
            info?.process,
            "this fixture is only meaningful while the exec has no process",
            file: file,
            line: line
        )
        return execID
    }

    /// An exec id that names nothing is refused, matching `resizeExec`'s shape.
    ///
    /// MEASURED, with `throw ExecManagerError.execNotFound(execID)` in
    /// `signalExec` replaced by `return` -- the mutation that compiles, since the
    /// `guard let` itself cannot simply be deleted: `swift test --filter
    /// ExecSignalTests` -> `Executed 4 tests, with 1 failure`, this test alone,
    /// on `signalExec accepted an exec id that names nothing`, and `swift test
    /// --filter ArcaEngineTests` -> `Executed 177 tests, with 1 failure` against
    /// a baseline of 177 with 0.
    func testAnUnknownExecIDIsRefused() async throws {
        let manager = makeExecManager()
        let unknown = String(repeating: "f", count: 64)

        do {
            try await manager.signalExec(execID: unknown, signal: 15)
            XCTFail("signalExec accepted an exec id that names nothing")
        } catch let error as ExecManagerError {
            guard case .execNotFound(let id) = error else {
                XCTFail("expected execNotFound, got \(error)")
                return
            }
            XCTAssertEqual(id, unknown)
        }
    }

    /// The property this method exists for, and the one place it deliberately
    /// departs from `resizeExec`: a signal for an exec with no process is an
    /// error, not a silent success.
    ///
    /// The assertion is on the thrown case rather than merely on "it threw",
    /// because `execNotFound` would also be a throw and would mean the fixture,
    /// not the guard, was doing the work.
    ///
    /// MEASURED, with the guard rewritten into `resizeExec`'s exact shape --
    ///
    ///     guard let process = execInfo.process else {
    ///         logger.debug("Ignoring signal - exec process not started yet",
    ///                      metadata: ["exec_id": "\(execID)"])
    ///         return
    ///     }
    ///
    /// -- and nothing else changed: `swift test --filter ExecSignalTests` ->
    /// `Executed 4 tests, with 7 failures`, spread over two test cases -- this
    /// one on `signalExec silently accepted a signal for an exec that never
    /// started`, and `testSignalNumbersInsideTheMapPassValidation` six more
    /// times, once per number it sweeps, on `signalExec silently accepted signal
    /// N for an unstarted exec`. The other two stayed green, and `swift test
    /// --filter ArcaEngineTests` -> `Executed 177 tests, with 7 failures` against
    /// a baseline of 177 with 0 -- which is what makes this the acceptance test:
    /// the mutation is visible to the suite the release gate runs, so a
    /// `signalExec` that swallows a signal cannot ship green.
    func testASignalToAnExecThatNeverStartedIsRefusedRatherThanDropped() async throws {
        let manager = makeExecManager()
        let execID = try await makeCreatedExec(in: manager)

        do {
            try await manager.signalExec(execID: execID, signal: 15)
            XCTFail("signalExec silently accepted a signal for an exec that never started")
        } catch let error as ExecManagerError {
            guard case .execNotStarted(let id) = error else {
                XCTFail("expected execNotStarted, got \(error)")
                return
            }
            XCTAssertEqual(id, execID)
        }
    }

    /// A number Containerization's Linux signal map has no entry for is refused
    /// before anything is sent.
    ///
    /// The values are chosen rather than sampled: 0 is an existence probe and not
    /// a signal to deliver; 32 and 33 are the gap between `SYS` and `RTMIN` in
    /// `Signal.linux`, so they are the two numbers a range check written as
    /// `1...64` would wrongly admit; 65 is one past `RTMAX`; -1 and 999 are the
    /// obvious ends.
    ///
    /// MEASURED, with the validating call replaced by the non-failable
    /// initializer -- `let resolved = Signal(rawValue: signal)` -- which is the
    /// mistake the doc comment on `signalExec` warns about and which compiles
    /// cleanly: `swift test --filter ExecSignalTests` -> `Executed 4 tests, with
    /// 6 failures`, all in this test, one per number, each reading `expected
    /// SignalError.invalidSignal for N, got Exec instance has not been started:
    /// 055f98f2...`. That message is worth reading closely: with validation gone,
    /// every bad number falls through to the *next* guard, so the mutation does
    /// not surface as a delivered signal -- it surfaces as the wrong refusal, and
    /// only an assertion on which error was thrown catches it. The three other
    /// tests stayed green, and `swift test --filter ArcaEngineTests` -> `Executed
    /// 177 tests, with 6 failures` against a baseline of 177 with 0.
    func testSignalNumbersOutsideContainerizationsLinuxMapAreRefused() async throws {
        let manager = makeExecManager()
        let execID = try await makeCreatedExec(in: manager)

        for number: Int32 in [-1, 0, 32, 33, 65, 999] {
            do {
                try await manager.signalExec(execID: execID, signal: number)
                XCTFail(
                    "signalExec accepted signal \(number), which is not in "
                        + "Containerization's Linux signal map"
                )
            } catch let error as SignalError {
                guard case .invalidSignal = error else {
                    XCTFail("expected invalidSignal for \(number), got \(error)")
                    return
                }
            } catch {
                XCTFail("expected SignalError.invalidSignal for \(number), got \(error)")
            }
        }
    }

    /// The control for the test above. Without it, a `signalExec` that refused
    /// every number on earth would pass that one, and the feature would be
    /// broken in the opposite direction.
    ///
    /// Reaching `execNotStarted` is what proves validation let the number
    /// through: it is the guard immediately after the one under test, so the
    /// number cleared validation and nothing else stopped it. The values span the
    /// map's shape -- both ends of 1...31 and both ends of 34...64 -- rather than
    /// only the familiar TERM and KILL.
    func testSignalNumbersInsideTheMapPassValidation() async throws {
        let manager = makeExecManager()
        let execID = try await makeCreatedExec(in: manager)

        for number: Int32 in [1, 9, 15, 31, 34, 64] {
            do {
                try await manager.signalExec(execID: execID, signal: number)
                XCTFail("signalExec silently accepted signal \(number) for an unstarted exec")
            } catch let error as ExecManagerError {
                guard case .execNotStarted = error else {
                    XCTFail("expected execNotStarted for \(number), got \(error)")
                    return
                }
            } catch {
                XCTFail("signal \(number) was rejected by validation: \(error)")
            }
        }
    }
}

/// One container, running, and no native container behind it.
///
/// `getNativeContainer` answering `nil` is honest rather than convenient: a
/// `LinuxContainer` cannot be built without a VM, and no test in this file starts
/// an exec. `startExec` would refuse with `containerNotFound`, which is the
/// correct answer to "exec into a container this process cannot reach".
private struct RunningContainerSource: ExecContainerSource {
    let containerID: String

    func getContainerState(id: String) async -> String? {
        id == containerID ? "running" : nil
    }

    func getNativeContainer(id: String) async -> LinuxContainer? {
        nil
    }
}
