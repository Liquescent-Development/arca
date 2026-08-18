import ArcaEngine
import Dispatch
import Foundation
import XCTest

/// The window between changing a signal's disposition and being able to observe
/// it, measured on both mechanisms.
///
/// **This file exists because that window had been reasoned about and never
/// measured.** `arca-engine` used to set `SIGTERM` to `SIG_IGN` and then resume
/// a `DispatchSourceSignal`; between those two statements the process is no
/// longer killed by the signal and not yet watching for it, and the reasoning
/// said a signal arriving there is discarded outright -- which would leave an
/// engine that ignores `SIGTERM` forever, reported by a supervisor as a
/// *shutdown* defect rather than the startup one it is. Nothing had driven it.
///
/// It is driven here rather than against the engine because the window is
/// microseconds wide inside a startup that takes a second: a shotgun would need
/// millions of engines to land in it, while raising the signal in the gap on
/// purpose settles it in one run. `SIGUSR1` and `SIGUSR2` stand in for `SIGTERM`
/// for the obvious reason -- their default action is also to terminate, so the
/// `SIG_IGN` step is load-bearing exactly as it is in the engine, and neither is
/// used for anything else in this process.
final class ShutdownSignalsTests: XCTestCase {
    /// How long a delivery is waited for before it counts as lost.
    ///
    /// Two seconds against a delivery that takes microseconds when it happens at
    /// all. A bound this loose cannot turn a slow machine into a false "lost";
    /// what it costs is four seconds on the two arms that are genuinely lost,
    /// which is the price of the negative control.
    private let bound: TimeInterval = 2

    /// How long the signal is given to be delivered before the gap is closed.
    ///
    /// The raise is asynchronous with respect to this thread, so without a
    /// settle the source might be resumed before the signal has been processed
    /// at all -- and then the arm would measure nothing rather than measuring a
    /// loss. 50ms is four orders of magnitude more than a signal delivery needs.
    private let settle: useconds_t = 50_000

    /// The mechanism this replaced loses a signal raised before its source is
    /// watching.
    ///
    /// **A NEGATIVE CONTROL, and not a claim that libdispatch is broken.** A
    /// `DispatchSourceSignal` observes deliveries from the moment its kevent is
    /// registered and makes no promise about earlier ones. What this records is
    /// that a lost signal is detectable here at all -- which is what gives
    /// `testTheRelayLosesNothingRaisedBeforeItsActionOrBehindIt`'s positive
    /// result its meaning. If either assertion below ever goes green, what has
    /// been invalidated is this file's ability to tell a delivery from a loss,
    /// not the engine.
    ///
    /// Two arms and not one: they answer different questions -- whether the
    /// kevent is registered when the source is created or when it is resumed --
    /// and the answer decides how much of the gap is lossy. It is the second,
    /// so the gap is wider than "between the two statements": it swallows the
    /// source's own construction.
    ///
    /// **It deliberately does not touch `ShutdownSignals`.** Routing the relay
    /// resumes a read source that lives as long as the process, and a second
    /// test that had already done so would leave this one unable to reach the
    /// state it is about. One test owns the relay for that reason, and this is
    /// not it.
    func testTheMechanismItReplacedLosesASignalRaisedBeforeItsSourceIsWatching() {
        let queue = DispatchQueue(label: "shutdown-signals-tests")

        // Arm one: raised after the disposition changed and before the source
        // exists at all. This is the widest reading of the gap.
        signal(SIGUSR1, SIG_IGN)
        kill(getpid(), SIGUSR1)
        usleep(settle)
        let beforeCreation = DispatchSemaphore(value: 0)
        let created = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: queue)
        created.setEventHandler { beforeCreation.signal() }
        created.resume()
        let deliveredBeforeCreation = beforeCreation.wait(timeout: .now() + bound) == .success
        created.cancel()

        // Arm two: raised after the source exists and before it is resumed.
        signal(SIGUSR2, SIG_IGN)
        let beforeResume = DispatchSemaphore(value: 0)
        let unresumed = DispatchSource.makeSignalSource(signal: SIGUSR2, queue: queue)
        unresumed.setEventHandler { beforeResume.signal() }
        kill(getpid(), SIGUSR2)
        usleep(settle)
        unresumed.resume()
        let deliveredBeforeResume = beforeResume.wait(timeout: .now() + bound) == .success
        unresumed.cancel()

        XCTAssertFalse(
            deliveredBeforeCreation,
            "negative control: a signal raised before the source exists must be undetectable, "
                + "or this file cannot tell a delivery from a loss"
        )
        XCTAssertFalse(
            deliveredBeforeResume,
            "negative control: a signal raised before the source is resumed must be undetectable, "
                + "or this file cannot tell a delivery from a loss"
        )
    }

    /// The relay delivers a signal that arrived before its action existed, and
    /// both of a pair that piled up behind a busy one.
    ///
    /// **One test for two arms because one test has to own the relay.**
    /// `route(to:)` creates and resumes a read source that lives as long as the
    /// process, so "nothing has routed yet" is a state exactly one test can
    /// reach -- and the first arm is about precisely that state, because it is
    /// the shape `arca-engine` starts in: the `dyld` constructor captures, and
    /// `EngineEntryPoint.main` routes some milliseconds later. Splitting these
    /// into two tests made the second one's first arm silently measure the
    /// other's action instead of its own, which is how this arrangement was
    /// arrived at rather than chosen.
    ///
    /// Arm one is the positive half of
    /// `testTheMechanismItReplacedLosesASignalRaisedBeforeItsSourceIsWatching`:
    /// the same gap, on the mechanism that replaced it.
    ///
    /// **Arm two pins the escalation, which nothing else touched.** The second
    /// `SIGTERM` an operator sends is what forces a drain a peer would otherwise
    /// hold open; `ServeCommand`'s action tells the first from the rest by
    /// counting them, so a relay that collapsed two deliveries into one would
    /// leave "handles SIGTERM" true and "can be stopped" false. Everything else
    /// in this file, and `EngineShutdownSignalTests`, sends exactly one signal.
    ///
    /// **The pile-up is forced rather than waited for.** The action parks on
    /// `gate` the first time it is asked to, which holds the relay's serial
    /// queue inside `deliver()`; the two signals raised while it is parked can
    /// therefore only reach the pipe, and `deliver()`'s next `read` is
    /// guaranteed to return both at once. Raising three signals and hoping two
    /// land in one wake-up would be a different test on every run.
    ///
    /// **Two different numbers for the pair, deliberately.** Standard signals do
    /// not queue: a second `SIGUSR1` arriving while the first is still pending
    /// is merged with it by the kernel, and this has to measure the relay rather
    /// than that. `SIGUSR1` is repeated only across the gate, by which point the
    /// first has long since been handled -- and it is repeated because "the same
    /// signal twice" is exactly the operator's escalation.
    func testTheRelayLosesNothingRaisedBeforeItsActionOrBehindIt() throws {
        // Arm one: captured, raised, and only then routed.
        try ShutdownSignals.shared.capture([SIGUSR1, SIGUSR2])
        kill(getpid(), SIGUSR1)
        usleep(settle)
        let early = DispatchSemaphore(value: 0)
        ShutdownSignals.shared.route { number in
            if number == SIGUSR1 { early.signal() }
        }
        XCTAssertEqual(
            early.wait(timeout: .now() + bound), .success,
            "a signal captured before anything routed it must still be acted on once "
                + "something does; otherwise the engine ignores SIGTERM forever"
        )

        // Arm two: two more piled up behind an action that is busy with the
        // first.
        let recorder = Recorder()
        let parked = DispatchSemaphore(value: 0)
        let gate = DispatchSemaphore(value: 0)
        ShutdownSignals.shared.route { number in
            if recorder.record(number) {
                parked.signal()
                gate.wait()
            }
        }

        kill(getpid(), SIGUSR1)
        XCTAssertEqual(
            parked.wait(timeout: .now() + bound), .success,
            "the first signal never reached the relay, so nothing was ever parked"
        )

        // The relay's queue is inside the action now. These two can reach the
        // pipe and nowhere else until the gate opens.
        kill(getpid(), SIGUSR2)
        kill(getpid(), SIGUSR1)
        usleep(settle)
        gate.signal()

        let arrived = recorder.awaiting(3, upTo: bound)
        XCTAssertEqual(
            arrived.count, 3,
            "every signal that reached the pipe must reach the action; got \(arrived)"
        )
        XCTAssertEqual(
            arrived.filter { $0 == SIGUSR1 }.count, 2,
            "a repeat of the same signal is an operator escalating and must not be collapsed "
                + "into the first; got \(arrived)"
        )
        XCTAssertEqual(
            arrived.filter { $0 == SIGUSR2 }.count, 1,
            "the other signal must arrive exactly once; got \(arrived)"
        )
    }

    /// Capturing a signal leaves it unblocked, whatever mask the process
    /// inherited.
    ///
    /// **A signal mask is inherited across `exec` and a process does not choose
    /// the one it starts with.** An engine spawned with `SIGTERM` blocked would
    /// install a perfectly good handler and never hear a thing -- unkillable by
    /// the ordinary signal, which is the failure the whole facility exists to
    /// prevent.
    ///
    /// It is also the far end of the only arrangement that closes the window
    /// before the engine's first instruction: `dyld` spends 10-13ms mapping and
    /// binding the binary (MEASURED by timestamping the engine's own
    /// constructor against its parent's clock), and nothing in the process can
    /// act in that time -- but a launcher that blocks these signals before
    /// `exec` makes anything arriving there PENDING rather than fatal, and this
    /// unblock is what then delivers it.
    ///
    /// The mask is asserted rather than a delivery, and deliberately: raising a
    /// signal whose default action is to terminate, in the hope that the
    /// sequence is right, risks killing the whole test process and losing every
    /// other result with it. What this engine contributes is the unblock; the
    /// pending-becomes-delivered step after it is the kernel's.
    func testCaptureUnblocksASignalTheProcessInherited() throws {
        var blocked = sigset_t()
        sigemptyset(&blocked)
        sigaddset(&blocked, SIGUSR2)
        XCTAssertEqual(pthread_sigmask(SIG_BLOCK, &blocked, nil), 0, "the test could not block SIGUSR2")

        var beforeCapture = sigset_t()
        sigemptyset(&beforeCapture)
        XCTAssertEqual(pthread_sigmask(SIG_BLOCK, nil, &beforeCapture), 0)
        XCTAssertEqual(
            sigismember(&beforeCapture, SIGUSR2), 1,
            "the arrangement under test is a BLOCKED signal; if this is 0 the rest proves nothing"
        )

        try ShutdownSignals.shared.capture([SIGUSR2])

        var afterCapture = sigset_t()
        sigemptyset(&afterCapture)
        XCTAssertEqual(pthread_sigmask(SIG_BLOCK, nil, &afterCapture), 0)
        XCTAssertEqual(
            sigismember(&afterCapture, SIGUSR2), 0,
            "capturing a signal must leave it unblocked, or an engine spawned with it blocked "
                + "installs a handler that never runs"
        )
    }
}

/// What the relay handed the action, in order, across threads.
///
/// The relay runs its action on a queue of its own and the test asserts from
/// `XCTest`'s thread, so the list is touched from two. `@unchecked Sendable` for
/// the reason `ShutdownRequests` in `ArcaEngine` is: the lock is the discipline,
/// and there is nothing else to check.
private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var signals: [Int32] = []

    /// Records `number` and answers whether it was the first ever recorded.
    ///
    /// One critical section for the append and the question, so that the answer
    /// cannot describe a list that has already changed.
    func record(_ number: Int32) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        signals.append(number)
        return signals.count == 1
    }

    /// Everything recorded once `count` have arrived, or once `bound` runs out.
    ///
    /// Returns what it has either way rather than throwing, because the shape of
    /// a short list is the finding: a caller asserting `3` wants to see the two
    /// it got.
    func awaiting(_ count: Int, upTo bound: TimeInterval) -> [Int32] {
        let deadline = Date().addingTimeInterval(bound)
        while true {
            let recorded = lock.withLock { signals }
            if recorded.count >= count || Date() >= deadline { return recorded }
            Thread.sleep(forTimeInterval: 0.005)
        }
    }
}
