import ContainerBridge
import Foundation
import Logging

/// Every ContainerBridge manager the engine serves over, built once.
///
/// `EnginePaths` unified where the paths come *from*; this unifies which derived
/// path reaches which constructor argument, which was the half still spelt out
/// twice -- once in `ServeCommand.run()` and once in the tests' own
/// `SandboxEngineService.forTesting`. Task 1's review measured that arrangement:
/// swapping `imageStoreRoot: paths.imageRootfs` in the command alone left all 34
/// tests of the day green, because the tests drove a parallel wiring over the
/// shared derivation rather than the wiring itself.
///
/// There is one wiring now, and the tests drive it. MEASURED here, with the same
/// swap applied to the `ContainerManager(...)` call below:
/// `swift test --filter ArcaEngineTests` reported `Executed 60 tests, with 1
/// failure`, that failure being
/// `ContainerBridgePathsTests.testTheInitfsIsInsideTheImageStoreTheEngineHandsContainerization`.
/// Restored, the same command reports `Executed 60 tests, with 0 failures`.
///
/// It lives in `ArcaEngine` rather than in the `arca-engine` executable for the
/// reason `EnginePaths` does: a test target cannot import an executable, so a
/// wiring only the executable can reach is a wiring no test can assert on.
///
/// Constructing this does not initialize anything. `initialize()` needs a live
/// `Containerization.VmnetNetwork` and boots nothing until the engine asks --
/// see the ordering note at `ServeCommand.run()`, which is the only caller
/// that may ask.
public struct EngineManagers: Sendable {
    /// The derivation every path below came from, exposed so a caller can name
    /// the same directories the managers were rooted in without re-deriving
    /// them.
    public let paths: EnginePaths

    public let stateStore: StateStore
    public let imageManager: ImageManager
    public let containerManager: ContainerManager
    public let volumeManager: VolumeManager
    public let networkManager: NetworkManager
    public let execManager: ExecManager
    public let portMapManager: PortMapManager

    private let logger: Logger

    /// Builds the managers for one state root.
    ///
    /// The kernel is a parameter rather than an `EnginePaths` member for the
    /// same reason it is a separate CLI option: it is a read-only input the
    /// engine is handed, not state the engine owns.
    ///
    /// `logLevel` reaches `ArcaConfig` only. It is a string here because that is
    /// what `ArcaConfig` takes; the command has already parsed its own
    /// `Logger.Level` from it.
    public init(stateRoot: URL, kernelPath: URL, logLevel: String, logger: Logger) throws {
        let paths = EnginePaths(stateRoot: stateRoot)
        self.paths = paths
        self.logger = logger

        // Before any manager opens the state root, and before the StateStore
        // below drops the `layer_cache` table that indexed these files: the
        // per-layer ext4 cache the single-composed-rootfs revert orphaned.
        // Nothing else can reach it now that the live cache is `image-rootfs`,
        // so a start that skipped it would leave that disk claimed forever. See
        // `LayerCacheReclaim` for why it refuses rather than guesses. ArcaDaemon
        // reclaims its own copy under `~/.arca`; this state root is private to
        // the engine and cannot reach the daemon's tree.
        try LayerCacheReclaim.run(stateRoot: paths.stateRoot, logger: logger)

        self.stateStore = try StateStore(path: paths.stateDatabase.path, logger: logger)
        self.imageManager = try Self.makeImageManager(paths: paths, logger: logger)
        self.containerManager = ContainerManager(
            imageManager: imageManager,
            kernelPath: kernelPath.path,
            imageStoreRoot: paths.imageStoreRoot,
            imageRootfsCachePath: paths.imageRootfs,
            logRoot: paths.logsRoot,
            stateStore: stateStore,
            logger: logger
        )
        self.volumeManager = VolumeManager(
            volumesBasePath: paths.volumesRoot.path,
            stateStore: stateStore,
            logger: logger
        )
        self.networkManager = NetworkManager(
            config: ArcaConfig(
                kernelPath: kernelPath.path,
                socketPath: paths.socket.path,
                logLevel: logLevel
            ),
            stateStore: stateStore,
            containerManager: containerManager,
            logger: logger
        )
        self.execManager = ExecManager(containerManager: containerManager, logger: logger)
        // `dumpNftablesOnPublish` follows the daemon's own rule
        // (`ArcaDaemon.swift:276`): the dump is a debugging aid and is gated on
        // the operator having asked for debug logging, not on a separate switch
        // the engine would then have to grow a CLI option for.
        self.portMapManager = PortMapManager(
            logger: logger,
            dumpNftablesOnPublish: logLevel.lowercased() == "debug"
        )
    }

    /// The engine's own image store, rooted the one way.
    ///
    /// Static, and called by `init` above rather than duplicated by it, so that
    /// a caller needing the image store and nothing else -- `arca-engine image
    /// load`, which has no kernel, no state database and no VM -- reaches the
    /// same `imageStorePath: paths.imageStoreRoot` mapping the served engine
    /// does. `EnginePaths` already unified where the path comes from; this is
    /// the other half, which derived path reaches which constructor argument,
    /// and it is the half Task 1's review measured going wrong silently.
    ///
    /// This is not a second construction path for tests. Tests drive it because
    /// `loadWorkspaceImages` does, exactly as they drive `init` through
    /// `SandboxEngineService.forTesting`.
    package static func makeImageManager(paths: EnginePaths, logger: Logger) throws -> ImageManager {
        try ImageManager(logger: logger, imageStorePath: paths.imageStoreRoot)
    }

    /// Hands `ContainerManager` the three collaborators it holds optionally.
    ///
    /// `ContainerManager` takes these by setter rather than by initializer
    /// because `NetworkManager.init` already takes a `ContainerManager`: the two
    /// refer to each other, so one edge has to be set after construction. That
    /// makes the edge easy to omit, and omitting it is silent. `ArcaDaemon` sets
    /// both (`ArcaDaemon.swift:236`, `:262`); until this existed the engine set
    /// neither, and `ContainerBridge` had already written down what that costs:
    ///
    /// - `ContainerManager.swift:1743` throws `volumeManagerNotAvailable` for
    ///   any container with anonymous volumes, so `Create` could not serve one.
    /// - `ContainerManager.swift:4129` `cleanupVolumesForContainer` **returns
    ///   silently** when `volumeManager` is nil, so `Remove` would delete the
    ///   container, report success, and leave its anonymous volumes on disk with
    ///   nothing in the store pointing at them. A leak the consumer cannot see
    ///   is the failure `ListResources` exists to prevent.
    /// - `ContainerManager.swift:826` builds a container's `NetworkSettings`
    ///   only when `networkManager` is set, so `Inspect` would report a
    ///   container on a network as attached to nothing.
    /// - `ContainerManager.swift:2494` publishes a container's ports only when
    ///   `portMapManager` is set, and the gate has no `else`, so a `Create` that
    ///   asked for ports would start a container that publishes none of them and
    ///   report success. `Inspect` would then name the binding anyway, because
    ///   Task 7 reports what the store holds -- see the note on
    ///   `SandboxEngineService.inspect(request:)`. Every check green over a
    ///   sandbox nothing can connect to.
    ///
    /// **The third line is not proved here the way the first two are, and that
    /// is stated rather than papered over.** Both tests below assert on
    /// behaviour a public method makes visible. `PortMapManager` exposes only
    /// `publishPorts` and `unpublishPorts` (`PortMapManager.swift:61`, `:162`)
    /// and no read at all, and `publishPorts` takes a non-optional
    /// `WireGuardClient` whose `connect` needs a booted VM
    /// (`NetworkManager.swift:836-838`). The one VM-free path that reaches the
    /// gate -- `removeContainer`'s database-only branch, `:3052-3070` --
    /// unpublishes a container that has no mappings, which is a no-op with no
    /// observable result: a test written on it would pass with this line
    /// deleted, which makes it worse than no test. Publication is provable only
    /// from the live tier, and is routed to Task 13 with the shape that would
    /// settle it: create with a `PortMapping`, `Start`, then connect to
    /// `127.0.0.1:<host_port>` from the test process.
    ///
    /// Called after all three `initialize()` calls, which is what `ArcaDaemon`
    /// does and what the setters' own comments ask for. Nothing read during
    /// `initialize()` consults either collaborator: the network restoration that
    /// does (`ContainerManager.swift:2427`) is inside `startContainer`, not
    /// inside `loadPersistedState`.
    ///
    /// Separate from the `initialize()` sequence, and VM-free, because that is
    /// what lets it be proved at all. `ContainerManager.initialize()` constructs
    /// a real `VmnetNetwork`, so no test may call a method containing it; this
    /// one a test can call, and `EngineManagerWiringTests` drives the first two
    /// lines through behaviour rather than through the call. MEASURED, one line
    /// removed at a time, `swift test --filter ArcaEngineTests`, reported by
    /// which tests fail rather than by how many:
    ///
    /// - without `setVolumeManager`, two tests fail and no others:
    ///   `EngineManagerWiringTests.testRemovingAContainerDeletesItsAnonymousVolumeAndSparesTheNamedOne`,
    ///   which drives `ContainerManager.removeContainer` directly, and
    ///   `LifecycleTests.testRemovingAContainerThroughTheRPCDeletesItsAnonymousVolumeAndSparesTheNamedOne`,
    ///   which drives the `Remove` RPC. Both find `["anon-vol", "named-vol"]`
    ///   still present after the removal has reported success. The second joined
    ///   the list when Task 12 landed `Remove`; the first is kept beside it
    ///   because they fail for the same reason at two different altitudes, and
    ///   the lower one keeps measuring if the RPC is ever rewritten.
    /// - without `setNetworkManager`, the only failing test is
    ///   `EngineManagerWiringTests.testAnAttachedContainerReportsTheNetworkItIsOn`,
    ///   on all three of its assertions, its networks dictionary having come
    ///   back `[]`.
    /// - without `setPortMapManager`, nothing fails, for the reason given above.
    ///   That is the finding, not an omission. Re-measured after Task 12: still
    ///   nothing, because the one VM-free path that reaches the gate
    ///   (`removeContainer`'s database-only branch) is reached here only by
    ///   containers with no port bindings, and unpublishing none is a no-op.
    public func wireCollaborators() async {
        await containerManager.setVolumeManager(volumeManager)
        await containerManager.setNetworkManager(networkManager)
        await containerManager.setPortMapManager(portMapManager)
    }

    /// The service over these managers.
    ///
    /// Here rather than at each call site for the reason the wiring above is:
    /// six arguments spelt out twice is six chances for the command and the
    /// tests to hand the service different managers.
    public func makeService() -> SandboxEngineService {
        makeService(execManager: execManager)
    }

    /// The same service with the exec manager substituted, which is how
    /// `ExecTeardownTests` stages a guest that does not answer.
    ///
    /// An overload rather than a defaulted parameter on the method above,
    /// because `ExecInstanceSource` is `package` and that method is `public`.
    /// The public one delegates here so there is still one place the six
    /// arguments are spelt out.
    package func makeService(execManager: any ExecInstanceSource) -> SandboxEngineService {
        SandboxEngineService(
            containerManager: containerManager,
            volumeManager: volumeManager,
            networkManager: networkManager,
            imageManager: imageManager,
            execManager: execManager,
            logger: logger
        )
    }
}
