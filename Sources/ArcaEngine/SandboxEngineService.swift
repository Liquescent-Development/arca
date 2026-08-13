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
/// **In this build, four of the eleven are implemented: `Capabilities`,
/// `Inspect`, `ListResources` and `PrepareImage`.** The other seven answer
/// `unsupported_capability` inside their response `oneof`.
///
/// `Inspect` and `ListResources` were both on that list because, when they were
/// written, this process called `initialize()` on no manager, and an
/// uninitialised manager does not report "I cannot tell", it reports "nothing
/// exists". `ServeCommand.run()` now initializes all three before it binds
/// the socket, so that reason has expired for both, and both now answer from
/// that loaded state below.
public final class SandboxEngineService: Arca_Engine_V1_SandboxEngineAsyncProvider {
    public let interceptors: Arca_Engine_V1_SandboxEngineServerInterceptorFactoryProtocol? = nil

    // `containerManager` is read by `inspect(request:)` and, with
    // `volumeManager` and `networkManager`, by `listResources(request:)` below.
    // `imageManager` is read by `prepareImage(request:)`. `execManager` is held
    // and, in this build, unread. Deliberate on both counts.
    //
    // Unread because the method that would consult it -- `Exec` -- is among the
    // seven this build does not implement. Held because
    // the dependency edge is itself a shipped property: gascan's
    // tests/release/engine-targets-check.sh asserts that `arca-engine` and
    // `ArcaEngine` reach neither `DockerAPI` nor `ArcaDaemon`, and that
    // assertion measures something only while this target genuinely depends on
    // ContainerBridge. Dropping the two to silence an unused-property reading
    // would make the release gate pass for a reason that has nothing to do with
    // what it exists to prove.
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
    ///
    /// **Absent content is `not_found`, and that is a correct, final answer.**
    /// It is not `unsupported_capability`, which means "this build cannot do
    /// that", and it is not an invitation to fetch. `engine.proto:308-313` says
    /// the same thing above the request message: "Materialise a rootfs for
    /// content THE ENGINE ALREADY HOLDS ... Absent content is a failure; it is
    /// never a fetch", and "How the engine comes to hold the content is
    /// deliberately unanswered by this contract." Content arrives by
    /// `arca-engine image load --oci-layout <dir>`, out of band, before any of
    /// this.
    ///
    /// **There is no fallback to `ImageManager.pullImage`, and adding one would
    /// undo the milestone.** It is the obvious-looking improvement here -- the
    /// manager is right there, it has the method, and the failing request names
    /// exactly what it would fetch. The design rejected it because it "would put
    /// registry credentials and Keychain access back inside the component the
    /// policy boundary exists to constrain"
    /// (docs/superpowers/specs/2026-08-10-p5-1-engine-service-and-wiring-design.md
    /// §2.2). A compromised guest must have no frame it can send that reaches a
    /// registry, and this is the method the proto itself calls "the one method
    /// that would grow a registry client if nobody were watching it".
    ///
    /// **What this verifies, and what it does not.** It asks the image store
    /// whether it holds the content in full: an image under exactly this digest,
    /// and every blob that image names present in the content store. That last
    /// part is the substance -- an image row can outlive its layer blobs, and
    /// the cheap answer, `imageExists(nameOrId:)`
    /// (`ContainerBridge/ImageManager.swift:616-624`), says `true` for one that
    /// has: it is built on `inspectImage`, which reads the index, the manifest
    /// and the config and never a layer. `Ack` carries no payload, so an `Ack`
    /// granted on that answer is a report the consumer has no way to check.
    ///
    /// It does **not** unpack the layers into the OverlayFS layer cache, which
    /// is the only thing in this codebase that materialises a rootfs. That is
    /// not a shortcut taken for convenience; the unpacker is not reachable here
    /// in a way that would be correct. `ContainerManager` builds its
    /// `OverlayFSUnpacker` inside `initialize()`
    /// (`ContainerBridge/ContainerManager.swift:280-285`) and keeps it private,
    /// and `Containerization.OverlayFSUnpacker.unpack` is per-*container*, not
    /// per-image: it creates `upper` and `work` directories at a container path
    /// and increments a reference count for each layer
    /// (`containerization/Sources/Containerization/Image/Unpacker/OverlayFSUnpacker.swift:123-144`).
    /// Running it for an image with no container would leak reference counts
    /// nothing will ever release, and its per-image half, `unpackLayerToCache`,
    /// is private upstream. `Create` unpacks, scoped to the container that owns
    /// the result; the promise this method can keep is that `Create` will find
    /// the content here and will not need to reach a registry for it.
    ///
    /// **The repository is checked as well as the digest.** Answering `Ack` for
    /// content held under a different repository would be a success followed by
    /// a `Create` failure, since `ContainerManager.createContainer` resolves the
    /// image by the reference it is given
    /// (`ContainerBridge/ContainerManager.swift:1696-1698`). The comparison
    /// splits both sides by Gas Can's own rule -- see
    /// `imageRepository(ofReference:)` -- and is exact. It normalizes no
    /// registry prefix, so content stored as `docker.io/library/alpine:3.19` is
    /// not found under a requested repository of `alpine`. That is the safe
    /// direction and it is chosen deliberately: a false `not_found` is visible
    /// and recoverable, a false `Ack` is neither.
    func prepareImage(request: Arca_Engine_V1_PrepareImageRequest) async -> Arca_Engine_V1_PrepareImageResponse {
        let resource = imageReference(forDigest: request.image)
        guard let key = imageStoreDigest(request.image) else {
            return Self.prepareImageFailure(engineError(
                .invalidResourceIdentity,
                resource: resource,
                message: "an image digest is a non-empty repository and a 64-character lowercase "
                    + "hex sha256 carrying no prefix"
            ))
        }

        let held = await engineErrorCatching(.commandIo, resource: resource) {
            try await self.imageManager.heldImageContent(digest: key)
        }
        switch held {
        case .failure(let error):
            return Self.prepareImageFailure(error)
        case .success(.noImageForDigest):
            return Self.prepareImageFailure(engineError(
                .notFound,
                resource: resource,
                message: "this engine holds no image with that content digest and will not fetch "
                    + "one; load it with 'arca-engine image load --oci-layout <dir>'"
            ))
        case .success(.blobsMissing(let reference, let digests)):
            return Self.prepareImageFailure(engineError(
                .notFound,
                resource: resource,
                message: "the image stored as \(reference) carries that content digest, but this "
                    + "engine does not hold \(digests.count) of the blobs it names: "
                    + digests.joined(separator: ", ")
            ))
        case .success(.held(let reference)):
            let stored = imageRepository(ofReference: reference)
            guard stored == request.image.repository else {
                return Self.prepareImageFailure(engineError(
                    .notFound,
                    resource: resource,
                    message: "this engine holds that content digest under repository "
                        + "\(stored), not \(request.image.repository)"
                ))
            }
            logger.info("image content is held in full", metadata: [
                "reference": "\(reference)",
                "digest": "\(key)",
            ])
            return Arca_Engine_V1_PrepareImageResponse.with { $0.ok = Arca_Engine_V1_Ack() }
        }
    }

    /// The failure arm, in one place.
    ///
    /// Five refusals reach it, and spelling the wrapper out five times is five
    /// chances for a later edit to build one of them differently.
    private static func prepareImageFailure(
        _ error: Arca_Engine_V1_EngineError
    ) -> Arca_Engine_V1_PrepareImageResponse {
        Arca_Engine_V1_PrepareImageResponse.with { $0.error = error }
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
    /// `engine.proto`'s contract for this method is "Every resource the engine
    /// holds, labelled or not" (engine.proto:387-391), because a consumer's
    /// drift and leak detection depends on seeing the unlabelled ones. Nothing
    /// here filters: an unlabelled resource is reported with `owner` unset,
    /// which is how the consumer sees one it does not own
    /// (engine.proto:169-173). That is deliberately NOT what `inspect` does one
    /// method up, where an unlabelled container is refused as
    /// `foreign_resource_refused` -- these answer different questions. This one
    /// reports what the engine holds; that one asserts a named container is the
    /// sandbox that was asked for, and it cannot assert that without labels.
    ///
    /// **An empty `ResourceList` is not an error arm.** It is a confident report
    /// of a clean host, which is precisely the report that hides a leak, so the
    /// two must stay distinguishable at every source below. An earlier revision
    /// of this method returned `[]` under every input: `initialize()` had been
    /// called on no manager, so containers and volumes had no loaded rows and
    /// `NetworkManager.listNetworks()` read two backends that were both nil.
    /// `ServeCommand.run()` now initializes all three before it binds the
    /// socket, so the state these three calls read is really there.
    ///
    /// Two further defects sat behind that emptiness and would have surfaced the
    /// moment state was loaded: `listContainers(all: true)` with no filters
    /// dropped every container labelled `com.arca.internal=true`, and
    /// `listNetworks()` swallowed a WireGuard-backend failure with `try?`,
    /// turning a real failure into a clean answer. Both are fixed in
    /// `ContainerBridge`, and this method uses both: `includeInternal: true`, and
    /// a `try` that carries a backend failure out as `command_io` rather than as
    /// a short list. A silently incomplete list is worse than no list.
    func listResources(request: Arca_Engine_V1_ListResourcesRequest) async -> Arca_Engine_V1_ListResourcesResponse {
        let collected = await engineErrorCatching(.commandIo) {
            var resources: [Arca_Engine_V1_Resource] = []
            for container in try await self.containerManager.listContainers(
                all: true, includeInternal: true
            ) {
                resources.append(resourceMessage(
                    kind: .container,
                    name: containerResourceName(names: container.names, id: container.id),
                    labels: container.labels
                ))
            }
            for volume in try await self.volumeManager.listVolumes() {
                resources.append(resourceMessage(
                    kind: .volume, name: volume.name, labels: volume.labels
                ))
            }
            for network in try await self.networkManager.listNetworks() {
                resources.append(resourceMessage(
                    kind: .network, name: network.name, labels: network.labels
                ))
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
