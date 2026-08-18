import Darwin
import Foundation
import GRPC
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import XCTest

@testable import ArcaEngine

/// That the guard which stops `serve()` hanging cannot also kill a healthy shutdown.
///
/// **The engine waits on its accepted connections draining, and only the first signal completes
/// that wait.** So a listening socket closing for any other reason would leave the process
/// waiting forever while holding the flock that makes `EngineServer.start` refuse the path to a
/// successor -- an engine that can neither serve nor be replaced. The guard against that reads
/// "the listener closed and nothing asked for it", and it is one `guard` away from being a
/// disaster: keyed wrongly, it fires on EVERY graceful shutdown, mid-drain, and turns a clean
/// stop into `EXIT_FAILURE`.
///
/// **What makes the guard safe is an ordering, and these tests are what measure it.** The signal
/// handler records the request as the CONDITION of the branch that then initiates the shutdown,
/// so by the time the resulting close reaches the observer the request is always recorded. That
/// is structural in the handler; it is not structural in the rule, and a refactor could invert
/// it without looking wrong.
///
/// **WHAT THESE TESTS DO NOT PIN, said plainly because the alternative is a reader assuming
/// otherwise.** They exercise `ShutdownRequests` and the NIO/grpc-swift semantics the rule rests
/// on, wired here the way `ServeCommand.serve` wires them -- not `serve()` itself, which is
/// private to the executable and reaches `VmnetNetwork` through `run()`, so it needs an
/// entitlement and a host vmnet. Changing `serve()`'s own wiring would not fail these. What
/// would fail them is the thing most likely to happen: a dependency bump that changed when
/// `onClose` completes relative to quiescence.
final class ShutdownObserverTests: XCTestCase {
    private var group: MultiThreadedEventLoopGroup!

    /// The paths and raw peers these tests need. See `SocketFixtures`, which is
    /// where the path generator and the silent-peer connect now live.
    private let sockets = SocketFixtures()

    override func setUp() {
        super.setUp()
        group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    }

    override func tearDown() {
        XCTAssertNoThrow(try group.syncShutdownGracefully())
        sockets.removeAll()
        super.tearDown()
    }

    private func testSocketPath() -> String {
        sockets.path(prefix: "arca-shutdown-observer")
    }

    private func connectRawSocket(to path: String) throws -> Int32 {
        try sockets.connectRawSocket(to: path)
    }

    /// The observer, wired as `serve()` wires it, reporting whether it would have exited.
    ///
    /// `exit()` cannot run inside a test process, so what is measured is the branch taken.
    private func installObserver(
        _ engine: EngineServer,
        _ asked: ShutdownRequests,
        wouldExit: NIOLockedValueBox<Bool>,
        ran: NIOLockedValueBox<Bool>
    ) {
        engine.onClose.whenComplete { _ in
            ran.withLockedValue { $0 = true }
            guard !asked.anyRecorded else { return }
            wouldExit.withLockedValue { $0 = true }
        }
    }

    /// The load-bearing case: a graceful shutdown with a peer holding the drain open.
    ///
    /// `onClose` completes here long before `quiesced` does -- that is the whole reason the
    /// engine stopped waiting on it -- so this is precisely when a mis-keyed guard would fire.
    ///
    /// **The peer is a held `Exec` because `SilentConnectionQuiescer` took the raw silent
    /// socket's power to hold anything.** This test used to connect a silent socket, and after
    /// that handler landed the engine closes such a peer the moment it is asked to quiesce --
    /// so `onClose` and quiescence completed together and the premise in the paragraph above
    /// was no longer true of the fixture, while the test went on passing. An RPC in flight is
    /// now the only thing that holds a graceful shutdown open; see `SocketFixtures.holdAnExecOpen`.
    ///
    /// **The timing above is ASSERTED rather than described, and it was not until fix round 1.**
    /// `drained` is what makes the fixture load-bearing: nothing here failed when the peer
    /// stopped holding anything, which is how the docstring came to say "long before" about two
    /// events that had started completing together. With `drained` checked at the same instant
    /// as `ran`, the pair IS the premise -- the listener has closed and quiescence has not --
    /// and swapping this peer back to `connectRawSocket` turns the test red instead of leaving
    /// it green against a sentence that has stopped being true.
    func testTheObserverDoesNotFireOnAGracefulShutdownWithAHeldPeer() async throws {
        let path = testSocketPath()
        let engine = try await EngineServer.start(
            socketPath: path, service: .forTesting(), group: group)
        let peer = sockets.holdAnExecOpen(to: path, group: group)
        try await Task.sleep(nanoseconds: 300_000_000)

        let asked = ShutdownRequests()
        let wouldExit = NIOLockedValueBox(false)
        let ran = NIOLockedValueBox(false)
        installObserver(engine, asked, wouldExit: wouldExit, ran: ran)

        // Recorded first, then initiated -- the order the handler makes structural.
        XCTAssertTrue(asked.recordAndReportFirst())
        let drained = NIOLockedValueBox(false)
        engine.beginGracefulShutdown().whenComplete { _ in drained.withLockedValue { $0 = true } }
        try await Task.sleep(nanoseconds: 500_000_000)

        XCTAssertTrue(
            ran.withLockedValue { $0 },
            "the listener must have closed, or this test asserts nothing at all"
        )
        XCTAssertFalse(
            drained.withLockedValue { $0 },
            """
            the drain completed while the peer still held an Exec open, so this test is no \
            longer standing in the window it exists to cover: onClose and quiescence are \
            completing together, and a mis-keyed guard would no longer be caught here.
            """
        )
        XCTAssertFalse(
            wouldExit.withLockedValue { $0 },
            "the guard fired on a healthy graceful shutdown, which would exit non-zero mid-drain"
        )

        try await peer.release()
        try await engine.shutDown()
    }

    /// The control, and without it the assertion above passes against a dead observer.
    func testTheObserverFiresWhenNoShutdownWasRecorded() async throws {
        let path = testSocketPath()
        let engine = try await EngineServer.start(
            socketPath: path, service: .forTesting(), group: group)

        let asked = ShutdownRequests()
        let wouldExit = NIOLockedValueBox(false)
        let ran = NIOLockedValueBox(false)
        installObserver(engine, asked, wouldExit: wouldExit, ran: ran)

        engine.server.close(promise: nil)
        try await Task.sleep(nanoseconds: 500_000_000)

        XCTAssertTrue(
            wouldExit.withLockedValue { $0 },
            "a listener that closed with nothing asking for it must end the process"
        )
        try engine.releaseSocketPath()
    }

    /// That the ordering is load-bearing rather than incidental.
    ///
    /// Inverting it -- initiate, then record -- makes the observer reach the exit branch on a
    /// perfectly healthy shutdown. Asserted rather than printed: without this, a refactor that
    /// moved the record after the initiate would leave the two tests above green, and the first
    /// would silently become a test of nothing.
    func testInvertingTheOrderWouldKillAHealthyShutdown() async throws {
        let path = testSocketPath()
        let engine = try await EngineServer.start(
            socketPath: path, service: .forTesting(), group: group)
        let peer = try connectRawSocket(to: path)
        try await Task.sleep(nanoseconds: 300_000_000)

        let asked = ShutdownRequests()
        let wouldExit = NIOLockedValueBox(false)
        let ran = NIOLockedValueBox(false)
        installObserver(engine, asked, wouldExit: wouldExit, ran: ran)

        engine.beginGracefulShutdown()
        try await Task.sleep(nanoseconds: 200_000_000)
        _ = asked.recordAndReportFirst()
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertTrue(
            wouldExit.withLockedValue { $0 },
            "recording after the close must lose the race; if it does not, the ordering the "
                + "handler relies on is not what makes the guard safe and this suite is "
                + "measuring the wrong invariant"
        )

        close(peer)
        try await engine.shutDown()
    }
}
