import ArcaEngine
import ArcaSignalCaptureAtLoad
import ArgumentParser
import ContainerBridge
import Foundation
import Logging
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix

/// The first instruction in this process that belongs to this project, and it
/// exists so that there is one.
///
/// **`@main` is here and not on `ArcaEngineCommand` because something has to run
/// before ArgumentParser does** -- and even this is not early enough on its own.
/// `SIGTERM`'s disposition is whatever `exec` left, which is the default, and it
/// holds until the process replaces it. MEASURED by spawning this binary and
/// signalling it after a delay, six engines per delay: with the capture at the
/// top of this function, every engine was still killed at 0, 1, 2 and 5ms, and
/// every engine survived from 20ms. What runs in those milliseconds is `dyld`,
/// so the capture itself is a `dyld` constructor -- `ArcaSignalCaptureAtLoad` --
/// and this function's first job is to check that it ran.
///
/// The action installed here is the engine-free one, because at this point there
/// is no engine: nothing is bound, nothing is claimed, and the only correct
/// response to being asked to stop is to stop. `ServeCommand.serve()` replaces
/// it the moment there is a server to drain, and restores it on the way out. A
/// signal delivered before this line is not lost -- the constructor's handler
/// has already queued it in the pipe, and it is acted on the instant the route
/// exists, which is the property that makes the two-step arrangement work at
/// all.
///
/// **Capturing is not optional and a failure here is not survivable.** A process
/// that could not take charge of `SIGTERM` is one whose response to `kill` is
/// undefined; starting anyway would hide that until an operator tried to stop
/// it, which is the worst possible moment to find out. The `capture` call below
/// is therefore not redundant with the constructor even though it installs the
/// same two signals: it is what turns the constructor's status into an exit, and
/// what reads the pipe back for the relay.
@main
enum EngineEntryPoint {
    static func main() async {
        let atLoad = arca_signal_capture_at_load_result()
        guard atLoad == 0 else {
            complain(
                atLoad < 0
                    ? "arca-engine did not capture its shutdown signals at load; "
                        + "ArcaSignalCaptureAtLoad was not linked in"
                    : "arca-engine could not capture its shutdown signals at load: "
                        + "\(String(cString: strerror(atLoad)))"
            )
            Foundation.exit(EXIT_FAILURE)
        }
        do {
            try ShutdownSignals.shared.capture([SIGTERM, SIGINT])
        } catch {
            complain("arca-engine cannot take charge of its shutdown signals: \(error)")
            Foundation.exit(EXIT_FAILURE)
        }
        ShutdownSignals.shared.route(to: stopWithNothingBound)
        await ArcaEngineCommand.main()
    }

    /// What a shutdown signal means when no server is bound: stop, now, and say
    /// so.
    ///
    /// **Zero, and it is a claim rather than a default.** The process was asked
    /// to stop and it stopped, having claimed nothing and left nothing behind --
    /// which is this process succeeding, the same reading `releaseAndExit` gives
    /// an operator's second signal. Gas Can's live tier reduces every shutdown
    /// to `ExitStatus::success`, so anything else here would report a clean stop
    /// as a failed one.
    ///
    /// It is the action for the tail of the run as well as the head. Once
    /// `serve()` has returned there is again nothing bound -- `runUntilQuiesced`
    /// releases the path -- and a signal arriving while the event-loop group
    /// shuts down means the same thing it meant during startup.
    ///
    /// stderr rather than the engine's `Logger`, deliberately: this runs before
    /// `--log-level` has been parsed, and at least once after the logger's
    /// subsystem is being torn down. The one line it writes is not log output,
    /// it is the process saying why it is gone.
    @Sendable
    static func stopWithNothingBound(on number: Int32) {
        complain("arca-engine stopping on signal \(number); nothing was bound")
        Foundation.exit(EXIT_SUCCESS)
    }

    private static func complain(_ line: String) {
        FileHandle.standardError.write(Data("\(line)\n".utf8))
    }
}

/// The entry point's command, and nothing else.
///
/// It carries no options of its own, and that is forced rather than tidy.
/// ArgumentParser parses every command in the chain, so a parent holding
/// REQUIRED options makes them required of its subcommands too: with
/// `--socket-path` and its three siblings declared here, `arca-engine image
/// load --state-root R --oci-layout L` exited with `Error: Missing expected
/// argument '--socket-path <socket-path>'` -- MEASURED against the built binary
/// before this split. An image load cannot be made to name a socket it will
/// never bind.
///
/// `serve` is the `defaultSubcommand`, so the invocation Gas Can already
/// ships -- `arca-engine --socket-path ... --state-root ... --kernel-path ...
/// --vminit-layout ...`, with no subcommand named -- still reaches
/// `ServeCommand.run()` unchanged. That is not assumed: every test in
/// `EngineCommandRefusalTests` spawns exactly that form.
///
/// `usage` and `discussion` are spelt out because the split cost them. A root
/// holding no options of its own generates `USAGE: arca-engine <subcommand>`
/// and an OPTIONS list holding nothing but `-h`, which is what `--help`
/// printed until this was written: the four options the engine cannot start
/// without were reachable only by knowing to type `arca-engine serve --help`
/// first. Milestone 4 writes a launchd plist against this binary, and whoever
/// writes it -- or debugs a start that failed -- reads `--help`.
/// `ImageLoadTests.testHelpDocumentsTheOptionsTheEngineCannotStartWithout` is
/// what stops this regressing a second time; it regressed silently the first
/// time because nothing in the suite read help output at all.
struct ArcaEngineCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "arca-engine",
        abstract: "Serves the arca.engine.v1 sandbox-engine contract over a Unix socket.",
        usage: """
            arca-engine --socket-path <socket-path> --state-root <state-root> \
            --kernel-path <kernel-path> --vminit-layout <vminit-layout> [--log-level <log-level>]
            arca-engine image load --state-root <state-root> --oci-layout <oci-layout>
            """,
        discussion: """
            Named with no subcommand -- the first form under USAGE -- arca-engine serves \
            the contract over the socket given. All four of those options are required and \
            none is defaulted, because a default is how a process silently ends up pointed \
            at another product's state; 'arca-engine serve --help' describes what each \
            takes. 'arca-engine image load --help' covers loading an image into this \
            engine's own store without serving anything.
            """,
        subcommands: [ServeCommand.self, ImageCommand.self],
        defaultSubcommand: ServeCommand.self
    )
}

/// Serves the contract until it is told to stop. The engine's whole reason for
/// existing, and now one subcommand among others only because a sibling needed
/// a parent that demanded nothing.
struct ServeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "serve",
        abstract: "Serves the arca.engine.v1 sandbox-engine contract over a Unix socket."
    )

    @Option(name: .customLong("socket-path"), help: "Path of the Unix socket to serve on.")
    var socketPath: String

    @Option(name: .customLong("state-root"), help: "Directory holding engine state.")
    var stateRoot: String

    // Read-only inputs, separate from --state-root and from each other. None of
    // the three is defaulted and none falls back to ~/.arca: a default is how a
    // process silently ends up pointed at another product's state.
    @Option(name: .customLong("kernel-path"), help: "Path of the Linux kernel image to boot sandboxes with.")
    var kernelPath: String

    @Option(name: .customLong("vminit-layout"), help: "Directory holding the arca-vminit OCI layout.")
    var vminitLayout: String

    @Option(name: .customLong("log-level"), help: "trace, debug, info, notice, warning, error.")
    var logLevel: String = "info"

    func run() async throws {
        let logger = engineLogger(logLevel: logLevel)

        // First, and before anything is created or constructed: a bad input
        // must cost a clear error naming which option and which path, not a
        // half-initialised engine that answers unsupported_capability for
        // everything that matters. This runs ahead of the socket directory too,
        // so a refusal leaves nothing behind on disk.
        let inputs = EngineInputs(
            stateRoot: URL(fileURLWithPath: stateRoot),
            kernelPath: URL(fileURLWithPath: kernelPath),
            vminitLayout: URL(fileURLWithPath: vminitLayout)
        )
        try validateEngineInputs(inputs)

        // The socket's mode is set to 0600 immediately after bind (EngineServer),
        // but bind returns an already-listening server, so there is a brief
        // window before that lands. The containing directory is the real
        // control for that window: nothing other than its owner can reach the
        // path to connect if the directory itself is 0700.
        try createSocketParentDirectory(for: socketPath)

        // Every manager below is rooted in the state root this engine owns, and
        // that ownership is the design: a state root shared with a live
        // ArcaDaemon is the hazard EngineInputs records, and an image store
        // shared with it is the one EnginePaths records.
        //
        // One factory, which the tests call too. Neither the paths nor which
        // path reaches which constructor argument is spelt out here a second
        // time: a hand-copy of these lines in TestSupport is what let the suite
        // stay green while the engine's real image-store root changed. See
        // EngineManagers.
        let managers = try EngineManagers(
            stateRoot: inputs.stateRoot,
            kernelPath: inputs.kernelPath,
            logLevel: logLevel,
            logger: logger
        )

        // Before any manager that resolves an init image. This is the second of
        // initialize()'s three preconditions, and the engine now satisfies it
        // itself rather than inheriting an image ArcaDaemon happened to load
        // into the shared store.
        _ = try await loadVminit(
            from: inputs.vminitLayout,
            into: managers.imageManager,
            stateRoot: inputs.stateRoot,
            logger: logger
        )

        // Order matters, and it is NOT ArcaDaemon's -- an earlier revision of
        // this comment claimed parity and there is none. The daemon runs
        // imageManager, containerManager, networkManager, volumeManager
        // (ArcaDaemon.swift:74, 208, 232, 258). This runs volume, container,
        // network, for three reasons of its own:
        //
        //   - the vminit image must be in the store before
        //     ContainerManager.initialize() resolves an initfs from it, which
        //     the loadVminit above has just done;
        //   - VolumeManager is first because it is the only one of the three
        //     that touches nothing but the filesystem and the StateStore. The
        //     cheap VM-free step ahead of the one that claims a host resource
        //     means a bad state root is refused before any vmnet network is
        //     created -- and it is the seam EngineCommandRefusalTests drives,
        //     since no test may reach the vmnet step;
        //   - NetworkManager is last of the three because it resolves
        //     containers through a ContainerManager.
        //
        // Running this at all is what a private state root bought. The restore
        // loop inside ContainerManager.initialize() marks every container the
        // StateStore records as `running` exited 137 and writes that back; over
        // a root shared with a live ArcaDaemon that write orphaned the daemon's
        // running VMs. Over this engine's own root the containers it rewrites
        // are the ones that died with the previous instance of this engine,
        // which is what crash recovery is for -- CrashRecoveryTests drives that
        // loop directly, which `restored=0` against a fresh root never could.
        //
        // A failure here propagates out of run() and the process exits
        // non-zero. Nothing below binds a socket, so a client never reaches an
        // engine that cannot act -- pinned by
        // EngineCommandRefusalTests.testAManagerThatCannotInitializeRefusesBeforeBindingTheSocket,
        // which drives this binary because these three calls are unreachable
        // from a unit test: ContainerManager.initialize() constructs a real
        // Containerization.VmnetNetwork.
        try await managers.volumeManager.initialize()
        try await managers.containerManager.initialize()
        try await managers.networkManager.initialize()

        // After all three, as ArcaDaemon does. Without this the engine holds a
        // ContainerManager that cannot create a container with anonymous
        // volumes, silently leaks them on Remove, reports a networked container
        // as attached to nothing, and publishes none of a sandbox's ports while
        // reporting the create as a success. See
        // EngineManagers.wireCollaborators, which also records why the last of
        // those four is the one no test in this repository can prove.
        await managers.wireCollaborators()

        let service = managers.makeService()

        let group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
        try await serve(service: service, group: group, logger: logger)
        try await group.shutdownGracefully()
        logger.info("engine stopped", metadata: ["socket": "\(socketPath)"])
    }

    /// Runs the engine until it closes, and holds every object that references
    /// an event loop.
    ///
    /// **This is a separate function so that those objects are released before
    /// `run()` shuts the group down. Inlining it reintroduces a crash.**
    /// MEASURED: with the server still live at group-shutdown time, the process
    /// printed `ERROR: Cannot schedule tasks on an EventLoop that has already
    /// shut down` on every run, and under `SWIFTNIO_STRICT=1` the same runs
    /// died with `SelectableEventLoop.swift:483: Fatal error` and exit 133 --
    /// NIO's own note says the error becomes a forced crash in a future
    /// version. It was not a race: a run that slept 1.5s after the group
    /// shutdown logged, survived the sleep, and then crashed on the way out of
    /// `run()`, which is where the server was being deallocated. Scoping it
    /// here so it is released first gives exit 0 with no diagnostic, verified
    /// under `SWIFTNIO_STRICT=1`.
    ///
    /// The order matters and the alternatives do not help: awaiting the
    /// teardown inside a `Task.detached`, dropping the redundant close, and
    /// swapping the async `shutdownGracefully()` for a blocking
    /// `syncShutdownGracefully()` on a Dispatch thread were each measured and
    /// each still crashed.
    ///
    /// **That fix was necessary and it was not sufficient, because it released
    /// the wrong objects.** Scoping the server here says nothing about the
    /// connections the server ACCEPTED, and those are what `quiesced` below is
    /// about.
    private func serve(
        service: SandboxEngineService,
        group: MultiThreadedEventLoopGroup,
        logger: Logger
    ) async throws {
        let engine = try await EngineServer.start(
            socketPath: socketPath,
            service: service,
            group: group
        )
        logger.info("engine listening", metadata: ["socket": "\(socketPath)"])

        // The hand-over. Signals have been captured since the entry point, and
        // until this line an engine-free action answered them; from here they
        // reach one that drains this server. The `defer` hands them back, which
        // also drops the last reference this closure holds to the engine --
        // the job cancelling the old `DispatchSourceSignal`s used to do.
        //
        // **There is no window at the swap, and that is the property being
        // relied on rather than a hope.** A signal arriving mid-swap is not
        // lost: `ShutdownSignals` has been holding the disposition since before
        // ArgumentParser ran, so the process cannot be killed by one, and the
        // byte it queues is delivered to whichever action the lock hands out.
        // The residual is narrower and benign -- a signal between
        // `EngineServer.start` returning and this line ends the process with
        // the socket file still on disk, which is exactly the state a `SIGKILL`
        // leaves and which `EngineServer.start` already reasons about.
        //
        // **This function no longer makes the drain promise, and that is the
        // point rather than a tidy-up.** It used to make one and hand the future
        // to `runUntilQuiesced`, which meant it could hand over `engine.onClose`
        // instead -- the pre-fix defect, one identifier away, and MEASURED green
        // across the entire suite at `723875a`. Starting the drain and waiting
        // for it are two halves of `EngineServer` now, and neither takes a
        // future from this file.
        let asked = ShutdownRequests()
        ShutdownSignals.shared.route(
            to: Self.shutdownAction(logger: logger, for: engine, asked: asked)
        )
        defer { ShutdownSignals.shared.route(to: EngineEntryPoint.stopWithNothingBound) }

        // **The only thing that completes the drain is the first signal, so a
        // listening socket that closes for any OTHER reason would leave this
        // function waiting on a promise nothing will ever fulfil.** That is a
        // regression this change introduced and it is worse than what it
        // replaced: awaiting `onClose` at least ended the process, whereas
        // waiting forever holds the `flock` on the lockfile, which is precisely
        // what makes `EngineServer.start` refuse the path to a successor. An
        // engine that cannot serve and cannot be replaced is the worst of the
        // three outcomes.
        //
        // The distinction is "did anything ask for this", not "did the listener
        // close" -- the graceful path closes the listener itself, by design,
        // and `asked` is recorded before that close is initiated, so a shutdown
        // that was asked for always finds this true.
        //
        // **Reachability is unmeasured.** Three things below close the listener
        // and none of them can reach this branch: the two signal handlers each
        // record `asked` first, and `runUntilQuiesced`'s own close runs only
        // after the drain has completed, which only the first signal starts. So
        // the case needs an unrecoverable failure in the server channel itself
        // -- `EngineServer.start` configures no idle timeout. Recorded as a
        // guard whose trigger nothing drives.
        engine.onClose.whenComplete { _ in
            guard !asked.anyRecorded else { return }
            logger.error(
                """
                the listening socket closed with no shutdown requested; the engine can no \
                longer serve and nothing will complete its drain
                """,
                metadata: ["socket": "\(socketPath)"]
            )
            Self.releaseAndExit(engine, logger: logger, status: EXIT_FAILURE)
        }

        try await engine.runUntilQuiesced()
    }

    /// How long a graceful shutdown waits for accepted connections to drain
    /// before stopping anyway.
    ///
    /// Ten seconds is chosen against the two clocks that already bound this
    /// process from outside, so that the engine is the one that decides: Gas
    /// Can's live tier gives a stopping engine 30s before it calls the
    /// supervisor stuck (`LiveEngine::stop`), and launchd's `ExitTimeOut`
    /// defaults to 20s before it escalates to SIGKILL. A drain that has not
    /// finished in ten has met something that will not finish, and being
    /// SIGKILLed instead would run none of the cleanup below.
    ///
    /// **Nothing measures this number**, and it is a policy rather than a
    /// finding: an ordinary drain here completes in milliseconds.
    private static let shutdownGrace = TimeAmount.seconds(10)

    /// Gives up the socket path and ends the process with `status`.
    ///
    /// Every caller is past the point where returning is possible, and each has
    /// to leave the path exactly as `shutDown()` would.
    ///
    /// **`status` is a parameter because the callers do not mean the same
    /// thing, and collapsing them onto `EXIT_SUCCESS` made a failure
    /// unobservable.** An operator's second signal ASKED for the remaining
    /// connections to be abandoned, so abandoning them is success. A drain that
    /// ran out of grace abandoned them because it could not finish, and so did
    /// a listener that closed underneath the engine; neither is.
    ///
    /// The consumer that matters reads exactly this byte: Gas Can's
    /// `shutdown.rs` counts `!status.success()`, so while every path exited 0
    /// its `0/96` could not distinguish 96 completed drains from 96 that gave
    /// up at ten seconds -- in the instrument that measured this fix. One byte
    /// carries that distinction, and it is cheaper and harder to lose than a
    /// second assertion somewhere else would be.
    private static func releaseAndExit(
        _ engine: EngineServer,
        logger: Logger,
        status: Int32
    ) -> Never {
        do {
            try engine.releaseSocketPath()
        } catch {
            // Reported rather than dropped: whoever starts the next engine on
            // this path has to reason about what is left there, and this is the
            // only moment anything knows.
            logger.error("could not release the socket path", metadata: ["error": "\(error)"])
        }
        // Qualified: bare `exit` inside a `ParsableCommand` resolves to
        // ArgumentParser's own `exit(withError:)` instance method, and the
        // compiler rejects it here rather than quietly calling something else.
        Foundation.exit(status)
    }

    /// Turns SIGTERM and SIGINT into a graceful close, and a repeat of either
    /// into an immediate one.
    ///
    /// Without this the process had no shutdown path at all: nothing closed the
    /// server, nothing shut the event-loop group down, and nothing unlinked the
    /// socket, so the only way it ended was by being killed -- which runs no
    /// cleanup and leaves behind exactly the ambiguous socket file that
    /// `EngineServer.start` then has to reason about.
    ///
    /// **This is an action and no longer an installation, and that is the fix
    /// for the startup race rather than a refactor.** It used to set each signal
    /// to `SIG_IGN` and resume a `DispatchSourceSignal` -- necessarily here,
    /// because its closures capture `engine`, and therefore necessarily after
    /// the bind. Two windows followed, and the second was never measured by
    /// anyone until this change:
    ///
    /// - From `exec` to that `SIG_IGN` the default disposition held, so a
    ///   SIGTERM anywhere in startup killed the engine with 143 (128 + 15) --
    ///   input validation, the vminit load and all three `initialize()` calls,
    ///   including the one that builds a real `VmnetNetwork`. A client could
    ///   only observe the tail of it, because the socket does not exist until
    ///   `EngineServer.start` binds. MEASURED by spawning this binary and
    ///   signalling it, the arms interleaved in one process against one binary.
    ///   Gas Can's `startup.rs` is that instrument, and its three arms report,
    ///   against `db11cc0` and then against this code: signalled at the spawn
    ///   instant, **12 of 12 killed and still 12 of 12**; signalled once the
    ///   engine has created its state database and before it binds, **12 of 12
    ///   killed, then 0 of 12**; signalled once serving, **0 of 12 both times**.
    ///   The first arm does not move because it signals into `dyld` -- 10-13ms
    ///   elapse before this binary's first instruction and no code inside a
    ///   process can act in them; `ArcaSignalCaptureAtLoad` records the
    ///   measurement and what would close it.
    /// - From that `SIG_IGN` to `source.resume()` the process was neither killed
    ///   nor observing, so a signal there was discarded outright. MEASURED for
    ///   the first time by `ShutdownSignalsTests`, in-process and
    ///   deterministically: **lost, both when raised before the source is
    ///   created and when raised after it is created and before it is resumed.**
    ///   The reasoning was right, and the consequence would have been an engine
    ///   that ignores SIGTERM forever -- which Gas Can's supervisor reports as
    ///   "the engine ignored `SIGTERM`", reading as a shutdown defect rather
    ///   than the startup one it is.
    ///
    /// Both are gone because capturing and acting are now separate: the
    /// disposition is taken in a `dyld` constructor, before ArgumentParser or
    /// the Swift runtime, and every delivery is queued in a pipe until
    /// something reads it.
    /// See `ShutdownSignals`. **A bare `SIG_IGN` installed early would have
    /// closed the first window and been worse than the defect** -- a startup
    /// SIGTERM would become a silent no-op, an operator's `kill` appearing to do
    /// nothing at all -- which is why the early action is
    /// `EngineEntryPoint.stopWithNothingBound` and not an absence.
    ///
    /// The defect reached Gas Can's live tier first, as **2 of 440** engines
    /// exiting 143 in
    /// `shutdown::the_engine_exits_cleanly_with_nothing_holding_a_connection`
    /// -- and in that workload only. It is `LiveEngine::start().await.stop()
    /// .await`, with nothing whatever between the connect that decides the
    /// engine is up and the pipe close that signals it; the other two open a
    /// gRPC channel or boot a VM first, which closes the window long before
    /// their signal lands. **Nothing in this file can produce 143 deliberately**
    /// -- its only exit calls are `Foundation.exit` with `EXIT_SUCCESS` or
    /// `EXIT_FAILURE`, in `releaseAndExit` and in
    /// `EngineEntryPoint.stopWithNothingBound` -- so a 143 in a tier log is
    /// always the kernel and never the engine. It is also NOT the pre-fix crash
    /// recorded on `EngineServer.runUntilQuiesced`, which was exit 133.
    ///
    /// **The window predates the wait moving into `ArcaEngine`, and that is a
    /// diff rather than a rate.** The region from `EngineServer.start` through
    /// the old `signal` call was byte-identical between `fa1d707` and
    /// `723875a`; that commit's whole executable delta is the two statements
    /// ending `serve()` and the method they now call, all of which run after
    /// this action is installed. No spike was run against `fa1d707` -- none is
    /// needed to say the code is unchanged, and none was run, so nothing here
    /// claims a rate for it.
    ///
    /// The escalation matters because a graceful shutdown waits for in-flight
    /// RPCs, and a client holding a stream open can hold the engine open with
    /// it. Without a second signal that forces the issue, "handles SIGTERM"
    /// would be true and "can be stopped" would not.
    ///
    /// **That paragraph was written before the code did any of it, and it is
    /// true for the first time now.** Until the engine started waiting on the
    /// drain -- `EngineServer.runUntilQuiesced`, which `serve()` calls with the
    /// future of the `quiesced` promise this function is handed -- one signal
    /// ended the process whatever a client was doing: the wait was on the
    /// LISTENING channel's close, which
    /// `ServerQuiescingHelper` performs synchronously, so nothing ever waited
    /// for an in-flight RPC and the second signal had nothing left to force.
    /// The wait is real now, so the escalation has to be.
    private static func shutdownAction(
        logger: Logger,
        for engine: EngineServer,
        asked: ShutdownRequests
    ) -> @Sendable (Int32) -> Void {
        // One action for both numbers, run on the relay's serial queue, so two
        // signals arriving together can never run it concurrently -- the
        // guarantee the pair of sources this replaces got from sharing a queue.
        // `asked` is the caller's because `serve()` reads it too, from the
        // listening channel's close; it carries its own lock for that reason.
        { number in
            if asked.recordAndReportFirst() {
                logger.info("shutting down gracefully", metadata: ["signal": "\(number)"])

                // The one call that starts the drain, and it is `asked`'s
                // branch condition that makes it happen exactly once --
                // `beginGracefulShutdown` hands `initiateGracefulShutdown` a
                // promise, and a second call would complete that promise
                // twice. The second signal takes the escalation branch below
                // instead, which closes the listener rather than draining.
                let drained = engine.beginGracefulShutdown()

                // **The drain is bounded, and it has to be, because
                // quiescing cannot close every connection it asks to
                // close.** `ServerQuiescingHelper` sends each accepted
                // channel a `ChannelShouldQuiesceEvent`; grpc-swift turns
                // that into a GOAWAY and closes the connection once its
                // streams finish -- but only for a connection whose
                // protocol it has finished negotiating. One that has been
                // accepted and has sent nothing yet is in no protocol at
                // all, nothing closes it, and the drain waits on it for as
                // long as the peer cares to hold the socket.
                //
                // MEASURED, and it is not theoretical. A raw socket
                // connected to the engine and left silent held the first
                // SIGTERM open past 5s, **5 times out of 5**. It also
                // reached the live tier by accident: with the drain
                // unbounded,
                // `shutdown::the_engine_exits_cleanly_with_a_client_channel_still_open`
                // hung past its 30s bound once in roughly 200 engines --
                // a tonic channel whose HTTP/2 preface had not been
                // exchanged when the signal landed is exactly that state.
                //
                // So "handles SIGTERM" must not depend on a peer being
                // well behaved. The escalation below is the operator's
                // lever and this is the one that needs no operator.
                let forced = drained.eventLoop.scheduleTask(in: shutdownGrace) {
                    logger.error(
                        "connections did not drain within the grace period; closing anyway",
                        metadata: ["grace": "\(shutdownGrace)"]
                    )
                    // Non-zero: this is the drain failing, not an operator
                    // choosing to abandon it. See `releaseAndExit`.
                    releaseAndExit(engine, logger: logger, status: EXIT_FAILURE)
                }
                // Same event loop as the promise, so a drain that finishes
                // first and this cancellation are ordered against each
                // other rather than racing.
                drained.whenComplete { _ in forced.cancel() }
            } else {
                logger.notice("closing immediately", metadata: ["signal": "\(number)"])
                engine.server.close(promise: nil)

                // **Ending the process here rather than letting `serve()`
                // return, because what is being escalated past is the wait
                // for accepted connections to close.** Closing the
                // listening channel does not close them -- NIO's accepted
                // channels outlive their listener -- so returning would
                // leave `quiesced` pending for exactly as long as the
                // client holds its connection, and completing `quiesced`
                // instead would shut the event-loop group down with those
                // channels still registered, which is the crash the
                // graceful path exists to avoid. Nothing after this needs
                // the group.
                //
                // Zero, unlike the grace-period path above: abandoning the
                // remaining connections is what the second signal asked
                // for, so doing it is this process succeeding.
                releaseAndExit(engine, logger: logger, status: EXIT_SUCCESS)
            }
        }
    }

    /// Creates the socket's parent directory mode 0700 if it does not already
    /// exist. Existing directories are left with whatever mode they already
    /// have -- this only strengthens a fresh directory, it does not tighten
    /// one the caller chose to leave looser.
    private func createSocketParentDirectory(for socketPath: String) throws {
        let parent = URL(fileURLWithPath: socketPath).deletingLastPathComponent()
        guard !FileManager.default.fileExists(atPath: parent.path) else { return }
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
        )
    }
}

