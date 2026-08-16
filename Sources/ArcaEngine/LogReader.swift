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
/// buffer, chunked", so this concatenates the entries' payloads and splits the
/// result on a byte count. A consumer concatenates the frames back and must not
/// have to know where the split fell; splitting on entry boundaries would make
/// the chunk count a function of the log's content, which is exactly the
/// coupling the contract's wording rules out.
package enum LogReader {
    /// The default split size.
    ///
    /// Well under grpc-swift's 4MiB default receive limit, which is the size
    /// error the streaming contract exists to avoid, and large enough that an
    /// ordinary log is one or two frames.
    package static let chunkByteLimit = 64 * 1024

    /// The log at `combinedPath`, filtered and chunked.
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
    /// repository's other readers skip, which turns a truncated or foreign log
    /// file into a short log that reads exactly like a complete one; `Logs` has
    /// an error arm and uses it.
    package static func chunks(
        combinedPath: URL,
        sinceUnixMillis: Int64?,
        chunkByteLimit: Int = LogReader.chunkByteLimit
    ) throws -> [Data] {
        split(
            try payload(combinedPath: combinedPath, sinceUnixMillis: sinceUnixMillis),
            into: chunkByteLimit
        )
    }

    /// The concatenated payload of every entry that passes the filter.
    ///
    /// Split on `0x0A` over the bytes rather than over a `String`: an entry is
    /// JSON, which carries no raw newline, so the byte split is exact, and it
    /// avoids decoding the whole file to UTF-16 to find line breaks.
    package static func payload(combinedPath: URL, sinceUnixMillis: Int64?) throws -> Data {
        let contents = try Data(contentsOf: combinedPath)
        var payload = Data()
        for line in contents.split(
            separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true
        ) {
            let entry = try ContainerLogCodec.decode(line: Data(line))
            if let since = sinceUnixMillis {
                guard let stamped = LogEntryTimestamp.date(from: entry.time) else {
                    throw LogReaderError.unreadableTimestamp(entry.time)
                }
                if LogEntryTimestamp.unixMillis(from: stamped) < since {
                    continue
                }
            }
            payload.append(try ContainerLogCodec.payload(of: entry))
        }
        return payload
    }

    /// `payload` in order, in pieces of at most `limit` bytes.
    ///
    /// An empty payload is no chunks at all, not one empty chunk: the consumer
    /// concatenates whatever arrives, so an empty log is an empty stream.
    package static func split(_ payload: Data, into limit: Int) -> [Data] {
        precondition(limit > 0, "a chunk limit of \(limit) would not terminate")
        var chunks: [Data] = []
        var start = payload.startIndex
        while start < payload.endIndex {
            let end = payload.index(start, offsetBy: limit, limitedBy: payload.endIndex)
                ?? payload.endIndex
            chunks.append(Data(payload[start..<end]))
            start = end
        }
        return chunks
    }
}

package enum LogReaderError: Error, CustomStringConvertible {
    case unreadableTimestamp(String)

    package var description: String {
        switch self {
        case .unreadableTimestamp(let time):
            return "log entry time \(time) is not a readable timestamp"
        }
    }
}
