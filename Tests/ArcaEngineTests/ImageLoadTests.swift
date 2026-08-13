import Foundation
import Logging
import XCTest
@testable import ArcaEngine

/// `arca-engine image load`, at both ends: the loading itself, which lives in
/// the `ArcaEngine` library so that a test can reach it, and the subcommand
/// over it, which only a spawned binary can prove is wired at all.
///
/// Both ends are needed and neither substitutes for the other. Task 4's review
/// found six tests that proved `validateEngineInputs` and never that `run()`
/// called it -- deleting the call left the whole suite green. The last two
/// tests here are what stops `image load` acquiring the same hole.
final class ImageLoadTests: XCTestCase {
    private let logger = Logger(label: "image-load-tests")

    /// The reference the fixture layout carries. A workspace image, not
    /// `arca-vminit:latest`: this path exists for content a consumer pushes,
    /// and a test that loaded vminit through it would prove the two are
    /// interchangeable, which is the merge this subcommand deliberately avoids.
    private static let workspaceReference = "workspace:latest"

    // MARK: - Loading

    /// Which reference was loaded, not merely that a load returned.
    ///
    /// `references` is the only thing that tells loading something from loading
    /// nothing, so a test that asserted `XCTAssertNoThrow` and stopped would
    /// pass against a load that reported an empty list.
    func testALayoutLoadsTheReferenceItNames() async throws {
        let root = try temporaryEngineRoot()

        let report = try await loadWorkspaceImages(
            fromOCILayout: try workspaceLayout(in: root),
            stateRoot: root.appendingPathComponent("state"),
            logger: logger
        )

        XCTAssertEqual(
            report.references, [Self.workspaceReference],
            "the load must report the reference it put in the store"
        )
    }

    /// The row most likely to pass for the wrong reason, and the milestone's
    /// central property: the images land in the engine's OWN store.
    ///
    /// On a machine where Apple's shared store already holds the same image, a
    /// test that only checked "it loaded" cannot tell the two stores apart, so
    /// this asserts the resolved path -- read back from the `ImageManager` that
    /// performed the load, never re-derived here -- and then that bytes really
    /// arrived under it. ArcaDaemon shares Apple's store and deletes
    /// `initfs.ext4` out of it on every start; an `image load` that wrote there
    /// would undo the whole milestone silently.
    func testTheImagesLandInTheEnginesOwnStoreAndNotApples() async throws {
        let root = try temporaryEngineRoot()
        let stateRoot = root.appendingPathComponent("state")

        let report = try await loadWorkspaceImages(
            fromOCILayout: try workspaceLayout(in: root), stateRoot: stateRoot, logger: logger
        )

        XCTAssertEqual(
            report.storeRoot.path, EnginePaths(stateRoot: stateRoot).imageStoreRoot.path,
            "the load must use the image store this engine derives from its state root"
        )
        XCTAssertTrue(
            report.storeRoot.path.hasPrefix(stateRoot.path + "/"),
            "the store written to must live under the state root given, got \(report.storeRoot.path)"
        )
        XCTAssertFalse(
            report.storeRoot.path.contains("com.apple.containerization"),
            "the load must not resolve into Apple's shared store, got \(report.storeRoot.path)"
        )

        // The path assertions above describe intent; this one is the bytes. A
        // store root that was named correctly and never written to would satisfy
        // every assertion above.
        XCTAssertFalse(
            try filesUnder(report.storeRoot).isEmpty,
            "the images must physically land in \(report.storeRoot.path), which is empty"
        )
    }

    // MARK: - Refusing

    /// A missing directory is a refusal naming the option and the path tried --
    /// the posture Task 4 established for the startup options, for the same
    /// reason: a degraded mode a consumer cannot see is worse than a failure it
    /// can.
    func testAMissingLayoutIsRefusedNamingTheOptionAndPath() async throws {
        let root = try temporaryEngineRoot()
        let absent = root.appendingPathComponent("no-such-layout")

        guard let error = await refusal(loading: absent, into: root) else { return }
        guard case .missingInput(let name, let path) = error else {
            return XCTFail("expected missingInput, got \(error)")
        }
        XCTAssertEqual(name, "--oci-layout")
        XCTAssertEqual(path, absent.path)
    }

    /// A file where the layout directory should be. Without this guard the
    /// refusal would name a missing `oci-layout` inside a path that is not a
    /// directory at all, rather than the option that was pointed at a file.
    func testAFileWhereTheLayoutShouldBeIsRefused() async throws {
        let root = try temporaryEngineRoot()
        let layout = root.appendingPathComponent("layout")
        try Data("not a layout".utf8).write(to: layout)

        guard let error = await refusal(loading: layout, into: root) else { return }
        guard case .unreadableInput(let name, let path, let cause) = error else {
            return XCTFail("expected unreadableInput, got \(error)")
        }
        XCTAssertEqual(name, "--oci-layout")
        XCTAssertEqual(path, layout.path)
        XCTAssertTrue(
            cause.contains("is a file"),
            "the refusal must say what was wrong with it, got \(cause)"
        )
    }

    /// A half-written layout -- the shape an interrupted export leaves behind --
    /// is refused by name of the marker it lacks, before any store is opened.
    ///
    /// The cause is asserted on the validation's own phrasing and not on
    /// `index.json` alone, and that is not fussiness. MEASURED: with
    /// `"index.json"` dropped from the marker loop, this test still passed --
    /// validation let the layout through, `ImageStore.load` then failed with
    /// `notFound: "<path>/index.json"`, and the wrap put that under the same
    /// case and the same option name. `is not an OCI layout` is the phrase only
    /// `validateOCILayoutDirectory` produces, so it is what tells the check
    /// having run from the store having tripped over the same missing file.
    func testADirectoryMissingOnlyItsIndexIsRefused() async throws {
        let root = try temporaryEngineRoot()
        let layout = root.appendingPathComponent("layout")
        try FileManager.default.createDirectory(at: layout, withIntermediateDirectories: true)
        try Data(#"{"imageLayoutVersion":"1.0.0"}"#.utf8)
            .write(to: layout.appendingPathComponent("oci-layout"))

        guard let error = await refusal(loading: layout, into: root) else { return }
        guard case .unreadableInput(let name, _, let cause) = error else {
            return XCTFail("expected unreadableInput, got \(error)")
        }
        XCTAssertEqual(name, "--oci-layout")
        XCTAssertTrue(
            cause.contains("is not an OCI layout") && cause.contains("index.json"),
            "the refusal must be the marker check's own, naming the marker that was "
                + "missing, got \(cause)"
        )
    }

    /// Loading nothing is not success.
    ///
    /// A well-formed layout holding no manifests passes the marker check and
    /// then imports nothing. `ImageStore.load` does refuse it -- it throws when
    /// the imported set is empty
    /// (containerization/.../ImageStore+OCILayout.swift:101-103) -- but with
    /// `failed to import image`, which names no option and no path. This asserts
    /// the refusal a user can act on, which is `loadWorkspaceImages`' wrapping:
    /// the option, the path, and the cause kept verbatim.
    ///
    /// There is deliberately no `guard !references.isEmpty` in the production
    /// path to go with this. The store refuses first, so such a guard could
    /// never be seen to fail, and a guard no test can drive is not a guard.
    func testALayoutHoldingNoImagesIsRefusedRatherThanLoadingNothing() async throws {
        let root = try temporaryEngineRoot()
        let layout = root.appendingPathComponent("layout")
        try FileManager.default.createDirectory(at: layout, withIntermediateDirectories: true)
        try Data(#"{"imageLayoutVersion":"1.0.0"}"#.utf8)
            .write(to: layout.appendingPathComponent("oci-layout"))
        try Data(#"{"schemaVersion":2,"manifests":[]}"#.utf8)
            .write(to: layout.appendingPathComponent("index.json"))

        guard let error = await refusal(loading: layout, into: root) else { return }
        guard case .unreadableInput(let name, let path, let cause) = error else {
            return XCTFail("expected unreadableInput, got \(error)")
        }
        XCTAssertEqual(name, "--oci-layout")
        XCTAssertEqual(path, layout.path)
        // Coupled to the store's own wording, and deliberately: a refusal that
        // named the option and the path but dropped the cause would satisfy
        // every other assertion here while telling a user nothing about what
        // was wrong with their layout. MEASURED against the built binary --
        // `Error: --oci-layout is unusable at <path>: internalError: "failed to
        // import image"`.
        XCTAssertTrue(
            cause.contains("import"),
            "the refusal must carry the store's own cause, not swallow it, got \(cause)"
        )
    }

    // MARK: - The subcommand over it

    /// The subcommand is wired to the loading, and to this engine's own store.
    ///
    /// Only a spawned binary can hold this: a test target cannot import an
    /// executable, so nothing else can tell an `image load` that calls
    /// `loadWorkspaceImages` from one that prints a cheerful line and exits 0.
    ///
    /// Every assertion below is on something invented microseconds earlier --
    /// this run's own state root and its layout's reference -- so none of them
    /// can be satisfied by ArgumentParser's static usage text, which is the trap
    /// Task 4's review found the second time round.
    func testTheImageLoadSubcommandLoadsIntoTheStateRootsOwnStore() throws {
        let root = try temporaryEngineRoot()
        let stateRoot = root.appendingPathComponent("state")
        let layout = try workspaceLayout(in: root)

        let run = try runEngine(arguments: [
            "image", "load",
            "--state-root", stateRoot.path,
            "--oci-layout", layout.path,
        ])

        XCTAssertTrue(
            run.exitedOnItsOwn,
            "an image load must load and exit, not serve; stderr: \(run.errorText)"
        )
        XCTAssertEqual(
            run.status, 0,
            "a valid layout must load; stderr: \(run.errorText)"
        )

        let storeRoot = EnginePaths(stateRoot: stateRoot).imageStoreRoot
        XCTAssertTrue(
            run.outputText.contains(Self.workspaceReference),
            "the load must report which reference it loaded, got: \(run.outputText)"
        )
        XCTAssertTrue(
            run.outputText.contains(storeRoot.path),
            "the load must report the store it wrote to, got: \(run.outputText)"
        )
        XCTAssertFalse(
            try filesUnder(storeRoot).isEmpty,
            "the subcommand must write the image into \(storeRoot.path), which is empty"
        )
    }

    /// The subcommand refuses, and leaves nothing behind when it does.
    ///
    /// `contains("--oci-layout")` would be satisfied by the subcommand's own
    /// usage line, which ArgumentParser prints on any parse error before `run()`
    /// is entered -- Task 4's review found exactly that. The path assertion is
    /// the one that cannot be: it is a temp path this test invented, so only
    /// `EngineStartupError`'s own rendering can put it on stderr.
    ///
    /// The last assertion carries the ordering. Validation runs before the image
    /// store is opened, and opening a store creates its directories; if the two
    /// swapped, everything above still passes and a refused load would have left
    /// a state root on disk.
    func testTheImageLoadSubcommandRefusesAMissingLayoutAndCreatesNoState() throws {
        let root = try temporaryEngineRoot()
        let stateRoot = root.appendingPathComponent("state")
        let absent = root.appendingPathComponent("no-such-layout")

        let run = try runEngine(arguments: [
            "image", "load",
            "--state-root", stateRoot.path,
            "--oci-layout", absent.path,
        ])

        XCTAssertTrue(
            run.exitedOnItsOwn,
            "a refused load must exit; stderr: \(run.errorText)"
        )
        XCTAssertNotEqual(
            run.status, 0,
            "a refusal must be a non-zero exit; stderr: \(run.errorText)"
        )
        XCTAssertTrue(
            run.errorText.contains(absent.path),
            "stderr must carry the refusal's own message, naming the path tried, "
                + "and not merely ArgumentParser's usage line; got: \(run.errorText)"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: stateRoot.path),
            "a refused load must create no state, but \(stateRoot.path) exists"
        )
    }

    // MARK: - What the command line itself promises

    /// `arca-engine --help` documents how to start the engine.
    ///
    /// The subcommand split cost this and nothing noticed, because nothing in
    /// this suite read help output at all. A root command with no options of
    /// its own generates `USAGE: arca-engine <subcommand>` and an OPTIONS list
    /// holding only `-h`, so the four options the engine cannot start without
    /// became reachable only by first knowing to type `arca-engine serve
    /// --help`. Milestone 4 writes a launchd plist against this binary; whoever
    /// writes it, or debugs a start that failed, reads `--help`.
    ///
    /// Asserted against the `--help` invocation's own STDOUT at exit 0, which
    /// is what keeps it out of reach of the usage line ArgumentParser prints on
    /// every parse error -- that goes to stderr, with exit 64. Task 4's review
    /// found assertions satisfied by exactly that text.
    func testHelpDocumentsTheOptionsTheEngineCannotStartWithout() throws {
        let run = try runEngine(arguments: ["--help"])

        XCTAssertEqual(
            run.status, 0,
            "--help must succeed; stderr: \(run.errorText)"
        )
        for option in ["--socket-path", "--state-root", "--kernel-path", "--vminit-layout"] {
            XCTAssertTrue(
                run.outputText.contains(option),
                "arca-engine --help must document \(option), which the engine cannot "
                    + "start without; got: \(run.outputText)"
            )
        }
        XCTAssertTrue(
            run.outputText.contains("serve --help"),
            "arca-engine --help must point at where the options are described; "
                + "got: \(run.outputText)"
        )
    }

    /// `arca-engine image` does not exit 0 having done nothing.
    ///
    /// ArgumentParser's default for a bare group is help and exit 0, so
    /// `arca-engine image && echo ok` printed `ok` having loaded no image. That
    /// is the shape this project guards against elsewhere: Gas Can's
    /// `build-arca-engine.sh` grew a listing guard because
    /// `swift test --filter <no match>` exits 0 having run nothing.
    func testTheImageGroupRefusesToDoNothing() throws {
        let run = try runEngine(arguments: ["image"])

        XCTAssertNotEqual(
            run.status, 0,
            "a group that loaded no image must not report success; stdout: \(run.outputText)"
        )
        XCTAssertTrue(
            run.errorText.contains("load"),
            "the refusal must name the action that was missing, got: \(run.errorText)"
        )
    }

    // MARK: - Fixtures

    /// A real OCI layout holding one workspace image.
    ///
    /// Real rather than stubbed, for the reason `OCILayoutFixture` records: the
    /// references and digests under test are the ones the real loader returns,
    /// and a hand-invented image proves the invention.
    private func workspaceLayout(in root: URL) throws -> URL {
        try OCILayoutFixture.write(
            at: root.appendingPathComponent("workspace"),
            reference: Self.workspaceReference,
            payload: "pushed by the consumer, not by startup"
        )
    }

    /// Every file below `directory`, or an empty list if it does not exist.
    ///
    /// Recursive because the store nests its content under directories of its
    /// own choosing; what is asserted is that something was written, not the
    /// shape Containerization writes it in, which is not this engine's to fix.
    private func filesUnder(_ directory: URL) throws -> [String] {
        guard let walker = FileManager.default.enumerator(atPath: directory.path) else { return [] }
        return walker.compactMap { entry in
            guard let name = entry as? String else { return nil }
            var isDirectory: ObjCBool = false
            let path = directory.appendingPathComponent(name).path
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
                  !isDirectory.boolValue else { return nil }
            return name
        }
    }

    /// Runs a load that must be refused and hands back the refusal.
    ///
    /// A function rather than `XCTAssertThrowsError`, which takes a
    /// non-`async` autoclosure and so cannot call this at all. Returning nil
    /// after failing, rather than throwing, lets each caller `guard ... else {
    /// return }` and read as one case.
    private func refusal(
        loading layout: URL,
        into root: URL,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async -> EngineStartupError? {
        do {
            let report = try await loadWorkspaceImages(
                fromOCILayout: layout,
                stateRoot: root.appendingPathComponent("state"),
                logger: logger
            )
            XCTFail(
                "the load must refuse \(layout.path), but reported \(report.references) "
                    + "in \(report.storeRoot.path)",
                file: file, line: line
            )
            return nil
        } catch let error as EngineStartupError {
            return error
        } catch {
            XCTFail("expected an EngineStartupError, got \(error)", file: file, line: line)
            return nil
        }
    }
}
