import ContainerBridge
import Foundation
import Logging
@testable import ArcaEngine

/// The ContainerBridge sources this target's source-text guards read.
///
/// Shared rather than copied into each guard's own file. Two spellings of "find the repo
/// root from `#filePath`" would be free to drift, and the way that drifts is that one
/// guard silently starts reading a file that is not the one it names -- which for a text
/// guard is indistinguishable from the guard passing.
///
/// Located from `#filePath` rather than from the test bundle, because the bundle holds no
/// sources. A missing or unreadable file throws and fails the test; it is never skipped. A
/// guard that quietly passes when it cannot find what it guards is worse than no guard.
enum BridgeSources {
    static func containerManager(testFile: StaticString = #filePath) throws -> String {
        try read("Sources/ContainerBridge/ContainerManager.swift", testFile: testFile)
    }

    private static func read(_ relativePath: String, testFile: StaticString) throws -> String {
        let repoRoot = URL(fileURLWithPath: "\(testFile)")
            .deletingLastPathComponent()  // ArcaEngineTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
        return try String(
            contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8
        )
    }
}
extension SandboxEngineService {
    /// A service over real ContainerBridge managers against a throwaway state
    /// root. Nothing in Tasks 1-6's tests starts a VM; these managers exist
    /// because the service holds them, not because the tests drive them.
    ///
    /// `StateStore` and `ImageManager` construction is force-tried: a failure
    /// here means the on-disk test fixture (a fresh temp directory) could not
    /// be created, which should fail the test run loudly rather than surface
    /// as an ordinary assertion failure.
    static func forTesting() -> SandboxEngineService {
        forTesting(
            stateRoot: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("arca-engine-tests-\(UUID().uuidString)"),
            // Outside the state root on purpose. Nothing here boots a sandbox,
            // so it is never read, and putting it under the root would quietly
            // restate the derivation `--kernel-path` replaced.
            kernelPath: URL(fileURLWithPath: "/opt/arca/vmlinux")
        )
    }

    /// The same service against a state root and kernel the caller names, so a
    /// test can assert on where the managers were actually rooted.
    ///
    /// The managers come from `EngineManagers` -- the one factory `arca-engine`
    /// itself calls -- and not from a copy of its constructor calls. The copy is
    /// what made this helper a replica of the wiring rather than the wiring:
    /// while it stood, Task 1's review measured that swapping
    /// `imageStoreRoot: paths.imageRootfs` in `ServeCommand` left the whole
    /// suite green. See the measurement recorded on `EngineManagers` for what
    /// the same swap costs now.
    ///
    /// The kernel is a parameter rather than an `EnginePaths` member for the
    /// same reason it is a separate CLI option: it is a read-only input the
    /// engine is handed, not state the engine owns. Deriving it here while
    /// `arca-engine` took it from `--kernel-path` would put the drift back.
    ///
    /// No defaults on either, in keeping with the rule the path parameters on
    /// `ContainerManager` follow: the no-argument overload above states the
    /// throwaway values it wants.
    ///
    /// Nothing here calls `EngineManagers`' managers' `initialize()`. That needs
    /// a live `Containerization.VmnetNetwork`, which is a host resource and not
    /// state-root-scoped; `arca-engine` is the only caller that asks for one.
    static func forTesting(stateRoot: URL, kernelPath: URL) -> SandboxEngineService {
        try! EngineManagers(
            stateRoot: stateRoot,
            kernelPath: kernelPath,
            logLevel: "info",
            logger: Logger(label: "arca-engine-tests")
        ).makeService()
    }
}
