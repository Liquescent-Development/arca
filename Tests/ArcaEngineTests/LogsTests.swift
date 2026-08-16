import ContainerBridge
import Foundation
import Logging
import SandboxEngineProto
import XCTest
@testable import ArcaEngine

/// `Logs`, and the two things it makes load-bearing: the JSON log format, which
/// nothing in this repository had ever asserted round-trips, and the entry
/// timestamp, which had to gain milliseconds before `since_unix_millis` could
/// be honoured at all.
final class LogsTests: XCTestCase {

    // MARK: - The format, driven through the real writer and back

    /// **Every payload goes through a real `FileLogWriter` and comes back
    /// through `LogReader`, and the assertion is byte equality on the whole
    /// concatenation.**
    ///
    /// This is the test the format never had. `FileLogWriter` built its entries
    /// by string interpolation with five `replacingOccurrences` calls, and
    /// nothing read them back with any expectation of exactness: both existing
    /// readers `continue` past a line they cannot parse, so a payload that
    /// destroyed its line vanished and looked like a container that had said
    /// nothing.
    ///
    /// **Two of these were destroyed by the writer as it stood, and neither is
    /// exotic.**
    ///
    /// - A C0 control byte other than `\n`, `\r` or `\t` -- `\u{07}` from a
    ///   bell, `\u{0B}`, a NUL -- went into the file raw. JSON forbids a raw
    ///   control character in a string, so the line was invalid JSON and every
    ///   reader dropped it.
    /// - Bytes that are not valid UTF-8 became the prose `[binary data: N
    ///   bytes, base64: ...]`, which no reader decodes. That is not only a
    ///   binary-output case: `write(_:)` is handed whatever chunk the runtime
    ///   produces, so an ordinary UTF-8 text log whose multi-byte sequence
    ///   straddles a chunk boundary arrives here as two invalid chunks. The
    ///   last two payloads below are exactly that -- the three bytes of `€`
    ///   split across two writes -- and they must reassemble.
    ///
    /// A CRLF line was mangled too: `components(separatedBy: .newlines)` splits
    /// on `\r` as well as `\n`, so `dos\r\n` became two entries with an empty
    /// one between and the `\r` was rewritten as `\n`.
    func testEveryAdversarialPayloadSurvivesTheWriterAndComesBackByteExact() throws {
        let root = Self.throwawayRoot()
        let manager = ContainerLogManager(logRoot: root, logger: Self.logger)
        let (stdout, _) = try manager.createLogWriters(dockerID: Self.dockerID)

        var expected = Data()
        for payload in Self.adversarialPayloads {
            try stdout.write(payload.bytes)
            expected.append(payload.bytes)
        }

        let paths = try XCTUnwrap(manager.getLogPaths(dockerID: Self.dockerID))
        let read = try LogReader.payload(combinedPath: paths.combinedPath, sinceUnixMillis: nil)

        XCTAssertEqual(
            read, expected,
            "the log must come back byte-exact; it came back as "
                + "\(Self.readable(read)) against \(Self.readable(expected))"
        )
    }

    /// The same payloads, one at a time, so a failure names the payload rather
    /// than reporting one long mismatch.
    ///
    /// The whole-log test above is the one that matters -- it is what a
    /// consumer actually receives -- but a single concatenated comparison
    /// cannot say which payload broke, and "what did not survive" is a
    /// question this task has to answer precisely.
    ///
    /// A payload that makes the read *throw* is caught and reported rather than
    /// thrown on, so one unreadable payload does not hide the verdict on the
    /// rest. That is not hypothetical: under the writer this replaced, the C0
    /// payload produced invalid JSON, and a rethrow ended the loop before the
    /// non-UTF-8 payloads were reached at all.
    func testEachAdversarialPayloadSurvivesOnItsOwn() throws {
        for payload in Self.adversarialPayloads {
            let root = Self.throwawayRoot()
            let manager = ContainerLogManager(logRoot: root, logger: Self.logger)
            let (stdout, _) = try manager.createLogWriters(dockerID: Self.dockerID)
            try stdout.write(payload.bytes)

            let paths = try XCTUnwrap(manager.getLogPaths(dockerID: Self.dockerID))
            do {
                let read = try LogReader.payload(
                    combinedPath: paths.combinedPath, sinceUnixMillis: nil
                )
                XCTAssertEqual(
                    read, payload.bytes,
                    "\(payload.name) did not survive: \(Self.readable(read)) "
                        + "against \(Self.readable(payload.bytes))"
                )
            } catch {
                XCTFail("\(payload.name) could not be read back at all: \(error)")
            }
        }
    }

    /// Every line the writer produces is valid JSON carrying the three fields
    /// Docker's format defines.
    ///
    /// Asserted independently of `LogReader`, because a codec that encoded and
    /// decoded its own private format would pass every round-trip above while
    /// writing something the two Docker-surface readers -- which reach for
    /// `stream`, `log` and `time` by name -- cannot use.
    func testEveryLineIsValidJSONWithDockersThreeFields() throws {
        let root = Self.throwawayRoot()
        let manager = ContainerLogManager(logRoot: root, logger: Self.logger)
        let (stdout, _) = try manager.createLogWriters(dockerID: Self.dockerID)
        for payload in Self.adversarialPayloads {
            try stdout.write(payload.bytes)
        }

        let paths = try XCTUnwrap(manager.getLogPaths(dockerID: Self.dockerID))
        let contents = try Data(contentsOf: paths.combinedPath)
        let lines = contents.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
        XCTAssertFalse(lines.isEmpty, "the adversarial payloads must produce entries")

        for line in lines {
            let object = try JSONSerialization.jsonObject(with: Data(line))
            let json = try XCTUnwrap(object as? [String: Any], "an entry must be a JSON object")
            XCTAssertEqual(json["stream"] as? String, "stdout")
            XCTAssertNotNil(json["log"] as? String, "every entry carries a string `log`")
            XCTAssertNotNil(json["time"] as? String, "every entry carries a string `time`")
        }
    }

    // MARK: - combined.log

    /// **`combined.log` is the file `Logs` reads, and until this change nothing
    /// wrote it.** Its path was derived, registered in `LogPaths` and handed to
    /// three call sites, and no `FileLogWriter` was ever pointed at it: a
    /// `Logs` that read it would have reported every container as silent.
    ///
    /// Ordering across the two streams is the whole reason to read it. The
    /// per-stream files carry no relationship to each other, and merging them on
    /// their stamps orders them only to the millisecond, leaving every tie in a
    /// burst to the merge. Here the writes alternate, and the combined file must
    /// hold them in that order with each entry still saying which stream it came
    /// from.
    func testCombinedLogHoldsBothStreamsInTheOrderTheyWereWritten() throws {
        let root = Self.throwawayRoot()
        let manager = ContainerLogManager(logRoot: root, logger: Self.logger)
        let (stdout, stderr) = try manager.createLogWriters(dockerID: Self.dockerID)

        try stdout.write(Data("one\n".utf8))
        try stderr.write(Data("two\n".utf8))
        try stdout.write(Data("three\n".utf8))
        try stderr.write(Data("four\n".utf8))

        let paths = try XCTUnwrap(manager.getLogPaths(dockerID: Self.dockerID))
        let entries = try Self.entries(at: paths.combinedPath)

        XCTAssertEqual(
            entries.map { [$0.stream, $0.log] },
            [
                ["stdout", "one\n"],
                ["stderr", "two\n"],
                ["stdout", "three\n"],
                ["stderr", "four\n"],
            ],
            "combined.log must interleave the two streams in write order"
        )
        XCTAssertEqual(
            try LogReader.payload(combinedPath: paths.combinedPath, sinceUnixMillis: nil),
            Data("one\ntwo\nthree\nfour\n".utf8)
        )
    }

    /// The per-stream files still hold only their own stream, so nothing that
    /// reads them gained the other one.
    func testEachStreamFileStillHoldsOnlyItsOwnStream() throws {
        let root = Self.throwawayRoot()
        let manager = ContainerLogManager(logRoot: root, logger: Self.logger)
        let (stdout, stderr) = try manager.createLogWriters(dockerID: Self.dockerID)

        try stdout.write(Data("out\n".utf8))
        try stderr.write(Data("err\n".utf8))

        let paths = try XCTUnwrap(manager.getLogPaths(dockerID: Self.dockerID))
        XCTAssertEqual(try Self.entries(at: paths.stdoutPath).map(\.log), ["out\n"])
        XCTAssertEqual(try Self.entries(at: paths.stderrPath).map(\.log), ["err\n"])
    }

    // MARK: - The timestamp, and the filter that needs it

    /// **The writer stamps milliseconds.** `LogsRequest.since_unix_millis` is
    /// in milliseconds and an `ISO8601DateFormatter` at its default options
    /// emits whole seconds, so without this the filter cannot be honoured: every
    /// entry in a second reads as that second's first instant, and a `since`
    /// inside the second returns the whole of it.
    ///
    /// Asserted on the shape of the stamp rather than on two observed values,
    /// which would be a race: two writes can land in the same millisecond.
    func testTheWriterStampsMillisecondsAndTheyParseBack() throws {
        let root = Self.throwawayRoot()
        let manager = ContainerLogManager(logRoot: root, logger: Self.logger)
        let (stdout, _) = try manager.createLogWriters(dockerID: Self.dockerID)
        try stdout.write(Data("line\n".utf8))

        let paths = try XCTUnwrap(manager.getLogPaths(dockerID: Self.dockerID))
        let time = try XCTUnwrap(Self.entries(at: paths.combinedPath).first?.time)

        XCTAssertNotNil(
            time.range(of: #"\.\d{3}Z$"#, options: .regularExpression),
            "a stamp must carry three fractional digits; it was \(time)"
        )
        XCTAssertNotNil(
            LogEntryTimestamp.date(from: time),
            "the reader's formatter must parse the writer's stamp; it did not parse \(time)"
        )
    }

    /// **What widening the writer costs the two readers that were already
    /// there, measured rather than argued.**
    ///
    /// `DockerAPI/Handlers/ContainerHandlers.swift` and
    /// `ArcaDaemon/DockerRawStreamUpgrader.swift` both parsed these files with
    /// a bare `ISO8601DateFormatter()` and `continue`d past a line whose `time`
    /// would not parse. This asserts the fact that makes that fatal: a
    /// default-options formatter returns nil for the stamp the writer now
    /// emits. Left alone, both would have reported every container as silent,
    /// and would have done it without an error. Both now go through
    /// `LogEntryTimestamp`.
    ///
    /// This test does not reach either reader -- their parse functions are
    /// private to their targets and neither target is in the release gate's
    /// filter. It pins the mechanism, not the call sites.
    func testADefaultFormatterCannotReadTheStampTheWriterEmits() {
        let stamp = LogEntryTimestamp.string(from: Date(timeIntervalSince1970: 1_755_300_000.25))
        XCTAssertEqual(stamp, "2025-08-15T23:20:00.250Z")
        XCTAssertNil(
            ISO8601DateFormatter().date(from: stamp),
            "if a default formatter could read this, the reader updates were unnecessary"
        )
        XCTAssertNotNil(LogEntryTimestamp.date(from: stamp))
    }

    /// **`since_unix_millis` inside a single second, which is the case the
    /// whole-second stamp could not express.**
    ///
    /// Three entries, 100ms apart, all within one wall-clock second. The filter
    /// asks for the middle one onwards. Under a whole-second stamp all three
    /// carry the same instant and no `since` can separate them: the request
    /// either returns all three or none.
    ///
    /// The dates are chosen here rather than taken from `Date()` so the boundary
    /// is exact and the test cannot race.
    func testSinceMillisSeparatesEntriesInsideOneSecond() throws {
        let root = Self.throwawayRoot()
        let combinedPath = root.appendingPathComponent("combined.log")
        let second = Date(timeIntervalSince1970: 1_755_300_000)
        let entries: [(offset: TimeInterval, text: String)] = [
            (0.100, "first\n"),
            (0.200, "second\n"),
            (0.300, "third\n"),
        ]
        try Self.write(
            entries.map { (second.addingTimeInterval($0.offset), $0.text) },
            to: combinedPath
        )

        let middle = LogEntryTimestamp.unixMillis(from: second.addingTimeInterval(0.200))
        XCTAssertEqual(middle, 1_755_300_000_200)

        XCTAssertEqual(
            try LogReader.payload(combinedPath: combinedPath, sinceUnixMillis: middle),
            Data("second\nthird\n".utf8),
            "since is inclusive of the entry stamped exactly at it"
        )
        XCTAssertEqual(
            try LogReader.payload(combinedPath: combinedPath, sinceUnixMillis: middle + 1),
            Data("third\n".utf8),
            "one millisecond later excludes the entry at the boundary"
        )
        XCTAssertEqual(
            try LogReader.payload(combinedPath: combinedPath, sinceUnixMillis: nil),
            Data("first\nsecond\nthird\n".utf8),
            "an absent filter is from the beginning"
        )
    }

    /// A line the codec cannot read is an error, not a skipped line.
    ///
    /// Both of the repository's other readers `continue` past one, which turns a
    /// truncated write or a foreign file into a short log indistinguishable from
    /// a complete one. `LogsChunk` has an error arm and `Logs` uses it.
    func testAnUnreadableLineIsAnErrorRatherThanASkippedLine() throws {
        let root = Self.throwawayRoot()
        let combinedPath = root.appendingPathComponent("combined.log")
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true
        )
        try Data("{\"stream\":\"stdout\",\"log\":\"good\\n\",\"time\":\"2026-08-15T00:00:00.000Z\"}\nnot an entry\n".utf8)
            .write(to: combinedPath)

        XCTAssertThrowsError(
            try LogReader.payload(combinedPath: combinedPath, sinceUnixMillis: nil)
        )
    }

    // MARK: - Chunking

    /// **Chunked by size and not by entry**, because the consumer concatenates
    /// data frames and must not need to know where the engine split.
    ///
    /// Twenty entries of ten bytes each, split at seventeen: a chunking that
    /// followed entry boundaries would produce twenty frames of ten bytes, and
    /// one that followed the limit produces eleven whose last is short. The
    /// concatenation is the same either way, which is the point -- so the frame
    /// sizes are what is asserted.
    func testChunksAreCutOnTheByteLimitAndNotOnEntryBoundaries() throws {
        let root = Self.throwawayRoot()
        let combinedPath = root.appendingPathComponent("combined.log")
        let second = Date(timeIntervalSince1970: 1_755_300_000)
        let lines = (0..<20).map { index in
            (second, String(format: "%09d", index) + "\n")
        }
        try Self.write(lines, to: combinedPath)

        let chunks = try LogReader.chunks(
            combinedPath: combinedPath, sinceUnixMillis: nil, chunkByteLimit: 17
        )

        XCTAssertEqual(
            chunks.map(\.count), Array(repeating: 17, count: 11) + [13],
            "200 bytes at a 17-byte limit is eleven full frames and a short one"
        )
        XCTAssertEqual(
            chunks.reduce(into: Data()) { $0.append($1) },
            Data(lines.map(\.1).joined().utf8),
            "the frames must concatenate back to the log"
        )
    }

    /// An empty log is an empty stream, not one empty frame.
    func testAnEmptyLogIsNoChunksAtAll() throws {
        let root = Self.throwawayRoot()
        let manager = ContainerLogManager(logRoot: root, logger: Self.logger)
        _ = try manager.createLogWriters(dockerID: Self.dockerID)
        let paths = try XCTUnwrap(manager.getLogPaths(dockerID: Self.dockerID))

        XCTAssertEqual(
            try LogReader.chunks(combinedPath: paths.combinedPath, sinceUnixMillis: nil), []
        )
    }

    // MARK: - The handler

    /// The whole method over a real container: the frames it sends, and the
    /// bytes they concatenate to.
    func testLogsStreamsTheContainersOwnLogInOrder() async throws {
        let managers = try Self.managers()
        try await Self.seed(managers, labels: SandboxIdentity.labels(from: Self.ownerLabels))
        let (stdout, stderr) = try managers.containerManager.logManager
            .createLogWriters(dockerID: Self.dockerID)
        try stdout.write(Data("hello\n".utf8))
        try stderr.write(Data("warned\n".utf8))
        try stdout.write(Data("bye\n".utf8))

        let chunks = await managers.makeService().logChunks(
            request: Arca_Engine_V1_LogsRequest.with { $0.sandboxID = Self.sandboxID }
        )

        XCTAssertEqual(
            try Self.concatenated(chunks), Data("hello\nwarned\nbye\n".utf8),
            "Logs must return the container's own output, both streams, in order"
        )
    }

    /// **Refused before anything is read, by the rule and the codes `Inspect`
    /// uses.** A container name is a flat namespace this engine does not own, so
    /// a sandbox id can resolve to a container that is not gascan's, and this
    /// engine cannot assert that an unlabelled one IS the sandbox that was asked
    /// for. Returning its output would be returning a stranger's.
    func testAnUnlabelledContainerIsRefusedRatherThanRead() async throws {
        let managers = try Self.managers()
        try await Self.seed(managers, labels: [:])
        let (stdout, _) = try managers.containerManager.logManager
            .createLogWriters(dockerID: Self.dockerID)
        try stdout.write(Data("a secret\n".utf8))

        let chunks = await managers.makeService().logChunks(
            request: Arca_Engine_V1_LogsRequest.with { $0.sandboxID = Self.sandboxID }
        )

        XCTAssertEqual(chunks.count, 1)
        guard case .error(let error) = chunks.first?.outcome else {
            return XCTFail("expected the error arm: \(String(describing: chunks.first?.outcome))")
        }
        XCTAssertEqual(error.code, EngineErrorCode.foreignResourceRefused.rawValue)
        XCTAssertEqual(error.resource, Self.sandboxID)
        XCTAssertFalse(
            error.message.contains("a secret"),
            "a refusal must not carry the log it refused to read"
        )
    }

    /// **The resolver hazard, on the first method whose output is data.**
    ///
    /// `ContainerManager.resolveContainerID` reads any pure-hex string of four
    /// or more characters as a Docker id prefix and matches it against every
    /// container the engine holds. `SandboxIdentity.refusalReason`'s own note
    /// calls that harmless for a read-only method, because an `Inspect`
    /// reporting the wrong container is caught by "the consumer's own ownership
    /// check". A `LogsChunk` carries bytes and no labels, so the consumer has
    /// nothing to check with, and the container seeded here carries the
    /// caller's own owner labels on purpose -- without the identity gate the
    /// ownership guard is satisfied and another sandbox's output goes back.
    ///
    /// The second assertion is the one that matters: a refusal that still
    /// carried the bytes would satisfy the first.
    func testAHexSandboxIdIsRefusedRatherThanResolvedToAnUnrelatedContainer() async throws {
        let managers = try Self.managers()
        try await Self.seed(managers, labels: SandboxIdentity.labels(from: Self.ownerLabels))
        let (stdout, _) = try managers.containerManager.logManager
            .createLogWriters(dockerID: Self.dockerID)
        try stdout.write(Data("another sandbox's output\n".utf8))

        // Self.dockerID is 64 `a`s, so this is a prefix of it.
        let chunks = await managers.makeService().logChunks(
            request: Arca_Engine_V1_LogsRequest.with { $0.sandboxID = "aaaa" }
        )

        XCTAssertEqual(chunks.count, 1)
        guard case .error(let error) = chunks.first?.outcome else {
            return XCTFail("expected the error arm: \(String(describing: chunks.first?.outcome))")
        }
        XCTAssertEqual(error.code, EngineErrorCode.invalidResourceIdentity.rawValue)
        XCTAssertEqual(error.resource, "aaaa")
        XCTAssertFalse(
            error.message.contains("another sandbox"),
            "a refusal must not carry the log it refused to read"
        )
    }

    /// A sandbox that is not there is `not_found`. `Inspect` answers `absent`
    /// for the same read, because `InspectResponse` has an absent arm and
    /// `LogsChunk` has two arms and no third.
    func testAnAbsentSandboxIsNotFound() async throws {
        let managers = try Self.managers()
        try await managers.containerManager.loadPersistedState()

        let chunks = await managers.makeService().logChunks(
            request: Arca_Engine_V1_LogsRequest.with { $0.sandboxID = Self.sandboxID }
        )

        XCTAssertEqual(chunks.count, 1)
        guard case .error(let error) = chunks.first?.outcome else {
            return XCTFail("expected the error arm: \(String(describing: chunks.first?.outcome))")
        }
        XCTAssertEqual(error.code, EngineErrorCode.notFound.rawValue)
        XCTAssertEqual(error.resource, Self.sandboxID)
    }

    /// A sandbox that exists but has never run has no log, and no log is an
    /// empty stream rather than a failure: `getLogPaths` answers nil until the
    /// container's writers have been created, which is what a
    /// created-but-never-started sandbox looks like.
    func testASandboxThatHasNeverRunAnswersAnEmptyStreamRatherThanAnError() async throws {
        let managers = try Self.managers()
        try await Self.seed(managers, labels: SandboxIdentity.labels(from: Self.ownerLabels))

        let chunks = await managers.makeService().logChunks(
            request: Arca_Engine_V1_LogsRequest.with { $0.sandboxID = Self.sandboxID }
        )

        XCTAssertEqual(chunks, [], "a sandbox that has never run has an empty log, not an error")
    }

    /// The filter reaches the reader from the request, and an absent field is
    /// "from the beginning" rather than zero.
    ///
    /// `LogsRequest.since_unix_millis` is an `optional int64`, so the generated
    /// `sinceUnixMillis` reads `0` when unset -- an implementation that passed
    /// it through without consulting `hasSinceUnixMillis` would filter from the
    /// epoch, which returns everything and so looks identical here. What
    /// separates them is the filtered call: a request whose `since` is in the
    /// future must return nothing.
    func testTheRequestsSinceFilterReachesTheReader() async throws {
        let managers = try Self.managers()
        try await Self.seed(managers, labels: SandboxIdentity.labels(from: Self.ownerLabels))
        let (stdout, _) = try managers.containerManager.logManager
            .createLogWriters(dockerID: Self.dockerID)
        try stdout.write(Data("now\n".utf8))

        let service = managers.makeService()
        let unfiltered = await service.logChunks(
            request: Arca_Engine_V1_LogsRequest.with { $0.sandboxID = Self.sandboxID }
        )
        XCTAssertEqual(try Self.concatenated(unfiltered), Data("now\n".utf8))

        let future = LogEntryTimestamp.unixMillis(from: Date().addingTimeInterval(3600))
        let filtered = await service.logChunks(
            request: Arca_Engine_V1_LogsRequest.with {
                $0.sandboxID = Self.sandboxID
                $0.sinceUnixMillis = future
            }
        )
        XCTAssertEqual(
            filtered, [],
            "a since an hour ahead excludes everything the container has said"
        )
    }

    // MARK: - Fixtures

    private struct Payload {
        let name: String
        let bytes: Data
    }

    /// The payloads requirement 3 names, plus the three the code review of the
    /// writer turned up: a bare `\r`, a CRLF line, and C0 control bytes.
    private static let adversarialPayloads: [Payload] = [
        Payload(name: "an embedded double quote", bytes: Data(#"say "hi" now"# .utf8)),
        Payload(name: "an embedded backslash", bytes: Data(#"C:\path\to\thing"# .utf8)),
        Payload(name: "an embedded newline", bytes: Data("first\nsecond\n".utf8)),
        Payload(name: "an embedded tab", bytes: Data("column\tcolumn\n".utf8)),
        Payload(name: "a lone opening brace", bytes: Data("{\n".utf8)),
        Payload(
            name: "a line that looks like an entry",
            bytes: Data(#"{"stream":"stderr","log":"forged","time":"2026-01-01T00:00:00.000Z"}"#
                .appending("\n").utf8)
        ),
        Payload(name: "a bare carriage return", bytes: Data("progress\r".utf8)),
        Payload(name: "a CRLF line ending", bytes: Data("dos\r\n".utf8)),
        Payload(
            name: "C0 control bytes",
            bytes: Data("bell\u{07}vtab\u{0B}nul\u{00}esc\u{1B}\n".utf8)
        ),
        Payload(name: "non-UTF-8 bytes", bytes: Data([0xFF, 0xFE, 0x00, 0x80, 0xC3, 0x28])),
        // The three bytes of `€` split across two writes, which is what an
        // ordinary text log looks like when a chunk boundary falls inside a
        // multi-byte sequence.
        Payload(name: "the first half of a split UTF-8 sequence", bytes: Data([0xE2, 0x82])),
        Payload(name: "the second half of a split UTF-8 sequence", bytes: Data([0xAC])),
    ]

    private static let logger = Logger(label: "arca-engine-tests")
    private static let dockerID = String(repeating: "a", count: 64)
    private static let sandboxID = "logs-a1b2c3d4e5f6"
    private static let image = "ghcr.io/liquescent-development/gascan/workspace@sha256:"
        + String(repeating: "1", count: 64)

    private static let ownerLabels = Arca_Engine_V1_OwnerLabels.with {
        $0.managedBy = "gascan"
        $0.sandboxID = sandboxID
    }

    private static func throwawayRoot() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("arca-logs-tests-\(UUID().uuidString)")
    }

    /// The engine's own managers over a throwaway state root, as `InspectTests`
    /// builds them and for the same reason: this is the factory `arca-engine`
    /// calls, so what these tests read is what it serves.
    private static func managers() throws -> EngineManagers {
        try EngineManagers(
            stateRoot: throwawayRoot(),
            kernelPath: URL(fileURLWithPath: "/opt/arca/vmlinux"),
            logLevel: "info",
            logger: logger
        )
    }

    /// One container row through `StateStore` and then `loadPersistedState()`,
    /// which is the restore path the engine itself runs.
    private static func seed(
        _ managers: EngineManagers, labels: [String: String]
    ) async throws {
        try await managers.stateStore.saveContainer(
            id: dockerID,
            name: sandboxID,
            image: image,
            imageID: "sha256:probe",
            createdAt: Date(),
            status: "created",
            running: false,
            paused: false,
            restarting: false,
            pid: 0,
            exitCode: 0,
            startedAt: nil,
            finishedAt: Date(),
            stoppedByUser: false,
            entrypoint: nil,
            configJSON: String(
                decoding: try JSONEncoder().encode(
                    ContainerConfiguration(image: image, labels: labels)
                ),
                as: UTF8.self
            ),
            hostConfigJSON: String(
                decoding: try JSONEncoder().encode(HostConfig(portBindings: [:])),
                as: UTF8.self
            )
        )
        try await managers.containerManager.loadPersistedState()
    }

    /// The entries in a log file, in file order.
    private static func entries(at path: URL) throws -> [ContainerLogEntry] {
        try Data(contentsOf: path)
            .split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
            .map { try ContainerLogCodec.decode(line: Data($0)) }
    }

    /// A log file written entry by entry at dates the caller chooses, so a
    /// timestamp assertion has an exact boundary rather than a race.
    private static func write(_ lines: [(Date, String)], to path: URL) throws {
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        var contents = Data()
        for (date, text) in lines {
            contents.append(try ContainerLogCodec.encode(
                ContainerLogCodec.entry(stream: "stdout", payload: Data(text.utf8), at: date)
            ))
        }
        try contents.write(to: path)
    }

    /// The data frames concatenated, failing on any frame that is not one.
    private static func concatenated(
        _ chunks: [Arca_Engine_V1_LogsChunk],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> Data {
        var buffer = Data()
        for chunk in chunks {
            guard case .data(let data) = chunk.outcome else {
                XCTFail(
                    "expected a data frame: \(String(describing: chunk.outcome))",
                    file: file, line: line
                )
                throw XCTSkip("no data frame to concatenate")
            }
            buffer.append(data)
        }
        return buffer
    }

    /// Bytes as something a failure message can be read from.
    private static func readable(_ data: Data) -> String {
        "\(Array(data))"
    }
}
