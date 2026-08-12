import Foundation
import GRPC
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

    /// Completes when the server has finished closing, however that was
    /// initiated.
    public var onClose: EventLoopFuture<Void> { server.onClose }

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

        return EngineServer(server: server, socketPath: socketPath, lock: lock)
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
