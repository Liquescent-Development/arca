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
    ///
    /// Both pipes are drained from the moment the child starts, and NOT read
    /// after it exits. A pipe holds about 64KB; a child that fills one blocks
    /// in `write` and never exits, so a version that waits first and reads
    /// afterwards would sit out the whole deadline and then report
    /// `exitedOnItsOwn == false` -- "the engine must load and exit, not serve"
    /// -- which names a cause that is not the one. Unreachable with
    /// `OCILayoutFixture`'s kilobyte layout, and reachable the day someone
    /// points this at a real image with `--log-level trace`.
    ///
    /// MEASURED, both patterns against `/bin/sh -c 'seq 1 60000'` (~349KB) on
    /// this machine under a 5s deadline: reading after the wait reported
    /// `exitedOnItsOwn=false status=15 bytes=65536` -- stalled at exactly the
    /// pipe buffer, then killed by the harness's own SIGTERM -- while draining
    /// from the start reported `exitedOnItsOwn=true status=0 bytes=348894`.
    func runEngine(arguments: [String]) throws -> EngineRun {
        let process = Process()
        process.executableURL = try engineBinary()
        process.arguments = arguments

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()
        let output = PipeDrain(outputPipe, name: "stdout")
        let errors = PipeDrain(errorPipe, name: "stderr")

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
            outputText: try output.textAtEOF(),
            errorText: try errors.textAtEOF()
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

/// Reads one of a child's pipes to EOF on a thread of its own, so the child is
/// never blocked writing into a full buffer.
///
/// The read end is taken as a raw descriptor rather than as the `FileHandle`
/// that owns it: a descriptor is `Sendable` and a `FileHandle` is not, and the
/// work has to cross to another thread. `@unchecked Sendable` for the same
/// reason `ShutdownRequests` in `ArcaEngineCommand` is -- the two fields are
/// touched on one thread each, in an order the semaphore fixes.
private final class PipeDrain: @unchecked Sendable {
    private var data = Data()
    private let finished = DispatchSemaphore(value: 0)
    private let name: String

    init(_ pipe: Pipe, name: String) {
        self.name = name
        let descriptor = pipe.fileHandleForReading.fileDescriptor
        DispatchQueue.global().async { [self] in
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
                guard count > 0 else { break }
                data.append(contentsOf: buffer[0..<count])
            }
            finished.signal()
        }
    }

    /// Everything the child wrote, once it has closed the pipe.
    ///
    /// Bounded, and a timeout throws rather than handing back what arrived so
    /// far: a partial read returned as if whole is an assertion passing or
    /// failing on text the child had not finished writing. The wait should be
    /// instant -- the caller reaps the child first, which closes its end -- so
    /// reaching the timeout is a defect in this harness and says so.
    func textAtEOF() throws -> String {
        guard finished.wait(timeout: .now() + 10) == .success else {
            throw PipeNeverClosed(name: name)
        }
        return String(decoding: data, as: UTF8.self)
    }
}

struct PipeNeverClosed: Error, CustomStringConvertible {
    let name: String
    var description: String {
        "the engine's \(name) did not reach EOF within 10s of the process being reaped"
    }
}

struct EngineBinaryMissing: Error, CustomStringConvertible {
    let path: String
    var description: String {
        "arca-engine was not built beside the test bundle at \(path)"
    }
}

