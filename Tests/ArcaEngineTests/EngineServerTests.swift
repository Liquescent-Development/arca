import Foundation
import GRPC
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import XCTest
#if canImport(Darwin)
import Darwin
#endif
@testable import ArcaEngine

final class EngineServerTests: XCTestCase {
    /// Held as instance state, not test-local, so `tearDown()` -- a
    /// synchronous XCTest hook -- can close them with the blocking
    /// `syncShutdownGracefully()`/`wait()` pair. Both are `noasync` (calling
    /// them from inside an `async throws` test method is a compile error);
    /// this is the same split grpc-swift's own async-context tests use
    /// (GRPCNetworkFrameworkTests.swift's `tearDown()`). It also sidesteps a
    /// real race: closing with `try await server.close().get()` followed
    /// immediately by `try await group.shutdownGracefully()` intermittently
    /// logged "Cannot schedule tasks on an EventLoop that has already shut
    /// down" -- the async continuation for `close()` can resume before every
    /// callback chained on the same future has run. The blocking `.wait()`
    /// forms don't return until that chain is fully drained.
    private var group: MultiThreadedEventLoopGroup!
    private var engine: EngineServer?

    /// Every path any test in this class handed to `EngineServer` or bound
    /// itself, given back in `tearDown`. See `SocketFixtures`.
    private let sockets = SocketFixtures()

    override func setUp() {
        super.setUp()
        group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    }

    override func tearDown() {
        XCTAssertNoThrow(try engine?.server.close().wait())
        XCTAssertNoThrow(try group.syncShutdownGracefully())
        sockets.removeAll()
        super.tearDown()
    }

    private func testSocketPath() -> String {
        sockets.path(prefix: "arca-engine-test")
    }

    /// The socket carries the engine's whole authority, so it must not be
    /// reachable by another user on a shared machine.
    func testTheSocketIsCreatedOwnerOnly() async throws {
        let path = testSocketPath()

        engine = try await EngineServer.start(
            socketPath: path,
            service: .forTesting(),
            group: group
        )

        let mode = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber
        XCTAssertEqual((mode?.uint16Value ?? 0) & 0o777, 0o600)
    }

    /// A stale socket file from a killed engine must not make the next start
    /// fail. Removing it is safe only because nothing is listening on it.
    ///
    /// The fixture must be an actual socket-typed file, not a plain file: a
    /// killed process leaves behind the socket special file it bound to,
    /// because nothing ever unlinked it. `EngineServer` itself refuses to
    /// unlink a path that is not a socket (EngineServer.swift), so a
    /// plain-file fixture here would be testing the opposite of "stale
    /// socket."
    func testAStaleSocketFileDoesNotBlockStartup() async throws {
        let path = testSocketPath()
        try Self.bindSocket(at: path, listening: false)

        engine = try await EngineServer.start(
            socketPath: path,
            service: .forTesting(),
            group: group
        )
    }

    /// A socket with something still listening on it is NOT stale, and taking
    /// it would leave the incumbent alive on an inode nothing can dial again.
    ///
    /// This is the case the type check alone could not see: an `lstat` cannot
    /// tell a dead engine's leftover from a live one's socket, and the earlier
    /// implementation unlinked both.
    func testALiveListenerOnThePathIsRefusedRatherThanUnlinked() async throws {
        let path = testSocketPath()
        let incumbent = try Self.bindSocket(at: path, listening: true)
        defer { close(incumbent) }

        do {
            engine = try await EngineServer.start(
                socketPath: path,
                service: .forTesting(),
                group: group
            )
            XCTFail("starting on a path with a live listener must fail")
        } catch let error as EngineServerError {
            guard case .pathHasALiveListener = error else {
                return XCTFail("wrong refusal: \(error)")
            }
        }

        // The incumbent's socket is still the one at the path.
        var status = stat()
        XCTAssertEqual(lstat(path, &status), 0, "the live socket must not have been unlinked")
    }

    /// Two engines cannot serve the same path. The lock, not the socket file,
    /// is what decides -- it is held by a live process and released by a dead
    /// one, with no inference in between.
    func testASecondEngineIsRefusedWhileTheFirstIsAlive() async throws {
        let path = testSocketPath()
        engine = try await EngineServer.start(
            socketPath: path,
            service: .forTesting(),
            group: group
        )
        let firstInode = try Self.inode(of: path)

        let second = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { XCTAssertNoThrow(try second.syncShutdownGracefully()) }

        do {
            _ = try await EngineServer.start(
                socketPath: path,
                service: .forTesting(),
                group: second
            )
            XCTFail("a second engine must not take a live engine's path")
        } catch let error as EngineServerError {
            guard case .pathIsHeldByALiveEngine(_, let holder) = error else {
                return XCTFail("wrong refusal: \(error)")
            }
            XCTAssertEqual(holder, "\(getpid())", "the refusal must name the holder")
        }

        XCTAssertEqual(
            try Self.inode(of: path),
            firstInode,
            "the first engine's socket must still be the one at the path"
        )
    }

    /// After a shutdown the path is free for the next engine: no socket file,
    /// and the lock released.
    ///
    /// The second assertion is the one with teeth. The socket's disappearance
    /// is not this code's doing -- MEASURED: closing the server unlinks it, so
    /// this half passes with `shutDown`'s own removal step deleted, and it is
    /// asserted as a property of the shutdown rather than as proof of a line.
    /// Releasing the lock has no other owner: with `lock.release()` removed the
    /// successor below cannot start, which is what makes this test capable of
    /// failing.
    ///
    /// What both halves together stand for is the artifact the old
    /// implementation left on every single exit, because it had no shutdown
    /// path at all.
    func testAfterShuttingDownTheNextEngineCanTakeThePath() async throws {
        let path = testSocketPath()
        let first = try await EngineServer.start(
            socketPath: path,
            service: .forTesting(),
            group: group
        )

        try await first.shutDown()

        var status = stat()
        XCTAssertNotEqual(lstat(path, &status), 0, "no socket may be left at the path")

        let second = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let successor = try await EngineServer.start(
            socketPath: path,
            service: .forTesting(),
            group: second
        )
        try await successor.shutDown()
        try await second.shutdownGracefully()
    }

    /// `runUntilQuiesced` returns when the ACCEPTED connections have drained,
    /// not when the listening socket closes.
    ///
    /// **This is the test the executable could not have.** `ServeCommand.serve`
    /// is private and `run()` constructs a real `VmnetNetwork`, so proving this
    /// there needs an entitlement and a host vmnet. The mutation that matters --
    /// awaiting `onClose` instead of the drain, which is the pre-fix behaviour
    /// exactly -- left `swift test --filter ArcaEngineTests` at `Executed 167
    /// tests, with 0 failures` while the wait lived there, and Gas Can's live
    /// tier was the only thing that caught it. Every measurement behind that is
    /// recorded on `runUntilQuiesced` itself.
    ///
    /// **The accept race is SETUP, not assertion, and it fails safe.** An
    /// unaccepted connection lets the drain complete immediately, so the pending
    /// assertion goes red rather than falsely green.
    ///
    /// `closed` is the control, and without it the second assertion passes
    /// against a shutdown that never started. It is a `whenComplete` rather than
    /// `onClose.wait()` because `wait()` is `noasync` (swift-nio's
    /// `EventLoopFuture.swift:1090`) and so cannot be called from an `async`
    /// test method at all; `ShutdownObserverTests` takes the same control from
    /// its `ran` box.
    func testRunUntilQuiescedWaitsForAcceptedConnectionsNotTheListener() async throws {
        let path = testSocketPath()
        let engine = try await EngineServer.start(
            socketPath: path,
            service: .forTesting(),
            group: group
        )
        let peer = try sockets.connectRawSocket(to: path)
        try await Task.sleep(nanoseconds: 300_000_000)

        let closed = NIOLockedValueBox(false)
        engine.onClose.whenComplete { _ in closed.withLockedValue { $0 = true } }

        let quiesced = group.next().makePromise(of: Void.self)
        let returned = NIOLockedValueBox(false)
        let waiting = Task {
            try await engine.runUntilQuiesced(connectionsDrained: quiesced.futureResult)
            returned.withLockedValue { $0 = true }
        }

        engine.server.initiateGracefulShutdown(promise: quiesced)
        try await Task.sleep(nanoseconds: 500_000_000)

        XCTAssertTrue(
            closed.withLockedValue { $0 },
            "the listener must have closed, or this test asserts nothing at all"
        )
        XCTAssertFalse(
            returned.withLockedValue { $0 },
            """
            runUntilQuiesced returned while an accepted connection was still open. \
            That is the pre-fix behaviour: it waited on the LISTENING socket, which \
            ServerQuiescingHelper closes synchronously, and shut the event-loop \
            group down under live channels.
            """
        )

        close(peer)
        try await waiting.value
        XCTAssertTrue(
            returned.withLockedValue { $0 },
            "once the peer is gone the drain completes and the wait must return"
        )
    }

    /// Binds a raw AF_UNIX socket to `path`.
    ///
    /// Closed without unlinking and without listening, this leaves exactly the
    /// artifact a killed engine would: a socket-typed file with nothing behind
    /// it. Left open and listening, it is an incumbent engine.
    @discardableResult
    private static func bindSocket(at path: String, listening: Bool) throws -> Int32 {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        precondition(pathBytes.count <= 103, "socket path too long for sockaddr_un")
        withUnsafeMutableBytes(of: &address.sun_path) { rawPath in
            let base = rawPath.baseAddress!.assumingMemoryBound(to: CChar.self)
            for (index, byte) in pathBytes.enumerated() {
                base[index] = CChar(bitPattern: byte)
            }
            base[pathBytes.count] = 0
        }

        let bindResult = withUnsafePointer(to: &address) { addressPointer -> Int32 in
            addressPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.bind(descriptor, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            let code = errno
            close(descriptor)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }

        guard listening else {
            close(descriptor)
            return -1
        }
        guard Darwin.listen(descriptor, 1) == 0 else {
            let code = errno
            close(descriptor)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        return descriptor
    }

    private static func inode(of path: String) throws -> UInt64 {
        var status = stat()
        guard lstat(path, &status) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return status.st_ino
    }
}
