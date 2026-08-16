import ContainerBridge
import Containerization
import Foundation
import Logging
import SandboxEngineProto
import XCTest

@testable import ArcaEngine

/// `Exec`: the two adapters it is built out of, and every refusal it can answer
/// before a guest process exists.
///
/// **What this suite covers is deliberately less than `Exec`, and saying so
/// precisely is half the work.** `startExec` needs a native container instance
/// (`ExecManager.swift:262-264`) and no VM-free path can produce one -- nor can
/// one put a container into state `running`, which `createExec` demands
/// (`ExecManager.swift:197`, measured in the note on `ExecContainerSource`). So everything below
/// stops at or before `createExec`. **Nothing here says a byte ever reached a
/// guest, that stdin was ever read, that a signal was ever delivered, or that
/// `tty` merges stderr into stdout.** Those are gascan's live `exec.rs`, and the
/// `tty` and `signals` capability flags are earned there and nowhere else.
///
/// What this suite does buy: the opening-frame rule, both identity refusals in
/// the order that makes them mean anything, argv this engine cannot carry, the
/// mapping from `ExecManager`'s vocabulary onto the contract's, and the two
/// adapters -- which are pure value transformations and are therefore fully
/// provable here.
///
/// XCTest and not swift-testing, and in `ArcaEngineTests` and not `ArcaTests`,
/// for the two reasons recorded on `ExecSignalTests`: Gas Can's release gate
/// runs SwiftPM with `--disable-swift-testing` and filters on
/// `^ArcaEngineTests\.`, so a `@Test`, or a class in the other target, is a test
/// nothing executes.
final class ExecTests: XCTestCase {

    // MARK: - The adapters

    /// One write, one frame, on the stream the writer was built for.
    func testEachWriteBecomesOneFrameOnItsOwnStream() async throws {
        let relay = ExecFrameRelay()
        try ExecOutputWriter(stream: .stdout, relay: relay).write(Data("out".utf8))
        try ExecOutputWriter(stream: .stderr, relay: relay).write(Data("err".utf8))
        relay.finish()

        let frames = await Self.drain(relay)
        XCTAssertEqual(frames.count, 2, "one write must produce exactly one frame")
        XCTAssertEqual(frames.first?.frame, .stdout(Data("out".utf8)))
        XCTAssertEqual(frames.last?.frame, .stderr(Data("err".utf8)))
    }

    /// **The acceptance test for `ExecOutputWriter.close()`, and it exists
    /// because the obvious implementation of that method is wrong.**
    ///
    /// `startExec` closes stdout and then stderr after the process exits
    /// (`ExecManager.swift:334-354`), and the two writers share one relay. A
    /// `close()` that finished the relay -- which is what a `Writer` is normally
    /// for -- would end the response stream at the first close, dropping
    /// whatever the other stream had still to say and, after it, the `Exit`
    /// frame that is the whole answer.
    ///
    /// MEASURED, with `close()` changed to `{ relay.finish() }` and nothing else
    /// touched: `swift test --disable-swift-testing --filter ArcaEngineTests` ->
    /// `Executed 221 tests, with 2 failures` against a baseline of 221 with 0.
    /// The two are this test, on `stderr said nothing after stdout was closed`,
    /// and `testTheExitFrameSurvivesBothWritersClosing`, on `the exit frame did
    /// not survive both writers closing: []`. Nothing else in the suite moves.
    func testClosingOneWriterDoesNotEndTheOther() async throws {
        let relay = ExecFrameRelay()
        let stdout = ExecOutputWriter(stream: .stdout, relay: relay)
        let stderr = ExecOutputWriter(stream: .stderr, relay: relay)

        try stdout.write(Data("before".utf8))
        try stdout.close()
        try stderr.write(Data("after".utf8))
        relay.finish()

        let frames = await Self.drain(relay)
        XCTAssertEqual(
            frames.map(\.frame),
            [.stdout(Data("before".utf8)), .stderr(Data("after".utf8))],
            "stderr said nothing after stdout was closed"
        )
    }

    /// The same defect from the side that matters most: the `Exit` frame is sent
    /// after `startExec` has closed both writers, so a `close()` that ended the
    /// stream would take the exit status with it.
    func testTheExitFrameSurvivesBothWritersClosing() async throws {
        let relay = ExecFrameRelay()
        let stdout = ExecOutputWriter(stream: .stdout, relay: relay)
        let stderr = ExecOutputWriter(stream: .stderr, relay: relay)

        try stdout.close()
        try stderr.close()
        relay.send(
            Arca_Engine_V1_ExecServerFrame.with {
                $0.exit = Arca_Engine_V1_Exit.with { exit in exit.code = 7 }
            })
        relay.finish()

        let frames = await Self.drain(relay)
        guard case .exit(let exit) = frames.last?.frame else {
            return XCTFail("the exit frame did not survive both writers closing: \(frames)")
        }
        XCTAssertEqual(exit.code, 7)
    }

    /// Two writers on two threads, one stream, nothing lost and nothing
    /// reordered within a stream.
    ///
    /// This is the property design §2.7 asks for, stated as something a test can
    /// fail. It does **not** assert an interleaving between the two streams:
    /// stdout and stderr are driven by two independent `readabilityHandler`s
    /// (`LinuxProcess.swift:165`, `:184`) and no order between them exists to
    /// assert. What must hold is that every frame arrives exactly once and that
    /// each stream's own frames stay in order, which is what a racing pair of
    /// producers on an unsynchronised sink would break.
    func testConcurrentWritersLoseNothingAndKeepEachStreamInOrder() async throws {
        let count = 200
        let relay = ExecFrameRelay()
        let stdout = ExecOutputWriter(stream: .stdout, relay: relay)
        let stderr = ExecOutputWriter(stream: .stderr, relay: relay)

        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for index in 0..<count {
                    try? stdout.write(Data("o\(index)".utf8))
                }
            }
            group.addTask {
                for index in 0..<count {
                    try? stderr.write(Data("e\(index)".utf8))
                }
            }
            await group.waitForAll()
        }
        relay.finish()

        var out: [String] = []
        var err: [String] = []
        for frame in await Self.drain(relay) {
            switch frame.frame {
            case .stdout(let data): out.append(String(decoding: data, as: UTF8.self))
            case .stderr(let data): err.append(String(decoding: data, as: UTF8.self))
            default: XCTFail("unexpected frame \(String(describing: frame.frame))")
            }
        }
        XCTAssertEqual(out, (0..<count).map { "o\($0)" })
        XCTAssertEqual(err, (0..<count).map { "e\($0)" })
    }

    /// Stdin carries every chunk unchanged and ends -- and *ending* is the
    /// assertion that matters, because finishing this stream is what closes the
    /// guest's stdin (`LinuxProcess.swift:211-240`). A `close()` that did not
    /// finish it would leave a process waiting on input forever.
    func testTheStdinRelayCarriesEveryChunkAndEndsOnClose() async throws {
        let relay = ExecStdinRelay()
        let chunks = [Data("one".utf8), Data(), Data([0xFF, 0xFE])]
        for chunk in chunks {
            relay.send(chunk)
        }
        relay.close()

        var received: [Data] = []
        for await chunk in relay.stream() {
            received.append(chunk)
        }
        XCTAssertEqual(received, chunks, "stdin must arrive byte-exact, empty writes included")
    }

    // MARK: - The opening frame

    func testAStreamThatEndsBeforeItsExecStartIsRefused() async throws {
        let error = try await Self.refusal(from: [])
        XCTAssertEqual(error.code, EngineErrorCode.invalidState.rawValue)
        XCTAssertTrue(
            error.message.contains("ExecStart"),
            "the refusal must name what was missing: \(error.message)"
        )
    }

    /// Any other first frame is a protocol error (`engine.proto:408-411`), and
    /// the message names the frame that arrived -- because "protocol error" on
    /// its own sends the reader to the contract rather than to their own code.
    func testAFirstFrameThatIsNotExecStartIsRefused() async throws {
        let openings: [(Arca_Engine_V1_ExecClientFrame.OneOf_Frame, String)] = [
            (.stdin(Data("hello".utf8)), "stdin"),
            (.resize(Arca_Engine_V1_Resize()), "Resize"),
            (.signal(15), "signal"),
            (.close(Arca_Engine_V1_Close()), "Close"),
        ]
        for (opening, name) in openings {
            let error = try await Self.refusal(from: [
                Arca_Engine_V1_ExecClientFrame.with { $0.frame = opening }
            ])
            XCTAssertEqual(error.code, EngineErrorCode.invalidState.rawValue, "for \(name)")
            XCTAssertTrue(
                error.message.contains(name),
                "the refusal must name the frame that arrived: \(error.message)"
            )
        }
    }

    /// A client frame with its `oneof` unset is refused rather than ignored, for
    /// the reason the contract gives about unset outcomes in the other
    /// direction: a frame that means nothing is not a frame that means nothing
    /// happened.
    func testAFirstFrameWithNothingSetIsRefused() async throws {
        let error = try await Self.refusal(from: [Arca_Engine_V1_ExecClientFrame()])
        XCTAssertEqual(error.code, EngineErrorCode.invalidState.rawValue)
    }

    // MARK: - Identity, before anything is resolved

    /// **The gate `Logs` established, and this test is what says it runs
    /// first.**
    ///
    /// `resolveContainerID` prefix-matches any pure-hex string of four or more
    /// characters against every Docker id the engine holds
    /// (`SandboxIdentity.refusalReason(forSandboxId:)`), and the seeded
    /// container's id is 64 `a`s -- so `aaaa` resolves to it. The container is
    /// labelled, so with the gate removed the call would sail past the ownership
    /// check and be refused by `createExec` instead, as `invalid_state`. The
    /// assertion is therefore on **which** refusal came back, not that one did.
    ///
    /// MEASURED, with the `containerNameRefusal` guard in `driveExec` deleted:
    /// `Executed 221 tests, with 2 failures` against a baseline of 221 with 0.
    /// This test answers **`invalid_state`** where `invalid_resource_identity`
    /// was expected -- and that particular substitution is the finding, not a
    /// detail of it: `invalid_state` is `createExec`'s `containerNotRunning`,
    /// so `aaaa` had already resolved to the seeded container and the call had
    /// already reached `ExecManager` against it. `testAnEmptySandboxIdIsRefused`
    /// fails beside it with `not_found`. No other test in the suite moves.
    func testAHexSandboxIdIsRefusedBeforeAnythingIsResolved() async throws {
        let managers = try Self.managers()
        try await Self.seed(managers, labels: SandboxIdentity.labels(from: Self.ownerLabels))

        let error = try await Self.refusal(
            from: [Self.start(sandboxID: String(Self.dockerID.prefix(4)))],
            service: managers.makeService()
        )
        XCTAssertEqual(error.code, EngineErrorCode.invalidResourceIdentity.rawValue)
    }

    func testAnEmptySandboxIdIsRefused() async throws {
        let error = try await Self.refusal(from: [Self.start(sandboxID: "")])
        XCTAssertEqual(error.code, EngineErrorCode.invalidResourceIdentity.rawValue)
    }

    /// A sandbox that is not there is `not_found`, which is a reconciler's cue
    /// to create it -- distinct from the refusal below, which is its cue not to.
    func testAnUnknownSandboxIsNotFound() async throws {
        let error = try await Self.refusal(from: [Self.start(sandboxID: Self.sandboxID)])
        XCTAssertEqual(error.code, EngineErrorCode.notFound.rawValue)
        XCTAssertEqual(error.resource, Self.sandboxID)
    }

    /// An unlabelled container under the sandbox's name is refused as foreign,
    /// exactly as `Inspect` and `Logs` refuse it: the engine will not assert
    /// that something it cannot identify is the sandbox that was asked for, and
    /// `Exec` would be running the caller's command inside it.
    ///
    /// MEASURED, with the `SandboxIdentity.owner(from:)` guard deleted:
    /// `Executed 221 tests, with 1 failure` against a baseline of 221 with 0,
    /// this test alone, answering `invalid_state` -- `createExec`'s
    /// `containerNotRunning` -- where `foreign_resource_refused` was expected.
    /// That is the call having reached `ExecManager` against a container this
    /// engine cannot claim.
    func testAnUnlabelledContainerIsRefusedAsForeign() async throws {
        let managers = try Self.managers()
        try await Self.seed(managers, labels: [:])

        let error = try await Self.refusal(
            from: [Self.start(sandboxID: Self.sandboxID)],
            service: managers.makeService()
        )
        XCTAssertEqual(error.code, EngineErrorCode.foreignResourceRefused.rawValue)
        XCTAssertEqual(error.resource, Self.sandboxID)
    }

    // MARK: - argv

    /// `argv` is bytes on the wire and `[String]` everywhere after
    /// `createExec`, so an argument that is not UTF-8 is refused by name.
    ///
    /// The alternative is what makes this worth a test: `String(decoding:as:)`
    /// never fails -- it substitutes U+FFFD -- so the lossy version compiles,
    /// reads correctly, and runs a command the consumer did not ask for.
    ///
    /// MEASURED, with the `guard let argument = String(data:encoding:)` replaced
    /// by `argv.append(String(decoding: bytes, as: UTF8.self))`:
    /// `Executed 221 tests, with 1 failure` against a baseline of 221 with 0,
    /// this test alone. **The code assertion still passed and only the message
    /// assertion failed**, which is worth stating because it decides how this
    /// test has to be written: the lossy decode sails past here and the call is
    /// refused further down by `createExec`, which also answers `invalid_state`.
    /// A test asserting the code alone would have been green against the
    /// mutation. The verbatim failure was `the refusal must name which argument
    /// it could not carry: Container is not running: aaaa...`.
    func testArgvThatIsNotUTF8IsRefusedRatherThanDecodedLossily() async throws {
        let managers = try Self.managers()
        try await Self.seed(managers, labels: SandboxIdentity.labels(from: Self.ownerLabels))

        let error = try await Self.refusal(
            from: [
                Arca_Engine_V1_ExecClientFrame.with { frame in
                    frame.start = Arca_Engine_V1_ExecStart.with { start in
                        start.sandboxID = Self.sandboxID
                        start.argv = [Data("echo".utf8), Data([0xFF, 0xFE, 0x80])]
                    }
                }
            ],
            service: managers.makeService()
        )
        XCTAssertEqual(error.code, EngineErrorCode.invalidState.rawValue)
        XCTAssertTrue(
            error.message.contains("argv[1]"),
            "the refusal must name which argument it could not carry: \(error.message)"
        )
    }

    // MARK: - ExecManager's refusals, in the contract's vocabulary

    /// A container the engine holds and can identify, but which is not running,
    /// is `invalid_state` -- `createExec`'s own refusal, translated.
    ///
    /// **This is the test that proves the call reaches `ExecManager` at all.**
    /// Every other case above stops short of it, so without this one a
    /// `driveExec` that refused everything would pass the whole suite.
    func testALabelledContainerThatIsNotRunningIsRefusedWithItsOwnReason() async throws {
        let managers = try Self.managers()
        try await Self.seed(managers, labels: SandboxIdentity.labels(from: Self.ownerLabels))

        let error = try await Self.refusal(
            from: [Self.start(sandboxID: Self.sandboxID)],
            service: managers.makeService()
        )
        XCTAssertEqual(error.code, EngineErrorCode.invalidState.rawValue)
        XCTAssertTrue(
            error.message.contains("not running"),
            "the refusal must carry ExecManager's own reason: \(error.message)"
        )
    }

    /// The table in `execError(for:resource:)`, driven directly.
    ///
    /// Asserted here rather than only through `driveExec` because most of these
    /// arms are unreachable without a VM: an exec id that names nothing, an exec
    /// already running, a start that failed. A mapping nothing drives is a
    /// mapping that can be changed silently.
    func testEveryExecManagerFailureHasItsOwnContractCode() {
        let cases: [(Error, EngineErrorCode)] = [
            (ExecManagerError.containerNotFound("c"), .notFound),
            (ExecManagerError.containerNotRunning("c"), .invalidState),
            (ExecManagerError.invalidCommand("empty"), .invalidState),
            (ExecManagerError.execNotFound("e"), .invalidState),
            (ExecManagerError.execAlreadyRunning("e"), .invalidState),
            (ExecManagerError.execNotStarted("e"), .invalidState),
            (ExecManagerError.startFailed("boom"), .commandFailed),
            (SignalError.invalidSignal("999"), .invalidState),
        ]
        for (error, expected) in cases {
            let mapped = SandboxEngineService.execError(for: error, resource: "sandbox")
            XCTAssertEqual(mapped.code, expected.rawValue, "for \(error)")
            XCTAssertEqual(mapped.resource, "sandbox")
            XCTAssertFalse(mapped.message.isEmpty, "for \(error)")
        }
    }

    /// The refusal for a signal number the guest has no meaning for names the
    /// number, which `engine.proto:437` requires and which a rewrapped error
    /// would lose.
    func testAnUnknownSignalNumberIsRefusedByItsNumber() {
        let mapped = SandboxEngineService.execError(
            for: SignalError.invalidSignal("999"), resource: "sandbox"
        )
        XCTAssertEqual(mapped.code, EngineErrorCode.invalidState.rawValue)
        XCTAssertTrue(
            mapped.message.contains("999"),
            "the refusal must name the number the client sent: \(mapped.message)"
        )
    }

    // MARK: - The shape of a refusal

    /// A refusal is one frame and it is the only frame: no `Exit` follows it.
    ///
    /// `Exit{code: 0}` after an error would read to a consumer as a command that
    /// ran and succeeded, and gascan stops reading at the error frame
    /// (`gascan-arca/src/backend.rs:322-324`) -- so anything sent afterwards is
    /// both wrong and invisible, which is the worst pair.
    func testARefusalIsTheOnlyFrameAndCarriesNoExit() async throws {
        let managers = try Self.managers()
        try await Self.seed(managers, labels: SandboxIdentity.labels(from: Self.ownerLabels))

        let frames = try await Self.frames(
            managers.makeService(),
            [Self.start(sandboxID: Self.sandboxID)]
        )
        XCTAssertEqual(frames.count, 1, "a refusal must be one frame: \(frames)")
        guard case .error = frames.first?.frame else {
            return XCTFail("expected an error frame, got \(String(describing: frames.first))")
        }
    }

    // MARK: - Fixtures

    /// The container, the ids and the opening frame live in `ExecFixtures`,
    /// because `ExecTeardownTests` drives the same engine and the same seeded
    /// container one method further in.
    private static let dockerID = ExecFixtures.dockerID
    private static let sandboxID = ExecFixtures.sandboxID
    private static let ownerLabels = ExecFixtures.ownerLabels

    private static func start(sandboxID: String) -> Arca_Engine_V1_ExecClientFrame {
        ExecFixtures.start(sandboxID: sandboxID)
    }

    /// Every frame a relay holds, once it has been finished.
    private static func drain(
        _ relay: ExecFrameRelay
    ) async -> [Arca_Engine_V1_ExecServerFrame] {
        var collected: [Arca_Engine_V1_ExecServerFrame] = []
        for await frame in relay.frames {
            collected.append(frame)
        }
        return collected
    }

    /// The frames `Exec` answers `client` with, over a service the caller chose.
    ///
    /// The default service holds no containers at all, which is what the tests
    /// that never get as far as one want.
    private static func frames(
        _ service: SandboxEngineService,
        _ client: [Arca_Engine_V1_ExecClientFrame]
    ) async throws -> [Arca_Engine_V1_ExecServerFrame] {
        let (stream, continuation) = AsyncStream.makeStream(
            of: Arca_Engine_V1_ExecClientFrame.self
        )
        for frame in client {
            continuation.yield(frame)
        }
        continuation.finish()

        var collected: [Arca_Engine_V1_ExecServerFrame] = []
        try await service.runExec(frames: stream) { collected.append($0) }
        return collected
    }

    /// The single engine error `Exec` refuses `client` with, failing if the
    /// answer was not exactly one error frame.
    private static func refusal(
        from client: [Arca_Engine_V1_ExecClientFrame],
        service: SandboxEngineService? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> Arca_Engine_V1_EngineError {
        let service = try service ?? managers().makeService()
        let frames = try await frames(service, client)
        guard frames.count == 1, case .error(let error) = frames.first?.frame else {
            XCTFail("expected exactly one error frame, got \(frames)", file: file, line: line)
            throw XCTSkip("no refusal to assert on")
        }
        return error
    }

    private static func managers() throws -> EngineManagers {
        try ExecFixtures.managers()
    }

    private static func seed(
        _ managers: EngineManagers, labels: [String: String]
    ) async throws {
        try await ExecFixtures.seed(managers, labels: labels)
    }
}
