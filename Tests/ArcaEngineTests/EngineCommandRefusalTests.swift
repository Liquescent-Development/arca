import Foundation
import XCTest

/// Drives the built `arca-engine` binary rather than `validateEngineInputs`.
///
/// `EngineStartupTests` calls the validation function directly, which proves the
/// function and never the call. MEASURED: with `try validateEngineInputs(inputs)`
/// deleted outright from `ServeCommand.run()`, all six of those tests, and
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
        let root = try temporaryEngineRoot()
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
        // `ServeCommand` that this test does not pass, all four of the other
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

    /// The vminit load runs, and refuses, inside `run()`.
    ///
    /// `EngineStartupTests` calls `loadVminit` directly, which proves the
    /// function and not the call -- the same hole this file exists for, and the
    /// call is newer than the validation. A wrong reference is the only refusal
    /// reachable from outside without a 178MB image: the layout below is real,
    /// well-formed, and holds `vminit:latest`, so the engine can only learn that
    /// by loading it.
    ///
    /// Neither message assertion below can be satisfied by ArgumentParser's
    /// usage line, which it prints on any parse error before `run()` is
    /// entered: the first carries the layout's own temp path, invented
    /// microseconds earlier, and the second carries a phrase only
    /// `EngineStartupError`'s rendering produces.
    ///
    /// That second one is deliberately coupled to the message's wording, and
    /// has to be. `vminit:latest` is a *substring* of `arca-vminit:latest`, so
    /// `contains("vminit:latest")` is implied by `contains("arca-vminit:latest")`
    /// and asserts nothing about the found reference. MEASURED: with `\(actual)`
    /// dropped from `EngineStartupError.description`, the substring pair
    /// reported `Executed 58 tests, with 0 failures`. Anchoring on `holds ` and
    /// `not ` is what distinguishes the two, at the cost of a reword going red.
    func testTheCommandRefusesALayoutHoldingAnotherImage() throws {
        let root = try temporaryEngineRoot()
        let kernel = root.appendingPathComponent("vmlinux")
        try Data("k".utf8).write(to: kernel)
        let layout = root.appendingPathComponent("vminit")
        try OCILayoutFixture.write(
            at: layout, reference: "vminit:latest", payload: "not the engine's init"
        )

        let run = try runEngine(arguments: [
            "--socket-path", root.appendingPathComponent("e.sock").path,
            "--state-root", root.appendingPathComponent("state").path,
            "--kernel-path", kernel.path,
            "--vminit-layout", layout.path,
        ])

        XCTAssertTrue(
            run.exitedOnItsOwn,
            "the engine must refuse an unknown init image, not serve on it; stderr: \(run.errorText)"
        )
        XCTAssertNotEqual(
            run.status, 0,
            "a refusal must be a non-zero exit; stderr: \(run.errorText)"
        )
        XCTAssertTrue(
            run.errorText.contains("--vminit-layout") && run.errorText.contains(layout.path),
            "the refusal must name the option and the layout it read, got: \(run.errorText)"
        )
        XCTAssertTrue(
            run.errorText.contains("holds vminit:latest")
                && run.errorText.contains("not arca-vminit:latest"),
            "the refusal must say which image was found and which was wanted, got: \(run.errorText)"
        )
    }

    /// A manager that cannot initialize is a refusal, and no socket is bound.
    ///
    /// This is the milestone's fail-fast claim, and only a spawned binary can
    /// hold it: the three `initialize()` calls in `run()` are unreachable from a
    /// unit test, because `ContainerManager.initialize()` constructs a real
    /// `Containerization.VmnetNetwork` -- a host resource, and the reason no
    /// test in this target may call it.
    ///
    /// `VolumeManager.initialize()` is the seam that makes this testable at all.
    /// It runs FIRST of the three, so a failure there stops the sequence before
    /// anything reaches vmnet, on an entitled machine and an unentitled one
    /// alike. It fails here because `<state-root>/volumes` is a symlink to
    /// itself: `fileExists` follows it and reports false, so `initialize()`
    /// tries to create the directory and the kernel refuses the loop. MEASURED
    /// on this machine: `NSPOSIXErrorDomain Code=5` under
    /// `NSCocoaErrorDomain Code=512`, with no privileges and no external path
    /// involved.
    ///
    /// The socket assertion is the one that carries the ordering. MEASURED with
    /// the three calls moved to after `EngineServer.start`:
    /// `swift test --filter ArcaEngineTests` reported `Executed 60 tests, with 1
    /// failure`, and that failure was the socket assertion ALONE -- the exit
    /// status and the message assertion both still passed, because the engine
    /// binds, then initialize throws, and a throw out of `run()` runs no
    /// graceful shutdown, so the bound socket is left on disk. Exit status
    /// cannot tell those two arrangements apart.
    ///
    /// MEASURED with the three calls deleted outright: three failures in this
    /// one test, `exitedOnItsOwn` first, since the engine then serves.
    func testAManagerThatCannotInitializeRefusesBeforeBindingTheSocket() throws {
        let root = try temporaryEngineRoot()
        let kernel = root.appendingPathComponent("vmlinux")
        try Data("k".utf8).write(to: kernel)
        let layout = root.appendingPathComponent("vminit")
        try OCILayoutFixture.write(
            at: layout, reference: "arca-vminit:latest", payload: "the engine's init"
        )

        // Named for this run, so the refusal it produces names a directory no
        // usage line and no other test could have mentioned.
        let stateRoot = root.appendingPathComponent("state-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: stateRoot, withIntermediateDirectories: true)
        let volumes = stateRoot.appendingPathComponent("volumes")
        try FileManager.default.createSymbolicLink(
            atPath: volumes.path, withDestinationPath: volumes.path
        )

        let socket = root.appendingPathComponent("e.sock")
        let run = try runEngine(arguments: [
            "--socket-path", socket.path,
            "--state-root", stateRoot.path,
            "--kernel-path", kernel.path,
            "--vminit-layout", layout.path,
        ])

        XCTAssertTrue(
            run.exitedOnItsOwn,
            "an engine whose managers cannot initialize must exit, not serve; stderr: \(run.errorText)"
        )
        XCTAssertNotEqual(
            run.status, 0,
            "a manager that cannot initialize must be a non-zero exit; stderr: \(run.errorText)"
        )

        // Which failure it was. Without this the test passes on any refusal at
        // all -- a bad kernel, a bad layout, a failure to reach `initialize()`
        // whatsoever -- and would prove nothing about the initialize sequence.
        //
        // Read from the `Error: ` line and NOT from the whole of stderr, which
        // is the trap this assertion started in. `VolumeManager.initialize()`
        // logs `volumesBasePath=<state-root>/volumes` at info on its way IN, so
        // `errorText.contains("volumes") && errorText.contains(<state root>)`
        // is satisfied by the success path's own log line -- it would have held
        // over an engine that initialized the volume manager fine and then died
        // at `VmnetNetwork()`, which is a different claim entirely. Only
        // ArgumentParser's terminal `Error: ` line carries the thrown error, and
        // the vmnet failure's line ("failed to create vmnet network with status
        // ...") names no path at all.
        let errorLine = run.errorText
            .split(separator: "\n")
            .first { $0.hasPrefix("Error: ") }
            .map(String.init) ?? ""
        XCTAssertTrue(
            errorLine.contains(volumes.lastPathComponent)
                && errorLine.contains(stateRoot.lastPathComponent),
            "the refusal must be the volume manager's own, naming the directory it "
                + "could not create under a state root named microseconds ago; "
                + "the Error line was \(errorLine.isEmpty ? "absent" : errorLine), "
                + "full stderr: \(run.errorText)"
        )

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: socket.path),
            "the socket must bind only after every manager initializes, but \(socket.path) exists"
        )
    }

    // MARK: - Fixtures

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
