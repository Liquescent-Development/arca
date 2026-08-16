import ContainerBridge
import Containerization
import Foundation
import Logging
import SandboxEngineProto
import XCTest

@testable import ArcaEngine

/// The ways `runSession` can fail to tear an exec down: three staged against a
/// guest that does not answer, and two against a client that goes away.
///
/// **The last two are a different shape and the difference is the point.** The
/// first three reach the teardown through a protocol violation, which is an
/// ordinary return down an ordinary code path. The last two reach it through
/// **cancellation of the task running the handler**, which is what a real
/// client reset does, and which for three rounds of fixes nothing here drove --
/// so a teardown that was correct in every detail was never invoked at all.
///
/// **What these tests assert is that the RPC ends, and that is the whole
/// point.** A `runSession` that does not return is a `driveExec` that does not
/// return, which is an `outbound.finish()` that never runs -- so the caller's
/// drain never ends and the gRPC handler, the response stream and the exec
/// instance are held for the life of the engine, with graceful shutdown unable
/// to drain. None of that shows up as a failing assertion anywhere else; it
/// shows up as an engine that will not stop.
///
/// **They are reachable at all because of `ExecInstanceSource`.** Over the
/// concrete `ExecManager`, `startExec` returns the moment it finds no native
/// container and `execInfo.process` is nil forever, so the situation every
/// bound below exists for cannot be staged -- see the note on that protocol for
/// why no VM-free test can do better. `StallingExecManager` at the foot of this
/// file is the guest that hangs.
///
/// XCTest and not swift-testing, and in `ArcaEngineTests`, for the two reasons
/// recorded on `ExecSignalTests`: Gas Can's release gate runs SwiftPM with
/// `--disable-swift-testing` and filters on `^ArcaEngineTests\.`, so a `@Test`,
/// or a class in the other target, is a test nothing executes.
///
/// **These are wall-clock tests and they are written to be slow rather than
/// tight.** Each one that stages a guest which stops answering waits out a real
/// `guestTeardownBound`, so it costs somewhere around ten to twelve seconds;
/// the assertions leave wide margins because this machine runs at load average
/// 3-5 and a bound asserted to the second is a bound that flakes. What must not
/// be widened is the *lower* bound in those tests: it is what says the guest
/// really did hang.
final class ExecTeardownTests: XCTestCase {

    /// **Defect 1: the session returns even when the guest never does.**
    ///
    /// The staged guest is the worst one: `startExec` never records a process
    /// and never returns, so the readiness wait cannot rescue the kill, the kill
    /// cannot end the process, and the only thing that can end this session is
    /// the bound on the wait for it.
    ///
    /// MEASURED, with the wait restored to `8679113`'s shape -- `completes(
    /// execution, within:)`, racing `_ = try? await task.value` against a sleep
    /// -- and nothing else changed: `swift test --disable-swift-testing --filter
    /// ExecTeardownTests` -> `Executed 4 tests, with 1 failure`, this test alone,
    /// `failed (30.707 seconds)` on `XCTUnwrap failed: expected non-nil value of
    /// type "Duration" - runExec never returned within 30s`. The sleep arm wins
    /// the race and `cancelAll()` runs, but the arm parked in `task.value`
    /// cannot be cancelled out of and `withTaskGroup` drains every child before
    /// returning -- so the bound returns exactly when the thing it was bounding
    /// returns, which here is never. Against the fix the same test passes in
    /// 12.066 seconds: two seconds of readiness wait, then the ten-second bound.
    func testASessionOutlivesAGuestThatNeverAnswers() async throws {
        let guest = StallingExecManager(start: .blocksWithoutRecordingAProcess)
        let elapsed = await Self.exec(try await Self.service(over: guest), within: .seconds(30))

        let took = try XCTUnwrap(
            elapsed,
            "runExec never returned within 30s: with the wait on the guest inert, the RPC "
                + "handler, the response stream and the exec instance leak for the life of "
                + "the engine and shutdown can never drain"
        )
        // The lower bound is the half that says the instrument worked: a session
        // that came back in under a second came back because the guest answered,
        // which would make the upper bound meaningless.
        XCTAssertGreaterThan(
            took, .seconds(9),
            "the guest was supposed to hang and the session was supposed to wait out its "
                + "bound; returning this fast means it did not hang: \(took)"
        )
        XCTAssertLessThan(
            took, .seconds(25),
            "the session waits out three bounds at most and only one of them can be "
                + "reached here: \(took)"
        )
    }

    /// **Defect 2: the kill waits for the process it has to kill.**
    ///
    /// `createExec` records the exec with `process` nil
    /// (`ExecManager.swift:220`) and `startExec` fills it in only after a round
    /// trip to the guest agent (`:310-320`). Two `ExecStart` frames back to back
    /// are a protocol violation, so the session breaks its dispatch loop and
    /// force-kills while that round trip is still in flight -- and a kill sent
    /// then throws `execNotStarted`, which is the one error that means *the
    /// process had not started yet*, because nothing in `ExecManager` clears
    /// `process` once set.
    ///
    /// The assertion is on **which** kill the guest saw, not on the session's
    /// timing, and that is deliberate: a timing assertion would pass over a
    /// `forceKill` that waited and then still sent nothing.
    ///
    /// MEASURED, with `forceKill`'s body restored to `8679113`'s shape -- a bare
    /// `signalExec` with no readiness wait and one `catch` logging at `.info` --
    /// and the bound added by defect 3 left in place, so this measures defect 2
    /// alone: `swift test --disable-swift-testing --filter ExecTeardownTests` ->
    /// `Executed 4 tests, with 3 failures`, all three in this test and no other
    /// test moving. Verbatim, in order:
    ///
    ///     XCTAssertEqual failed: ("[ArcaEngineTests.StallingExecManager.Kill(
    ///     signal: 9, sawTheProcess: false)]") is not equal to ("[...Kill(
    ///     signal: 9, sawTheProcess: true)]")
    ///     XCTAssertFalse failed - the guest process outlived the stream that
    ///     started it, which is the whole of what this kill is for
    ///     XCTAssertLessThan failed: ("10.082170167000001 seconds") is not less
    ///     than ("5.0 seconds")
    ///
    /// The three are one fact seen three ways: the kill went out 300ms before
    /// the process existed, `signalExec` threw `execNotStarted`, the `catch`
    /// swallowed it as "it may already have exited", the guest was still running
    /// when the session gave up, and the session took the full ten-second bound
    /// to give up because nothing had killed anything. Against the fix all three
    /// pass and the test takes 0.316 seconds.
    func testTheKillWaitsForTheProcessItIsThereToKill() async throws {
        let guest = StallingExecManager(
            start: .recordsTheProcessThenBlocks(after: .milliseconds(300)))
        let elapsed = await Self.exec(try await Self.service(over: guest), within: .seconds(30))

        let kills = await guest.kills
        XCTAssertEqual(
            kills, [StallingExecManager.Kill(signal: 9, sawTheProcess: true)],
            "the SIGKILL that ends a refused stream must reach the process; one sent into "
                + "the window before the process is recorded throws execNotStarted, and the "
                + "guest then runs on owned by nothing"
        )
        let running = await guest.guestIsStillRunning
        XCTAssertFalse(
            running,
            "the guest process outlived the stream that started it, which is the whole of "
                + "what this kill is for"
        )
        // The consequence of the same defect at the other end: a kill that
        // landed ends the session at once, and a kill that went nowhere leaves
        // it waiting out the bound on a process nothing can now stop.
        let took = try XCTUnwrap(elapsed, "runExec never returned within 30s")
        XCTAssertLessThan(took, .seconds(5), "\(took)")
    }

    /// **Defect 3, first half: a kill that never comes back does not hold the
    /// session.**
    ///
    /// `signalExec` reaches `LinuxProcess.kill` and then `agent.signalProcess`,
    /// a ttrpc call to the guest over vsock with no timeout, and
    /// `await Task.detached { }.value` is not cancellation-aware -- so before
    /// this bound, `forceKill` was an unbounded wait sitting in front of the
    /// bounded one.
    ///
    /// The staged guest takes the signal and then stops answering, rather than
    /// ignoring it: that keeps the test to one bound instead of two, and it is
    /// the likelier shape besides -- an agent whose reply is lost, not one that
    /// did nothing.
    ///
    /// MEASURED, with `forceKill`'s `Self.detached(within:)` replaced by
    /// `8679113`'s `await Task.detached { }.value` and the readiness wait left
    /// in place, so this measures the bound alone: `swift test
    /// --disable-swift-testing --filter ExecTeardownTests` -> `Executed 4 tests,
    /// with 1 failure`, this test alone, `failed (31.587 seconds)` on `XCTUnwrap
    /// failed: expected non-nil value of type "Duration" - runExec never
    /// returned within 30s`. Against the fix it passes in 10.085 seconds.
    func testAKillThatNeverComesBackDoesNotHoldTheSession() async throws {
        let guest = StallingExecManager(
            start: .recordsTheProcessThenBlocks(after: .zero), killHangs: true)
        let elapsed = await Self.exec(try await Self.service(over: guest), within: .seconds(30))

        let took = try XCTUnwrap(
            elapsed,
            "runExec never returned within 30s: an unbounded wait on the guest agent in "
                + "front of the bounded one leaves the session exactly as stuck"
        )
        XCTAssertGreaterThan(
            took, .seconds(9),
            "the kill was supposed to hang and the session was supposed to wait out its "
                + "bound; returning this fast means it did not hang: \(took)"
        )
        XCTAssertLessThan(took, .seconds(25), "\(took)")
    }

    /// **Defect 3, second half: nor does a reap that never comes back.**
    ///
    /// `deleteExec` reaches `LinuxProcess.delete` and then
    /// `agent.deleteProcess`, the same kind of unbounded call, and on this path
    /// it is a real round trip: `startExec` never reached its own
    /// `process.delete()`, so the memoisation that makes the reap free on the
    /// success path has nothing stored. It runs against the same guest that has
    /// just been killed.
    ///
    /// MEASURED, with `reap`'s `Self.detached(within:)` replaced by `8679113`'s
    /// `await Task.detached { }.value`: `swift test --disable-swift-testing
    /// --filter ExecTeardownTests` -> `Executed 4 tests, with 1 failure`, this
    /// test alone, `failed (31.069 seconds)` on `XCTUnwrap failed: expected
    /// non-nil value of type "Duration" - runExec never returned within 30s`.
    /// Against the fix it passes in 10.079 seconds -- and note where that is
    /// spent: the kill and the exit wait both come back at once here, so the ten
    /// seconds are the reap's own bound and nothing else's.
    func testAReapThatNeverComesBackDoesNotHoldTheSession() async throws {
        let guest = StallingExecManager(
            start: .recordsTheProcessThenBlocks(after: .zero), reapHangs: true)
        let elapsed = await Self.exec(try await Self.service(over: guest), within: .seconds(30))

        let took = try XCTUnwrap(
            elapsed,
            "runExec never returned within 30s: the reap is the last unbounded wait, and "
                + "one is enough"
        )
        let reaps = await guest.reaps
        XCTAssertEqual(reaps, 1, "the exec instance must still be reaped, once")
        XCTAssertGreaterThan(
            took, .seconds(9),
            "the reap was supposed to hang and the session was supposed to wait out its "
                + "bound; returning this fast means it did not hang: \(took)"
        )
        XCTAssertLessThan(took, .seconds(25), "\(took)")
    }

    /// **Defect 4: a real client reset ran no teardown at all.**
    ///
    /// **The reset a client actually performs is two events, not one, and the
    /// order is what defeated every test before this one.** gascan drops the
    /// sender feeding its request stream first
    /// (`gascan-arca/src/backend.rs:263-266`), which reaches the engine as an
    /// **orderly end of input** -- so `inbound.failure` is nil and the dispatch
    /// loop ends exactly as a half-close ends it. The RST_STREAM that makes
    /// grpc-swift cancel the handler task follows only once the transport's
    /// relay drops the tonic stream (`gascan-arca/src/channel.rs:193`), and by
    /// then the session has already committed to the ordinary path. The other
    /// three tests in this file end the inbound stream and never cancel, so all
    /// three take the violation path and none of them can see this.
    ///
    /// The staged guest is the ordinary one: it records its process and then
    /// runs, as `sh -c "sleep 3600"` does. Nothing here hangs -- the point is
    /// that a session with nothing wrong with it must still tear down when its
    /// client stops being there.
    ///
    /// MEASURED, with the wait before the teardown decision deleted so the
    /// ordinary path is `8679113`'s `await execution.value` again and the rest
    /// of this round left in place: `swift test --disable-swift-testing --filter
    /// ExecTeardownTests` -> `Executed 7 tests, with 13 failures`, five of them
    /// here -- `failed (40.031 seconds)`, which is this test's own two
    /// twenty-second bounds expiring -- and no test outside this round moving.
    /// Verbatim, in order:
    ///
    ///     XCTAssertTrue failed - a cancelled handler must still kill the guest
    ///     process; without it the process outlives the stream that started it
    ///     and nothing in the engine owns it
    ///     XCTAssertEqual failed: ("[]") is not equal to ("[ArcaEngineTests.
    ///     StallingExecManager.Kill(signal: 9, sawTheProcess: true)]")
    ///     XCTAssertEqual failed: ("0") is not equal to ("1") - the exec
    ///     instance must be reaped, once
    ///     XCTAssertFalse failed - the guest process outlived the stream that
    ///     started it
    ///     XCTAssertTrue failed - the RPC handler never returned, so the
    ///     session leaks
    ///
    /// That is the live defect in five lines: no kill was sent, no instance was
    /// reaped, the guest was still running, and the handler itself never came
    /// back -- the session was parked in `execution.value` and the cancellation
    /// landed on a wait that cannot be interrupted. Against the fix the test
    /// passes in 0.037 seconds.
    func testARealClientResetStillKillsAndReapsTheGuest() async throws {
        let guest = StallingExecManager(start: .recordsTheProcessThenBlocks(after: .zero))
        let service = try await Self.service(over: guest)

        let ran = await Self.reset(service, over: guest)

        let killed = await Self.holds(within: .seconds(20)) { await guest.kills.isEmpty == false }
        XCTAssertTrue(
            killed,
            "a cancelled handler must still kill the guest process; without it the process "
                + "outlives the stream that started it and nothing in the engine owns it"
        )
        let kills = await guest.kills
        XCTAssertEqual(kills, [StallingExecManager.Kill(signal: 9, sawTheProcess: true)])
        let reaps = await guest.reaps
        XCTAssertEqual(reaps, 1, "the exec instance must be reaped, once")
        let running = await guest.guestIsStillRunning
        XCTAssertFalse(running, "the guest process outlived the stream that started it")

        let ended = await Self.holds(within: .seconds(20)) {
            for await _ in ran {}
            return true
        }
        XCTAssertTrue(ended, "the RPC handler never returned, so the session leaks")
    }

    /// **The live instrument's own case: a reset that lands before the guest
    /// process has been recorded.**
    ///
    /// `exec::a_reset_before_the_process_starts_still_kills_the_guest` is
    /// written to hit the window between `createExec` recording the exec with
    /// `process` nil and `startExec` filling it in, and it cannot guarantee it
    /// hits it. This one can: the staged guest records its process 300ms after
    /// `startExec` is entered, and the reset lands within the poll interval of
    /// the dispatch loop ending.
    ///
    /// **What it pins that the test above does not is that the readiness wait
    /// inside `forceKill` still runs when the task that called it is
    /// cancelled.** That wait is only reachable because it sits inside a
    /// detached closure; written anywhere in the session's own task it would be
    /// skipped on exactly this path, and the kill would go out to an exec with
    /// no process, throw `execNotStarted`, and leave the guest to start a
    /// process nothing owns.
    ///
    /// MEASURED, under the same mutation as the test above -- the wait before
    /// the teardown decision deleted, nothing else changed: `swift test
    /// --disable-swift-testing --filter
    /// testAResetBeforeTheProcessStartsStillKillsTheGuest` -> `Executed 1 test,
    /// with 5 failures`, `failed (40.098 seconds)`, every assertion in the
    /// test. Verbatim, in order:
    ///
    ///     XCTAssertTrue failed - a cancelled handler must still kill the guest
    ///     process
    ///     XCTAssertEqual failed: ("[]") is not equal to ("[ArcaEngineTests.
    ///     StallingExecManager.Kill(signal: 9, sawTheProcess: true)]")
    ///     XCTAssertFalse failed - the guest process outlived the stream that
    ///     started it
    ///     XCTAssertEqual failed: ("0") is not equal to ("1") - the exec
    ///     instance must be reaped, once
    ///     XCTAssertTrue failed - the RPC handler never returned, so the
    ///     session leaks
    ///
    /// The forty seconds are the test's own two twenty-second bounds expiring,
    /// which is what it looks like from outside when a session never comes
    /// back. Against the fix it passes in 0.331 seconds.
    func testAResetBeforeTheProcessStartsStillKillsTheGuest() async throws {
        let guest = StallingExecManager(
            start: .recordsTheProcessThenBlocks(after: .milliseconds(300)))
        let service = try await Self.service(over: guest)

        let ran = await Self.reset(service, over: guest)

        let killed = await Self.holds(within: .seconds(20)) { await guest.kills.isEmpty == false }
        XCTAssertTrue(killed, "a cancelled handler must still kill the guest process")
        let kills = await guest.kills
        XCTAssertEqual(
            kills, [StallingExecManager.Kill(signal: 9, sawTheProcess: true)],
            "the kill must wait for the process it is there to kill even on the cancellation "
                + "path; one sent into the window before the process is recorded throws "
                + "execNotStarted and the guest then runs on owned by nothing"
        )
        let running = await guest.guestIsStillRunning
        XCTAssertFalse(running, "the guest process outlived the stream that started it")
        let reaps = await guest.reaps
        XCTAssertEqual(reaps, 1, "the exec instance must be reaped, once")

        let ended = await Self.holds(within: .seconds(20)) {
            for await _ in ran {}
            return true
        }
        XCTAssertTrue(ended, "the RPC handler never returned, so the session leaks")
    }

    /// **Defect 4, second half: the teardown a cancelled handler runs is still
    /// bounded, and the bounds are still real.**
    ///
    /// Every bound the previous round added is a race between
    /// `ExecCompletion.wait()` and a sleep, and **both arms return at once in a
    /// task that is already cancelled** -- the sleep by throwing, `wait()` by
    /// returning, which is the abandonment that type exists to offer. Run in
    /// the cancelled handler's own task, `finishes` would therefore answer
    /// `true` -- "the guest answered" -- without anything having answered, so
    /// `forceKill` would log nothing, the wait for the process would report an
    /// exit that never happened, and `deleteExec` would go out to a guest agent
    /// still holding an unacknowledged SIGKILL. Three bounds silently worth
    /// nothing on the one path they exist for.
    ///
    /// The staged guest takes the kill and then stops answering, which is
    /// `testAKillThatNeverComesBackDoesNotHoldTheSession`'s guest reached by
    /// cancellation instead of by a protocol violation. The assertion is that
    /// the session waits the bound out rather than returning at once, which is
    /// the difference between a bound and a bound-shaped expression.
    ///
    /// MEASURED, with `finishes` restored to running its race in the calling
    /// task and the rest of this round left in place, so this measures the
    /// detachment alone: `swift test --disable-swift-testing --filter
    /// ExecTeardownTests` -> `Executed 7 tests, with 1 failure`, this test
    /// alone, on `XCTAssertGreaterThan failed: ("0.0001375 seconds") is not
    /// greater than ("9.0 seconds")`. A seventh of a millisecond is the whole
    /// teardown -- kill, wait and reap -- reporting three successes it never
    /// waited for. Against the fix it passes in 10.071 seconds.
    func testACancelledHandlersTeardownStillWaitsOutItsBounds() async throws {
        let guest = StallingExecManager(
            start: .recordsTheProcessThenBlocks(after: .zero), killHangs: true)
        let service = try await Self.service(over: guest)

        let ran = await Self.reset(service, over: guest)
        let cancelled = ContinuousClock.now

        let ended = await Self.holds(within: .seconds(30)) {
            for await _ in ran {}
            return true
        }
        XCTAssertTrue(
            ended,
            "the teardown must be bounded even when it is not cancellable: an unbounded one "
                + "run detached is worse than the hang it replaced"
        )
        let took = ContinuousClock.now - cancelled
        XCTAssertGreaterThan(
            took, .seconds(9),
            "the kill was supposed to hang and the teardown was supposed to wait out its "
                + "bound; returning this fast means every bound on this path collapsed to "
                + "zero and reported success: \(took)"
        )
        XCTAssertLessThan(took, .seconds(25), "\(took)")
        let reaps = await guest.reaps
        XCTAssertEqual(reaps, 1, "the exec instance must still be reaped, once")
    }

    // MARK: - Fixtures

    /// Opens an exec, lets the guest process start, and then resets it the way
    /// a real client resets it. Returns a stream that finishes when the RPC
    /// handler returns.
    ///
    /// **The two events and their order are the fixture.** First the request
    /// stream ends cleanly, which is what gascan's dropped sender reaches the
    /// engine as and which the session must not confuse with a client that has
    /// gone away -- a half-close is an ordinary thing for a client that is still
    /// reading to do. Then the handler's task is cancelled, which is what
    /// `ServerHandlerComponents.cancel()` does when the peer's RST_STREAM
    /// arrives (grpc-swift's `GRPCAsyncServerHandler.swift`, `cancel(error:)`).
    ///
    /// **The wait between them is not a courtesy.** A cancellation delivered
    /// before the dispatch loop has ended is the case that already worked --
    /// `Task.isCancelled` is read after the loop -- so a fixture that raced the
    /// two would pass against the defect roughly half the time. `stdinHasEnded`
    /// is the session's own `stdin.close()`, the statement between the loop and
    /// the decision, observed from the guest side.
    private static func reset(
        _ service: SandboxEngineService,
        over guest: StallingExecManager
    ) async -> AsyncStream<Void> {
        let (client, frames) = AsyncStream.makeStream(of: Arca_Engine_V1_ExecClientFrame.self)
        frames.yield(ExecFixtures.start(sandboxID: ExecFixtures.sandboxID))

        let (ran, returned) = AsyncStream.makeStream(of: Void.self)
        let handler = Task {
            defer { returned.finish() }
            _ = try? await service.runExec(frames: client) { _ in }
        }

        frames.finish()
        let closed = await holds(within: .seconds(10)) { await guest.stdinHasEnded }
        XCTAssertTrue(
            closed,
            "the session never got past its dispatch loop, so what follows would not be "
                + "testing the teardown decision at all"
        )
        handler.cancel()
        return ran
    }

    /// Whether `condition` came to hold inside `bound`.
    ///
    /// Polled rather than signalled because what these tests wait on happens
    /// inside the session under test, which has no seam to signal through; the
    /// interval is what decides how tightly the cancellation lands after the
    /// dispatch loop ends, and 10ms is short against every bound here and long
    /// enough that the session's next few statements have run.
    private static func holds(
        within bound: Duration,
        _ condition: @escaping @Sendable () async -> Bool
    ) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                // The cancellation check is load-bearing: `condition` is an
                // actor read and `try?` swallows the sleep's `CancellationError`,
                // so a loop written without it spins at full tilt once the bound
                // arm has won -- and `withTaskGroup` drains every child, so the
                // bound would never be reported at all.
                while Task.isCancelled == false {
                    if await condition() { return true }
                    try? await Task.sleep(for: .milliseconds(10))
                }
                return false
            }
            group.addTask {
                try? await Task.sleep(for: bound)
                return false
            }
            let held = await group.next() ?? false
            group.cancelAll()
            return held
        }
    }

    /// The engine's own service over one seeded, labelled container, with the
    /// exec manager replaced by a guest that can be made to hang.
    private static func service(
        over guest: StallingExecManager
    ) async throws -> SandboxEngineService {
        let managers = try ExecFixtures.managers()
        try await ExecFixtures.seed(
            managers, labels: SandboxIdentity.labels(from: ExecFixtures.ownerLabels))
        return managers.makeService(execManager: guest)
    }

    /// Two `ExecStart` frames, which `engine.proto:408-411` allows exactly one
    /// of. The second is the protocol violation that breaks the dispatch loop
    /// and sends the session down its teardown path.
    private static var twoStarts: [Arca_Engine_V1_ExecClientFrame] {
        [
            ExecFixtures.start(sandboxID: ExecFixtures.sandboxID),
            ExecFixtures.start(sandboxID: ExecFixtures.sandboxID),
        ]
    }

    /// Runs `Exec` over the violating frames and reports how long it took to
    /// return, or nil if it outlasted `bound`.
    ///
    /// **The bound here is deliberately not written the way the defect under
    /// test was written.** A group child parked in `await task.value` cannot be
    /// cancelled out of, and `withTaskGroup` drains every child before it
    /// returns, so a bound built that way reports "in time" exactly when there
    /// is nothing to report -- it would make every test in this file pass
    /// against the code they exist to catch. This races an `AsyncStream` the
    /// runner finishes, and `AsyncStream` iteration is cancellation-aware.
    ///
    /// The runner is abandoned rather than cancelled on expiry, because a
    /// `runExec` that hangs is the finding, and cancelling it could unwind the
    /// hang and hide it.
    private static func exec(
        _ service: SandboxEngineService,
        within bound: Duration
    ) async -> Duration? {
        let (client, frames) = AsyncStream.makeStream(of: Arca_Engine_V1_ExecClientFrame.self)
        for frame in twoStarts {
            frames.yield(frame)
        }
        frames.finish()

        let (ran, returned) = AsyncStream.makeStream(of: Void.self)
        let started = ContinuousClock.now
        Task.detached {
            defer { returned.finish() }
            _ = try? await service.runExec(frames: client) { _ in }
        }

        return await withTaskGroup(of: Duration?.self) { group in
            group.addTask {
                for await _ in ran {}
                return ContinuousClock.now - started
            }
            group.addTask {
                try? await Task.sleep(for: bound)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}

/// An exec manager that can be made to behave the three ways a guest misbehaves,
/// which the concrete `ExecManager` cannot be made to behave at all.
///
/// Every stall below is a real await and never a blocked thread, so the session
/// under test runs exactly the concurrency it runs in production; what it does
/// not run is a virtual machine.
actor StallingExecManager: ExecInstanceSource {
    /// One signal as it arrived, and the one fact about it that decides whether
    /// it did anything.
    struct Kill: Equatable, Sendable {
        let signal: Int32
        /// Whether `startExec` had recorded the process by the time this
        /// arrived. False is the defect: `signalExec` throws `execNotStarted`,
        /// nothing is sent, and the guest goes on to start a process the session
        /// no longer has any way to reach.
        let sawTheProcess: Bool
    }

    /// What `startExec` does, which is the thing the session's longest bound is
    /// waiting on.
    enum Start: Sendable {
        /// Records the process after `after` and then blocks, as a started guest
        /// process that has not exited. A delivered SIGKILL ends it.
        case recordsTheProcessThenBlocks(after: Duration)
        /// Never records a process and never returns. The readiness wait cannot
        /// rescue a kill here and the kill cannot end the process, so only the
        /// bound on the wait can end the session.
        case blocksWithoutRecordingAProcess
    }

    /// The one exec this manager vends. Fixed rather than generated because a
    /// session creates exactly one and the tests never need to tell two apart.
    static let execID = String(repeating: "e", count: 64)

    private let start: Start
    private let killHangs: Bool
    private let reapHangs: Bool

    private var processRecorded = false
    private var startEntered = false
    private var startReturned = false
    private var stdinEnded = false
    private var recordedKills: [Kill] = []
    private var recordedReaps = 0
    private var recordedExitCode: Int?

    private let processRuns: AsyncStream<Void>
    private let endTheProcess: AsyncStream<Void>.Continuation

    init(start: Start, killHangs: Bool = false, reapHangs: Bool = false) {
        self.start = start
        self.killHangs = killHangs
        self.reapHangs = reapHangs
        let (runs, end) = AsyncStream.makeStream(of: Void.self)
        self.processRuns = runs
        self.endTheProcess = end
    }

    // MARK: - What the tests read

    var kills: [Kill] { recordedKills }
    var reaps: Int { recordedReaps }

    /// True while `startExec` has been entered and has not come back: a guest
    /// process still running.
    var guestIsStillRunning: Bool { startEntered && !startReturned }

    /// True once the session has closed the guest's stdin, which `runSession`
    /// does on the statement immediately after its dispatch loop ends
    /// (`ExecSession.swift:531`, between the loop and the teardown decision).
    ///
    /// It is the only point in the session a VM-free test can observe from
    /// outside, and the cancellation test needs one: a cancellation delivered
    /// before the dispatch loop has ended is a different case that already
    /// worked, so a test that raced the two would pass against the defect.
    var stdinHasEnded: Bool { stdinEnded }

    private func noteStdinEnded() { stdinEnded = true }

    // MARK: - ExecInstanceSource

    func createExec(
        containerID: String,
        cmd: [String],
        env: [String]?,
        workingDir: String?,
        user: String?,
        tty: Bool,
        attachStdin: Bool,
        attachStdout: Bool,
        attachStderr: Bool
    ) async throws -> String {
        Self.execID
    }

    func startExec(
        execID: String,
        detach: Bool,
        tty: Bool?,
        stdin: ReaderStream?,
        stdout: Writer?,
        stderr: Writer?
    ) async throws {
        startEntered = true
        // The real `startExec` hands stdin to `LinuxProcess.startStdinRelay`,
        // which reads the stream until it ends; this reads it for the one fact
        // a test needs, which is when it ended.
        if let stdin {
            let bytes = stdin.stream()
            Task { [weak self] in
                for await _ in bytes {}
                await self?.noteStdinEnded()
            }
        }
        if case .recordsTheProcessThenBlocks(let after) = start {
            if after > .zero {
                try? await Task.sleep(for: after)
            }
            processRecorded = true
        }
        // **Not cancellation-aware, and that is the faithful part.** Cancelling
        // the session's `execution` task does not kill a guest process; only a
        // signal that reaches the guest does. A stall that unwound on
        // cancellation would make `guestIsStillRunning` false for a reason
        // production never supplies, and the assertion that the guest did not
        // outlive its stream would pass over a kill that never landed.
        // `Task.value` is the one wait in the language that cancellation cannot
        // interrupt -- the same fact defect 1 turned on.
        let runs = processRuns
        await Task.detached { for await _ in runs {} }.value
        recordedExitCode = 137
        startReturned = true
    }

    func resizeExec(execID: String, height: Int?, width: Int?) async throws {}

    func signalExec(execID: String, signal: Int32) async throws {
        recordedKills.append(Kill(signal: signal, sawTheProcess: processRecorded))
        guard processRecorded else {
            throw ExecManagerError.execNotStarted(execID)
        }
        // The signal lands whether or not this call ever comes back: `killHangs`
        // models an agent whose reply is lost, not one that did nothing. Ending
        // the process before stalling is also what keeps the test that uses it
        // to one bound rather than two.
        endTheProcess.finish()
        if killHangs {
            await Self.stalls()
        }
    }

    func deleteExec(execID: String) async throws {
        recordedReaps += 1
        if reapHangs {
            await Self.stalls()
        }
    }

    func execProcessStarted(execID: String) async -> Bool { processRecorded }

    func execExitCode(execID: String) async -> Int? { recordedExitCode }

    /// An agent call that does not come back.
    ///
    /// An hour's sleep rather than a stream nothing ever finishes, and the
    /// difference is only that the sleep cannot outlive the test process.
    /// Nothing cancels these tasks -- the session abandons them, which is the
    /// behaviour under test -- so from the session's side an hour and forever
    /// are the same thing.
    private static func stalls() async {
        try? await Task.sleep(for: .seconds(3600))
    }
}
