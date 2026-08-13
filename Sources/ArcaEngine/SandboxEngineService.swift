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
/// **In this build, two of the eleven are implemented: `Capabilities` and
/// `Inspect`.** The other nine answer `unsupported_capability` inside their
/// response `oneof`.
///
/// `Inspect` and `ListResources` were both on that list because, when they were
/// written, this process called `initialize()` on no manager, and an
/// uninitialised manager does not report "I cannot tell", it reports "nothing
/// exists". `ArcaEngineCommand.run()` now initializes all three before it binds
/// the socket, so that reason has expired for both: `Inspect` answers from that
/// loaded state below, and `ListResources` still answers
/// `unsupported_capability` because it is unwritten -- Task 8's work -- not
/// because the state behind it is empty.
public final class SandboxEngineService: Arca_Engine_V1_SandboxEngineAsyncProvider {
    public let interceptors: Arca_Engine_V1_SandboxEngineServerInterceptorFactoryProtocol? = nil

    // `containerManager` is read by `inspect(request:)` below. The other four
    // are held and, in this build, unread. Deliberate on both counts.
    //
    // Unread because the methods that would consult them are the ones this
    // build does not implement. Held because the dependency edge is itself a
    // shipped property: gascan's tests/release/engine-targets-check.sh asserts
    // that `arca-engine` and `ArcaEngine` reach neither `DockerAPI` nor
    // `ArcaDaemon`, and that assertion measures something only while this
    // target genuinely depends on ContainerBridge. Dropping the four to silence
    // an unused-property reading would make the release gate pass for a reason
    // that has nothing to do with what it exists to prove.
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
    /// Three arms, kept distinct. `engine.proto`'s `InspectResponse`
    /// (`:354-365`) separates "it is not there" from "I could not tell" because
    /// they "demand opposite behaviour from a reconciler": on `absent` a
    /// consumer creates the sandbox, so answering `absent` for a sandbox that is
    /// running induces a duplicate, and answering an error for one that is
    /// genuinely gone stalls the reconciler instead. A read that throws is the
    /// error arm; a read that resolves nothing is the absent arm; they are never
    /// merged.
    ///
    /// **The owner labels are read before the image digest, and the order is the
    /// point.** Container names are a flat namespace this engine does not own,
    /// so the name a sandbox id resolves to can belong to something else
    /// entirely -- and something else was very likely created from a tag, which
    /// `imageDigest(fromReference:)` refuses. Checking the digest first answers
    /// `invalid_output` for that container, and `invalid_output` is the code
    /// gascan reserves for "the engine sent me something I cannot interpret"
    /// (`crates/gascan-arca/src/error.rs`), which tells the consumer the engine
    /// is broken when the truth is a foreign resource.
    /// `foreign_resource_refused` exists for exactly that, so the label read
    /// goes first and the digest refusal is left to describe only containers
    /// this engine has already established are gascan's.
    ///
    /// Refusing an unlabelled container rather than returning a `Sandbox`
    /// without an owner is the same finding one hop later: gascan turns an
    /// ownerless `Sandbox` into `invalid_output("sandbox {id} carries no owner
    /// labels")` itself (`translate.rs:412-414`), so the ownerless sandbox arm
    /// reaches the consumer as the same wrong code.
    ///
    /// This is not the engine interpreting labels, which `engine.proto:143-148`
    /// forbids. The engine is not deciding whether a labelled resource is the
    /// caller's; it is declining to assert that an unlabelled one **is** the
    /// sandbox that was asked for. The consumer's judgment is untouched: a
    /// container labelled for a different sandbox is returned with its labels,
    /// and `translate.rs:421-425` raises `OwnershipMismatch` on its own. No
    /// `sandbox_id` comparison happens here.
    ///
    /// **The ports are what the store holds, and that is deliberate.**
    /// `setPortMapManager` is unwired until Task 11, so a container's stored
    /// `hostConfig.portBindings` can name a binding that was never actually
    /// published on the host. Reporting the store is still correct: drift
    /// detection compares the engine's report against the desired spec, and a
    /// report synthesised from anything else would compare the wrong thing. What
    /// this method must never do is emit a port value the store did not hold --
    /// see `sandboxPorts(fromBindings:)` for the three stored shapes the
    /// contract cannot carry and why each is refused rather than invented.
    func inspect(request: Arca_Engine_V1_InspectRequest) async -> Arca_Engine_V1_InspectResponse {
        let name = SandboxIdentity.containerName(forSandboxId: request.sandboxID)
        let found = await engineErrorCatching(.commandIo, resource: name) {
            try await self.containerManager.getContainer(id: name)
        }
        switch found {
        case .failure(let error):
            return Arca_Engine_V1_InspectResponse.with { $0.error = error }
        case .success(nil):
            return Arca_Engine_V1_InspectResponse.with { $0.absent = Arca_Engine_V1_Absent() }
        case .success(.some(let container)):
            return await sandboxResponse(
                for: container, name: name, sandboxId: request.sandboxID
            )
        }
    }

    /// The sandbox arm, and the two refusals that stand in front of it.
    ///
    /// Separate from `inspect(request:)` so that the order the doc comment above
    /// argues for is the order this reads in: labels, then digest, then ports.
    private func sandboxResponse(
        for container: Container,
        name: String,
        sandboxId: String
    ) async -> Arca_Engine_V1_InspectResponse {
        guard let owner = SandboxIdentity.owner(from: container.config.labels) else {
            return Arca_Engine_V1_InspectResponse.with {
                $0.error = engineError(
                    .foreignResourceRefused,
                    resource: name,
                    message: "container \(name) carries no gascan owner labels, so this engine "
                        + "cannot assert it is the sandbox that was asked for"
                )
            }
        }
        guard let digest = imageDigest(fromReference: container.image) else {
            return Arca_Engine_V1_InspectResponse.with {
                $0.error = engineError(
                    .invalidOutput,
                    resource: name,
                    message: "container image \(container.image) is not an exact digest reference"
                )
            }
        }
        let bindings = await containerManager.convertPortBindingsToMappings(
            container.hostConfig.portBindings
        )
        switch sandboxPorts(fromBindings: bindings) {
        case .failure(let unrepresentable):
            return Arca_Engine_V1_InspectResponse.with {
                $0.error = engineError(
                    .invalidOutput, resource: name, message: unrepresentable.reason
                )
            }
        case .success(let ports):
            return Arca_Engine_V1_InspectResponse.with { response in
                response.sandbox = Arca_Engine_V1_Sandbox.with { sandbox in
                    sandbox.sandboxID = sandboxId
                    sandbox.image = digest
                    sandbox.state = sandboxState(fromStatus: container.state.status)
                    sandbox.owner = owner
                    sandbox.ports = ports
                }
            }
        }
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
    /// Unimplemented in this build, for the reason `inspect` used to give and
    /// with a sharper edge.
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
    /// dropped every container labelled `com.arca.internal=true`, and
    /// `NetworkManager.listNetworks()` swallowed a WireGuard-backend failure
    /// with `try?`, turning a real failure into a clean answer. Both are now
    /// fixed in `ContainerBridge` -- `listContainers` takes an `includeInternal:`
    /// argument and `listNetworks()` throws -- and this method must use both
    /// when it is written, because a silently incomplete list is worse than no
    /// list.
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
