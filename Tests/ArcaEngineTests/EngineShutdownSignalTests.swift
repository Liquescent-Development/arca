import Foundation
import XCTest

/// What a `SIGTERM` does to the built binary while it is still starting up.
///
/// **This drives the executable and not a function, because the defect was a
/// call site and an ordering.** `ShutdownSignalsTests` proves the mechanism;
/// nothing in it says the engine installs that mechanism, or installs it before
/// the work `ServeCommand.run()` does. MEASURED: against `db11cc0` -- the
/// commit before the fix -- 12 of 12 engines signalled inside their own startup
/// were killed by the signal, and 0 of 12 signalled once they were serving were.
///
/// The signal is sent when the engine's state database appears, which is the
/// first thing `run()` puts on disk after validating its inputs and roughly a
/// second before it binds a socket. Waiting for a file the ENGINE creates is
/// what makes "its own code is running, and it has claimed nothing yet" a fact
/// rather than a guess about timing -- a fixed delay would be a different test
/// on every machine, and `EngineNeverReachedTheMoment` is what stops a run that
/// died early from passing as one that survived.
///
/// **The instant deliberately is NOT the spawn.** MEASURED by timestamping the
/// engine's own `dyld` constructor against its parent's clock: 10-13ms elapse
/// between the spawn returning and the engine's first instruction, all of it
/// `dyld`. A signal there kills the process whatever this repository does, so a
/// test that sent one would be asserting something about the loader. Gas Can's
/// `startup.rs` reports that arm without asserting it, for the same reason.
final class EngineShutdownSignalTests: XCTestCase {
    /// The engine must never be killed by a signal it exists to handle.
    ///
    /// Two assertions and they are not the same one. `wasKilledBySignal` is the
    /// defect itself: the kernel's default disposition running instead of the
    /// engine's code, which a shell reports as 143 and which nothing in
    /// `ArcaEngineCommand` can produce deliberately -- its only exits are
    /// `EXIT_SUCCESS` and `EXIT_FAILURE`. The line on stderr is the other half,
    /// because "not killed" is also true of an engine that ignored the signal
    /// and carried on: a bare `SIG_IGN` installed early satisfies the first
    /// assertion and fails this one, and it is the wrong fix precisely because
    /// an operator's `kill` would then appear to do nothing.
    ///
    /// **`exitedOnItsOwn` is deliberately NOT asserted, because here it is
    /// vacuous.** This target's binary is unsigned -- `swift test` relinks it
    /// and strips the entitlements -- and the layout it is handed holds no
    /// `arca-vminit`, so this startup was going to fail a few milliseconds later
    /// whatever the signal did. The process ends either way, so an assertion
    /// that it ended says nothing. Gas Can's `startup.rs` is where that half is
    /// real: it runs a signed engine with a real layout, one that would serve
    /// indefinitely, and counts "never exited" as its own unclean outcome.
    ///
    /// **The status is not asserted for the same reason.** Whichever of the
    /// signal and the doomed vminit load finishes first decides the byte;
    /// `startup.rs` asserts `exited 0` where the question is not confounded.
    func testASignalDuringStartupDoesNotKillTheEngine() throws {
        let root = try temporaryEngineRoot()
        let state = root.appendingPathComponent("state")
        let kernel = root.appendingPathComponent("vmlinux")
        try Data("not a kernel, and never read: nothing here boots a VM".utf8).write(to: kernel)
        let layout = try validVminitLayout(in: root)

        let database = state.appendingPathComponent("state.db")
        let run = try runEngine(
            arguments: [
                "--socket-path", root.appendingPathComponent("sock/e.sock").path,
                "--state-root", state.path,
                "--kernel-path", kernel.path,
                "--vminit-layout", layout.path,
            ],
            signallingOnce: { FileManager.default.fileExists(atPath: database.path) }
        )

        XCTAssertFalse(
            run.wasKilledBySignal,
            "a SIGTERM during startup must reach the engine's own code, not the default "
                + "disposition; status: \(run.status), stderr: \(run.errorText)"
        )
        XCTAssertTrue(
            run.errorText.contains("stopping on signal 15"),
            "the engine must ACT on a startup signal rather than ignore it, and its own line "
                + "saying so is the only evidence that separates the two here; stderr: "
                + "\(run.errorText)"
        )
    }
}
