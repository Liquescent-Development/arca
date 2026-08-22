import ContainerBridge
import Foundation
import Logging
@testable import ArcaEngine

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
