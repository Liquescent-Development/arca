import ContainerBridge
import Foundation
import Logging
import XCTest
@testable import ArcaEngine

final class EngineStartupTests: XCTestCase {
    private func temporaryRoot() -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("arca-startup-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true
        )
        return root
    }

    // MARK: - `--state-root`

    /// `--state-root` is the one option the engine deletes out of: `EngineManagers.init`
    /// reclaims `<state-root>/layers` on every start. Until this refusal existed the option
    /// was validated by nothing at all, and `arca-engine serve --state-root ""` recursively
    /// removed `$CWD/layers` -- MEASURED in this task's review round.
    ///
    /// The four forms below are refused **before any check reads the filesystem**, which is
    /// what `EngineInputs` keeping the raw option text buys: `URL(fileURLWithPath:)` resolves
    /// every one of them against the working directory, so a `URL`-typed input would arrive
    /// here indistinguishable from a state root the operator meant.
    func testAnEmptyOrRelativeStateRootIsRefusedAndNamesTheOption() throws {
        // `~/foo` is here rather than among the absolute forms because `URL` would have
        // resolved it too -- against `$HOME`, MEASURED on 2026-08-22 -- so it belongs to the
        // same class: a value the engine would not have taken literally.
        for value in ["", ".", "..", "relative/root", "~/foo", "~"] {
            let root = temporaryRoot()
            let kernelPath = root.appendingPathComponent("vmlinux")
            FileManager.default.createFile(atPath: kernelPath.path, contents: Data())
            let layout = root.appendingPathComponent("vminit")
            try FileManager.default.createDirectory(at: layout, withIntermediateDirectories: true)
            for marker in ["oci-layout", "index.json"] {
                FileManager.default.createFile(
                    atPath: layout.appendingPathComponent(marker).path, contents: Data()
                )
            }

            XCTAssertThrowsError(
                try validateEngineInputs(
                    EngineInputs(
                        stateRoot: value,
                        kernelPath: kernelPath.path,
                        vminitLayout: layout.path
                    )
                ),
                "expected \(value.debugDescription) to be refused"
            ) { error in
                guard let startupError = error as? EngineStartupError,
                    case .unusableOptionValue(let name, let raw, _) = startupError
                else {
                    return XCTFail("expected unusableOptionValue, got \(error)")
                }
                XCTAssertEqual(name, "--state-root")
                XCTAssertEqual(raw, value)
            }
        }
    }

    /// An absolute state root is not enough: `.`, `..` and empty components survive into the
    /// `URL` verbatim and are resolved by the filesystem afterwards, so the path checked and
    /// the path deleted from need not be the same directory. The all-slashes spellings are
    /// refused for their own reason -- they name the filesystem root.
    ///
    /// The kernel and layout here are deliberately absent. The assertion is that the
    /// state-root refusal comes first -- a `missingInput` for `--kernel-path` would mean the
    /// engine had already begun reading the filesystem on the strength of an unchecked root.
    func testANonCanonicalOrFilesystemRootStateRootIsRefusedBeforeAnyOtherCheck() {
        // `"//"` and `"///"` are the reason this list grew in round 2: while the rule compared
        // against `"/"` by string they returned nil here, passed the boundary, and were stopped
        // only by the reclaim's own copy of the check -- which prevents the deletion but loses
        // the ordering property this test is about. MEASURED on 2026-08-22:
        // `URL(fileURLWithPath:)` maps both to `"/"`.
        for value in ["/a/../b", "/a/./b", "/", "//", "///", "/a//b"] {
            XCTAssertThrowsError(
                try validateEngineInputs(
                    EngineInputs(
                        stateRoot: value,
                        kernelPath: "/nonexistent/vmlinux",
                        vminitLayout: "/nonexistent/vminit"
                    )
                ),
                "expected \(value.debugDescription) to be refused"
            ) { error in
                guard let startupError = error as? EngineStartupError,
                    case .unusableOptionValue(let name, _, _) = startupError
                else {
                    return XCTFail("expected unusableOptionValue for \(value), got \(error)")
                }
                XCTAssertEqual(name, "--state-root")
            }
        }
    }

    /// A canonical absolute state root passes this check, so the refusals above are refusing
    /// the form and not the option.
    func testACanonicalAbsoluteStateRootIsAccepted() throws {
        let root = temporaryRoot()
        let kernelPath = root.appendingPathComponent("vmlinux")
        FileManager.default.createFile(atPath: kernelPath.path, contents: Data())
        let layout = root.appendingPathComponent("vminit")
        try FileManager.default.createDirectory(at: layout, withIntermediateDirectories: true)
        for marker in ["oci-layout", "index.json"] {
            FileManager.default.createFile(
                atPath: layout.appendingPathComponent(marker).path, contents: Data()
            )
        }

        XCTAssertNoThrow(
            try validateEngineInputs(
                EngineInputs(
                    stateRoot: root.path, kernelPath: kernelPath.path, vminitLayout: layout.path
                )
            )
        )
    }

    /// A missing kernel is a refusal to start, not a degraded engine. An engine
    /// that starts and answers unsupported_capability for everything that
    /// matters is the state the C1 review finding was raised against.
    func testAMissingKernelRefusesAndNamesThePathTried() throws {
        let root = temporaryRoot()
        let kernelPath = root.appendingPathComponent("vmlinux")
        let inputs = EngineInputs(
            stateRoot: root.path,
            kernelPath: kernelPath.path,
            vminitLayout: root.appendingPathComponent("vminit").path
        )

        XCTAssertThrowsError(try validateEngineInputs(inputs)) { error in
            guard let startupError = error as? EngineStartupError,
                  case .missingInput(let name, let path) = startupError else {
                return XCTFail("expected missingInput, got \(error)")
            }
            XCTAssertEqual(name, "--kernel-path")
            XCTAssertEqual(path, kernelPath.path)
        }
    }

    /// Existing is not the same as being the right kind of thing. A directory
    /// where the kernel should be passes an existence check and then fails much
    /// later, inside the VM boot, with a message about the wrong subject.
    func testADirectoryWhereTheKernelShouldBeIsRefused() throws {
        let root = temporaryRoot()
        let kernelPath = root.appendingPathComponent("vmlinux")
        try FileManager.default.createDirectory(at: kernelPath, withIntermediateDirectories: true)
        let layout = root.appendingPathComponent("vminit")
        try FileManager.default.createDirectory(at: layout, withIntermediateDirectories: true)

        XCTAssertThrowsError(
            try validateEngineInputs(
                EngineInputs(
                    stateRoot: root.path,
                    kernelPath: kernelPath.path,
                    vminitLayout: layout.path
                )
            )
        ) { error in
            guard let startupError = error as? EngineStartupError,
                  case .unreadableInput(let name, let path, _) = startupError else {
                return XCTFail("expected unreadableInput, got \(error)")
            }
            XCTAssertEqual(name, "--kernel-path")
            XCTAssertEqual(path, kernelPath.path)
        }
    }

    /// The mirror of the case above: a file where the OCI layout directory
    /// should be. `appendingPathComponent` on a file path yields a path that
    /// simply does not exist, so without this guard the refusal would name a
    /// missing `oci-layout` rather than the option that was pointed at a file.
    func testAFileWhereTheVminitLayoutShouldBeIsRefused() throws {
        let root = temporaryRoot()
        let kernelPath = root.appendingPathComponent("vmlinux")
        FileManager.default.createFile(atPath: kernelPath.path, contents: Data("k".utf8))
        let layout = root.appendingPathComponent("vminit")
        FileManager.default.createFile(atPath: layout.path, contents: Data("not a layout".utf8))

        XCTAssertThrowsError(
            try validateEngineInputs(
                EngineInputs(
                    stateRoot: root.path,
                    kernelPath: kernelPath.path,
                    vminitLayout: layout.path
                )
            )
        ) { error in
            guard let startupError = error as? EngineStartupError,
                  case .unreadableInput(let name, let path, let cause) = startupError else {
                return XCTFail("expected unreadableInput, got \(error)")
            }
            XCTAssertEqual(name, "--vminit-layout")
            XCTAssertEqual(path, layout.path)
            XCTAssertTrue(
                cause.contains("is a file"),
                "the refusal must say what was wrong with it, got \(cause)"
            )
        }
    }

    /// The vminit layout must be a directory holding an OCI layout, not merely
    /// a path that exists.
    func testAVminitLayoutWithoutAnOCIMarkerIsRefused() throws {
        let root = temporaryRoot()
        let kernelPath = root.appendingPathComponent("vmlinux")
        FileManager.default.createFile(atPath: kernelPath.path, contents: Data("k".utf8))
        let layout = root.appendingPathComponent("vminit")
        try FileManager.default.createDirectory(at: layout, withIntermediateDirectories: true)

        XCTAssertThrowsError(
            try validateEngineInputs(
                EngineInputs(
                    stateRoot: root.path,
                    kernelPath: kernelPath.path,
                    vminitLayout: layout.path
                )
            )
        )
    }

    /// Each marker in the loop is load-bearing on its own. The test above
    /// creates a layout with neither, so it stays green with `index.json`
    /// dropped from the list -- `oci-layout` catches the empty directory for it.
    /// A half-written layout, which is the shape an interrupted export leaves
    /// behind, is the case only this test refuses.
    func testAVminitLayoutMissingOnlyItsIndexIsRefused() throws {
        let root = temporaryRoot()
        let kernelPath = root.appendingPathComponent("vmlinux")
        FileManager.default.createFile(atPath: kernelPath.path, contents: Data("k".utf8))
        let layout = root.appendingPathComponent("vminit")
        try FileManager.default.createDirectory(at: layout, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: layout.appendingPathComponent("oci-layout").path,
            contents: Data(#"{"imageLayoutVersion":"1.0.0"}"#.utf8)
        )

        XCTAssertThrowsError(
            try validateEngineInputs(
                EngineInputs(
                    stateRoot: root.path,
                    kernelPath: kernelPath.path,
                    vminitLayout: layout.path
                )
            )
        ) { error in
            guard let startupError = error as? EngineStartupError,
                  case .unreadableInput(let name, _, let cause) = startupError else {
                return XCTFail("expected unreadableInput, got \(error)")
            }
            XCTAssertEqual(name, "--vminit-layout")
            XCTAssertTrue(
                cause.contains("index.json"),
                "the refusal must name the marker that was missing, got \(cause)"
            )
        }
    }

    /// All three present and well-formed is the only case that proceeds.
    func testCompleteInputsValidate() throws {
        let root = temporaryRoot()
        let kernelPath = root.appendingPathComponent("vmlinux")
        FileManager.default.createFile(atPath: kernelPath.path, contents: Data("k".utf8))
        let layout = root.appendingPathComponent("vminit")
        try FileManager.default.createDirectory(at: layout, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: layout.appendingPathComponent("oci-layout").path,
            contents: Data(#"{"imageLayoutVersion":"1.0.0"}"#.utf8)
        )
        FileManager.default.createFile(
            atPath: layout.appendingPathComponent("index.json").path,
            contents: Data(#"{"schemaVersion":2,"manifests":[]}"#.utf8)
        )

        XCTAssertNoThrow(
            try validateEngineInputs(
                EngineInputs(
                    stateRoot: root.path,
                    kernelPath: kernelPath.path,
                    vminitLayout: layout.path
                )
            )
        )
    }

    // MARK: - Loading vminit into the engine's own store

    private let logger = Logger(label: "engine-startup-tests")

    /// An image manager rooted exactly where `arca-engine` roots its own: at
    /// `EnginePaths`' image store, under the state root. Not a stub -- the
    /// digest the regeneration decision turns on is the one the real load
    /// returns, so a fake source of digests would prove only the fake.
    private func imageManager(for stateRoot: URL) throws -> ImageManager {
        try ImageManager(
            logger: logger, imageStorePath: EnginePaths(stateRoot: stateRoot).imageStoreRoot
        )
    }

    /// The digest is recorded so that initfs.ext4 is regenerated when vminit
    /// changes and only then. Unconditional deletion would rebuild a ~178MB
    /// image on every start; sharing Apple's path -- which is what ArcaDaemon
    /// deletes -- would destroy a live daemon's initfs.
    func testAnUnrecordedDigestReadsAsAbsentAndRoundTrips() throws {
        let root = temporaryRoot()
        XCTAssertNil(recordedVminitDigest(stateRoot: root))

        try recordVminitDigest("sha256:abc123", stateRoot: root)
        XCTAssertEqual(recordedVminitDigest(stateRoot: root), "sha256:abc123")

        try recordVminitDigest("sha256:def456", stateRoot: root)
        XCTAssertEqual(recordedVminitDigest(stateRoot: root), "sha256:def456")
    }

    /// The record lives under the state root, never beside Apple's shared
    /// initfs.ext4.
    func testTheDigestRecordLivesUnderTheStateRoot() throws {
        let root = temporaryRoot()
        try recordVminitDigest("sha256:abc123", stateRoot: root)

        let recorded = root.appendingPathComponent("vminit-digest")
        XCTAssertTrue(FileManager.default.fileExists(atPath: recorded.path))
        XCTAssertFalse(recorded.path.contains("com.apple.containerization"))
    }

    /// The load is the engine's own, into the engine's own store: the image
    /// lands under the state root and nowhere else, and the digest it returns
    /// is the one recorded.
    ///
    /// This drives `ImageManager.loadFromOCILayout` against a real OCI layout,
    /// so the digest under test is Containerization's, not the test's.
    func testLoadingTheLayoutRecordsTheDigestItReturnsUnderTheStateRoot() async throws {
        let root = temporaryRoot()
        let layout = root.appendingPathComponent("vminit")
        try OCILayoutFixture.write(
            at: layout, reference: "arca-vminit:latest", payload: "a vminit"
        )

        let digest = try await loadVminit(
            from: layout, into: try imageManager(for: root), stateRoot: root, logger: logger
        )

        XCTAssertTrue(
            digest.hasPrefix("sha256:"),
            "the recorded key must be the loaded image's digest, got \(digest)"
        )
        XCTAssertEqual(recordedVminitDigest(stateRoot: root), digest)

        // A second manager over the same root, so the assertion is that the
        // image persisted into that store -- not that the manager which loaded
        // it remembers having done so.
        let found = await (try imageManager(for: root)).imageExists(
            nameOrId: "arca-vminit:latest"
        )
        XCTAssertTrue(
            found,
            "the image must land in the engine's own store, under its state root"
        )
    }

    /// The regeneration decision itself, both ways, through the real load.
    ///
    /// `testAnUnrecordedDigestReadsAsAbsentAndRoundTrips` covers neither branch:
    /// MEASURED with the comparison reverted to unconditional regeneration, it
    /// still passed. Only this test goes red -- and it goes red the other way
    /// too, with regeneration removed entirely.
    ///
    /// Two layouts differing only in their layer bytes stand in for "the vminit
    /// changed", which is what the record exists to notice.
    func testAnUnchangedVminitKeepsTheInitfsAndAChangedOneDeletesIt() async throws {
        let root = temporaryRoot()
        let paths = EnginePaths(stateRoot: root)
        let manager = try imageManager(for: root)

        let layout = root.appendingPathComponent("vminit")
        try OCILayoutFixture.write(
            at: layout, reference: "arca-vminit:latest", payload: "the first vminit"
        )
        let first = try await loadVminit(
            from: layout, into: manager, stateRoot: root, logger: logger
        )

        // Stands in for the ~178MB image Containerization builds at this exact
        // path. Its contents are what the assertions read: the property is
        // "still the same file", not "some file exists".
        let built = Data("built from the first vminit".utf8)
        try FileManager.default.createDirectory(
            at: paths.imageStoreRoot, withIntermediateDirectories: true
        )
        try built.write(to: paths.initfs)

        let again = try await loadVminit(
            from: layout, into: manager, stateRoot: root, logger: logger
        )
        XCTAssertEqual(again, first, "the same layout must load to the same digest")
        XCTAssertEqual(
            try? Data(contentsOf: paths.initfs), built,
            "an unchanged vminit must leave the initfs alone: rebuilding a ~178MB "
                + "image on every start is the cost this record exists to avoid"
        )

        let changed = root.appendingPathComponent("vminit-next")
        try OCILayoutFixture.write(
            at: changed, reference: "arca-vminit:latest", payload: "the second vminit"
        )
        let second = try await loadVminit(
            from: changed, into: manager, stateRoot: root, logger: logger
        )

        XCTAssertNotEqual(second, first, "a different vminit must load to a different digest")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: paths.initfs.path),
            "a changed vminit must delete the initfs built from the old one, or the "
                + "engine boots its sandboxes on an init image it no longer has"
        )
        XCTAssertEqual(recordedVminitDigest(stateRoot: root), second)
    }

    /// A layout holding some other image is a refusal, and the refusal names
    /// the option and the path -- the same two things the missing-input and
    /// unreadable-input refusals name. ArcaDaemon logs and continues here;
    /// booting sandboxes on an unknown init image is not a warning.
    func testALayoutHoldingAnotherImageIsRefusedAndNamesTheOptionAndPath() async throws {
        let root = temporaryRoot()
        let layout = root.appendingPathComponent("vminit")
        try OCILayoutFixture.write(
            at: layout, reference: "vminit:latest", payload: "not the engine's init"
        )
        let manager = try imageManager(for: root)

        do {
            _ = try await loadVminit(
                from: layout, into: manager, stateRoot: root, logger: logger
            )
            XCTFail("an unexpected reference must be refused, not loaded")
        } catch let error as EngineStartupError {
            guard case .unexpectedVminitReference(let name, let path, let expected, let actual)
                = error
            else {
                return XCTFail("expected unexpectedVminitReference, got \(error)")
            }
            XCTAssertEqual(name, "--vminit-layout")
            XCTAssertEqual(path, layout.path)
            XCTAssertEqual(expected, "arca-vminit:latest")
            XCTAssertEqual(actual, "vminit:latest")
            XCTAssertTrue(
                error.description.contains("--vminit-layout")
                    && error.description.contains(layout.path),
                "a refusal that does not say what to fix is worse than a crash, got: \(error)"
            )
            // The payload assertions above pin what the case carries; this pins
            // what the user is shown. MEASURED: with `\(actual)` dropped from
            // `description`, every assertion above still passed and the whole
            // suite reported `Executed 58 tests, with 0 failures`. `holds ` is
            // the anchor because `vminit:latest` is a substring of
            // `arca-vminit:latest`, so an unanchored `contains` for the found
            // reference is satisfied by the wanted one.
            XCTAssertTrue(
                error.description.contains("holds vminit:latest"),
                "the rendered refusal must name the image actually found, got: \(error)"
            )
        }

        XCTAssertNil(
            recordedVminitDigest(stateRoot: root),
            "a refused load must record nothing, or the next start reads a digest "
                + "for an image the engine never accepted"
        )
    }
}
