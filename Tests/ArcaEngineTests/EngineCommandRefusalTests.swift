import Foundation
import XCTest

/// Drives the built `arca-engine` binary rather than `validateEngineInputs`.
///
/// `EngineStartupTests` calls the validation function directly, which proves the
/// function and never the call. MEASURED: with `try validateEngineInputs(inputs)`
/// deleted outright from `ArcaEngineCommand.run()`, all six of those tests, and
/// the whole suite, reported `Executed 49 tests, with 0 failures`. The same hole
/// hides the ordering: moving the call after `createSocketParentDirectory` was
/// equally invisible. Task 6 edits exactly that region of `run()` to add
/// `initialize()`, so an unproved call site is a live hazard, not a theoretical
/// one.
///
/// Spawning the binary needs no import of it, so this lives in `ArcaEngineTests`
/// -- the only target Gas Can's release gate runs -- rather than in `ArcaTests`,
/// which the gate would have to be taught about.
final class EngineCommandRefusalTests: XCTestCase {
    /// A refusal must exit, name the option, and leave nothing behind. All three
    /// in one test because they are one behaviour: validation runs before any
    /// side effect. Splitting them would spawn the binary three times to assert
    /// three things about the same run.
    func testTheCommandRefusesAMissingKernelBeforeCreatingTheSocketDirectory() throws {
        let root = try temporaryRoot()
        let socketDirectory = root.appendingPathComponent("sock")
        let absentKernel = root.appendingPathComponent("vmlinux")
        let layout = try validVminitLayout(in: root)

        let run = try runEngine(arguments: [
            "--socket-path", socketDirectory.appendingPathComponent("e.sock").path,
            "--state-root", root.appendingPathComponent("state").path,
            "--kernel-path", absentKernel.path,
            "--vminit-layout", layout.path,
        ])

        // First, because if the engine served instead of refusing then the exit
        // status below describes this test's own SIGTERM, not the engine's
        // decision, and would read as a pass.
        XCTAssertTrue(
            run.exitedOnItsOwn,
            "the engine must refuse and exit, not start serving without a kernel; stderr: \(run.errorText)"
        )
        XCTAssertNotEqual(
            run.status, 0,
            "a refusal must be a non-zero exit; stderr: \(run.errorText)"
        )
        XCTAssertTrue(
            run.errorText.contains("--kernel-path"),
            "the refusal must name the option that was wrong, got: \(run.errorText)"
        )

        // The assertion above is not enough on its own, and cannot be: ArgumentParser
        // prints a usage line on *any* parse error, on stderr, before `run()` is
        // entered -- and that usage line contains the literal `--kernel-path`.
        // MEASURED: with one unrelated required option added to
        // `ArcaEngineCommand` that this test does not pass, all four of the other
        // assertions passed on a pure parse failure while `validateEngineInputs`
        // was never reached.
        //
        // The absent kernel's path is a temp path this test invented microseconds
        // earlier, so no usage line can contain it. Only `EngineStartupError`'s
        // own `\(name) names nothing that exists: \(path)` puts it on stderr,
        // which means reaching this assertion at all requires having reached the
        // validation. Task 5 and Task 6 both edit this command's options.
        XCTAssertTrue(
            run.errorText.contains(absentKernel.path),
            "stderr must carry the validation's own message, naming the path tried, "
                + "and not merely ArgumentParser's usage line; got: \(run.errorText)"
        )

        // The ordering assertion. `createSocketParentDirectory` runs early in
        // `run()`; if validation moved after it, everything above still passes
        // and only this fails.
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: socketDirectory.path),
            "validation must run before anything is created on disk, but \(socketDirectory.path) exists"
        )
    }

    // MARK: - Running the binary

    private struct EngineRun {
        /// Whether the process ended before the deadline. False means it was
        /// still running and this test killed it -- the shape a deleted
        /// validation call takes, since the engine then goes on to serve.
        let exitedOnItsOwn: Bool
        let status: Int32
        let errorText: String
    }

    /// The built `arca-engine`, found beside the test bundle.
    ///
    /// Not a hardcoded `.build/debug/arca-engine`: Gas Can's gate builds the
    /// checkout with `--configuration release`, which puts both the bundle and
    /// the binary in `.build/release` instead. Deriving from the bundle is
    /// correct under either configuration.
    ///
    /// A missing binary fails the test. There is no skip: the whole point of
    /// this file is that the call site is otherwise unproved, so a version that
    /// quietly passes when it cannot find the binary would restore the hole.
    private func engineBinary() throws -> URL {
        let binary = Bundle(for: Self.self)
            .bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("arca-engine")
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            throw EngineBinaryMissing(path: binary.path)
        }
        return binary
    }

    private struct EngineBinaryMissing: Error, CustomStringConvertible {
        let path: String
        var description: String {
            "arca-engine was not built beside the test bundle at \(path)"
        }
    }

    /// Runs the engine and waits, but never indefinitely.
    ///
    /// `waitUntilExit()` alone would hang forever in the exact case this test
    /// exists to catch: an engine that does not refuse goes on to serve, and a
    /// hung suite reports nothing.
    private func runEngine(arguments: [String]) throws -> EngineRun {
        let process = Process()
        process.executableURL = try engineBinary()
        process.arguments = arguments

        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = Pipe()

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

        let errorText = String(
            decoding: errorPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self
        )
        return EngineRun(
            exitedOnItsOwn: exitedOnItsOwn,
            status: process.terminationStatus,
            errorText: errorText
        )
    }

    // MARK: - Fixtures

    /// A short root, removed when the test ends.
    ///
    /// Short because a macOS Unix socket path is capped near 104 characters, and
    /// `NSTemporaryDirectory()` already spends about half of that. With a full
    /// UUID the engine would fail to bind for that reason instead of the one
    /// under test -- which matters in the mutation case, where the engine is
    /// meant to get far enough to serve.
    private func temporaryRoot() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("arca-cmd-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    /// A well-formed vminit layout, so the kernel is the only thing wrong.
    private func validVminitLayout(in root: URL) throws -> URL {
        let layout = root.appendingPathComponent("vminit")
        try FileManager.default.createDirectory(at: layout, withIntermediateDirectories: true)
        try Data(#"{"imageLayoutVersion":"1.0.0"}"#.utf8)
            .write(to: layout.appendingPathComponent("oci-layout"))
        try Data(#"{"schemaVersion":2,"manifests":[]}"#.utf8)
            .write(to: layout.appendingPathComponent("index.json"))
        return layout
    }
}
