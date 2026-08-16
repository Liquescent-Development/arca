import Foundation
import Containerization
import Logging

/// The one spelling of a log entry's timestamp, for everything that writes an
/// entry and everything that reads one back.
///
/// **`.withFractionalSeconds` is load-bearing.** `engine.proto`'s
/// `LogsRequest.since_unix_millis` filters in milliseconds, and
/// `ISO8601DateFormatter` at its default options emits whole seconds, so a
/// filter built on a default-formatted stamp rounds every entry down to its
/// second and returns up to a second of log the caller asked to be excluded.
/// A filter that silently over-returns is worse than widening the writer, so
/// the writer widens.
///
/// **Write and parse share one configuration, and that is not tidiness.** A
/// default-options `ISO8601DateFormatter` cannot *parse* a fractional-seconds
/// stamp -- `date(from:)` returns nil for it -- so two spellings here would not
/// be a rounding difference between writer and reader, they would be a reader
/// that discards every line the writer produced. Both readers of these files in
/// this repository skip an entry whose `time` will not parse
/// (`DockerAPI/Handlers/ContainerHandlers.swift`,
/// `ArcaDaemon/DockerRawStreamUpgrader.swift`), so the failure would arrive as
/// an empty log rather than as an error.
public enum LogEntryTimestamp {
    /// A fresh formatter per call, matching what this file did before: a
    /// `static let` would share one `ISO8601DateFormatter` across the two
    /// writer threads a container has, and Foundation does not document that
    /// type as thread-safe.
    private static var formatter: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }

    public static func string(from date: Date) -> String {
        formatter.string(from: date)
    }

    public static func date(from string: String) -> Date? {
        formatter.date(from: string)
    }

    /// Unix milliseconds for a parsed entry stamp.
    ///
    /// Rounded rather than truncated: the writer emits exactly three fractional
    /// digits, so the true value is a whole number of milliseconds, and
    /// `timeIntervalSince1970 * 1000` lands a hair under it in binary floating
    /// point often enough that truncation would shift an entry back by one.
    public static func unixMillis(from date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }
}

/// One line of a container's log, as the log files hold it.
///
/// Docker-compatible: `stream`, `log` and `time` are the three fields Docker's
/// json-file driver writes and the three both of this repository's existing
/// readers look up by name.
public struct ContainerLogEntry: Codable, Sendable, Equatable {
    /// `"stdout"` or `"stderr"`.
    public let stream: String
    /// The payload. Text when `encoding` is absent; base64 when it is
    /// `"base64"`.
    public let log: String
    /// The entry's stamp, in `LogEntryTimestamp`'s format.
    public let time: String
    /// Absent for a text entry, which is the overwhelmingly common one, so an
    /// ordinary line still carries exactly Docker's three fields.
    public let encoding: String?

    public init(stream: String, log: String, time: String, encoding: String? = nil) {
        self.stream = stream
        self.log = log
        self.time = time
        self.encoding = encoding
    }
}

/// Turns a payload into a log line and a log line back into a payload.
///
/// **Encoding is `JSONEncoder`'s and not five `replacingOccurrences` calls,
/// and the change fixed a real hole.** The hand-rolled escaping this replaced
/// covered `\`, `"`, `\n`, `\r` and `\t` and nothing else, so any other C0
/// control byte in a container's output -- `\u{01}` from a progress bar,
/// `\u{0B}`, a stray NUL -- went into the file raw, where JSON forbids it, and
/// every reader's `JSONSerialization` call rejected the line and skipped it.
/// A payload that cannot survive the writer is a writer bug, so the writer no
/// longer hand-rolls the part a library gets right.
///
/// **`encoding: "base64"` is how a non-UTF-8 payload survives.** A JSON string
/// holds Unicode scalars, not arbitrary bytes, so bytes that are not valid
/// UTF-8 cannot go in `log` as text. They previously became the prose
/// `[binary data: N bytes, base64: ...]`, which no reader decodes, so the bytes
/// were gone. This is not an exotic case: `write(_:)` is handed whatever chunk
/// the runtime produces, and a multi-byte UTF-8 sequence split across two
/// chunks makes an ordinary text log arrive here as invalid UTF-8. Both halves
/// now round-trip byte-exactly and concatenate back into the original text.
public enum ContainerLogCodec {
    /// The only value `ContainerLogEntry.encoding` ever takes.
    public static let base64Encoding = "base64"

    /// `.sortedKeys` so a line is a deterministic function of its entry, which
    /// is what lets a test compare bytes. `.withoutEscapingSlashes` keeps a
    /// path in a log line readable, as the hand-rolled encoder left it.
    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    /// The entry for `payload`, text if it is UTF-8 and base64 if it is not.
    public static func entry(stream: String, payload: Data, at date: Date) -> ContainerLogEntry {
        let time = LogEntryTimestamp.string(from: date)
        if let text = String(data: payload, encoding: .utf8) {
            return ContainerLogEntry(stream: stream, log: text, time: time)
        }
        return ContainerLogEntry(
            stream: stream,
            log: payload.base64EncodedString(),
            time: time,
            encoding: base64Encoding
        )
    }

    /// One newline-terminated line. JSON strings carry no raw newline, so the
    /// terminator is unambiguous and the file stays splittable on `0x0A`.
    public static func encode(_ entry: ContainerLogEntry) throws -> Data {
        var line = try encoder.encode(entry)
        line.append(UInt8(ascii: "\n"))
        return line
    }

    public static func decode(line: Data) throws -> ContainerLogEntry {
        do {
            return try JSONDecoder().decode(ContainerLogEntry.self, from: line)
        } catch {
            throw LogWriterError.unreadableEntry(
                String(decoding: line, as: UTF8.self), "\(error)"
            )
        }
    }

    /// The bytes `entry` was made from.
    public static func payload(of entry: ContainerLogEntry) throws -> Data {
        switch entry.encoding {
        case .none:
            return Data(entry.log.utf8)
        case .some(base64Encoding):
            guard let decoded = Data(base64Encoded: entry.log) else {
                throw LogWriterError.unreadableEntry(entry.log, "log is not valid base64")
            }
            return decoded
        case .some(let other):
            throw LogWriterError.unknownEncoding(other)
        }
    }
}

/// An append-only log file, safe to share between writers.
///
/// Exists so that `combined.log` can have one owner and two appenders. Every
/// append is one whole line under one lock, so the combined file's order is the
/// order the entries were produced in across both streams -- which is the only
/// thing a log consumer can use to interleave stdout and stderr, since the two
/// per-stream files carry no cross-file ordering at all.
public final class LogFile: @unchecked Sendable {
    public let path: URL
    private let handle: FileHandle
    private let lock = NSLock()

    public init(path: URL) throws {
        self.path = path

        let parentDir = path.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: parentDir,
            withIntermediateDirectories: true,
            attributes: nil
        )

        if !FileManager.default.fileExists(atPath: path.path) {
            FileManager.default.createFile(atPath: path.path, contents: nil, attributes: nil)
        }

        guard let handle = try? FileHandle(forWritingTo: path) else {
            throw LogWriterError.cannotOpenFile(path.path)
        }
        self.handle = handle
        try self.handle.seekToEnd()
    }

    public func append(_ data: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        try handle.write(contentsOf: data)
    }

    public func close() throws {
        lock.lock()
        defer { lock.unlock() }
        try handle.close()
    }

    deinit {
        try? handle.close()
    }
}

/// A Writer implementation that persists container stdout/stderr to log files
/// Implements Docker-compatible JSON log format for OCI compliance
///
/// Every entry lands in two files: this stream's own, and the container's
/// `combined.log`, which is the only file that records the order stdout and
/// stderr actually arrived in.
public final class FileLogWriter: Writer, @unchecked Sendable {
    private let file: LogFile
    private let combined: LogFile
    private let stream: String  // "stdout" or "stderr"
    private let lock = NSLock()

    /// Create a new FileLogWriter
    /// - Parameters:
    ///   - path: Path to this stream's log file
    ///   - stream: Stream identifier ("stdout" or "stderr")
    ///   - combined: The container's combined log, shared with the other
    ///     stream's writer and owned by `ContainerLogManager`. Not optional and
    ///     not defaulted: a writer that could be built without one would leave
    ///     `combined.log` empty for that container, which is exactly the state
    ///     this file was in before -- the path was declared, registered and
    ///     never written.
    public init(path: URL, stream: String, combined: LogFile) throws {
        self.stream = stream
        self.file = try LogFile(path: path)
        self.combined = combined
    }

    /// Write data to the log file in Docker JSON format
    /// Format: {"log":"message\n","stream":"stdout","time":"2025-01-17T12:34:56.789Z"}
    public func write(_ data: Data) throws {
        lock.lock()
        defer { lock.unlock() }

        for payload in Self.entryPayloads(of: data) {
            let line = try ContainerLogCodec.encode(
                ContainerLogCodec.entry(stream: stream, payload: payload, at: Date())
            )
            try file.append(line)
            try combined.append(line)
        }
    }

    /// The payloads this chunk becomes, one entry each.
    ///
    /// Split on `"\n"` and nothing else, keeping the separator on the line it
    /// ended, so concatenating every payload back gives the chunk verbatim.
    /// This used to be `components(separatedBy: .newlines)`, which is a
    /// `CharacterSet` covering `\r`, `\u{0B}`, `\u{0C}`, `\u{85}`, `\u{2028}`
    /// and `\u{2029}` as well: a CRLF-terminated line became two entries with
    /// an empty one between them, and every one of those separators was
    /// rewritten as `\n` on the way out. A `\r` now stays inside its payload
    /// and is escaped there.
    ///
    /// A chunk that is not valid UTF-8 is one entry, undivided -- there is no
    /// safe place to look for a line break in bytes whose encoding is unknown.
    private static func entryPayloads(of data: Data) -> [Data] {
        guard let message = String(data: data, encoding: .utf8) else {
            return [data]
        }
        let pieces = message.components(separatedBy: "\n")
        var payloads: [Data] = []
        for (index, piece) in pieces.enumerated() {
            let isLast = index == pieces.count - 1
            // The empty tail of a message that ended with a newline, and the
            // whole of an empty write. Neither is an entry.
            if isLast && piece.isEmpty {
                continue
            }
            payloads.append(Data((isLast ? piece : piece + "\n").utf8))
        }
        return payloads
    }

    /// Close this stream's log file.
    ///
    /// Not the combined file: it is shared with the other stream's writer and
    /// closed by `ContainerLogManager.removeLogs`, so that it has exactly one
    /// owner and cannot be closed twice.
    public func close() throws {
        lock.lock()
        defer { lock.unlock() }
        try file.close()
    }
}

/// Container log manager - tracks log file locations for containers
/// @unchecked Sendable: Safe because logPaths dictionary is protected by NSLock
public final class ContainerLogManager: @unchecked Sendable {
    private let logger: Logger
    private let baseLogDir: URL
    private var logPaths: [String: LogPaths] = [:]  // Docker ID -> LogPaths
    private var combinedFiles: [String: LogFile] = [:]  // Docker ID -> combined.log
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
    ///
    /// The container's `combined.log` is opened here and held here. It is the
    /// one file both writers append to, so this manager is its only owner and
    /// `removeLogs` its only closer; a second call for the same container
    /// reuses the open file rather than opening a second handle onto it.
    public func createLogWriters(dockerID: String) throws -> (FileLogWriter, FileLogWriter) {
        let logDir = containerLogDir(dockerID: dockerID)

        let stdoutPath = logDir.appendingPathComponent("stdout.log")
        let stderrPath = logDir.appendingPathComponent("stderr.log")
        let combinedPath = logDir.appendingPathComponent("combined.log")

        logger.debug("Creating log writers", metadata: [
            "docker_id": "\(dockerID)",
            "log_dir": "\(logDir.path)"
        ])

        lock.lock()
        defer { lock.unlock() }

        let combined: LogFile
        if let existing = combinedFiles[dockerID] {
            combined = existing
        } else {
            combined = try LogFile(path: combinedPath)
            combinedFiles[dockerID] = combined
        }

        let stdoutWriter = try FileLogWriter(
            path: stdoutPath, stream: "stdout", combined: combined
        )
        let stderrWriter = try FileLogWriter(
            path: stderrPath, stream: "stderr", combined: combined
        )

        logPaths[dockerID] = LogPaths(
            stdoutPath: stdoutPath,
            stderrPath: stderrPath,
            combinedPath: combinedPath
        )

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

        // Before the directory goes: this manager owns the combined handle, and
        // it is the only thing that closes it.
        if let combined = combinedFiles.removeValue(forKey: dockerID) {
            try combined.close()
        }

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
    /// A line in a log file that is not an entry this codec produced. Carries
    /// the line and the underlying complaint, because the two failures behind
    /// it -- a truncated write and a foreign file -- look identical without it.
    case unreadableEntry(String, String)
    case unknownEncoding(String)

    public var description: String {
        switch self {
        case .cannotOpenFile(let path):
            return "Cannot open log file: \(path)"
        case .writeError(let msg):
            return "Log write error: \(msg)"
        case .unreadableEntry(let line, let reason):
            return "Unreadable log entry (\(reason)): \(line)"
        case .unknownEncoding(let encoding):
            return "Unknown log entry encoding: \(encoding)"
        }
    }
}
