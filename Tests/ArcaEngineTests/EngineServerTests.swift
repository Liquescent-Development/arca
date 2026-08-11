import Foundation
import GRPC
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
    private var server: Server?

    override func setUp() {
        super.setUp()
        group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    }

    override func tearDown() {
        XCTAssertNoThrow(try server?.close().wait())
        XCTAssertNoThrow(try group.syncShutdownGracefully())
        super.tearDown()
    }

    /// `sockaddr_un.sun_path` holds at most 103 usable bytes (`SocketAddress.
    /// init(unixDomainSocketPath:)`, swift-nio's SocketAddresses.swift:352),
    /// and `NSTemporaryDirectory()` on macOS is a per-invocation path under
    /// `/var/folders/...` long enough that a descriptive prefix plus a UUID
    /// overflows it. `/tmp` is short enough to leave headroom and is the
    /// conventional location for Unix domain sockets for exactly this reason.
    private static func testSocketPath() -> String {
        "/tmp/arca-engine-test-\(UUID().uuidString).sock"
    }

    /// The socket carries the engine's whole authority, so it must not be
    /// reachable by another user on a shared machine.
    func testTheSocketIsCreatedOwnerOnly() async throws {
        let path = Self.testSocketPath()

        server = try await EngineServer.start(
            socketPath: path,
            service: .forTesting(),
            group: group
        )

        let mode = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber
        XCTAssertEqual((mode?.uint16Value ?? 0) & 0o777, 0o600)
    }

    /// A stale socket file from a killed engine must not make the next start
    /// fail. Removing it is safe only because the caller owns the path.
    ///
    /// The fixture must be an actual socket-typed file, not a plain file: a
    /// killed process leaves behind the socket special file it bound to,
    /// because nothing ever unlinked it. `EngineServer` itself refuses to
    /// unlink a path that is not a socket (EngineServer.swift), so a
    /// plain-file fixture here would be testing the opposite of "stale
    /// socket."
    func testAStaleSocketFileDoesNotBlockStartup() async throws {
        let path = Self.testSocketPath()
        try Self.createStaleSocketFile(at: path)

        server = try await EngineServer.start(
            socketPath: path,
            service: .forTesting(),
            group: group
        )
    }

    /// Binds a raw AF_UNIX socket to `path` and closes it without unlinking,
    /// leaving exactly the artifact a killed engine would: a socket-typed
    /// file with nothing listening behind it.
    private static func createStaleSocketFile(at path: String) throws {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { close(descriptor) }

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
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}
