import ContainerBridge
import Foundation

/// Reads a container's log back out of the file `FileLogWriter` wrote, for the
/// `Logs` RPC.
///
/// **It reads `combined.log` and neither per-stream file.** Ordering across
/// stdout and stderr is the thing a log consumer cannot reconstruct for itself:
/// the two per-stream files carry no relationship to each other, and merging
/// them on their timestamps would only order them to the millisecond the stamp
/// records, leaving every tie -- which is most of a burst -- in whichever order
/// the merge happened to produce. `combined.log` is written by both stream
/// writers under one lock, so its order is the order the output arrived in. The
/// per-entry `"stream"` field is still there and still says which stream each
/// line came from; nothing is lost by reading the one file.
///
/// **The result is bytes, not entries.** `LogsChunk.data` is "one logical
/// buffer, chunked", so this concatenates the entries' payloads and cuts the
/// result on a byte count. A consumer concatenates the frames back and must not
/// have to know where the cut fell; cutting on entry boundaries would make the
/// frame count a function of the log's content, which is exactly the coupling
/// the contract's wording rules out.
///
/// **Nothing here holds the log.** An earlier version read the file with
/// `Data(contentsOf:)`, built a second `Data` by concatenation, copied that into
/// an array of frames and handed the array back -- four copies of the whole log
/// alive at once, before a single byte reached the wire. The proto streams this
/// method because "a log larger than the default message limit would otherwise
/// fail as a size error rather than as a log", and nothing rotates
/// `combined.log`: `ContainerBridge` has no rotation at all, so a long-lived
/// chatty sandbox's log is bounded only by the disk. That made one `Logs` call
/// able to allocate the whole file several times over inside the process that
/// hosts every sandbox. Peak memory is now
/// `readWindowBytes + maxEntryBytes + 2 * chunkByteLimit` -- a constant, and
/// **not** a function of the log's size -- and the first frame goes out as soon
/// as one frame's worth of payload exists.
///
/// CORRECTED: that sentence read "`O(readWindow + chunkByteLimit)` regardless of
/// the log's size", and it was **measurably false**. A 512KiB file containing no
/// `0x0A` byte anywhere accumulated all eight read windows into the carry before
/// the decode failed, so the real bound was the longest run without a terminator
/// -- which is the whole file for a file that is not one of ours, and a file
/// that is not one of ours is precisely the input this reader exists to detect.
/// `maxEntryBytes` is what makes the corrected sentence true rather than merely
/// narrower.
package enum LogReader {
    /// The default cut size.
    ///
    /// Bounded on both sides and both bounds are asserted, because the reason
    /// for the value is the only thing that makes it right. **Above:** it must
    /// stay well under grpc-swift's 4MiB default receive limit, which is the
    /// size error the streaming contract exists to avoid -- a value past that
    /// reintroduces exactly the failure streaming was designed around.
    /// **Below:** a small value turns an ordinary log into thousands of frames,
    /// each with its own proto and its own `send`.
    package static let chunkByteLimit = 64 * 1024

    /// How much of the file is read at a time while looking for the next
    /// terminator.
    ///
    /// Independent of `chunkByteLimit`: one bounds the frame, this bounds the
    /// read. An entry longer than this is still handled, because the bytes after
    /// the last terminator carry into the next window -- so this bounds the read
    /// and `maxEntryBytes` bounds the carry. **This comment used to end "so this
    /// is a buffer size and not a limit on anything", one sentence after the
    /// class comment claimed a constant memory bound. Both could not be true and
    /// the carry was the one that was unbounded.**
    package static let readWindowBytes = 64 * 1024

    /// The longest run of bytes with no terminator that this reader will hold
    /// before refusing the file.
    ///
    /// **A policy limit, and it is stated as one rather than derived**, because
    /// nothing in this repository bounds the length of one entry: an entry is
    /// one runtime `write(_:)` chunk up to its first `\n`, wrapped in JSON, and
    /// the chunking is the container runtime's. What the limit buys is the
    /// class comment's bound being true; what it costs is that a single log line
    /// longer than this becomes an error rather than a log, and
    /// `LogReaderError.entryTooLong` names the limit so that an operator who
    /// meets it knows what to change.
    ///
    /// 4MiB is far above any entry this writer has been seen to produce and
    /// still bounds one `Logs` call to a few megabytes inside the process that
    /// hosts every sandbox. The failure it really exists for is not a long line
    /// at all: it is a file that is not a log, which has no terminators at any
    /// length.
    package static let maxEntryBytes = 4 * 1024 * 1024

    /// The log at `combinedPath`, filtered, cut, and handed to `sink` one frame
    /// at a time in order.
    ///
    /// - Parameter sinceUnixMillis: Keep entries stamped at or after this many
    ///   Unix milliseconds. Inclusive, and nil means from the beginning, which
    ///   is what `engine.proto` says an absent field means. The comparison is
    ///   honest only because `LogEntryTimestamp` writes milliseconds: under the
    ///   whole-second stamps this file's writer emitted before, every entry in
    ///   a second rounded down to its start and a filter would have returned
    ///   up to a second of log the caller excluded.
    ///
    /// Throws rather than skipping on a line it cannot read. Both of this
    /// repository's Docker-surface readers skip, which turns a truncated or
    /// foreign log file into a short log that reads exactly like a complete
    /// one; `Logs` has an error arm and uses it. A consequence worth stating:
    /// one corrupt line fails the whole call rather than returning the readable
    /// prefix, which is the right trade for a consumer that must not mistake a
    /// partial log for a complete one -- but frames already handed to `sink`
    /// have already gone, and `gascan-arca/src/backend.rs` discards them on the
    /// error arm for exactly that reason.
    package static func stream(
        combinedPath: URL,
        sinceUnixMillis: Int64?,
        chunkByteLimit: Int = LogReader.chunkByteLimit,
        into sink: (Data) async throws -> Void
    ) async throws {
        precondition(chunkByteLimit > 0, "a chunk limit of \(chunkByteLimit) would not terminate")

        let handle = try FileHandle(forReadingFrom: combinedPath)
        defer { try? handle.close() }

        var carried = Data()
        var frame = Data()

        /// Appends one entry's payload and hands out whole frames as they fill.
        func take(_ line: Data) async throws {
            guard let payload = try payload(ofLine: line, sinceUnixMillis: sinceUnixMillis) else {
                return
            }
            frame.append(payload)
            while frame.count >= chunkByteLimit {
                let cut = frame.index(frame.startIndex, offsetBy: chunkByteLimit)
                try await sink(Data(frame[frame.startIndex..<cut]))
                frame = Data(frame[cut...])
            }
        }

        while let window = try handle.read(upToCount: readWindowBytes), !window.isEmpty {
            carried.append(window)
            let split = ContainerLogCodec.lines(of: carried)
            carried = split.remainder
            for line in split.lines {
                try await take(line)
            }
            // Checked after each window rather than at the end, which is the
            // whole point: at the end the file is already in memory.
            guard carried.count <= maxEntryBytes else {
                throw LogReaderError.entryTooLong(bytes: carried.count, limit: maxEntryBytes)
            }
        }
        // A trailing partial line can only be a torn write, and `take` reports
        // it as the unreadable entry it is rather than dropping it.
        if !carried.isEmpty {
            try await take(carried)
        }
        if !frame.isEmpty {
            try await sink(frame)
        }
    }

    /// One line's payload, or nil when the filter excludes it.
    private static func payload(ofLine line: Data, sinceUnixMillis: Int64?) throws -> Data? {
        let entry = try ContainerLogCodec.decode(line: line)
        if let since = sinceUnixMillis {
            guard let stamped = LogEntryTimestamp.date(from: entry.time) else {
                throw LogReaderError.unreadableTimestamp(entry.time)
            }
            if LogEntryTimestamp.unixMillis(from: stamped) < since {
                return nil
            }
        }
        return try ContainerLogCodec.payload(of: entry)
    }
}

package enum LogReaderError: Error, CustomStringConvertible {
    case unreadableTimestamp(String)
    /// Names the limit as well as the length, because the two questions an
    /// operator has on meeting this are "how long was it" and "how long is
    /// allowed", and a message carrying one of them answers neither.
    case entryTooLong(bytes: Int, limit: Int)

    package var description: String {
        switch self {
        case .unreadableTimestamp(let time):
            return "log entry time \(time) is not a readable timestamp"
        case .entryTooLong(let bytes, let limit):
            return "no line terminator in \(bytes) bytes, past this reader's "
                + "\(limit)-byte limit on one entry; either the log holds a single line "
                + "longer than that, or this file is not a container log"
        }
    }
}
