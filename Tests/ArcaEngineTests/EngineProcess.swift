import Foundation
import XCTest

/// One run of the built `arca-engine`.
struct EngineRun {
    /// Whether the process ended before the deadline. False means it was still
    /// running and the test killed it -- the shape a deleted refusal takes,
    /// since the engine then goes on to serve.
    let exitedOnItsOwn: Bool
    let status: Int32
    let outputText: String
    let errorText: String
}

/// Spawning the real binary, shared by every test that has to prove a call site
/// rather than a function.
///
/// Shared because there are two such files now. `EngineCommandRefusalTests`
/// proves that `serve` refuses bad inputs before it binds anything;
/// `ImageLoadTests` proves that `image load` reaches `loadWorkspaceImages` at
/// all. A second copy of the runner is a second 30-second deadline and a second
/// way to look for the binary, free to drift from the first.
///
/// Spawning needs no import of the executable, which is what lets these tests
/// live in `ArcaEngineTests` -- the only target Gas Can's release gate runs --
/// rather than in `ArcaTests`, which the gate would have to be taught about.
extension XCTestCase {
    /// The built `arca-engine`, found beside the test bundle.
    ///
    /// Not a hardcoded `.build/debug/arca-engine`: Gas Can's gate builds the
    /// checkout with `--configuration release`, which puts both the bundle and
    /// the binary in `.build/release` instead. Deriving from the bundle is
    /// correct under either configuration.
    ///
    /// A missing binary fails the test. There is no skip: the whole point of
    /// these files is that the call site is otherwise unproved, so a version
    /// that quietly passed when it could not find the binary would restore the
    /// hole.
    func engineBinary() throws -> URL {
        let binary = Bundle(for: Self.self)
            .bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("arca-engine")
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            throw EngineBinaryMissing(path: binary.path)
        }
        return binary
    }

    /// Runs the engine and waits, but never indefinitely.
    ///
    /// `waitUntilExit()` alone would hang forever in the exact case these tests
    /// exist to catch: an engine that does not refuse goes on to serve, and a
    /// hung suite reports nothing.
    ///
    /// Callers that pass no subcommand reach `ServeCommand`, which is the root
    /// command's `defaultSubcommand`. That indirection is deliberately not
    /// spelt out in the arguments: the invocation Gas Can ships names no
    /// subcommand, so neither may the tests that stand for it.
    func runEngine(arguments: [String]) throws -> EngineRun {
        let process = Process()
        process.executableURL = try engineBinary()
        process.arguments = arguments

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()

        let deadline = Date().addingTimeInterval(30)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }

        let exitedOnItsOwn = !process.isRunning
        if !exitedOnItsOwn {
            // SIGTERM, which the engine turns into a graceful shutdown, so the
            // socket is unlinked and nothing is left listening for the next test.
            process.terminate()
        }
        process.waitUntilExit()

        return EngineRun(
            exitedOnItsOwn: exitedOnItsOwn,
            status: process.terminationStatus,
            outputText: String(
                decoding: outputPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self
            ),
            errorText: String(
                decoding: errorPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self
            )
        )
    }

    /// A short root, removed when the test ends.
    ///
    /// Short because a macOS Unix socket path is capped near 104 characters, and
    /// `NSTemporaryDirectory()` already spends about half of that. With a full
    /// UUID the engine would fail to bind for that reason instead of the one
    /// under test -- which matters in the mutation case, where the engine is
    /// meant to get far enough to serve.
    func temporaryEngineRoot() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("arca-cmd-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
}

struct EngineBinaryMissing: Error, CustomStringConvertible {
    let path: String
    var description: String {
        "arca-engine was not built beside the test bundle at \(path)"
    }
}
