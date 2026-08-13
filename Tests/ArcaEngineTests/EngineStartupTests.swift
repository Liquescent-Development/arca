import Foundation
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

    /// A missing kernel is a refusal to start, not a degraded engine. An engine
    /// that starts and answers unsupported_capability for everything that
    /// matters is the state the C1 review finding was raised against.
    func testAMissingKernelRefusesAndNamesThePathTried() throws {
        let root = temporaryRoot()
        let kernelPath = root.appendingPathComponent("vmlinux")
        let inputs = EngineInputs(
            stateRoot: root,
            kernelPath: kernelPath,
            vminitLayout: root.appendingPathComponent("vminit")
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
                EngineInputs(stateRoot: root, kernelPath: kernelPath, vminitLayout: layout)
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
                EngineInputs(stateRoot: root, kernelPath: kernelPath, vminitLayout: layout)
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
                EngineInputs(stateRoot: root, kernelPath: kernelPath, vminitLayout: layout)
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
                EngineInputs(stateRoot: root, kernelPath: kernelPath, vminitLayout: layout)
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
                EngineInputs(stateRoot: root, kernelPath: kernelPath, vminitLayout: layout)
            )
        )
    }
}
