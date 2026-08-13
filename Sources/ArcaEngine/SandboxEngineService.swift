import ContainerBridge
import GRPC
import Logging
import SandboxEngineProto

/// Arca's implementation of the published sandbox-engine contract.
///
/// Each method is intended as a thin seam: translate in, call ContainerBridge,
/// translate out. Business logic belongs in ContainerBridge and mapping belongs
/// in EngineTranslation, so that this file stays readable as a list of the
/// contract's eleven methods.
///
/// **In this build, one of the eleven is implemented: `Capabilities`.** The
/// other ten answer `unsupported_capability` inside their response `oneof`.
/// `Inspect` and `ListResources` joined that list because, when they were
/// written, this process called `initialize()` on no manager, and an
/// uninitialised manager does not report "I cannot tell", it reports "nothing
/// exists". `ArcaEngineCommand.run()` now initializes all three before it binds
/// the socket, so that reason has expired: implementing the two is Tasks 7 and
/// 8's work, and until then they answer `unsupported_capability` because they
/// are unwritten, not because the state behind them is empty.
public final class SandboxEngineService: Arca_Engine_V1_SandboxEngineAsyncProvider {
    public let interceptors: Arca_Engine_V1_SandboxEngineServerInterceptorFactoryProtocol? = nil

    // Held and, in this build, unread. Deliberate on both counts.
    //
    // Unread because the only two methods that consulted them could not report
    // anything true without loaded state. Held because the dependency edge is
    // itself a shipped property: gascan's tests/release/engine-targets-check.sh
    // asserts that `arca-engine` and `ArcaEngine` reach neither `DockerAPI` nor
    // `ArcaDaemon`, and that assertion measures something only while this
    // target genuinely depends on ContainerBridge. Dropping these five to
    // silence an unused-property reading would make the release gate pass for a
    // reason that has nothing to do with what it exists to prove.
    let containerManager: ContainerManager
    let volumeManager: VolumeManager
    let networkManager: NetworkManager
    let imageManager: ImageManager
    let execManager: ExecManager
    let logger: Logger

    public init(
        containerManager: ContainerManager,
        volumeManager: VolumeManager,
        networkManager: NetworkManager,
        imageManager: ImageManager,
        execManager: ExecManager,
        logger: Logger
    ) {
        self.containerManager = containerManager
        self.volumeManager = volumeManager
        self.networkManager = networkManager
        self.imageManager = imageManager
        self.execManager = execManager
        self.logger = logger
    }

    /// The stated answer for an operation this build does not implement.
    ///
    /// unsupported_capability rather than a gRPC status: a status would tell the
    /// consumer the engine is unreachable, which is a different and more
    /// alarming fact than "this build cannot do that".
    static func notImplemented(_ rpc: String) -> Arca_Engine_V1_EngineError {
        engineError(
            .unsupportedCapability,
            message: "\(rpc) is not implemented by this engine build"
        )
    }

    /// See the note on the `create(request:)` overload above.
    ///
    /// Every capability flag reports what this build implements. Milestone 1
    /// implements no create and no exec, so every feature flag is false and
    /// offline is unverified; later milestones flip each flag as they earn
    /// it. A flag that is true before its code exists induces a consumer to
    /// send a request the engine cannot honour.
    func capabilities(request: Arca_Engine_V1_CapabilitiesRequest) async -> Arca_Engine_V1_CapabilitiesResponse {
        guard let version = engineVersion(from: ArcaVersion.version) else {
            return Arca_Engine_V1_CapabilitiesResponse.with {
                $0.error = engineError(
                    .invalidOutput,
                    message: "engine version \(ArcaVersion.version) is not a readable semantic version"
                )
            }
        }
        return Arca_Engine_V1_CapabilitiesResponse.with { response in
            response.capabilities = Arca_Engine_V1_Capabilities.with { capabilities in
                capabilities.engineVersion = version
                capabilities.contractMinor = 0
                capabilities.projectMount = false
                capabilities.namedVolumes = false
                capabilities.tty = false
                capabilities.signals = false
                capabilities.loopbackPublish = false
                capabilities.resourceLimits = false
                capabilities.offline = .unverified
            }
        }
    }

    public func capabilities(
        request: Arca_Engine_V1_CapabilitiesRequest,
        context: GRPCAsyncServerCallContext
    ) async throws -> Arca_Engine_V1_CapabilitiesResponse {
        await capabilities(request: request)
    }

    /// See the note on the `create(request:)` overload above.
    ///
    /// Unimplemented in this build, and that is a deliberate reversal.
    ///
    /// An earlier revision answered from `ContainerManager`. Because the process
    /// then called `ContainerManager.initialize()` on no manager, the only two
    /// writers of `ContainerManager.containers` never ran, so that
    /// implementation could return exactly one answer: `absent`.
    /// `engine.proto`'s `InspectResponse`
    /// has three arms specifically so that "it is not there" stays
    /// distinguishable from "I could not tell", and those "demand opposite
    /// behaviour from a reconciler": on `absent` a consumer creates the
    /// sandbox. An engine that answers `absent` for a sandbox that is running
    /// induces a duplicate.
    ///
    /// `unsupported_capability` is the honest answer for a build that holds no
    /// loaded state. It costs the consumer nothing it was getting -- the
    /// previous answer carried no information -- and it cannot be mistaken for
    /// an observation. `ArcaEngineCommand.run()` now calls `initialize()` on all
    /// three managers before it binds the socket, so the state is there; Task 7
    /// restores this method along with the `Sandbox` translation in
    /// `EngineTranslation`, which stays in the target, tested, for that purpose.
    func inspect(request: Arca_Engine_V1_InspectRequest) async -> Arca_Engine_V1_InspectResponse {
        Arca_Engine_V1_InspectResponse.with { $0.error = Self.notImplemented("Inspect") }
    }

    public func inspect(
        request: Arca_Engine_V1_InspectRequest,
        context: GRPCAsyncServerCallContext
    ) async throws -> Arca_Engine_V1_InspectResponse {
        await inspect(request: request)
    }

    /// Test seam: grpc-swift's `GRPCAsyncServerCallContext` has no public
    /// initialiser reachable from outside the GRPC module (its
    /// `init(headers:logger:contextProvider:)` is `internal`), so a test
    /// target cannot construct one to drive the protocol method directly.
    /// This overload carries the actual logic; the protocol-conforming
    /// method below just forwards to it, which is safe because none of the
    /// not-implemented bodies read the context.
    func create(request: Arca_Engine_V1_CreateRequest) async -> Arca_Engine_V1_CreateResponse {
        Arca_Engine_V1_CreateResponse.with {
            $0.failed = Arca_Engine_V1_CreateFailed.with { $0.error = Self.notImplemented("Create") }
        }
    }

    public func create(
        request: Arca_Engine_V1_CreateRequest,
        context: GRPCAsyncServerCallContext
    ) async throws -> Arca_Engine_V1_CreateResponse {
        await create(request: request)
    }

    /// See the note on the `create(request:)` overload above.
    func prepareImage(request: Arca_Engine_V1_PrepareImageRequest) async -> Arca_Engine_V1_PrepareImageResponse {
        Arca_Engine_V1_PrepareImageResponse.with { $0.error = Self.notImplemented("PrepareImage") }
    }

    public func prepareImage(
        request: Arca_Engine_V1_PrepareImageRequest,
        context: GRPCAsyncServerCallContext
    ) async throws -> Arca_Engine_V1_PrepareImageResponse {
        await prepareImage(request: request)
    }

    /// See the note on the `create(request:)` overload above.
    func createContainer(request: Arca_Engine_V1_CreateContainerRequest) async -> Arca_Engine_V1_CreateResponse {
        Arca_Engine_V1_CreateResponse.with {
            $0.failed = Arca_Engine_V1_CreateFailed.with {
                $0.error = Self.notImplemented("CreateContainer")
            }
        }
    }

    public func createContainer(
        request: Arca_Engine_V1_CreateContainerRequest,
        context: GRPCAsyncServerCallContext
    ) async throws -> Arca_Engine_V1_CreateResponse {
        await createContainer(request: request)
    }

    /// See the note on the `create(request:)` overload above.
    func start(request: Arca_Engine_V1_StartRequest) async -> Arca_Engine_V1_AckResponse {
        Arca_Engine_V1_AckResponse.with { $0.error = Self.notImplemented("Start") }
    }

    public func start(
        request: Arca_Engine_V1_StartRequest,
        context: GRPCAsyncServerCallContext
    ) async throws -> Arca_Engine_V1_AckResponse {
        await start(request: request)
    }

    /// See the note on the `create(request:)` overload above.
    func stop(request: Arca_Engine_V1_StopRequest) async -> Arca_Engine_V1_AckResponse {
        Arca_Engine_V1_AckResponse.with { $0.error = Self.notImplemented("Stop") }
    }

    public func stop(
        request: Arca_Engine_V1_StopRequest,
        context: GRPCAsyncServerCallContext
    ) async throws -> Arca_Engine_V1_AckResponse {
        await stop(request: request)
    }

    /// See the note on the `create(request:)` overload above.
    func remove(request: Arca_Engine_V1_RemoveRequest) async -> Arca_Engine_V1_AckResponse {
        Arca_Engine_V1_AckResponse.with { $0.error = Self.notImplemented("Remove") }
    }

    public func remove(
        request: Arca_Engine_V1_RemoveRequest,
        context: GRPCAsyncServerCallContext
    ) async throws -> Arca_Engine_V1_AckResponse {
        await remove(request: request)
    }

    public func exec(
        requestStream: GRPCAsyncRequestStream<Arca_Engine_V1_ExecClientFrame>,
        responseStream: GRPCAsyncResponseStreamWriter<Arca_Engine_V1_ExecServerFrame>,
        context: GRPCAsyncServerCallContext
    ) async throws {
        try await responseStream.send(
            Arca_Engine_V1_ExecServerFrame.with { $0.error = Self.notImplemented("Exec") }
        )
    }

    public func logs(
        request: Arca_Engine_V1_LogsRequest,
        responseStream: GRPCAsyncResponseStreamWriter<Arca_Engine_V1_LogsChunk>,
        context: GRPCAsyncServerCallContext
    ) async throws {
        try await responseStream.send(
            Arca_Engine_V1_LogsChunk.with { $0.error = Self.notImplemented("Logs") }
        )
    }

    /// See the note on the `create(request:)` overload above.
    ///
    /// Unimplemented in this build, for the same reason as `inspect` and with a
    /// sharper edge.
    ///
    /// `engine.proto`'s contract for this method is "Every resource the engine
    /// holds, labelled or not", because a consumer's drift and leak detection
    /// depends on seeing the unlabelled ones. An earlier revision walked
    /// `ContainerManager`, `VolumeManager` and `NetworkManager`; with
    /// `initialize()` called on none of them all three were permanently empty --
    /// containers and volumes had no loaded rows, and
    /// `NetworkManager.listNetworks()` read two backends that were both nil --
    /// so it returned `[]` under every input. An
    /// empty `ResourceList` is not an error arm: it is a confident report of a
    /// clean host, which is precisely the report that hides a leak.
    ///
    /// Two further defects sat behind that emptiness and would have surfaced
    /// the moment state was loaded: `listContainers(all: true)` with no filters
    /// drops every container labelled `com.arca.internal=true`, and
    /// `NetworkManager.listNetworks()` swallows a WireGuard-backend failure
    /// with `try?`, turning a real failure into a clean answer. Both must be
    /// fixed in `ContainerBridge` before this method reports anything; a
    /// silently incomplete list is worse than no list.
    func listResources(request: Arca_Engine_V1_ListResourcesRequest) async -> Arca_Engine_V1_ListResourcesResponse {
        Arca_Engine_V1_ListResourcesResponse.with { $0.error = Self.notImplemented("ListResources") }
    }

    public func listResources(
        request: Arca_Engine_V1_ListResourcesRequest,
        context: GRPCAsyncServerCallContext
    ) async throws -> Arca_Engine_V1_ListResourcesResponse {
        await listResources(request: request)
    }
}
