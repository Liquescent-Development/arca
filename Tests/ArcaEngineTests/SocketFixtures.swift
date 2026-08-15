import Darwin
import Foundation
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
    /// Silent on purpose: grpc-swift closes a connection whose protocol it has
    /// finished negotiating when quiescing sends its GOAWAY, and closing is
    /// exactly what must NOT happen while a test of the drain looks. One that
    /// has sent nothing is in no protocol at all, so it holds the drain open and
    /// the listener closes long before quiescence completes -- which is the
    /// window both `ShutdownObserverTests` and
    /// `EngineServerTests.testRunUntilQuiescedWaitsForAcceptedConnectionsNotTheListener`
    /// are about.
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
