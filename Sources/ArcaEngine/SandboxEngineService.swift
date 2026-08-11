import ContainerBridge
import GRPC
import Logging
import SandboxEngineProto

/// Arca's implementation of the published sandbox-engine contract.
///
/// Each method is a thin seam: translate in, call ContainerBridge, translate
/// out. Business logic belongs in ContainerBridge and mapping belongs in
/// EngineTranslation, so that this file stays readable as a list of the
/// contract's eleven methods.
public final class SandboxEngineService: Arca_Engine_V1_SandboxEngineAsyncProvider {
    public let interceptors: Arca_Engine_V1_SandboxEngineServerInterceptorFactoryProtocol? = nil

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
            guard let digest = imageDigest(fromReference: container.image) else {
                return Arca_Engine_V1_InspectResponse.with {
                    $0.error = engineError(
                        .invalidOutput,
                        resource: name,
                        message: "container image \(container.image) is not an exact digest reference"
                    )
                }
            }
            return Arca_Engine_V1_InspectResponse.with { response in
                response.sandbox = Arca_Engine_V1_Sandbox.with { sandbox in
                    sandbox.sandboxID = request.sandboxID
                    sandbox.image = digest
                    sandbox.state = sandboxState(fromStatus: container.state.status)
                    if let owner = SandboxIdentity.owner(from: container.config.labels) {
                        sandbox.owner = owner
                    }
                    sandbox.ports = []
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
    /// Unlabelled resources are reported, never filtered: a resource the
    /// engine holds no labels for is exactly what a consumer needs to see to
    /// notice drift, and hiding it here would defeat that silently
    /// (engine.proto:389-391).
    func listResources(request: Arca_Engine_V1_ListResourcesRequest) async -> Arca_Engine_V1_ListResourcesResponse {
        let collected = await engineErrorCatching(.commandIo) {
            var resources: [Arca_Engine_V1_Resource] = []
            for container in try await self.containerManager.listContainers(all: true) {
                resources.append(
                    resourceMessage(
                        kind: .container,
                        name: containerResourceName(names: container.names, id: container.id),
                        labels: container.labels
                    )
                )
            }
            for volume in try await self.volumeManager.listVolumes() {
                resources.append(
                    resourceMessage(kind: .volume, name: volume.name, labels: volume.labels)
                )
            }
            for network in await self.networkManager.listNetworks() {
                resources.append(
                    resourceMessage(kind: .network, name: network.name, labels: network.labels)
                )
            }
            return resources
        }
        switch collected {
        case .failure(let error):
            return Arca_Engine_V1_ListResourcesResponse.with { $0.error = error }
        case .success(let resources):
            return Arca_Engine_V1_ListResourcesResponse.with { response in
                response.resources = Arca_Engine_V1_ResourceList.with { $0.resources = resources }
            }
        }
    }

    public func listResources(
        request: Arca_Engine_V1_ListResourcesRequest,
        context: GRPCAsyncServerCallContext
    ) async throws -> Arca_Engine_V1_ListResourcesResponse {
        await listResources(request: request)
    }
}
