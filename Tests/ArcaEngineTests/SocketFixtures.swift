import Darwin
import Foundation
import GRPC
import NIOCore
import SandboxEngineProto
import XCTest

/// The socket paths a test created. Raw peers are connected here but owned by
/// the caller -- see `connectRawSocket` -- and `removeAll()` unlinks paths and
/// closes no descriptors.
///
/// One type rather than a copy per test class. `EngineServerTests` and
/// `ShutdownObserverTests` each declared their own path generator, and
/// `ShutdownObserverTests` its own raw connect; a duplicated fixture is how two
/// tests drift apart, and these two had already started to -- the `sun_path`
/// reasoning below was recorded against one copy and not the other, so nothing
/// stopped the second from growing a prefix that overflowed.
final class SocketFixtures {
    private var paths: [String] = []

    /// A socket path under `/tmp` that no other test will pick.
    ///
    /// `sockaddr_un.sun_path` holds at most 103 usable bytes (`SocketAddress.
    /// init(unixDomainSocketPath:)`, swift-nio's SocketAddresses.swift:352), and
    /// `NSTemporaryDirectory()` on macOS is a per-invocation path under
    /// `/var/folders/...` long enough that a descriptive prefix plus a UUID
    /// overflows it. `/tmp` is short enough to leave headroom and is the
    /// conventional location for Unix domain sockets for exactly this reason.
    func path(prefix: String) -> String {
        let path = "/tmp/\(prefix)-\(UUID().uuidString).sock"
        paths.append(path)
        return path
    }

    /// A raw peer, connected and silent.
    ///
    /// **This no longer holds the drain open, and until `SilentConnectionQuiescer`
    /// it was the only thing that did.** A peer that has sent nothing has
    /// negotiated no protocol, so no stream can exist and nothing is in flight;
    /// the engine now closes it the moment it is asked to quiesce. What this
    /// fixture is for is therefore the opposite of what it used to be for --
    /// `EngineServerTests.testAnAcceptedConnectionThatHasSaidNothingDoesNotHoldTheDrain`
    /// requires exactly that closing. Anything that needs a peer the shutdown
    /// must WAIT for wants [`holdAnExecOpen`] instead.
    ///
    /// **Two cheaper fixtures were tried against that requirement and neither
    /// works -- MEASURED, and recorded so they are not tried again.** One byte
    /// of the HTTP/2 preface leaves `HTTPVersionParser` at `.notEnoughBytes`, so
    /// `GRPCServerPipelineConfigurator` keeps buffering and never forwards it
    /// ("Don't forward the reads: we'll do so when we have configured the
    /// pipeline"); the byte never reaches `SilentConnectionQuiescer`, which
    /// reads the channel as silent and closes it. All 24 bytes do configure the
    /// pipeline, and then grpc-swift's own idle handler turns the quiesce into a
    /// GOAWAY and closes a connection with no open streams. Both left
    /// `testRunUntilQuiescedWaitsForAcceptedConnectionsNotTheListener` red on
    /// `XCTAssertNil failed: "returned"`, which is the drain completing.
    ///
    /// The second of those is no longer only a rejected attempt: that closing is
    /// itself a property worth pinning, and [`connectPrefacedSocket`] is the
    /// same peer used for what it does rather than for what it does not.
    ///
    /// The caller closes the descriptor: when it is released is the thing those
    /// tests are measuring, so this type must not decide it for them.
    ///
    /// It THROWS on a failed syscall rather than recording an XCTest failure and
    /// handing back the bad descriptor, which is what the two copies this
    /// replaces did. The returned peer decides the central assertion of the
    /// drain test, so a fixture that half-failed and continued would leave that
    /// test asserting against a connection it does not have.
    func connectRawSocket(to path: String) throws -> Int32 {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutablePointer(to: &address.sun_path) { raw in
            path.withCString { source in
                strncpy(UnsafeMutableRawPointer(raw).assumingMemoryBound(to: CChar.self), source, 103)
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &address) { raw in
            raw.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(descriptor, $0, size) }
        }
        guard result == 0 else {
            let code = errno
            close(descriptor)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }

        return descriptor
    }

    /// A raw peer that has sent the HTTP/2 connection preface and nothing after
    /// it: negotiated, with no stream open and no RPC in flight.
    ///
    /// **This is the peer that proves `SilentConnectionQuiescer` FORWARDS the
    /// quiesce event, and nothing else in this bundle can.** grpc-swift's
    /// `GRPCIdleHandler` is what turns `ChannelShouldQuiesceEvent` into a GOAWAY
    /// and closes a connection with no open streams, and it sits downstream of
    /// `SilentConnectionQuiescer` -- so it only ever sees the event because that
    /// handler passes it on. `GRPCIdleHandler.userInboundEventTriggered` then
    /// swallows it ("Swallow this event", grpc-swift 1.27
    /// `GRPCIdleHandler.swift`), which is why the forwarding has to happen at
    /// this end of the pipeline or not at all.
    ///
    /// A silent peer cannot show that: `SilentConnectionQuiescer` closes it
    /// itself, forwarded or not. Nor can a held `Exec`: its connection is closed
    /// by the client, so the drain completes either way. **MEASURED -- swallowing
    /// the event instead of forwarding it leaves every other test in this bundle
    /// green.**
    ///
    /// The 24 magic bytes are `HTTPVersionParser.http2ClientMagic` verbatim (RFC
    /// 7540 § 5.3); the nine after them are an empty `SETTINGS` frame, which is
    /// what a real client sends next and what makes this a well-formed
    /// connection rather than a prefix the server is still waiting to complete.
    ///
    /// The caller closes the descriptor, for the reason [`connectRawSocket`]
    /// gives: when the peer goes away is what these tests measure.
    func connectPrefacedSocket(to path: String) throws -> Int32 {
        let descriptor = try connectRawSocket(to: path)
        let preface: [UInt8] =
            Array("PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n".utf8)
            + [0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00]

        var sent = 0
        while sent < preface.count {
            let written = preface.withUnsafeBytes { bytes in
                write(descriptor, bytes.baseAddress!.advanced(by: sent), bytes.count - sent)
            }
            // A short write is legal and is resumed; only 0 or -1 is a failure.
            // Thrown rather than recorded, for `connectRawSocket`'s reason: a
            // half-written preface leaves the pipeline unconfigured, which is
            // the opposite of the peer this fixture promises.
            guard written > 0 else {
                let code = errno
                close(descriptor)
                throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
            }
            sent += written
        }
        return descriptor
    }

    /// A real gRPC client with an `Exec` call open and nothing sent on it, which
    /// the caller must hold for as long as the shutdown must wait.
    ///
    /// **An RPC in flight is the only thing that holds a graceful shutdown open,
    /// and after `SilentConnectionQuiescer` that is true by design rather than
    /// by accident.** grpc-swift closes a negotiated connection with no open
    /// streams when quiescing sends its GOAWAY, and the engine now closes one
    /// that has negotiated nothing; between them, a peer that is merely
    /// CONNECTED holds nothing. So a test of the window between the listener
    /// closing and quiescence completing has to open a stream, which means being
    /// a client -- hence `SandboxEngineProto` in this target's dependencies.
    ///
    /// `Exec` because it is bidirectionally streaming and because
    /// `SandboxEngineService.runExec` awaits the client's first frame before it
    /// does anything at all: sending none leaves the handler suspended and the
    /// stream open, with no container, no image and no VM involved. A unary
    /// method could not do this -- it answers and the stream ends.
    ///
    /// The returned value owns the connection and the call. Releasing it is what
    /// lets the drain finish, so the tests decide when, exactly as they do for
    /// the raw descriptor above.
    func holdAnExecOpen(to path: String, group: EventLoopGroup) -> HeldExec {
        // The `Configuration` initialiser rather than
        // `ClientConnection.insecure(group:).connect(...)`, because that builder
        // offers only `connect(host:port:)` and `withConnectedSocket(_:)` --
        // grpc-swift 1.27 exposes no Unix-domain-socket overload on it, though
        // `ConnectionTarget.unixDomainSocket(_:)` is public and is what the
        // configuration takes.
        var configuration = ClientConnection.Configuration.default(
            target: .unixDomainSocket(path),
            eventLoopGroup: group
        )
        // No backoff: a test that has just started this engine wants a failure
        // to dial to surface as a failed assertion, not to be retried quietly
        // until the test's own timeout.
        configuration.connectionBackoff = nil
        let connection = ClientConnection(configuration: configuration)
        let call: BidirectionalStreamingCall<
            Arca_Engine_V1_ExecClientFrame, Arca_Engine_V1_ExecServerFrame
        > = connection.makeBidirectionalStreamingCall(
            path: "/arca.engine.v1.SandboxEngine/Exec",
            callOptions: CallOptions()
        ) { _ in }
        return HeldExec(connection: connection, call: call)
    }

    /// One `Exec` call and the connection under it, released together.
    ///
    /// A type rather than a tuple because the order matters: cancelling the call
    /// is what ends the RPC the server is suspended in, and closing the
    /// connection first would tear the stream down underneath it.
    struct HeldExec {
        let connection: ClientConnection
        let call: BidirectionalStreamingCall<
            Arca_Engine_V1_ExecClientFrame, Arca_Engine_V1_ExecServerFrame
        >

        /// Awaited rather than fired and forgotten, because the caller's next
        /// move is usually `tearDown`'s `syncShutdownGracefully()`. Discarding
        /// the close future leaves the client channel going down while the
        /// event-loop group is being shut down under it -- the "Cannot schedule
        /// tasks on an EventLoop that has already shut down" race this class's
        /// own header describes, arrived at from the client end.
        ///
        /// It THROWS rather than swallowing: a connection that cannot be closed
        /// is something the test should report, not absorb.
        func release() async throws {
            call.cancel(promise: nil)
            try await connection.close().get()
        }
    }

    /// Unlinks every path handed out, and its lockfile.
    ///
    /// `/tmp` is not swept outside a reboot, so a test that leaves its socket and
    /// lockfile behind grows the directory on every run of the suite -- on a
    /// developer's machine and on CI alike.
    func removeAll() {
        for path in paths {
            unlink(path)
            unlink(path + ".lock")
        }
        paths = []
    }
}
