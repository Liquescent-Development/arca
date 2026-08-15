import Foundation
import Containerization
import Logging

/// A Writer implementation that persists container stdout/stderr to log files
/// Implements Docker-compatible JSON log format for OCI compliance
public final class FileLogWriter: Writer, @unchecked Sendable {
    private let fileHandle: FileHandle
    private let stream: String  // "stdout" or "stderr"
    private let lock = NSLock()

    /// Create a new FileLogWriter
    /// - Parameters:
    ///   - path: Path to the log file
    ///   - stream: Stream identifier ("stdout" or "stderr")
    public init(path: URL, stream: String) throws {
        self.stream = stream

        // Ensure parent directory exists
        let parentDir = path.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: parentDir,
            withIntermediateDirectories: true,
            attributes: nil
        )

        // Create or open log file
        if !FileManager.default.fileExists(atPath: path.path) {
            FileManager.default.createFile(atPath: path.path, contents: nil, attributes: nil)
        }

        guard let handle = try? FileHandle(forWritingTo: path) else {
            throw LogWriterError.cannotOpenFile(path.path)
        }

        self.fileHandle = handle
        try self.fileHandle.seekToEnd()
    }

    /// Write data to the log file in Docker JSON format
    /// Format: {"stream":"stdout","log":"message\n","time":"2025-01-17T12:34:56.789Z"}
    public func write(_ data: Data) throws {
        lock.lock()
        defer { lock.unlock() }

        // Convert data to string (container output is typically UTF-8 text)
        guard let message = String(data: data, encoding: .utf8) else {
            // If not valid UTF-8, write raw bytes as base64 encoded log entry
            let base64 = data.base64EncodedString()
            let logEntry = createLogEntry(message: "[binary data: \(data.count) bytes, base64: \(base64)]")
            try writeLogEntry(logEntry)
            return
        }

        // Split into lines to write each as separate log entry
        // This matches Docker's behavior
        let lines = message.components(separatedBy: .newlines)
        for (index, line) in lines.enumerated() {
            // Skip empty last line (happens when message ends with \n)
            if index == lines.count - 1 && line.isEmpty {
                continue
            }

            // Preserve original line endings
            let logLine = (index < lines.count - 1) ? line + "\n" : line
            let logEntry = createLogEntry(message: logLine)
            try writeLogEntry(logEntry)
        }
    }

    /// Create a Docker-compatible JSON log entry
    private func createLogEntry(message: String) -> Data {
        let timestamp = ISO8601DateFormatter().string(from: Date())

        // Build JSON manually to avoid encoding overhead
        // Format: {"stream":"stdout","log":"message","time":"2025-01-17T12:34:56.789Z"}
        let escapedMessage = message
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")

        let jsonString = "{\"stream\":\"\(stream)\",\"log\":\"\(escapedMessage)\",\"time\":\"\(timestamp)\"}\n"
        return jsonString.data(using: .utf8) ?? Data()
    }

    /// Write a log entry to the file
    private func writeLogEntry(_ data: Data) throws {
        try fileHandle.write(contentsOf: data)
    }

    /// Close the log file
    public func close() throws {
        lock.lock()
        defer { lock.unlock() }
        try fileHandle.close()
    }

    deinit {
        try? fileHandle.close()
    }
}

/// Container log manager - tracks log file locations for containers
/// @unchecked Sendable: Safe because logPaths dictionary is protected by NSLock
public final class ContainerLogManager: @unchecked Sendable {
    private let logger: Logger
    private let baseLogDir: URL
    private var logPaths: [String: LogPaths] = [:]  // Docker ID -> LogPaths
    private let lock = NSLock()

    public struct LogPaths: Sendable {
        public let stdoutPath: URL
        public let stderrPath: URL
        public let combinedPath: URL
    }

    /// - Parameter logRoot: The directory container log directories are created
    ///   under, and the directory `removeLogs` deletes from. Supplied by the
    ///   caller and never defaulted: this class both writes and deletes here,
    ///   and until Task 13b it derived `~/Library/Application Support/
    ///   com.apple.arca/logs` for itself, so every `ContainerManager` -- however
    ///   its own state root was set -- wrote container stdout/stderr into one
    ///   shared directory and removed containers' logs out of it. A throwaway
    ///   engine deleting under the operator's real log store is the failure
    ///   that shape allows.
    ///
    ///   A default would put that back the moment a caller omitted the
    ///   argument, which is the rule the milestone's design states for every
    ///   `ContainerBridge` change: none takes a default, because a default is
    ///   how a caller silently keeps the old behaviour after the reason for it
    ///   has gone.
    public init(logRoot: URL, logger: Logger) {
        self.logger = logger
        self.baseLogDir = logRoot
    }

    /// Get log directory for a container
    public func containerLogDir(dockerID: String) -> URL {
        baseLogDir.appendingPathComponent(dockerID)
    }

    /// Create log writers for a container
    /// Returns (stdout writer, stderr writer)
    public func createLogWriters(dockerID: String) throws -> (FileLogWriter, FileLogWriter) {
        let logDir = containerLogDir(dockerID: dockerID)

        let stdoutPath = logDir.appendingPathComponent("stdout.log")
        let stderrPath = logDir.appendingPathComponent("stderr.log")
        let combinedPath = logDir.appendingPathComponent("combined.log")

        logger.debug("Creating log writers", metadata: [
            "docker_id": "\(dockerID)",
            "log_dir": "\(logDir.path)"
        ])

        let stdoutWriter = try FileLogWriter(path: stdoutPath, stream: "stdout")
        let stderrWriter = try FileLogWriter(path: stderrPath, stream: "stderr")

        lock.lock()
        logPaths[dockerID] = LogPaths(
            stdoutPath: stdoutPath,
            stderrPath: stderrPath,
            combinedPath: combinedPath
        )
        lock.unlock()

        return (stdoutWriter, stderrWriter)
    }

    /// Get log paths for a container
    public func getLogPaths(dockerID: String) -> LogPaths? {
        lock.lock()
        defer { lock.unlock() }
        return logPaths[dockerID]
    }

    /// Register existing log paths for a container (used during daemon restart)
    /// This registers paths without creating new log writers (which would truncate files)
    public func registerExistingLogPaths(
        dockerID: String,
        stdoutPath: URL,
        stderrPath: URL,
        combinedPath: URL
    ) throws {
        lock.lock()
        defer { lock.unlock() }

        logPaths[dockerID] = LogPaths(
            stdoutPath: stdoutPath,
            stderrPath: stderrPath,
            combinedPath: combinedPath
        )

        logger.debug("Registered existing log paths", metadata: [
            "docker_id": "\(dockerID)",
            "stdout": "\(stdoutPath.path)",
            "stderr": "\(stderrPath.path)"
        ])
    }

    /// Remove log files for a container
    public func removeLogs(dockerID: String) throws {
        lock.lock()
        defer { lock.unlock() }

        let logDir = containerLogDir(dockerID: dockerID)
        if FileManager.default.fileExists(atPath: logDir.path) {
            try FileManager.default.removeItem(at: logDir)
            logger.debug("Removed log directory", metadata: [
                "docker_id": "\(dockerID)",
                "path": "\(logDir.path)"
            ])
        }

        logPaths.removeValue(forKey: dockerID)
    }
}

// MARK: - Errors

public enum LogWriterError: Error, CustomStringConvertible {
    case cannotOpenFile(String)
    case writeError(String)

    public var description: String {
        switch self {
        case .cannotOpenFile(let path):
            return "Cannot open log file: \(path)"
        case .writeError(let msg):
            return "Log write error: \(msg)"
        }
    }
}
