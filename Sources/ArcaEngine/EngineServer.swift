import Foundation
import GRPC
import NIOCore
import NIOPosix

/// Binds the sandbox-engine service to a Unix domain socket.
public struct EngineServer {
    /// Starts the engine on `socketPath`.
    ///
    /// A stale socket left by a killed engine is removed first: bind fails with
    /// EADDRINUSE against a file whose listener is gone, and an engine that
    /// cannot restart after a crash is worse than one that reclaims its own
    /// path. Only a socket is removed -- refusing to unlink a regular file
    /// keeps a mistyped path from destroying data.
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
    ) async throws -> Server {
        try removeStaleSocket(at: socketPath)
        let server = try await Server.insecure(group: group)
            .withServiceProviders([service])
            .bind(unixDomainSocketPath: socketPath)
            .get()
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: socketPath
        )
        return server
    }

    private static func removeStaleSocket(at path: String) throws {
        var status = stat()
        guard lstat(path, &status) == 0 else { return }
        guard (status.st_mode & S_IFMT) == S_IFSOCK else {
            throw EngineServerError.pathIsNotASocket(path)
        }
        try FileManager.default.removeItem(atPath: path)
    }
}

public enum EngineServerError: Error, CustomStringConvertible {
    case pathIsNotASocket(String)

    public var description: String {
        switch self {
        case .pathIsNotASocket(let path):
            return "refusing to replace \(path): it exists and is not a socket"
        }
    }
}
