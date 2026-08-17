import ArcaSignalCapture
import Dispatch
import Foundation
import NIOConcurrencyHelpers

/// Every signal the process is asked to stop by, from the earliest instant it
/// can be captured until it exits, routed to whatever is able to act when it
/// arrives.
///
/// **Capture and action are two steps, and separating them is the whole design.**
/// A process cannot act on a signal before its runtime exists, but it must stop
/// being *killed* by one from as close to `exec` as it can get. Fusing the two --
/// setting the disposition and registering an observer in one place -- is what
/// produced the two windows this type closes:
///
/// - Everything before the disposition changes runs under the default action, so
///   a `SIGTERM` there terminates the process outright. In `arca-engine` that
///   was the whole of startup: argument validation, the vminit load and all
///   three `initialize()` calls. MEASURED against `db11cc0` by spawning the
///   binary and signalling it at once, **12 exits of 12 were the kernel's**,
///   against 0 of 12 for the same binary signalled once it was serving.
/// - Between a `SIG_IGN` disposition and a resumed `DispatchSourceSignal` the
///   process is no longer killed and not yet observing, so a signal there is
///   discarded and the process ignores it forever -- which for a supervised
///   engine reads as "it ignored `SIGTERM`", a shutdown defect rather than the
///   startup one it is. MEASURED, in-process and deterministically, by
///   `ShutdownSignalsTests`: a signal raised in that gap never reaches the
///   source, whether it is raised before the source is created or after it is
///   created and before it is resumed.
///
/// Capture is a `sigaction` writing one byte per delivery into a pipe
/// (`ArcaSignalCapture`, which explains why that half is C). Action is a
/// `DispatchSourceRead` on the other end. A byte written before anything reads
/// the pipe simply waits there, so the second window does not exist: `route(to:)`
/// may be called at any later moment and still sees every signal that has
/// already arrived.
///
/// **`SIG_IGN` alone was never an option**, and not because it is untidy. An
/// early `SIG_IGN` with no observer makes a startup `SIGTERM` a silent no-op: an
/// operator's `kill` appears to do nothing and the process runs on. Dying with
/// 143 is bad; not dying and not saying so is worse.
///
/// **One relay per process, because a signal disposition is per-process.** There
/// is no public initialiser for that reason. [`capture(_:)`] is additive -- each
/// call adds numbers to the one pipe -- and [`route(to:)`] replaces the action
/// for everything not yet delivered.
public final class ShutdownSignals: @unchecked Sendable {
    /// The process's relay.
    public static let shared = ShutdownSignals()

    /// The read end of the capture pipe, `-1` until something has installed one.
    ///
    /// **Owned by `ArcaSignalCapture` rather than by this type, because the pipe
    /// has to exist before Swift does.** `arca-engine` installs from a `dyld`
    /// constructor, which runs before the runtime that would initialise a Swift
    /// property; this reads back whatever that left. A plain `var` and not
    /// locked, which is what `@unchecked Sendable` is carrying here: it is
    /// written by `capture(_:)` before `route` creates the source that reads it,
    /// and the source's creation is the ordering.
    private var readEnd: Int32 = -1

    /// Serial on purpose: two signals arriving together must not run their
    /// action concurrently. It is the same guarantee the pair of
    /// `DispatchSourceSignal`s this replaces got from sharing one queue.
    private let queue = DispatchQueue(label: "arca-engine.shutdown")

    /// The action, and the source that runs it. Both under one lock: `route`
    /// resumes the source the first time and only the first time, and deciding
    /// that from the same critical section that stores the action is what makes
    /// two callers safe.
    private let routing = NIOLockedValueBox(Routing())

    private struct Routing {
        var action: (@Sendable (Int32) -> Void)?
        var source: DispatchSourceRead?
    }

    private init() {}

    /// Makes each of `numbers` non-fatal, and records every one that arrives
    /// from this instant.
    ///
    /// Call it as early as the process can. Nothing before it is protected --
    /// the disposition is whatever `exec` left -- and no code inside a process
    /// can protect the part of its own startup that runs before its first
    /// instruction. **MEASURED, and the difference is the whole of this
    /// design's cost:** spawning `arca-engine` and signalling it after a delay,
    /// six engines per delay, with the capture at the top of the Swift entry
    /// point, every engine at 0, 1, 2 and 5ms was killed and every engine from
    /// 20ms survived. That residue is `dyld`, which is why `arca-engine`
    /// installs from a constructor (`ArcaSignalCaptureAtLoad`) and this method
    /// merely confirms it.
    ///
    /// Idempotent and additive: the pipe is made once, and re-installing a
    /// number already captured is harmless. That is what lets the executable
    /// call it after its constructor already has.
    ///
    /// Throws rather than reporting. A process that cannot capture its own
    /// shutdown signals is a process whose `kill` behaviour is undefined, and
    /// starting anyway would hide that until an operator tried to stop it.
    public func capture(_ numbers: [Int32]) throws {
        let code = numbers.withUnsafeBufferPointer { buffer in
            arca_signal_capture_install(buffer.baseAddress, Int32(buffer.count))
        }
        guard code == 0 else {
            throw ShutdownSignalsError.captureRefused(signals: numbers, code: code)
        }
        readEnd = arca_signal_capture_read_end()
        guard readEnd >= 0 else {
            throw ShutdownSignalsError.noPipe
        }
    }

    /// Routes every captured signal -- including any that arrived before this
    /// call -- to `action`, on this relay's serial queue.
    ///
    /// Calling it again replaces the action. Signals already handed to the
    /// previous action are not replayed, which is what makes the replacement a
    /// hand-over rather than a race: `arca-engine` swaps a "nothing is bound
    /// yet, stop" action for one that drains a live server, and the swap also
    /// drops the previous closure's references -- the engine's, in that case --
    /// exactly as cancelling the old signal sources used to.
    ///
    /// A precondition rather than an error: routing before capturing would
    /// silently observe a pipe no handler writes to, which looks exactly like
    /// an engine that ignores signals.
    public func route(to action: @escaping @Sendable (Int32) -> Void) {
        precondition(readEnd >= 0, "route(to:) before capture(_:) would observe nothing")
        let descriptor = readEnd
        routing.withLockedValue { routing in
            routing.action = action
            guard routing.source == nil else { return }
            let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
            source.setEventHandler { [self] in deliver() }
            routing.source = source
            source.resume()
        }
    }

    /// Hands every byte the pipe holds to the current action, one at a time.
    ///
    /// **The inner loop is the load-bearing one, and an earlier revision of this
    /// comment credited the outer one.** A read source reports readability, not
    /// a count, so two signals close together arrive as one wake-up carrying two
    /// bytes -- one `read`, two bytes, two actions. Dispatching only `buffer[0]`
    /// loses the escalation an operator's second `SIGTERM` is, and
    /// `ShutdownSignalsTests.testTheRelayLosesNothingRaisedBeforeItsActionOrBehindIt`
    /// catches exactly that: MEASURED, that mutation reports `got [30, 31]` --
    /// `SIGUSR1, SIGUSR2`, with the second `SIGUSR1` gone.
    ///
    /// **The outer loop is a belt no test can distinguish, recorded rather than
    /// left to be discovered.** MEASURED: replaced with a single `read` per
    /// wake-up, that same suite stays green, because the source is
    /// level-triggered and fires again while the pipe still holds anything. It
    /// earns its place only where that is not enough -- more than 64 signals
    /// queued at once, or a byte written between the `read` and the source
    /// re-arming -- and nothing can drive either from a test.
    private func deliver() {
        var buffer = [UInt8](repeating: 0, count: 64)
        while true {
            let count = buffer.withUnsafeMutableBytes { read(readEnd, $0.baseAddress, $0.count) }
            guard count > 0 else { return }
            let action = routing.withLockedValue { $0.action }
            for byte in buffer[0..<count] {
                action?(Int32(byte))
            }
        }
    }
}

/// Why a process could not take charge of its own shutdown signals.
public enum ShutdownSignalsError: Error, CustomStringConvertible {
    /// `pipe`, `fcntl` or `sigaction` refused, carrying its `errno`.
    case captureRefused(signals: [Int32], code: Int32)
    /// The install reported success and left no pipe, which cannot happen and
    /// is checked anyway: the alternative is a relay that observes nothing and
    /// looks exactly like an engine ignoring every signal.
    case noPipe

    public var description: String {
        switch self {
        case .captureRefused(let signals, let code):
            return "could not capture \(signals): \(String(cString: strerror(code)))"
        case .noPipe:
            return "the signal capture reported success without a pipe to read"
        }
    }
}
