import ContainerBridge
import Containerization
import Foundation
import Logging
import NIOConcurrencyHelpers
import SandboxEngineProto

/// The one place an `ExecServerFrame` is put on the response stream, and the
/// reason it exists is that there are two producers and one stream.
///
/// `startExec` is handed a `Writer` for stdout and another for stderr, and
/// containerization drives each from its own `readabilityHandler`
/// (`LinuxProcess.swift:165` and `:184`) -- two callbacks on two file handles,
/// with nothing ordering them against each other. A `Writer` that sent straight
/// to a `GRPCAsyncResponseStreamWriter` would therefore have two producers
/// racing on one stream, and an interleaved frame reads as a flake, which is the
/// most expensive class of defect this project has.
///
/// **Every frame goes through here, including the refusals and the final
/// `Exit`.** Not for tidiness: a refusal sent by one route and output by another
/// is two orderings to reason about, and the ordering that matters -- the last
/// output frame before `Exit` -- is exactly the one a second route would break.
/// `yield` is `AsyncStream.Continuation`'s, which is thread-safe and
/// order-preserving, so the sequence the consumer reads is the sequence the
/// writers produced.
///
/// **The buffer is unbounded, and that is a stated limit rather than an
/// oversight.** `Writer.write(_:)` is synchronous and returns `Void`
/// (`Writer.swift:20-23`), so it has nowhere to apply backpressure: the only
/// bounded policies `AsyncStream` offers -- `.bufferingNewest` and
/// `.bufferingOldest` -- **drop**, and dropping here is a container's output
/// silently going missing, which is the defect this milestone has spent three
/// tasks removing from the log path. What bounds it in practice is the guest:
/// frames arrive no faster than the process writes, and the consumer drains one
/// frame per `send`.
package final class ExecFrameRelay: Sendable {
    package let frames: AsyncStream<Arca_Engine_V1_ExecServerFrame>
    private let continuation: AsyncStream<Arca_Engine_V1_ExecServerFrame>.Continuation

    package init() {
        let (frames, continuation) = AsyncStream.makeStream(
            of: Arca_Engine_V1_ExecServerFrame.self,
            bufferingPolicy: .unbounded
        )
        self.frames = frames
        self.continuation = continuation
    }

    package func send(_ frame: Arca_Engine_V1_ExecServerFrame) {
        continuation.yield(frame)
    }

    /// Ends the stream, once, when the exec is over.
    ///
    /// Called by the session and by nothing else -- in particular **not** by
    /// `ExecOutputWriter.close()`; see the note there for what that would cost.
    package func finish() {
        continuation.finish()
    }
}

/// A `Writer` that turns one guest write into one server frame.
///
/// This and `ExecStdinRelay` are the two adapters `Exec` is built out of, and
/// they are where the logic lives because they are what a VM-free test can
/// reach: `startExec` requires a native container instance
/// (`ExecManager.swift:197-199`), so `Exec` end to end cannot be driven from
/// this repository at all.
package struct ExecOutputWriter: Writer {
    package enum Stream: Sendable {
        case stdout
        case stderr
    }

    private let stream: Stream
    private let relay: ExecFrameRelay

    package init(stream: Stream, relay: ExecFrameRelay) {
        self.stream = stream
        self.relay = relay
    }

    /// One write, one frame, with no filtering of any kind.
    ///
    /// An empty write becomes an empty frame rather than nothing. A filter here
    /// would make the frame count a function of the payload's content, and the
    /// consumer concatenates data frames without knowing where they were cut
    /// (`gascan-arca/src/backend.rs:311-316`), so an empty frame costs it
    /// nothing and a dropped one is a decision this adapter has no business
    /// making.
    package func write(_ data: Data) throws {
        relay.send(
            Arca_Engine_V1_ExecServerFrame.with { frame in
                switch stream {
                case .stdout: frame.stdout = data
                case .stderr: frame.stderr = data
                }
            })
    }

    /// **Deliberately does nothing, and must not finish the relay.**
    ///
    /// `startExec` closes stdout and then stderr once the process has exited
    /// (`ExecManager.swift:269-289`), and both writers share one relay. A
    /// `close()` that finished it would end the response stream at whichever
    /// writer closed first -- discarding the other stream's frames and, after
    /// them, the `Exit` frame that is the answer the consumer is waiting for.
    /// MEASURED with `close()` changed to `{ relay.finish() }`:
    /// `ExecTests.testClosingOneWriterDoesNotEndTheOther` and
    /// `.testTheExitFrameSurvivesBothWritersClosing` fail, and nothing else in
    /// `ArcaEngineTests` moves.
    package func close() throws {}
}

/// The client's `stdin` frames, as the `ReaderStream` `startExec` takes.
///
/// **`close()` finishes the stream, and finishing the stream is what closes the
/// guest's stdin.** `LinuxProcess.startStdinRelay` reads this stream until it
/// ends and then calls `_closeStdin()` (`LinuxProcess.swift:211-240`), so the
/// wire's `Close` frame maps onto `finish()` rather than onto a write of zero
/// bytes -- a zero-byte write would reach the guest as a write of nothing and
/// leave stdin open, which is the opposite of what the frame asks for.
///
/// `stream()` hands back the same stream on every call because `AsyncStream`
/// has one buffer and one consumer; the single consumer here is the relay task
/// above.
package final class ExecStdinRelay: ReaderStream, Sendable {
    private let data: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation

    package init() {
        let (data, continuation) = AsyncStream.makeStream(
            of: Data.self,
            bufferingPolicy: .unbounded
        )
        self.data = data
        self.continuation = continuation
    }

    package func stream() -> AsyncStream<Data> { data }

    package func send(_ bytes: Data) {
        continuation.yield(bytes)
    }

    package func close() {
        continuation.finish()
    }
}

/// The client's frames, republished as an `AsyncStream` the session can be
/// woken out of.
///
/// **It exists for one reason: the dispatch loop has to be interruptible by the
/// exec ending, and `GRPCAsyncRequestStream` cannot be.** The session reads
/// client frames while the guest process runs, and the process is the thing
/// that decides when the exec is over. A loop reading the request stream
/// directly would sit in `next()` until the consumer half-closed -- and gascan's
/// consumer does not half-close, it reads until it sees a terminal frame
/// (`gascan-arca/src/backend.rs:328-332`), which is the frame this session sends
/// *after* the loop ends. That is a deadlock, and republishing the frames
/// removes it: the task that runs `startExec` calls `finish()` here, and the
/// dispatch loop's `next()` returns nil immediately.
///
/// A client stream that **fails** rather than ending is recorded in `failure`
/// instead of being thrown, because the two demand different answers: a stream
/// that ended is a consumer that has said everything it means to say, and a
/// stream that failed is a consumer that is no longer there to be told anything.
private final class ExecClientRelay: @unchecked Sendable {
    let frames: AsyncStream<Arca_Engine_V1_ExecClientFrame>
    private let continuation: AsyncStream<Arca_Engine_V1_ExecClientFrame>.Continuation
    private let state = NIOLockedValueBox<Error?>(nil)

    /// The error the request stream ended with, or nil when it ended cleanly.
    var failure: Error? { state.withLockedValue { $0 } }

    init() {
        let (frames, continuation) = AsyncStream.makeStream(
            of: Arca_Engine_V1_ExecClientFrame.self,
            bufferingPolicy: .unbounded
        )
        self.frames = frames
        self.continuation = continuation
    }

    func send(_ frame: Arca_Engine_V1_ExecClientFrame) {
        continuation.yield(frame)
    }

    func finish() {
        continuation.finish()
    }

    func fail(_ error: Error) {
        state.withLockedValue { $0 = error }
        continuation.finish()
    }
}

extension SandboxEngineService {
    /// `Exec`, with the sink it sends through supplied by the caller.
    ///
    /// **A sink and not a `GRPCAsyncResponseStreamWriter`, for `streamLogs`'
    /// reason:** a test target cannot construct one, so the logic lives here and
    /// the protocol method below only supplies the writer. Task 4's review is
    /// why this seam is reused rather than reinvented -- a seam invented for one
    /// method replaced a compile-time guarantee with a wiring nothing checked,
    /// and 177 green tests did not notice.
    ///
    /// **What this method can be driven through VM-free, and what it cannot.**
    /// Everything up to and including `createExec` is reachable from
    /// `ArcaEngineTests`: the opening-frame rule, both identity refusals, argv
    /// that cannot be carried, and `createExec`'s own refusals -- because no
    /// VM-free path can put a container in state `running`, so `createExec`
    /// throws `containerNotRunning` against a real `ContainerManager`
    /// (`ExecManager.swift:132`, measured in the note on `ExecContainerSource`).
    /// Everything after it needs a booted guest and is gascan's live
    /// `exec.rs`. Be precise about which is which: the tests in this repository
    /// pin the refusals, not the session.
    ///
    /// **Three tasks run at once and each of them is here for a reason.** The
    /// caller's task drains `outbound` into `sink`, so `sink` is touched by one
    /// task and never has to be `Sendable`. One child reads the request stream
    /// into `inbound`. One child runs the whole session. The alternative --
    /// reading the request stream in the same task that dispatches its frames --
    /// deadlocks against a consumer that waits for `Exit` before half-closing;
    /// see the note on `ExecClientRelay`.
    func runExec<Frames: AsyncSequence & Sendable>(
        frames: Frames,
        into sink: (Arca_Engine_V1_ExecServerFrame) async throws -> Void
    ) async throws where Frames.Element == Arca_Engine_V1_ExecClientFrame {
        let inbound = ExecClientRelay()
        let outbound = ExecFrameRelay()

        // Unstructured on purpose, and it is the one place in this method that
        // is. A child of the group below would have to be cancelled and then
        // AWAITED before this method could return, so a request stream that did
        // not honour cancellation would hang the RPC. Left unstructured and
        // merely cancelled, the handler returns, grpc-swift tears the stream
        // down, and this task ends because its own iterator ends.
        let reader = Task {
            do {
                for try await frame in frames {
                    inbound.send(frame)
                }
                inbound.finish()
            } catch {
                inbound.fail(error)
            }
        }
        defer { reader.cancel() }

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { [self] in
                defer { outbound.finish() }
                await driveExec(inbound: inbound, outbound: outbound)
            }
            for await frame in outbound.frames {
                try await sink(frame)
            }
            try await group.waitForAll()
        }
    }

    /// The session itself: one `ExecStart`, then frames until the process exits.
    ///
    /// Never throws. Every failure it can name becomes a frame on `outbound`,
    /// because an uncaught throw in a provider method becomes a gRPC status and
    /// a status tells the consumer the engine is unreachable -- a different and
    /// more alarming fact than "that could not be done"
    /// (`engine.proto:52-58`).
    private func driveExec(inbound: ExecClientRelay, outbound: ExecFrameRelay) async {
        var frames = inbound.frames.makeAsyncIterator()

        guard let opening = await frames.next() else {
            return outbound.send(
                Self.execFailed(
                    engineError(
                        .invalidState,
                        message: "the exec stream ended before it opened; ExecStart must be its "
                            + "first frame (engine.proto:408-411)"
                    )))
        }
        guard case .start(let start) = opening.frame else {
            return outbound.send(
                Self.execFailed(
                    engineError(
                        .invalidState,
                        message: "the first frame of an exec stream must be ExecStart "
                            + "(engine.proto:408-411); this one was "
                            + Self.frameName(opening.frame)
                    )))
        }

        // Before anything is resolved, for the reason `Logs` records at
        // `streamLogs`: `resolveContainerID` prefix-matches any pure-hex string
        // of four or more characters against every Docker id the engine holds,
        // so a sandbox id of `beef` names an unrelated container. `Inspect` was
        // excused from this gate because a consumer can check the labels it
        // hands back; `Exec` carries bytes -- the guest's output, and the
        // client's input into a process that is not the caller's -- and there
        // are no labels in an `ExecServerFrame` for anyone to check.
        let name = SandboxIdentity.containerName(forSandboxId: start.sandboxID)
        if let refusal = containerNameRefusal(name) {
            return outbound.send(Self.execFailed(refusal))
        }

        let found = await engineErrorCatching(.commandIo, resource: name) {
            try await self.containerManager.getContainer(id: name)
        }
        // Qualified: this file imports `Containerization` for `Writer`,
        // `ReaderStream` and `Signal`, and that module has a `Container` of its
        // own, so the bare name is ambiguous here where it is not in
        // `streamLogs`.
        let container: ContainerBridge.Container
        switch found {
        case .failure(let error):
            return outbound.send(Self.execFailed(error))
        case .success(nil):
            return outbound.send(
                Self.execFailed(
                    engineError(
                        .notFound,
                        resource: name,
                        message: "no container named \(name) exists, so there is nothing to exec in"
                    )))
        case .success(.some(let resolved)):
            container = resolved
        }
        guard SandboxIdentity.owner(from: container.config.labels) != nil else {
            return outbound.send(
                Self.execFailed(
                    engineError(
                        .foreignResourceRefused,
                        resource: name,
                        message: "container \(name) carries no gascan owner labels, so this engine "
                            + "cannot assert it is the sandbox that was asked for"
                    )))
        }

        // `argv` is `repeated bytes` because "execve takes bytes, and a consumer
        // holding a non-UTF-8 argument must be able to send it"
        // (engine.proto:414-416). This engine cannot: `createExec` takes
        // `[String]` (`ExecManager.swift:107`) and so does
        // `LinuxProcessConfiguration.arguments`. It is refused by name rather
        // than lossily decoded -- `String(decoding:as:UTF8.self)` would
        // substitute U+FFFD and run a command the consumer did not ask for.
        var argv: [String] = []
        for (index, bytes) in start.argv.enumerated() {
            guard let argument = String(data: bytes, encoding: .utf8) else {
                return outbound.send(
                    Self.execFailed(
                        engineError(
                            .invalidState,
                            resource: name,
                            message: "argv[\(index)] is not UTF-8 and this engine cannot carry it: "
                                + "every path from here to the guest is [String]"
                        )))
            }
            argv.append(argument)
        }

        // `attachStderr` is true even when `tty` is set, and the tty rule is
        // NOT restated here. `startExec` sets `processConfig.terminal` and then
        // sets stderr only when that is false (`ExecManager.swift:211`, `:231`),
        // because a terminal merges stderr into stdout. Repeating the decision
        // here would put one gate in two places, which this project has
        // measured as removing the instrument rather than adding a defence:
        // deleting either copy leaves the suite green.
        let created = await Self.execCatching(resource: name) {
            try await self.execManager.createExec(
                containerID: container.id,
                cmd: argv,
                env: start.environment.map { "\($0.name)=\($0.value)" },
                workingDir: nil,
                user: nil,
                tty: start.tty,
                attachStdin: true,
                attachStdout: true,
                attachStderr: true
            )
        }
        let execID: String
        switch created {
        case .failure(let error):
            return outbound.send(Self.execFailed(error))
        case .success(let id):
            execID = id
        }

        await runSession(
            execID: execID,
            resource: name,
            frames: &frames,
            inbound: inbound,
            outbound: outbound
        )
    }

    /// From `startExec` to `Exit`, or to the one refusal that replaces it.
    private func runSession(
        execID: String,
        resource: String,
        frames: inout AsyncStream<Arca_Engine_V1_ExecClientFrame>.Iterator,
        inbound: ExecClientRelay,
        outbound: ExecFrameRelay
    ) async {
        let stdin = ExecStdinRelay()
        let stdout = ExecOutputWriter(stream: .stdout, relay: outbound)
        let stderr = ExecOutputWriter(stream: .stderr, relay: outbound)

        // **Unstructured, and only because the alternative cannot be made to
        // return.** `startExec` awaits `process.wait()`, which nothing bounds
        // (`ExecManager.swift:265`; `LinuxProcess.wait` takes a timeout it is
        // not given). Under `async let` or a task group this scope must await
        // that child before it can exit, so a guest that never dies -- a wedged
        // VM, an unreachable agent, a kill that did not land -- would hold the
        // RPC handler open for the life of the engine, with the response stream
        // and the exec instance behind it. Abandoning a task is the only thing
        // in structured concurrency that a hung child cannot veto, and the
        // shutdown path below bounds the wait so this method always returns.
        let execution = Task { [self] in
            try await runProcess(
                execID: execID,
                stdin: stdin,
                stdout: stdout,
                stderr: stderr,
                inbound: inbound
            )
        }

        // **A frame this engine cannot carry out is reported and the session
        // continues; only a protocol violation or a client reset ends it.** An
        // earlier version ended the exec on any refusal and force-killed the
        // guest, so a client that sent one unmapped signal number had its
        // perfectly healthy process destroyed -- an answer far larger than the
        // question, and one `engine.proto` never asks for. The consumer decides
        // what a refusal means to it: gascan stops reading at an error frame
        // (`gascan-arca/src/backend.rs:322-324`), and a consumer that stops
        // reading is a consumer that has reset, which the path below already
        // handles as cancellation. **The distinction is between a frame the
        // engine will not act on and a stream it can no longer trust.**
        var violation: Arca_Engine_V1_EngineError?
        dispatch: while let frame = await frames.next() {
            switch frame.frame {
            case .stdin(let bytes):
                stdin.send(bytes)
            case .close:
                stdin.close()
            case .resize(let resize):
                do {
                    try await awaitingProcess(execID: execID) {
                        try await self.execManager.resizeExec(
                            execID: execID,
                            height: Int(resize.rows),
                            width: Int(resize.columns)
                        )
                    }
                } catch {
                    outbound.send(Self.execFailed(Self.execError(for: error, resource: resource)))
                }
            case .signal(let number):
                do {
                    try await awaitingProcess(execID: execID) {
                        try await self.execManager.signalExec(execID: execID, signal: number)
                    }
                } catch {
                    outbound.send(Self.execFailed(Self.execError(for: error, resource: resource)))
                }
            case .start:
                violation = engineError(
                    .invalidState,
                    resource: resource,
                    message: "exactly one ExecStart may appear per exec stream "
                        + "(engine.proto:408-411) and this stream carried a second"
                )
                break dispatch
            case nil:
                violation = engineError(
                    .invalidState,
                    resource: resource,
                    message: "an exec client frame arrived with no frame set"
                )
                break dispatch
            }
        }
        stdin.close()

        let clientReset = inbound.failure != nil || Task.isCancelled
        var failure = violation
        if clientReset || violation != nil {
            // Before awaiting `execution`, not after: it is blocked in
            // `process.wait()` and only the guest process exiting frees it. An
            // await here without the kill is how this method would hang on a
            // sandbox whose command was `sleep 300`.
            await forceKill(execID: execID, resource: resource)
            // **And bounded afterwards, because `forceKill` is a best effort
            // that logs its own failure.** If the signal did not land -- an
            // unreachable agent, a stopped container, a wedged VM -- the wait
            // below never ends on its own, and this method not returning means
            // `outbound` is never finished, the caller's drain never ends, and
            // the RPC handler leaks along with the exec instance and the
            // response stream. That is the shape the engine's own shutdown work
            // exists to prevent, so the guest gets a bounded chance to die and
            // then the session stops waiting on it.
            if await Self.completes(execution, within: .seconds(10)) == false {
                execution.cancel()
                logger.error(
                    "exec did not end after being killed; abandoning the wait so the stream can close",
                    metadata: ["exec_id": "\(execID)", "container": "\(resource)"]
                )
                failure =
                    failure
                    ?? engineError(
                        .commandIo,
                        resource: resource,
                        message: "exec \(execID) did not end within 10s of being killed"
                    )
            }
        } else {
            // The ordinary path, and deliberately unbounded: this is waiting
            // for the command the caller asked to run, and a bound here would
            // be the engine deciding how long a consumer's own process may
            // take.
            do {
                try await execution.value
            } catch {
                failure = Self.execError(for: error, resource: resource)
            }
        }

        let info = await execManager.getExecInfo(execID: execID)
        await reap(execID: execID, resource: resource)

        // A consumer that has reset the stream is told nothing, because there is
        // nothing there to tell. Everything above still ran: the guest process
        // is killed and the exec instance is reaped, which is what the parent
        // design means by cancellation.
        if clientReset {
            logger.info(
                "exec cancelled by its client",
                metadata: [
                    "exec_id": "\(execID)",
                    "container": "\(resource)",
                    "reason": "\(inbound.failure.map { "\($0)" } ?? "the stream was cancelled")",
                ])
            return
        }
        if let failure {
            return outbound.send(Self.execFailed(failure))
        }
        guard let code = info?.exitCode else {
            // Unreachable by construction -- `startExec` records the exit code
            // before it returns (`ExecManager.swift:293`) and it returned
            // without throwing -- and reported rather than defaulted, because an
            // `Exit{code: 0}` invented here is a failing command reported as a
            // successful one.
            return outbound.send(
                Self.execFailed(
                    engineError(
                        .invalidOutput,
                        resource: resource,
                        message: "exec \(execID) completed without recording an exit code"
                    )))
        }
        outbound.send(
            Arca_Engine_V1_ExecServerFrame.with { frame in
                frame.exit = Arca_Engine_V1_Exit.with { exit in
                    exit.code = Int32(code)
                    // **Always zero, and it is a measured limit rather than a
                    // stub.** Nothing on this path carries a signal number: the
                    // guest reaps with `wait4` and immediately collapses the
                    // status to a single number, returning `128 + N` for a
                    // signalled process
                    // (`ContainerizationOS/Command.swift:306-315`), and
                    // `ExitStatus` carries no signal number at all -- only
                    // `exitCode` and `exitedAt` (`ExitStatus.swift:23`, `:25`).
                    // Deriving `signal` from
                    // `code - 128` would be a guess indistinguishable from a
                    // process that called `exit(143)`. gascan's other backend
                    // reports the same zero for the same reason
                    // (`gascan-apple/src/backend.rs:604`), so the two stay
                    // indistinguishable by their framing. **A signal delivered
                    // to the guest is therefore observed in `code`, which is
                    // what `exec.rs` asserts.**
                    exit.signal = 0
                }
            })
    }

    /// `startExec`, and the `finish()` that wakes the dispatch loop when it
    /// returns.
    ///
    /// **`tty` is passed as nil so that `createExec`'s stored flag decides,
    /// once.** `startExec` reads `tty ?? execInfo.config.tty`
    /// (`ExecManager.swift:211`), and two sources for one fact is how they come
    /// to disagree.
    private func runProcess(
        execID: String,
        stdin: ExecStdinRelay,
        stdout: ExecOutputWriter,
        stderr: ExecOutputWriter,
        inbound: ExecClientRelay
    ) async throws {
        defer { inbound.finish() }
        try await execManager.startExec(
            execID: execID,
            detach: false,
            tty: nil,
            stdin: stdin,
            stdout: stdout,
            stderr: stderr
        )
    }

    /// Runs `act`, and if it fails only because the process is not recorded
    /// yet, waits for it and runs it once more.
    ///
    /// **The race is real and it lands on the most ordinary thing a client
    /// does.** `createExec` records the exec with `process` nil
    /// (`ExecManager.swift:155`) and `startExec` fills it in only after a round
    /// trip to the guest agent (`:245-255`), while this session starts
    /// dispatching client frames immediately. A `signal` frame inside that
    /// window reaches `signalExec`, which throws `execNotStarted`
    /// (`:399-401`) -- so an interactive consumer that opens a shell and sends
    /// Ctrl-C in the first tens of milliseconds had its exec refused before the
    /// shell ever ran.
    ///
    /// **Waiting rather than ignoring, and that distinction is Task 4's
    /// ruling.** `resizeExec` tolerates the same race by returning silently
    /// (`:325-328`), which is right for a window size and wrong for a signal:
    /// "a signal that goes nowhere while the caller is told nothing is
    /// precisely this project's recurring defect". So the signal is neither
    /// dropped nor fatal -- it is held for as long as starting can reasonably
    /// take, and then delivered. A resize goes through the same wait for a
    /// smaller reason: `resizeExec`'s silent return means an initial window
    /// size sent immediately after `ExecStart` is otherwise lost with nothing
    /// said, and the guest keeps the default terminal size.
    ///
    /// **Polling, and it is a trade rather than an oversight.** The alternative
    /// is a readiness signal on `ExecManager`, which is shared with Arca's
    /// Docker surface -- a second consumer for a seam only this one needs.
    /// `getExecInfo` is already public and already answers the exact question.
    ///
    /// The bound is 2 seconds: long against a guest round trip, short enough
    /// that a `startExec` which threw -- and so will never record a process --
    /// stalls one frame's dispatch rather than the session. Stdin is unaffected
    /// either way; it buffers in `ExecStdinRelay` and nothing is lost.
    /// **The wait comes first, and it has to.** An earlier version of this ran
    /// `act` and waited only if it threw `execNotStarted` -- which works for
    /// `signalExec`, because that throws, and does nothing whatsoever for
    /// `resizeExec`, which **returns silently** in exactly the same situation
    /// (`ExecManager.swift:325-328`). So a resize sent before the process
    /// existed was still dropped with nothing said, and the wrapper only looked
    /// as though it covered both.
    ///
    /// MEASURED, and the live tier is what caught it: with the retry keyed on
    /// the throw, `exec::a_resize_sent_before_the_process_starts_still_reaches_the_guests_terminal`
    /// failed with `stdout: "done\r\n"` and no `WINCH` -- the guest's SIGWINCH
    /// trap never fired. The same test with a readiness handshake in front of
    /// the resize passed, which is what proved the instrument sound and the
    /// window real rather than the trap being broken.
    private func awaitingProcess(
        execID: String,
        _ act: () async throws -> Void
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while await execManager.getExecInfo(execID: execID)?.process == nil {
            if ContinuousClock.now >= deadline {
                break
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        try await act()
    }

    /// Whether `task` finished inside `bound`, without cancelling it if it did
    /// not.
    ///
    /// Structured concurrency has no way to stop waiting on a child, which is
    /// why `execution` is an unstructured task and why this is written by
    /// racing two of them.
    private static func completes(_ task: Task<Void, Error>, within bound: Duration) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                _ = try? await task.value
                return true
            }
            group.addTask {
                try? await Task.sleep(for: bound)
                return false
            }
            let finished = await group.next() ?? false
            group.cancelAll()
            return finished
        }
    }

    /// SIGKILL to the exec's process, whatever this task's own state.
    ///
    /// Detached because both callers reach it on paths where this task may
    /// already be cancelled -- a client reset -- and a cancelled task cannot be
    /// relied on to complete an RPC to the guest agent. The whole point of the
    /// path is that the guest process must not outlive the stream that started
    /// it, so the work has to be somewhere cancellation does not reach.
    ///
    /// A failure is logged and not raised. It is a best effort by construction:
    /// the process may have exited between the decision and the signal, in which
    /// case `signalExec` throws `execNotStarted` or the guest reports no such
    /// process, and neither is a fact the consumer asked about.
    private func forceKill(execID: String, resource: String) async {
        let logger = self.logger
        let execManager = self.execManager
        await Task.detached {
            do {
                try await execManager.signalExec(
                    execID: execID, signal: Signal.Linux.kill.rawValue)
            } catch {
                logger.info(
                    "exec could not be killed; it may already have exited",
                    metadata: [
                        "exec_id": "\(execID)",
                        "container": "\(resource)",
                        "error": "\(error)",
                    ])
            }
        }.value
    }

    /// Drops the exec instance, so `execInstances` does not grow by one per
    /// exec for the life of the process. Detached for `forceKill`'s reason.
    private func reap(execID: String, resource: String) async {
        let logger = self.logger
        let execManager = self.execManager
        await Task.detached {
            do {
                try await execManager.deleteExec(execID: execID)
            } catch {
                logger.warning(
                    "exec instance could not be reaped",
                    metadata: [
                        "exec_id": "\(execID)",
                        "container": "\(resource)",
                        "error": "\(error)",
                    ])
            }
        }.value
    }

    /// The failure arm of an `ExecServerFrame`, in one place, for `ackFailed`'s
    /// reason: a `oneof` left unset at one of a dozen early returns reads as
    /// neither an answer nor a failure.
    static func execFailed(
        _ error: Arca_Engine_V1_EngineError
    ) -> Arca_Engine_V1_ExecServerFrame {
        Arca_Engine_V1_ExecServerFrame.with { $0.error = error }
    }

    static func execCatching<T>(
        resource: String,
        _ body: () async throws -> T
    ) async -> Result<T, Arca_Engine_V1_EngineError> {
        do {
            return .success(try await body())
        } catch {
            return .failure(execError(for: error, resource: resource))
        }
    }

    /// The one table mapping what `ExecManager` throws onto the contract's
    /// vocabulary.
    ///
    /// A table rather than a judgment at each call site, for the reason
    /// `engine.proto:62-65` gives for gascan's own: a new failure mode must not
    /// quietly become an existing one. `SignalError` is here because
    /// `signalExec` deliberately lets Containerization's own refusal propagate
    /// rather than renaming it, and its description names the number the client
    /// sent.
    ///
    /// CORRECTED: that last clause used to read "which `engine.proto:437`
    /// requires of this refusal". It requires nothing of the kind --
    /// `engine.proto:436-437` is a comment and `int32 signal = 4;`, and says only
    /// that the field is a signal number to forward. **Naming the number is the
    /// milestone-3 design's requirement (§2.7), not the contract's**, and citing
    /// the stronger source is the over-citation this project keeps writing traps
    /// about.
    static func execError(
        for error: Error,
        resource: String
    ) -> Arca_Engine_V1_EngineError {
        switch error {
        case let error as ExecManagerError:
            let code: EngineErrorCode =
                switch error {
                case .containerNotFound: .notFound
                case .containerNotRunning, .invalidCommand, .execNotFound, .execAlreadyRunning,
                    .execNotStarted:
                    .invalidState
                case .startFailed: .commandFailed
                }
            return engineError(code, resource: resource, message: "\(error)")
        case let error as SignalError:
            return engineError(.invalidState, resource: resource, message: "\(error)")
        default:
            return engineError(.commandFailed, resource: resource, message: "\(error)")
        }
    }

    /// Names a client frame for a refusal's prose. Every case is spelled out
    /// rather than defaulted, so a frame added to the contract fails to compile
    /// here instead of being reported as something it is not.
    static func frameName(_ frame: Arca_Engine_V1_ExecClientFrame.OneOf_Frame?) -> String {
        switch frame {
        case .start: return "ExecStart"
        case .stdin: return "stdin"
        case .resize: return "Resize"
        case .signal: return "signal"
        case .close: return "Close"
        case nil: return "a frame with nothing set"
        }
    }
}
