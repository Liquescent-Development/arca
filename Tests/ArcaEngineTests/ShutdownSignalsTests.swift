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

    /// The mechanism the engine used to use loses a signal raised in its gap;
    /// the one that replaced it does not.
    ///
    /// **One test and not three, because the three are one comparison** and
    /// because they must run in this order: the first two leave `SIGUSR1` and
    /// `SIGUSR2` set to `SIG_IGN`, and the third replaces one of those
    /// dispositions with the capture's own handler.
    ///
    /// **The first two assertions are a NEGATIVE CONTROL, not a claim that
    /// libdispatch is broken.** A `DispatchSourceSignal` observes deliveries
    /// from the moment its kevent is registered and makes no promise about
    /// earlier ones; the assertions record that this test can in fact detect a
    /// lost signal. If either goes green, what has been invalidated is this
    /// test's ability to tell delivery from loss -- and with it the meaning of
    /// the third assertion -- rather than the engine.
    func testTheReplacedMechanismLosesASignalRaisedBeforeItsSourceIsWatchingAndTheNewOneDoesNot() throws {
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
        // Separate from arm one because they answer different questions --
        // whether the kevent is registered at creation or at resume -- and the
        // answer decides how much of the gap is lossy.
        signal(SIGUSR2, SIG_IGN)
        let beforeResume = DispatchSemaphore(value: 0)
        let unresumed = DispatchSource.makeSignalSource(signal: SIGUSR2, queue: queue)
        unresumed.setEventHandler { beforeResume.signal() }
        kill(getpid(), SIGUSR2)
        usleep(settle)
        unresumed.resume()
        let deliveredBeforeResume = beforeResume.wait(timeout: .now() + bound) == .success
        unresumed.cancel()

        // Arm three: the same gap, on the mechanism that replaced it. The
        // capture is installed, the signal is raised, and only then is anything
        // routed -- which is precisely the shape `arca-engine` starts in, where
        // the constructor captures and `EngineEntryPoint.main` routes some
        // milliseconds later.
        try ShutdownSignals.shared.capture([SIGUSR1])
        kill(getpid(), SIGUSR1)
        usleep(settle)
        let relayed = DispatchSemaphore(value: 0)
        ShutdownSignals.shared.route { number in
            if number == SIGUSR1 { relayed.signal() }
        }
        let deliveredByTheRelay = relayed.wait(timeout: .now() + bound) == .success

        XCTAssertFalse(
            deliveredBeforeCreation,
            "negative control: a signal raised before the source exists must be undetectable, "
                + "or this test cannot tell a delivery from a loss"
        )
        XCTAssertFalse(
            deliveredBeforeResume,
            "negative control: a signal raised before the source is resumed must be undetectable, "
                + "or this test cannot tell a delivery from a loss"
        )
        XCTAssertTrue(
            deliveredByTheRelay,
            "a signal captured before anything routed it must still be acted on once "
                + "something does; otherwise the engine ignores SIGTERM forever"
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
