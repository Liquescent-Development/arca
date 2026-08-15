import Foundation
import GRPC
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
#if canImport(Darwin)
import Darwin
#endif

/// A bound engine, together with the two resources whose lifetime is the
/// server's: the exclusive claim on the socket path, and the socket file.
///
/// These are one type rather than three because their correct lifetimes are
/// identical, and separating them is how the two defects this replaces came
/// about: nothing owned the socket file, so nothing unlinked it on the way out,
/// and nothing owned the path, so a second engine could take it from a first.
public struct EngineServer: Sendable {
    /// The bound gRPC server. Exposed because callers install their own
    /// shutdown trigger against it.
    public let server: Server

    private let socketPath: String
    private let lock: SocketPathLock
    private let drain: Drain

    /// Completes when the server has finished closing, however that was
    /// initiated.
    public var onClose: EventLoopFuture<Void> { server.onClose }

    /// Completes when every ACCEPTED connection has drained, which is a
    /// different event from `onClose` -- see `runUntilQuiesced`, which is the
    /// only thing that should be waiting on it. Exposed for the one caller that
    /// has to bound the drain from outside: `arca-engine` schedules its grace
    /// period against this and cancels it when this completes.
    public var drained: EventLoopFuture<Void> { drain.promise().futureResult }

    /// Starts the engine on `socketPath`.
    ///
    /// Claiming the path comes first and is the load-bearing step. An earlier
    /// revision decided "stale" from the file's type alone -- `lstat`, check
    /// `S_IFSOCK`, unlink -- which cannot distinguish a socket a dead engine
    /// left behind from one a live engine is serving on. A second engine
    /// started on the same path therefore unlinked the first's socket and bound
    /// its own, with no error and no warning; the first stayed alive holding
    /// its StateStore handle and (in later milestones) live VMs, listening on
    /// an inode nothing could dial again.
    ///
    /// Two checks replace it, because neither covers the other's gap:
    ///
    /// - An exclusive `flock` on a lockfile beside the socket. The kernel drops
    ///   it when the holder dies, so "can I take this lock" *is* "did the last
    ///   engine survive", with no heuristic in between. It is also atomic, which
    ///   closes the window between deciding to unlink and binding -- two engines
    ///   racing from a cold start cannot both pass it.
    /// - A `connect()` probe of the existing socket. The lock only knows about
    ///   engines that take it; the probe answers for anything else listening
    ///   there, which is what stops a mistyped path pointing at another
    ///   program's live socket from being unlinked.
    ///
    /// Only after both agree the path is free is a leftover socket removed, and
    /// only if it is a socket -- refusing to unlink a regular file keeps a
    /// mistyped path from destroying data.
    ///
    /// The socket is chmodded to 0600 immediately after `bind` returns, because
    /// the socket carries the engine's entire authority. `bind` itself returns
    /// an already-listening server, so there is a brief window between the
    /// listener accepting and the mode change landing -- this call does not
    /// close that window. The real control is the containing directory: the
    /// caller (the `arca-engine` executable) creates it mode 0700 before
    /// calling this, so nothing other than the socket's owner can even reach
    /// the path to connect during that window.
    public static func start(
        socketPath: String,
        service: SandboxEngineService,
        group: EventLoopGroup
    ) async throws -> EngineServer {
        let lock = try SocketPathLock.acquire(forSocketAt: socketPath)
        try removeStaleSocket(at: socketPath)

        let server: Server
        do {
            server = try await Server.insecure(group: group)
                .withServiceProviders([service])
                .bind(unixDomainSocketPath: socketPath)
                .get()
        } catch {
            try? lock.release()
            throw error
        }

        do {
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o600))],
                ofItemAtPath: socketPath
            )
        } catch {
            // `bind` returned an already-accepting server. Leaving it up on a
            // path whose mode is unknown is the one outcome worse than failing
            // to start, so unwind it before reporting.
            try? await server.close().get()
            try? lock.release()
            throw error
        }

        return EngineServer(
            server: server,
            socketPath: socketPath,
            lock: lock,
            drain: Drain(eventLoop: group.next())
        )
    }

    /// Asks the accepted connections to quiesce, and hands back the future that
    /// completes when they have drained.
    ///
    /// **This exists so that `runUntilQuiesced` has no caller-supplied future to
    /// get wrong, and that is the whole reason for the shape.** While the wait
    /// took an `EventLoopFuture<Void>` parameter, `arca-engine` could pass
    /// `engine.onClose` -- a public property of that exact type on that exact
    /// object, one identifier away -- and reinstate the pre-fix defect at the
    /// CALL SITE with the entire suite green. MEASURED at `723875a`, by a
    /// reviewer rather than by me:
    /// `runUntilQuiesced(connectionsDrained: engine.onClose)` gave `Executed 168
    /// tests, with 0 failures`.
    ///
    /// **That mutation is now a compile error rather than a caught failure**,
    /// which is the stronger of the two outcomes -- there is no argument to get
    /// wrong. Re-applied against this shape it gives
    /// `ArcaEngineCommand.swift:284:70: error: argument passed to call that
    /// takes no arguments`. Initiating and waiting are two halves of one object
    /// and neither takes a future from anyone.
    ///
    /// **Call this at most once.** `initiateGracefulShutdown` completes the
    /// promise it is handed, and handing the same promise over twice would
    /// complete it twice. `arca-engine` guarantees it structurally: the call sits
    /// inside `if asked.recordAndReportFirst()`, and a second signal takes the
    /// escalation branch instead, which closes the listener rather than draining.
    @discardableResult
    public func beginGracefulShutdown() -> EventLoopFuture<Void> {
        let promise = drain.promise()
        server.initiateGracefulShutdown(promise: promise)
        return promise.futureResult
    }

    /// Serves until every accepted connection has drained, then closes and gives
    /// up the socket path.
    ///
    /// It waits on the drain `beginGracefulShutdown` starts, and takes no
    /// argument on purpose -- see that method for the measurement that removed
    /// the parameter.
    ///
    /// **This is not a pure wait.** It calls `shutDown()`, so it returns with the
    /// server closed, the socket unlinked and the path lock released. A caller
    /// that wants to observe the drain without ending the engine needs a
    /// different method, not a flag on this one.
    /// `testRunUntilQuiescedReleasesThePathItServedOn` is what holds that half:
    /// with `shutDown()` deleted the lock is never released, and the successor
    /// that test starts on the same path is refused.
    ///
    /// **Do not create the drain promise in `start()`, and that bound is
    /// measured rather than reasoned about.** Storing `quiesced` as a `let` made
    /// in `start()` is the obvious tidier refactor and it is unbuildable: every
    /// `EngineServerTests` case starts an engine and never quiesces it, so every
    /// one of them would deallocate an uncompleted promise. MEASURED with
    /// exactly that change applied -- `ArcaEngine/EngineServer.swift:101: Fatal
    /// error: leaking promise created at ...`, and the test binary died on the
    /// FIRST test to run with `unexpected signal code 5`. Not a failing test: no
    /// results at all for any test in the class. The check is
    /// `EventLoopFuture.deinit`, which under `debugOnly` calls `fatalError` when
    /// a future deallocates with no value (swift-nio's
    /// `EventLoopFuture.swift:479`).
    ///
    /// **A promise created when a shutdown is INITIATED is not that hazard, and
    /// an earlier revision of this paragraph wrongly said it was.** It headlined
    /// "do not move the promise onto `EngineServer`" full stop, which
    /// generalised a measurement about `start()` into a verdict on the whole
    /// design family -- and would have foreclosed `beginGracefulShutdown`, the
    /// fix for a defect this comment sits above. `Drain` makes the promise on
    /// first ask by either half, so an engine nothing shuts down never creates
    /// one and has nothing to leak.
    ///
    /// **What this waits for is every ACCEPTED connection to have gone, and
    /// that is a different event from the listening socket closing.** It used to
    /// wait for `onClose`, which is the LISTENING channel's `closeFuture`, and
    /// `ServerQuiescingHelper` closes that immediately -- before the connections
    /// it has just asked to quiesce have finished doing so. So
    /// `ServeCommand.run()` shut the event-loop group down underneath live
    /// channels: each one's `closeFuture` callback then tried to schedule
    /// `ChannelCollector.channelRemoved` on a loop that had gone, which NIO
    /// reports as `Cannot schedule tasks on an EventLoop that has already shut
    /// down`; the collector therefore never reached `shutdownCompleted()`, and
    /// deallocated still holding the promise it makes at
    /// `QuiescingHelper.swift:141` -- `Fatal error: leaking promise`,
    /// `Trace/BPT trap: 5`, exit 133.
    ///
    /// **Every rate below was measured against binaries whose
    /// `ServeCommand.serve` performed this wait inline, not against this
    /// method.** They are evidence about waiting on the drain rather than on
    /// `onClose`; they are not evidence that this method is protected, and what
    /// protects it is named at the end of this comment.
    ///
    /// MEASURED with Gas Can's `shutdown.rs`, which stops 32 engines per figure
    /// because at this rate a single clean shutdown is worth nothing. Two
    /// binaries built from the code this replaces, run interleaved rather than
    /// A-then-B: awaiting `onClose`, **6 crashes in 192**; awaiting the drain,
    /// **0 in 192**. The container case, 32 engines each: **12/32 (38%)**
    /// against `onClose`.
    ///
    /// **The defect never needed a container.** `docs/status/START-HERE.md`
    /// recorded it as happening "once containers have been created", and that
    /// was a correlate: an engine that never created one still crashed 1 time in
    /// 96. A container widens the window -- more accepted traffic, more to tear
    /// down -- it does not change the bug.
    ///
    /// **Handing `initiateGracefulShutdown` a promise rather than `nil` is a
    /// consequence of the wait and NOT the fix**, and that was measured rather
    /// than argued. A third binary that passes the promise in and still awaits
    /// `onClose` -- the promise made, never waited on -- runs at **22/32 (69%)**,
    /// WORSE than the original. The crash does not go quiet, it changes address:
    /// the leaked promise stops being the collector's at
    /// `QuiescingHelper.swift:141` and becomes the one `ServeCommand.serve`
    /// makes, which the trace names as `ArcaEngineCommand.swift`. The `Cannot
    /// schedule tasks` line is unchanged throughout, and that is the tell -- the
    /// group is still going down under live channels, and only the bookkeeping
    /// moved.
    ///
    /// **AN EARLIER VERSION OF THIS COMMENT, WHILE IT LIVED IN
    /// `ArcaEngineCommand.swift`, SAID "NOTHING IN THIS REPOSITORY CAN PROVE ANY
    /// OF IT". THAT WAS FALSE AND A REVIEWER DISPROVED IT BY WRITING THE TEST.**
    /// The argument given was that a raw socket cannot be observed to have been
    /// accepted, so the fixture would decide the assertion by a race. The race is
    /// real but it is SETUP, not assertion, and it fails safe: an unaccepted
    /// connection lets the close drain immediately, so the pending assertion goes
    /// red rather than falsely green. Measured 20 runs, 20 passes, on a
    /// single-threaded loop with `EngineServer.start` and
    /// `SandboxEngineService.forTesting()`.
    ///
    /// **The PREMISE is pinned now, and pinning it is why this function exists.**
    /// That the listener closes while an accepted connection is still open -- so
    /// `onClose` completes and the drain does not -- is what
    /// `EngineServerTests.testRunUntilQuiescedWaitsForAcceptedConnectionsNotTheListener`
    /// drives, against a real `EngineServer` and a raw peer holding the drain
    /// open.
    ///
    /// **THE CALL SITE'S WRONG-ARGUMENT HALF IS CLOSED BY CONSTRUCTION AND THE
    /// REST OF IT IS STILL NOT PINNED.** While this took a future,
    /// `arca-engine` could pass `engine.onClose` and restore the defect at the
    /// call site with the suite green -- MEASURED at `723875a` by a reviewer,
    /// `Executed 168 tests, with 0 failures`. There is now no argument to get
    /// wrong. What no test still reaches is that `ServeCommand.serve` calls this
    /// at all: privacy is not what stops it -- `EngineProcess.swift` already
    /// spawns the binary to prove call sites -- but `ServeCommand.run()` reaches
    /// `networkManager.initialize()`, which constructs a real `VmnetNetwork`, so
    /// it needs an entitlement and a host vmnet.
    ///
    /// **The mutation that matters -- awaiting `onClose` below instead of
    /// `drained` -- is what moving the wait here made visible, and both halves
    /// of that were measured rather than argued.** Applied where the wait used
    /// to live, to `try await quiesced.futureResult.get()` in
    /// `ServeCommand.serve` at `fa1d707`, `swift test --filter ArcaEngineTests`
    /// reported `Executed 167 tests, with 0 failures`: the defect fully restored
    /// and the suite entirely green, with Gas Can's live tier the only
    /// instrument that caught it. Applied to the first line below instead:
    /// `Executed 169 tests, with 1 failure` --
    /// `testRunUntilQuiescedWaitsForAcceptedConnectionsNotTheListener`'s
    /// `XCTAssertNil failed: "returned"`, and no other test moved.
    ///
    /// **Deleting the second line was green until fix round 1, and half of what
    /// moved here had no test.** It now gives `Executed 169 tests, with 1
    /// failure`: `testRunUntilQuiescedReleasesThePathItServedOn` catches
    /// `refusing to serve on ...: the engine with pid ... already holds it`,
    /// because nothing released the lock. Restored, `Executed 169 tests, with 0
    /// failures`.
    public func runUntilQuiesced() async throws {
        try await drained.get()
        try await shutDown()
    }

    /// Closes the server, makes sure the socket is gone, and releases the path.
    ///
    /// MEASURED: closing the server already unlinks the socket file. A probe
    /// that closed the server and then stat'd the path found it absent before
    /// this method's own removal step ran. `removeOwnSocket()` is therefore a
    /// backstop for a close that does not get that far, not the mechanism, and
    /// no test can distinguish its presence from its absence. It is kept
    /// because the socket carries the engine's authority and the alternative is
    /// depending on an undocumented side effect of a dependency -- and it is
    /// documented as redundant so nobody later reads it as the working part.
    ///
    /// The defect this method exists for was that nothing called any of this:
    /// the process had no shutdown path, so the only way it ended was by being
    /// killed, which runs no close and therefore no unlink.
    ///
    /// Removing the socket is this process's to do: it was created by `bind`,
    /// and the lock proves no one else has claimed the path since.
    ///
    /// The lockfile itself is deliberately *not* unlinked. Removing it would
    /// let a later engine create a fresh file at the same path while a holder
    /// still has the old inode locked, and two engines would each believe they
    /// held the path exclusively. An advisory lock is a property of an inode,
    /// so the inode has to outlive every holder.
    public func shutDown() async throws {
        // Requesting the close is idempotent on purpose: a caller that already
        // triggered a graceful shutdown and awaited `onClose` still calls this
        // for the cleanup half, and `close()` on a closed channel reports
        // `alreadyClosed`. The promise is dropped rather than inspected because
        // it is not the postcondition -- `onClose` is, and it is awaited next.
        server.close(promise: nil)
        try await onClose.get()
        try releaseSocketPath()
    }

    /// Removes the socket and gives up the claim on its path, without waiting
    /// for the server to finish closing.
    ///
    /// The cleanup half of `shutDown()` on its own, for the one caller that
    /// cannot afford the other half: an operator signalling a second time is
    /// escalating past a wait for accepted connections to close, so a teardown
    /// that began by awaiting the very thing being escalated past would be no
    /// escalation at all. `arca-engine`'s shutdown handler calls this and then
    /// ends the process.
    ///
    /// The two steps live here rather than being repeated at that call site so
    /// the ordinary and the escalated path cannot drift into releasing
    /// different things.
    public func releaseSocketPath() throws {
        try removeOwnSocket()
        try lock.release()
    }

    private func removeOwnSocket() throws {
        var status = stat()
        guard lstat(socketPath, &status) == 0 else { return }
        guard (status.st_mode & S_IFMT) == S_IFSOCK else { return }
        try FileManager.default.removeItem(atPath: socketPath)
    }

    private static func removeStaleSocket(at path: String) throws {
        var status = stat()
        guard lstat(path, &status) == 0 else { return }
        guard (status.st_mode & S_IFMT) == S_IFSOCK else {
            throw EngineServerError.pathIsNotASocket(path)
        }
        guard try !hasALiveListener(at: path) else {
            throw EngineServerError.pathHasALiveListener(path)
        }
        try FileManager.default.removeItem(atPath: path)
    }

    /// Whether anything is accepting connections on `path`.
    ///
    /// The socket is non-blocking so a listener whose accept backlog is full
    /// answers `EAGAIN` immediately rather than parking engine startup on a
    /// `connect` that may never return. A full backlog means a live listener,
    /// so it counts as one. `ECONNREFUSED` is the answer for a socket file
    /// whose listener is gone -- the stale case -- and `ENOENT` means it was
    /// removed between the `lstat` above and here, which is equally free.
    static func hasALiveListener(at path: String) throws -> Bool {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        try encode(path, into: &address)

        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw EngineServerError.systemCallFailed(name: "socket", path: path, code: errno)
        }
        defer { close(descriptor) }

        guard fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0 else {
            throw EngineServerError.systemCallFailed(name: "fcntl", path: path, code: errno)
        }

        let result = withUnsafePointer(to: &address) { addressPointer -> Int32 in
            addressPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                connect(descriptor, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if result == 0 { return true }

        switch errno {
        case ECONNREFUSED, ENOENT:
            return false
        case EAGAIN, EINPROGRESS:
            return true
        default:
            throw EngineServerError.systemCallFailed(name: "connect", path: path, code: errno)
        }
    }

    /// Copies `path` into `sun_path`, refusing a path that does not fit.
    ///
    /// `sockaddr_un.sun_path` holds at most 103 usable bytes plus a terminator.
    /// A longer path is rejected here rather than truncated: a truncated path
    /// would make the probe answer about a *different* socket, which is the one
    /// way this check could report "free" about a path that is held.
    private static func encode(_ path: String, into address: inout sockaddr_un) throws {
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path) - 1
        guard bytes.count <= capacity else {
            throw EngineServerError.socketPathTooLong(path, limit: capacity)
        }
        withUnsafeMutableBytes(of: &address.sun_path) { rawPath in
            let base = rawPath.baseAddress!.assumingMemoryBound(to: CChar.self)
            for (index, byte) in bytes.enumerated() {
                base[index] = CChar(bitPattern: byte)
            }
            base[bytes.count] = 0
        }
    }
}

/// The one promise a graceful shutdown completes, shared by the half that
/// starts the drain and the half that waits for it.
///
/// **A class because `EngineServer` is a value type and both halves must reach
/// the same promise**, whichever runs first: `arca-engine` calls
/// `runUntilQuiesced` from `serve()` and `beginGracefulShutdown` from a signal
/// handler minutes later, and a test calls them in the opposite order. Creating
/// the promise on first ask rather than in `init` is what makes that order
/// irrelevant.
///
/// **It is also what keeps the promise out of `start()`.** A promise made for
/// every engine is leaked by every engine nothing shuts down, which is every
/// case in `EngineServerTests` -- and NIO turns that into a dead test binary
/// rather than a failing test. The measurement is on `runUntilQuiesced`. Here,
/// an engine that is never asked to quiesce never creates a promise at all.
final class Drain: Sendable {
    private let eventLoop: EventLoop
    private let made = NIOLockedValueBox<EventLoopPromise<Void>?>(nil)

    init(eventLoop: EventLoop) {
        self.eventLoop = eventLoop
    }

    /// The promise, created on the first call and returned unchanged after.
    ///
    /// The check and the store are one critical section, so two callers racing
    /// cannot end up holding different promises -- which would have the waiter
    /// waiting on one that nothing will ever complete.
    func promise() -> EventLoopPromise<Void> {
        made.withLockedValue { made in
            if let made { return made }
            let promise = eventLoop.makePromise(of: Void.self)
            made = promise
            return promise
        }
    }
}

/// An exclusive advisory lock on a socket path, held through a lockfile beside
/// it.
///
/// `@unchecked Sendable` because the descriptor and path are `let`s and the one
/// mutable field is a released-once flag touched only by the single owner that
/// `acquire` hands the lock to -- `EngineServer`, whose own shutdown is
/// sequential. It is not a general-purpose concurrent lock handle.
final class SocketPathLock: @unchecked Sendable {
    private let descriptor: Int32
    let path: String
    private var released = false

    private init(descriptor: Int32, path: String) {
        self.descriptor = descriptor
        self.path = path
    }

    /// Takes the lock for `socketPath`, or reports who holds it.
    ///
    /// The holder writes its pid into the file after locking, purely so the
    /// refusal can name a process. Reading it on the failure path is racy and
    /// diagnostic only -- the lock, not the contents, is what decides.
    static func acquire(forSocketAt socketPath: String) throws -> SocketPathLock {
        let path = socketPath + ".lock"
        let descriptor = open(path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            throw EngineServerError.systemCallFailed(name: "open", path: path, code: errno)
        }

        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(descriptor)
            guard code == EWOULDBLOCK else {
                throw EngineServerError.systemCallFailed(name: "flock", path: path, code: code)
            }
            throw EngineServerError.pathIsHeldByALiveEngine(
                socketPath,
                holder: (try? String(contentsOfFile: path, encoding: .utf8))?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            )
        }

        let lock = SocketPathLock(descriptor: descriptor, path: path)
        ftruncate(descriptor, 0)
        _ = "\(getpid())\n".withCString { pointer in
            write(descriptor, pointer, strlen(pointer))
        }
        return lock
    }

    func release() throws {
        guard !released else { return }
        released = true
        guard close(descriptor) == 0 else {
            throw EngineServerError.systemCallFailed(name: "close", path: path, code: errno)
        }
    }

    deinit {
        if !released { close(descriptor) }
    }
}

public enum EngineServerError: Error, CustomStringConvertible {
    case pathIsNotASocket(String)
    case pathIsHeldByALiveEngine(String, holder: String)
    case pathHasALiveListener(String)
    case socketPathTooLong(String, limit: Int)
    case systemCallFailed(name: String, path: String, code: Int32)

    public var description: String {
        switch self {
        case .pathIsNotASocket(let path):
            return "refusing to replace \(path): it exists and is not a socket"
        case .pathIsHeldByALiveEngine(let path, let holder):
            let who = holder.isEmpty ? "another engine" : "the engine with pid \(holder)"
            return "refusing to serve on \(path): \(who) already holds it"
        case .pathHasALiveListener(let path):
            return "refusing to replace \(path): something is listening on it"
        case .socketPathTooLong(let path, let limit):
            return "socket path \(path) exceeds the \(limit)-byte sockaddr_un limit"
        case .systemCallFailed(let name, let path, let code):
            return "\(name) failed on \(path): \(String(cString: strerror(code))) (errno \(code))"
        }
    }
}
