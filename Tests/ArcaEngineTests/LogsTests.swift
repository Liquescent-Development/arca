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
    /// nothing read them back with any expectation of exactness: every reader
    /// that existed `continue`d past a line it could not parse, so a payload that
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
    func testEveryAdversarialPayloadSurvivesTheWriterAndComesBackByteExact() async throws {
        let root = Self.throwawayRoot()
        let manager = ContainerLogManager(logRoot: root, logger: Self.logger)
        let (stdout, _) = try manager.createLogWriters(dockerID: Self.dockerID)

        var expected = Data()
        for payload in Self.adversarialPayloads {
            try stdout.write(payload.bytes)
            expected.append(payload.bytes)
        }

        let paths = try XCTUnwrap(manager.getLogPaths(dockerID: Self.dockerID))
        let read = try await Self.read(paths.combinedPath)

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
    func testEachAdversarialPayloadSurvivesOnItsOwn() async throws {
        for payload in Self.adversarialPayloads {
            let root = Self.throwawayRoot()
            let manager = ContainerLogManager(logRoot: root, logger: Self.logger)
            let (stdout, _) = try manager.createLogWriters(dockerID: Self.dockerID)
            try stdout.write(payload.bytes)

            let paths = try XCTUnwrap(manager.getLogPaths(dockerID: Self.dockerID))
            do {
                let read = try await Self.read(paths.combinedPath)
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
    /// writing something the three Docker-surface readers -- which reach for
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

    /// **One entry is one line to every reader of these files, and U+2028 is
    /// the payload that proves it has to be.**
    ///
    /// `JSONEncoder` escapes the C0 controls but leaves U+2028, U+2029 and
    /// U+0085 raw, because all three are legal inside a JSON string.
    /// Foundation's `CharacterSet.newlines` covers all three, and the three
    /// Docker-surface readers each split file content with
    /// `components(separatedBy: .newlines)` -- so a container that printed one of
    /// them had its entry cut in half, both halves failed to parse, and both
    /// were skipped. **The line vanished from `docker logs` with no error**, and
    /// the round-trip tests above could not see it because `LogReader` splits on
    /// `0x0A` and was unaffected.
    ///
    /// That is now impossible to reintroduce in one place and not the other:
    /// `ContainerLogCodec.lines` is the only definition of "a line" and all four
    /// readers call it. This test drives the three characters through a real
    /// writer and asserts the shared splitter sees one line each.
    ///
    /// The `.newlines` comparison is the reason, kept executable. It asserts a
    /// property of Foundation rather than of this code, and it is here so that
    /// the trap is visible at the assertion rather than only in this comment.
    func testTheSharedSplitterSeesOneLineWhereNewlinesWouldSeeTwo() throws {
        for (name, scalar) in [
            ("U+2028 LINE SEPARATOR", "\u{2028}"),
            ("U+2029 PARAGRAPH SEPARATOR", "\u{2029}"),
            ("U+0085 NEL", "\u{0085}"),
        ] {
            let root = Self.throwawayRoot()
            let manager = ContainerLogManager(logRoot: root, logger: Self.logger)
            let (stdout, _) = try manager.createLogWriters(dockerID: Self.dockerID)
            try stdout.write(Data("before\(scalar)after\n".utf8))

            let paths = try XCTUnwrap(manager.getLogPaths(dockerID: Self.dockerID))
            let contents = try Data(contentsOf: paths.combinedPath)

            XCTAssertEqual(
                ContainerLogCodec.allLines(of: contents).count, 1,
                "\(name) must leave one entry on one line"
            )
            XCTAssertEqual(
                try ContainerLogCodec.payload(
                    of: ContainerLogCodec.decode(
                        line: try XCTUnwrap(ContainerLogCodec.allLines(of: contents).first)
                    )
                ),
                Data("before\(scalar)after\n".utf8),
                "\(name) must survive the entry it is in"
            )
            XCTAssertEqual(
                String(decoding: contents, as: UTF8.self)
                    .components(separatedBy: .newlines)
                    .filter { !$0.isEmpty }
                    .count,
                2,
                "the reason this test exists: `.newlines` cuts \(name) in half, and a "
                    + "reader that used it would skip both halves"
            )
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
    func testCombinedLogHoldsBothStreamsInTheOrderTheyWereWritten() async throws {
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
        let combined = try await Self.read(paths.combinedPath)
        XCTAssertEqual(combined, Data("one\ntwo\nthree\nfour\n".utf8))
    }

    /// **The restore path registers all three paths or none.**
    ///
    /// `loadPersistedState` gates registration on the log files existing, and
    /// `combined.log` was not in that guard -- it could not have been, since
    /// nothing wrote the file. Now that `Logs` reads it, a container restored
    /// from a state store written before it had a writer would have its paths
    /// registered, `getLogPaths` would answer non-nil, and the read would fail
    /// `command_io` on a file that was never there. "This container has no log"
    /// and "this container's log is gone" are different facts and this is the
    /// boundary between them.
    func testARestoredContainerWithNoCombinedLogRegistersNoPathsAtAll() async throws {
        let managers = try Self.managers()

        // The two files a pre-change engine left behind, and not the third.
        let logDir = managers.containerManager.logManager.containerLogDir(dockerID: Self.dockerID)
        try FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        for name in ["stdout.log", "stderr.log"] {
            try Data().write(to: logDir.appendingPathComponent(name))
        }

        try await Self.seed(managers, labels: SandboxIdentity.labels(from: Self.ownerLabels))

        XCTAssertNil(
            managers.containerManager.logManager.getLogPaths(dockerID: Self.dockerID),
            "a container whose combined.log is absent must register no paths"
        )
        let frames = try await Self.frames(
            managers.makeService(),
            Arca_Engine_V1_LogsRequest.with { $0.sandboxID = Self.sandboxID }
        )
        XCTAssertEqual(
            frames, [],
            "and must therefore answer an empty log rather than a read failure"
        )
    }

    /// A `createLogWriters` that cannot open a stream file registers nothing.
    ///
    /// The combined handle is opened before either writer, so a writer that
    /// fails leaves a handle only `removeLogs` would ever close and, if the
    /// registration ran first, `logPaths` naming writers that do not exist.
    /// Both dictionaries are now written after the last fallible step.
    ///
    /// **The closing half of that is not falsifiable from here.** A retained
    /// handle and a closed one differ only in a file descriptor; the observable
    /// half is that nothing is registered, which is what this asserts.
    func testAFailedCreateLogWritersRegistersNothing() throws {
        let root = Self.throwawayRoot()
        let manager = ContainerLogManager(logRoot: root, logger: Self.logger)

        // A directory where `stdout.log` belongs, so opening it for writing
        // fails while the combined file opens fine.
        try FileManager.default.createDirectory(
            at: manager.containerLogDir(dockerID: Self.dockerID)
                .appendingPathComponent("stdout.log"),
            withIntermediateDirectories: true
        )

        XCTAssertThrowsError(try manager.createLogWriters(dockerID: Self.dockerID))
        XCTAssertNil(
            manager.getLogPaths(dockerID: Self.dockerID),
            "a failed creation must not leave paths registered for writers that do not exist"
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
    func testSinceMillisSeparatesEntriesInsideOneSecond() async throws {
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

        let atBoundary = try await Self.read(combinedPath, since: middle)
        XCTAssertEqual(
            atBoundary, Data("second\nthird\n".utf8),
            "since is inclusive of the entry stamped exactly at it"
        )
        let pastBoundary = try await Self.read(combinedPath, since: middle + 1)
        XCTAssertEqual(
            pastBoundary, Data("third\n".utf8),
            "one millisecond later excludes the entry at the boundary"
        )
        let unfiltered = try await Self.read(combinedPath)
        XCTAssertEqual(
            unfiltered, Data("first\nsecond\nthird\n".utf8),
            "an absent filter is from the beginning"
        )
    }

    /// A line the codec cannot read is an error, not a skipped line.
    ///
    /// All three of the repository's Docker-surface readers `continue` past one,
    /// which turns a truncated write or a foreign file into a short log
    /// indistinguishable from a complete one. `LogsChunk` has an error arm and
    /// `Logs` uses it.
    func testAnUnreadableLineIsAnErrorRatherThanASkippedLine() async throws {
        let root = Self.throwawayRoot()
        let combinedPath = root.appendingPathComponent("combined.log")
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true
        )
        try Data("{\"stream\":\"stdout\",\"log\":\"good\\n\",\"time\":\"2026-08-15T00:00:00.000Z\"}\nnot an entry\n".utf8)
            .write(to: combinedPath)

        do {
            _ = try await Self.read(combinedPath)
            XCTFail("an unreadable line must fail the call, not be skipped")
        } catch {
            // The arm this test exists for.
        }
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
    func testChunksAreCutOnTheByteLimitAndNotOnEntryBoundaries() async throws {
        let root = Self.throwawayRoot()
        let combinedPath = root.appendingPathComponent("combined.log")
        let second = Date(timeIntervalSince1970: 1_755_300_000)
        let lines = (0..<20).map { index in
            (second, String(format: "%09d", index) + "\n")
        }
        try Self.write(lines, to: combinedPath)

        let chunks = try await Self.chunks(combinedPath, limit: 17)

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

    /// **The shipped `chunkByteLimit`, pinned on both sides by its own reason.**
    ///
    /// The constant was unfalsifiable when it landed: a review changed it to
    /// `7` and `swift test --filter ArcaEngineTests` stayed at 194 tests with 0
    /// failures, because the only chunking test passed its own limit through the
    /// seam parameter and never touched the value production uses.
    ///
    /// Both bounds are the constant's own doc comment turned into assertions,
    /// and neither is arbitrary. **Above:** past grpc-swift's 4MiB default
    /// receive limit, a frame becomes the size error the streaming contract
    /// exists to avoid -- streaming would then have bought nothing. **Below:** a
    /// small limit turns an ordinary log into thousands of frames, each with its
    /// own proto and its own `send`; 4KiB is a page, and a limit under one is
    /// not a chunk size, it is a bug.
    func testTheShippedChunkLimitStaysInsideTheBoundsItsReasonGives() {
        XCTAssertLessThan(
            LogReader.chunkByteLimit, 4 * 1024 * 1024,
            "a frame at or past grpc-swift's 4MiB default receive limit is the size "
                + "error the streaming contract exists to avoid"
        )
        XCTAssertGreaterThanOrEqual(
            LogReader.chunkByteLimit, 4 * 1024,
            "a limit under a page turns an ordinary log into thousands of frames"
        )
    }

    /// The same limit, **through the whole handler**, which is the only place
    /// that says what the engine actually cuts on.
    ///
    /// The bounds above pin the value. This pins that `Logs` uses it: the
    /// handler calls `LogReader.stream` with no `chunkByteLimit` argument, and a
    /// handler that passed its own would satisfy every other test in this file,
    /// because every other log here fits in one frame either way.
    ///
    /// **The fixture is a literal and does not move with the constant.** It was
    /// `chunkByteLimit * 5 / 2`, which made the test circular: at
    /// `chunkByteLimit = 7` the line count computed to **zero**, the log was
    /// empty, the expected frame count computed to zero, and every assertion
    /// held vacuously -- the test was not among the failures of that mutation.
    /// A test that sizes its input from the thing it is pinning cannot catch a
    /// change to it. 160KiB is fixed here and the bounds test above keeps
    /// `chunkByteLimit` under a quarter of it, so there are always at least two
    /// frames.
    func testTheHandlerCutsAnOrdinaryLogOnTheShippedLimit() async throws {
        let managers = try Self.managers()
        try await Self.seed(managers, labels: SandboxIdentity.labels(from: Self.ownerLabels))
        let (stdout, _) = try managers.containerManager.logManager
            .createLogWriters(dockerID: Self.dockerID)
        let written = try Self.writeFixedLog(to: stdout)

        let frames = try await Self.frames(
            managers.makeService(),
            Arca_Engine_V1_LogsRequest.with { $0.sandboxID = Self.sandboxID }
        )
        let sizes = try Self.dataSizes(frames)

        XCTAssertGreaterThanOrEqual(
            sizes.count, 2,
            "a \(written)-byte log must be more than one frame at any limit the bounds "
                + "test permits; a single frame means the handler cut on something else"
        )
        XCTAssertEqual(
            sizes.count,
            written / LogReader.chunkByteLimit + (written % LogReader.chunkByteLimit == 0 ? 0 : 1),
            "the frame count must follow the shipped limit; the log was \(written) bytes"
        )
        XCTAssertTrue(
            sizes.dropLast().allSatisfy { $0 == LogReader.chunkByteLimit },
            "every frame but the last is exactly the limit; they were \(sizes)"
        )
        XCTAssertEqual(
            sizes.reduce(0, +), written,
            "the frames must concatenate back to the whole log"
        )
    }

    /// **Frames go out as they are cut, not after the whole log has been read.**
    ///
    /// This is the one observable difference between the streaming reader and
    /// the buffering one it replaced, and it is why the test is shaped like
    /// this. The log holds more than one frame of good entries and then a line
    /// that cannot be parsed. A reader that emits as it goes sends its data
    /// frames first and only then meets the corruption; a reader that read,
    /// filtered, concatenated and cut the whole log before handing anything
    /// back would meet the corruption first and the consumer would receive the
    /// error frame **and nothing else**. Both are "an error frame arrives", and
    /// only the position of the data frames tells them apart.
    ///
    /// It also states plainly what `Logs` does with a log that breaks partway:
    /// the readable prefix has already gone, and the error follows it.
    /// `gascan-arca/src/backend.rs` discards the prefix on the error arm, which
    /// is the consumer's decision and not this engine's.
    func testFramesGoOutBeforeALaterCorruptionIsReached() async throws {
        let managers = try Self.managers()
        try await Self.seed(managers, labels: SandboxIdentity.labels(from: Self.ownerLabels))
        let (stdout, _) = try managers.containerManager.logManager
            .createLogWriters(dockerID: Self.dockerID)

        _ = try Self.writeFixedLog(to: stdout)
        let paths = try XCTUnwrap(
            managers.containerManager.logManager.getLogPaths(dockerID: Self.dockerID)
        )
        let handle = try FileHandle(forWritingTo: paths.combinedPath)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("not an entry\n".utf8))
        try handle.close()

        let frames = try await Self.frames(
            managers.makeService(),
            Arca_Engine_V1_LogsRequest.with { $0.sandboxID = Self.sandboxID }
        )

        XCTAssertGreaterThanOrEqual(
            frames.count, 2,
            "the readable prefix must have gone out before the corruption was reached; "
                + "one frame alone means the whole log was read before anything was sent"
        )
        for (index, frame) in frames.dropLast().enumerated() {
            guard case .data = frame.outcome else {
                return XCTFail("frame \(index) must be data: \(String(describing: frame.outcome))")
            }
        }
        guard case .error(let error) = frames.last?.outcome else {
            return XCTFail("the last frame must be the error: \(String(describing: frames.last))")
        }
        XCTAssertEqual(error.code, EngineErrorCode.commandIo.rawValue)
        XCTAssertEqual(error.resource, Self.sandboxID)
    }

    /// **A sink that fails leaves as itself, and never as an engine error.**
    ///
    /// The two failures the handler can meet demand opposite answers: a log it
    /// could not read is reported to the consumer in an error frame, and a
    /// consumer that has gone away cannot be reported anything. A `catch` that
    /// did not tell them apart would either describe a broken connection as
    /// `command_io` -- putting a transport message inside an engine error's
    /// prose -- or swallow a genuine read failure because the send after it
    /// failed too.
    func testASendFailureLeavesAsItselfRatherThanAsAnEngineError() async throws {
        struct WriterGone: Error {}

        let managers = try Self.managers()
        try await Self.seed(managers, labels: SandboxIdentity.labels(from: Self.ownerLabels))
        let (stdout, _) = try managers.containerManager.logManager
            .createLogWriters(dockerID: Self.dockerID)
        try stdout.write(Data("something\n".utf8))

        var delivered = 0
        do {
            try await managers.makeService().streamLogs(
                request: Arca_Engine_V1_LogsRequest.with { $0.sandboxID = Self.sandboxID }
            ) { _ in
                delivered += 1
                throw WriterGone()
            }
            XCTFail("a sink that throws must carry its own error out of streamLogs")
        } catch is WriterGone {
            // The arm this test exists for.
        } catch {
            XCTFail("the sink's own error must arrive unchanged, not as \(error)")
        }
        XCTAssertEqual(delivered, 1, "the sink must not be called again after it failed")
    }

    /// **A file with no line terminator is refused at the cap, not after the
    /// whole of it is in memory.**
    ///
    /// The class comment claimed peak memory was constant in the log's size. It
    /// was not: MEASURED by review, a 512KiB file containing no `0x0A` byte
    /// accumulated all eight read windows into the carry before the decode
    /// failed, so the real bound was the longest run without a terminator --
    /// the whole file, for a file that is not a log. That is not a hypothetical
    /// input for this reader in particular: it throws on an unreadable line
    /// precisely because it exists to notice a truncated or foreign file, and a
    /// foreign file is the one with no terminators.
    ///
    /// The bound is a constant now because `maxEntryBytes` makes it one. What
    /// this test cannot see is the memory itself -- it asserts the refusal and
    /// its message, and the bound follows from the refusal happening at the cap
    /// rather than at the end of the file.
    func testAFileWithNoTerminatorIsRefusedAtTheCapRatherThanHeldWhole() async throws {
        let root = Self.throwawayRoot()
        let combinedPath = root.appendingPathComponent("combined.log")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // One byte past the cap, so the refusal is the cap's and not the
        // decode's, and no `0x0A` anywhere.
        try Data(repeating: UInt8(ascii: "x"), count: LogReader.maxEntryBytes + 1)
            .write(to: combinedPath)

        do {
            _ = try await Self.read(combinedPath)
            XCTFail("a file with no terminator must be refused")
        } catch let error as LogReaderError {
            guard case .entryTooLong(_, let limit) = error else {
                return XCTFail("expected entryTooLong, got \(error)")
            }
            XCTAssertEqual(limit, LogReader.maxEntryBytes)
            XCTAssertTrue(
                error.description.contains("\(LogReader.maxEntryBytes)"),
                "the message must name the limit: \(error.description)"
            )
        }
    }

    /// **An unreadable line's error message is bounded, whatever the line is.**
    ///
    /// MEASURED while running the mutation that removes the cap above: a 4MiB
    /// line with no terminator produced a **4MiB error message**, because the
    /// whole line went into `unreadableEntry`, out through
    /// `engineErrorCatching(.commandIo)` into `EngineError.message`, and onto
    /// the wire. A diagnostic the size of the thing it diagnoses is a second
    /// failure on top of the first.
    ///
    /// Asserted against a corrupt line the cap does not catch, because the two
    /// bounds are independent: the cap stops a file with no terminators, and
    /// this stops a long line that *is* terminated and still will not parse.
    func testAnUnreadableLinesErrorMessageIsBoundedHoweverLongTheLineIs() async throws {
        let root = Self.throwawayRoot()
        let combinedPath = root.appendingPathComponent("combined.log")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var corrupt = Data(repeating: UInt8(ascii: "x"), count: 300_000)
        corrupt.append(UInt8(ascii: "\n"))
        try corrupt.write(to: combinedPath)

        do {
            _ = try await Self.read(combinedPath)
            XCTFail("a line that is not an entry must be refused")
        } catch {
            let message = "\(error)"
            XCTAssertLessThan(
                message.count, 2_000,
                "the message must not carry the line; it was \(message.count) characters"
            )
            XCTAssertTrue(
                message.contains("300000 bytes in total"),
                "and must still say how long the line really was: \(message.prefix(400))"
            )
        }
    }

    /// The cap refuses a run with no terminator, and nothing else.
    ///
    /// A log larger than the cap made of ordinary terminated entries must come
    /// back whole. A cap that bounded the *file* rather than the *carry* would
    /// pass the test above and silently refuse every large log, which is the
    /// failure that would be worst to ship: it turns a working `Logs` into
    /// `command_io` at exactly the size the streaming contract exists for.
    func testALogLargerThanTheCapIsReturnedWholeWhenItsLinesAreTerminated() async throws {
        let root = Self.throwawayRoot()
        let manager = ContainerLogManager(logRoot: root, logger: Self.logger)
        let (stdout, _) = try manager.createLogWriters(dockerID: Self.dockerID)

        let line = String(repeating: "y", count: 999) + "\n"
        let lineCount = LogReader.maxEntryBytes / line.utf8.count + 8
        for _ in 0..<lineCount {
            try stdout.write(Data(line.utf8))
        }

        let paths = try XCTUnwrap(manager.getLogPaths(dockerID: Self.dockerID))
        let read = try await Self.read(paths.combinedPath)

        XCTAssertEqual(
            read.count, lineCount * line.utf8.count,
            "the cap bounds one entry, not the log; a \(read.count)-byte answer for a "
                + "\(lineCount * line.utf8.count)-byte log means it bounds the wrong thing"
        )
    }

    /// An empty log is an empty stream, not one empty frame.
    func testAnEmptyLogIsNoChunksAtAll() async throws {
        let root = Self.throwawayRoot()
        let manager = ContainerLogManager(logRoot: root, logger: Self.logger)
        _ = try manager.createLogWriters(dockerID: Self.dockerID)
        let paths = try XCTUnwrap(manager.getLogPaths(dockerID: Self.dockerID))

        let chunks = try await Self.chunks(paths.combinedPath)
        XCTAssertEqual(chunks, [])
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

        let chunks = try await Self.frames(
            managers.makeService(),
            Arca_Engine_V1_LogsRequest.with { $0.sandboxID = Self.sandboxID }
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

        let chunks = try await Self.frames(
            managers.makeService(),
            Arca_Engine_V1_LogsRequest.with { $0.sandboxID = Self.sandboxID }
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
        let chunks = try await Self.frames(
            managers.makeService(),
            Arca_Engine_V1_LogsRequest.with { $0.sandboxID = "aaaa" }
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

        let chunks = try await Self.frames(
            managers.makeService(),
            Arca_Engine_V1_LogsRequest.with { $0.sandboxID = Self.sandboxID }
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

        let chunks = try await Self.frames(
            managers.makeService(),
            Arca_Engine_V1_LogsRequest.with { $0.sandboxID = Self.sandboxID }
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
        let unfiltered = try await Self.frames(
            service,
            Arca_Engine_V1_LogsRequest.with { $0.sandboxID = Self.sandboxID }
        )
        XCTAssertEqual(try Self.concatenated(unfiltered), Data("now\n".utf8))

        let future = LogEntryTimestamp.unixMillis(from: Date().addingTimeInterval(3600))
        let filtered = try await Self.frames(
            service,
            Arca_Engine_V1_LogsRequest.with {
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
        // The three Unicode separators `JSONEncoder` leaves raw and
        // `CharacterSet.newlines` cuts on. See
        // `testTheSharedSplitterSeesOneLineWhereNewlinesWouldSeeTwo`.
        Payload(
            name: "the Unicode line separators",
            bytes: Data("ls\u{2028}ps\u{2029}nel\u{0085}\n".utf8)
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

    /// Every frame the streaming reader produces, in order.
    ///
    /// `limit` omitted calls the **production overload**, so a test that omits
    /// it exercises the shipped `chunkByteLimit` rather than one the test chose.
    /// That distinction is the whole of
    /// `testTheHandlerCutsAnOrdinaryLogOnTheShippedLimit`.
    private static func chunks(
        _ combinedPath: URL, since: Int64? = nil, limit: Int? = nil
    ) async throws -> [Data] {
        var collected: [Data] = []
        if let limit {
            try await LogReader.stream(
                combinedPath: combinedPath, sinceUnixMillis: since, chunkByteLimit: limit
            ) { collected.append($0) }
        } else {
            try await LogReader.stream(
                combinedPath: combinedPath, sinceUnixMillis: since
            ) { collected.append($0) }
        }
        return collected
    }

    /// Those frames concatenated, which is what the consumer receives.
    private static func read(_ combinedPath: URL, since: Int64? = nil) async throws -> Data {
        try await chunks(combinedPath, since: since)
            .reduce(into: Data()) { $0.append($1) }
    }

    /// The frames the service sends, collected. The service holds none of them;
    /// this helper does, and only because a test's log is a few lines long.
    private static func frames(
        _ service: SandboxEngineService, _ request: Arca_Engine_V1_LogsRequest
    ) async throws -> [Arca_Engine_V1_LogsChunk] {
        var collected: [Arca_Engine_V1_LogsChunk] = []
        try await service.streamLogs(request: request) { collected.append($0) }
        return collected
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

    /// A log of a fixed, literal size, written one 100-byte entry at a time.
    ///
    /// 160KiB, chosen here and not derived from `chunkByteLimit`: a fixture that
    /// scales with the constant under test moves with it and stops pinning it.
    /// Returns the byte count so a caller asserts against a number it did not
    /// compute from the constant either.
    @discardableResult
    private static func writeFixedLog(to writer: FileLogWriter) throws -> Int {
        let line = String(repeating: "x", count: 99) + "\n"
        let lineCount = 160 * 1024 / line.utf8.count
        for _ in 0..<lineCount {
            try writer.write(Data(line.utf8))
        }
        return lineCount * line.utf8.count
    }

    /// Every frame's payload size, failing on any frame that is not data.
    private static func dataSizes(
        _ frames: [Arca_Engine_V1_LogsChunk],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> [Int] {
        try frames.map { frame in
            guard case .data(let data) = frame.outcome else {
                XCTFail(
                    "expected a data frame: \(String(describing: frame.outcome))",
                    file: file, line: line
                )
                throw XCTSkip("no data frame to measure")
            }
            return data.count
        }
    }

    /// Bytes as something a failure message can be read from.
    private static func readable(_ data: Data) -> String {
        "\(Array(data))"
    }
}
