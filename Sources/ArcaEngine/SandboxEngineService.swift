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
/// **In this build, nine of the eleven are implemented: `Capabilities`,
/// `Inspect`, `ListResources`, `PrepareImage`, `Create`, `CreateContainer`,
/// `Start`, `Stop` and `Remove`.** The other two -- `Exec` and `Logs` -- answer
/// `unsupported_capability`, and both send it inside a stream frame rather than
/// a response `oneof`: `ExecServerFrame.frame.error` (`:1099`) and
/// `LogsChunk.outcome.error` (`:1109`). That is why neither is reachable from a
/// test in this target, which cannot construct a
/// `GRPCAsyncResponseStreamWriter`, and why gascan's live tier is what asserts
/// they answer at all.
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
    /// Every capability flag reports what this build implements, and a flag that
    /// is true before its code exists induces a consumer to send a request the
    /// engine cannot honour.
    ///
    /// **Four flags are true, and each one names a live test that drove the
    /// capability from outside this engine's own store.** `Inspect` reports what
    /// the store holds, deliberately, so it can corroborate none of them; every
    /// flag below that is true was earned by an observation of the guest or of
    /// the host, and every flag that is false is false because no such
    /// observation exists or because one was made and failed.
    ///
    /// - `projectMount`: the host writes a file into the project root, the
    ///   guest's own `Cmd` serves it back over a published port, and the host
    ///   then reads a file the guest wrote into the same directory. Earned by
    ///   `mounts::the_project_root_is_readable_in_the_guest_and_writable_back_to_the_host`
    ///   in gascan's `gascan-arca` live tier. SEEN TO FAIL, and isolated: with
    ///   `binds` here started empty instead of carrying the project mount, it
    ///   was the **only** live test that failed, after 180s with
    ///   `connected and read nothing`. `CreateTranslationTests
    ///   .testTheProjectMountAndTheVolumesBecomeBinds` also caught that
    ///   mutation, which is the difference between the two: the unit test sees
    ///   the argument, the live test sees the filesystem.
    /// - `loopbackPublish`: a TCP connection from the test process reads bytes
    ///   the guest produced. Earned by
    ///   `ports::a_published_port_is_reachable_from_the_test_process`.
    /// - `resourceLimits`: the guest's own `/sys/fs/cgroup/cpu.max` and
    ///   `memory.max` are exactly what the request asked for. Earned by
    ///   `limits::the_requested_cpu_and_memory_limits_are_the_guests_own_cgroup_limits`.
    ///   SEEN TO FAIL, and isolated: with `nanoCpus` and `memory` in
    ///   `sandboxContainerSpec` forced to nil, it was the **only** live test
    ///   that failed, and the guest reported `400000 100000` and `4294967296`
    ///   -- four CPUs and ContainerBridge's 4GiB default, in place of the one
    ///   CPU and 1GiB that were asked for.
    ///
    /// - `namedVolumes`: the guest's own `/proc/mounts` names all three managed
    ///   targets, each backed by a distinct ext4 block device whose size in
    ///   `/proc/partitions` is the capacity that target's volume was declared
    ///   with -- 262144, 524288 and 1048576 1K-blocks for 256MiB, 512MiB and
    ///   1GiB -- and the guest writes a token into each and reads it back.
    ///   Earned by
    ///   `mounts::the_managed_volumes_are_mounted_at_their_declared_targets_and_writable`.
    ///   SEEN TO FAIL, against this repository at 6c77bb8: the same test reported
    ///   `/home/workspace/.local is not mounted in the guest`, with the guest's
    ///   overlay reading
    ///   `lowerdir=/mnt/layer4:/mnt/layer3:/mnt/layer2:/mnt/layer1:/mnt/layer0`
    ///   -- five lowerdirs for a two-layer image, because vminitd counted
    ///   /dev/vdc upwards and swallowed the three volume devices as layers.
    ///   The writability half of that test passed even then, which is why it is
    ///   not the assertion that carries the claim: the targets exist in the
    ///   image, so the write landed in the container's own overlay.
    ///
    /// `tty` and `signals` are milestone 3's, with `Exec`. `offline` stays
    /// `.unverified` until milestone 4 proves it.
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
                capabilities.projectMount = true
                capabilities.namedVolumes = true
                capabilities.tty = false
                capabilities.signals = false
                capabilities.loopbackPublish = true
                capabilities.resourceLimits = true
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
    /// Volumes, then the network, then the container -- and whatever succeeded
    /// before a failure is reported.
    ///
    /// **The order is the contract's, and the report is the reason it matters.**
    /// `CreateFailed.created` exists because "losing this evidence leaks
    /// resources that nothing afterwards knows to look for"
    /// (engine.proto:279-283): the consumer removes exactly what it is told was
    /// made, so a resource created and not reported is a resource on the host
    /// that no `Remove` will ever name and only `ListResources` can find. Every
    /// step below appends to `created` immediately after the call that made the
    /// resource returns, never in a batch at the end, because a batch is one
    /// early return away from being skipped.
    ///
    /// **Nothing is created before both refusal gates.** The image is checked
    /// first and the request is translated second; both report an empty
    /// `created`, so their order decides only which refusal a malformed request
    /// hears first. The image goes first because it is the failure `PrepareImage`
    /// exists to pre-empt, and hearing it here means the `Ack` that preceded it
    /// was wrong -- which is worth surfacing ahead of a field-level complaint.
    ///
    /// **What this deliberately does NOT do**, both of which the daemon does and
    /// both of which would arrive together if this method were written by
    /// mirroring `ArcaDaemon`:
    ///
    /// - It runs no restart policy. `applyRestartPolicies()` calls
    ///   `startContainer` and boots VMs, which would resurrect sandboxes the
    ///   consumer believes stopped -- and the daemon does it before the socket
    ///   binds, so the consumer could not even observe it happening. The
    ///   container is created with the default `no` policy
    ///   (`ContainerManager.swift:1916`) and nothing here changes that.
    /// - It deletes no shared `initfs.ext4`. The private image-store root exists
    ///   precisely so that this engine never touches the file Apple's tooling
    ///   shares.
    func create(request: Arca_Engine_V1_CreateRequest) async -> Arca_Engine_V1_CreateResponse {
        let spec: SandboxContainerSpec
        switch await createSpec(for: request) {
        case .failure(let error):
            return Self.createFailed([], error)
        case .success(let translated):
            spec = translated
        }

        var created: [Arca_Engine_V1_Resource] = []

        for volume in request.volumes {
            let driver = volumeDriver(forCapacityBytes: volume.capacityBytes)
            let made = await Self.createCatching(resource: volume.name) {
                try await self.volumeManager.createVolume(
                    name: volume.name,
                    driver: driver.driver,
                    driverOpts: driver.options,
                    labels: spec.labels
                )
            }
            if case .failure(let error) = made {
                return Self.createFailed(created, error)
            }
            created.append(resourceMessage(kind: .volume, name: volume.name, labels: spec.labels))
        }

        if case .networkedName(let networkName) = request.network.mode {
            // Asked before creating, because `NetworkManager.createNetwork` does
            // not refuse a name it already holds: it generates a fresh id and
            // overwrites `networkNames[name]` (`NetworkManager.swift:467`), so a
            // repeated create would leave the first network on the host with
            // nothing pointing at it. `createDefaultNetworks` guards itself the
            // same way (`:297-330`); this is that guard at the one call site
            // that takes a name from the wire. It is a check-then-act and there
            // is no engine-side lock to make it otherwise -- the narrower race
            // is still much better than the silent overwrite.
            if await networkManager.getNetworkByName(name: networkName) != nil {
                return Self.createFailed(created, engineError(
                    .resourceConflict,
                    resource: networkName,
                    message: "this engine already holds a network named \(networkName)"
                ))
            }
            let made = await Self.createCatching(resource: networkName) {
                // `bridge` rather than `vmnet`, and it is the choice that decides
                // whether ports can ever publish: bridge networks are
                // WireGuard-backed (`NetworkManager.swift:393-395`), and
                // `getWireGuardClient` returns nil -- silently publishing
                // nothing -- for a container that is on no WireGuard network
                // (`:819-833`).
                try await self.networkManager.createNetwork(
                    name: networkName,
                    driver: "bridge",
                    subnet: nil,
                    gateway: nil,
                    ipRange: nil,
                    options: [:],
                    labels: spec.labels
                )
            }
            if case .failure(let error) = made {
                return Self.createFailed(created, error)
            }
            created.append(
                resourceMessage(kind: .network, name: networkName, labels: spec.labels)
            )
        }

        return await buildContainer(spec: spec, created: created)
    }

    /// The container phase of a create, shared by `Create` and `CreateContainer`.
    ///
    /// **Extracted rather than duplicated, and the reason is a mutation that
    /// survived.** `createSpec`'s comment records that a review replaced the one
    /// line deciding the image reference with `references.first ?? …` and the whole
    /// suite stayed green -- every sandbox would have recorded a tag and every
    /// `Inspect` would have answered `invalid_output`. Two independent container
    /// build paths would let exactly that drift back in on one of them.
    private func buildContainer(
        spec: SandboxContainerSpec,
        created: [Arca_Engine_V1_Resource]
    ) async -> Arca_Engine_V1_CreateResponse {
        var created = created
        let container = await Self.createCatching(resource: spec.name) {
            try await self.containerManager.createContainer(
                image: spec.image,
                name: spec.name,
                entrypoint: nil,
                command: nil,
                env: spec.env,
                workingDir: nil,
                labels: spec.labels,
                networkMode: spec.networkMode,
                binds: spec.binds,
                portBindings: spec.portBindings,
                memory: spec.memory,
                nanoCpus: spec.nanoCpus,
                user: spec.user
            )
        }
        if case .failure(let error) = container {
            return Self.createFailed(created, error)
        }
        created.append(resourceMessage(kind: .container, name: spec.name, labels: spec.labels))

        return Arca_Engine_V1_CreateResponse.with { response in
            response.created = Arca_Engine_V1_Created.with { $0.created = created }
        }
    }

    /// Both gates a create passes before anything is made: the engine really
    /// holds the content, and the request really translates.
    ///
    /// **This is a seam and not a convenience, and the reason is a mutation that
    /// survived.** The whole of Problem 1 -- the justification for widening a
    /// resolver shared with Arca's Docker surface -- rests on `create` handing
    /// `createContainer` the exact digest reference rather than a stored tag,
    /// because that same string is what `Inspect` re-parses
    /// (`imageDigest(fromReference:)`, `:196`) and what `startContainer:2218`
    /// re-resolves after a restart. Task 11's review replaced the one line that
    /// decides it with `references.first ?? …` -- the arrangement Problem 1
    /// explicitly rejected -- and the whole suite stayed green. Every sandbox
    /// would have recorded `workspace:latest` and every `Inspect` would have
    /// answered `invalid_output`, with 123 tests passing.
    ///
    /// `ImageResolutionTests` proves the *resolver* accepts the digest form.
    /// Nothing proved the *caller* produced it. The resolution itself is
    /// genuinely unreachable without a VM -- `createContainer`'s `nativeManager`
    /// guard throws first -- but the string is a pure value, so this returns it
    /// where a test can see it. `create(request:)` calls exactly this and builds
    /// no spec of its own; there is no second path for a test to drift onto.
    ///
    /// The order of the two gates decides only which refusal a malformed request
    /// hears first, since neither creates anything. The image goes first because
    /// it is the failure `PrepareImage` exists to pre-empt, and hearing it here
    /// means the `Ack` that preceded it was wrong.
    package func createSpec(
        for request: Arca_Engine_V1_CreateRequest
    ) async -> Result<SandboxContainerSpec, Arca_Engine_V1_EngineError> {
        if case .failure(let error) = await heldImageReferences(for: request.image) {
            return .failure(error)
        }
        // Problem 1's decision, in one expression: the digest form, never a
        // stored reference. See `SandboxContainerSpec.image`.
        return sandboxContainerSpec(for: request, image: imageReference(forDigest: request.image))
    }

    /// A create failure with the evidence attached.
    ///
    /// Every early return in `create(request:)` goes through this, so that
    /// "report what was made" cannot be forgotten at one of them.
    private static func createFailed(
        _ created: [Arca_Engine_V1_Resource],
        _ error: Arca_Engine_V1_EngineError
    ) -> Arca_Engine_V1_CreateResponse {
        Arca_Engine_V1_CreateResponse.with { response in
            response.failed = Arca_Engine_V1_CreateFailed.with {
                $0.created = created
                $0.error = error
            }
        }
    }

    /// `engineErrorCatching` with the one distinction `Create` has to preserve.
    ///
    /// A name that is already taken is `resource_conflict`, not
    /// `command_failed`. The two are opposite instructions to a reconciler:
    /// `command_failed` says the engine tried and something broke, so retrying
    /// is reasonable, while `resource_conflict` says the name is occupied and
    /// retrying will fail identically until something is removed. Collapsing
    /// them puts a reconciler into a loop against a sandbox that already exists.
    private static func createCatching<T>(
        resource: String,
        _ body: () async throws -> T
    ) async -> Result<T, Arca_Engine_V1_EngineError> {
        do {
            return .success(try await body())
        } catch {
            let code: EngineErrorCode
            switch error {
            case ContainerManagerError.nameConflict, VolumeError.alreadyExists:
                code = .resourceConflict
            default:
                code = .commandFailed
            }
            return .failure(engineError(code, resource: resource, message: "\(error)"))
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
    ///
    /// It is compared against **every** reference the digest is held under, and
    /// that is a correction rather than a nicety: a store holds one row per
    /// reference, `ImageManager.tagImage(source:target:)` adds a row to content
    /// that is already there, and the first revision of this method tested the
    /// request against whichever row `imageStore.list()` returned first. Two
    /// rows on one digest then made the answer depend on store ordering --
    /// `not_found` for content the engine held, naming a repository the caller
    /// had not asked about.
    func prepareImage(request: Arca_Engine_V1_PrepareImageRequest) async -> Arca_Engine_V1_PrepareImageResponse {
        switch await heldImageReferences(for: request.image) {
        case .failure(let error):
            return Self.prepareImageFailure(error)
        case .success:
            return Arca_Engine_V1_PrepareImageResponse.with { $0.ok = Arca_Engine_V1_Ack() }
        }
    }

    /// The references this engine holds a wire digest's content under, or the
    /// refusal that says why it holds none.
    ///
    /// **Shared by `PrepareImage` and `Create`, and sharing it is the point
    /// rather than a tidiness.** The two methods are a promise and the act that
    /// depends on it: an `Ack` means "`Create` will find this content and will
    /// not need a registry for it", and a `Create` that then decided held-ness
    /// by a second rule could refuse content its own engine had just promised.
    /// One function decides, so the two cannot disagree about one digest.
    ///
    /// The five refusals above it are the same five in either caller, and their
    /// prose is unchanged from when `prepareImage` spelt them out inline. See
    /// that method's doc comment for why the store is asked in full rather than
    /// through `imageExists`, why the repository is compared as well as the
    /// digest, and why the comparison is exact and normalizes nothing.
    func heldImageReferences(
        for image: Arca_Engine_V1_ImageDigest
    ) async -> Result<[String], Arca_Engine_V1_EngineError> {
        let resource = imageReference(forDigest: image)
        guard let key = imageStoreDigest(image) else {
            return .failure(engineError(
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
            return .failure(error)
        case .success(.noImageForDigest):
            return .failure(engineError(
                .notFound,
                resource: resource,
                message: "this engine holds no image with that content digest and will not fetch "
                    + "one; load it with 'arca-engine image load --oci-layout <dir>'"
            ))
        case .success(.blobsMissing(let references, let digests)):
            return .failure(engineError(
                .notFound,
                resource: resource,
                message: "this engine has that content digest in its store under "
                    + "\(references.joined(separator: ", ")), but does not hold \(digests.count) "
                    + "of the blobs it names: " + digests.joined(separator: ", ")
            ))
        case .success(.held(let references)):
            // Every reference the digest is held under, because a tag puts a
            // second row on one piece of content and the request names one of
            // them. Testing a single row would refuse content the engine holds,
            // by whichever row the store listed first.
            let stored = Set(references.map(imageRepository(ofReference:))).sorted()
            guard stored.contains(image.repository) else {
                return .failure(engineError(
                    .notFound,
                    resource: resource,
                    message: "this engine does not hold that content digest under repository "
                        + "\(image.repository); it holds it under "
                        + stored.joined(separator: ", ")
                ))
            }
            logger.info("image content is held in full", metadata: [
                "references": "\(references.joined(separator: ", "))",
                "digest": "\(key)",
            ])
            return .success(references)
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
    ///
    /// **The container only.** `engine.proto:296-302` states it: everything named
    /// in `retained` already exists and is reused, so this creates no volume and no
    /// network. Gas Can already enforces the other half --
    /// `CreateOutcome::for_recreate` refuses an answer carrying the whole topology
    /// (`crates/gascan-arca/tests/backend_unary.rs:740`) -- so an engine that
    /// rebuilt a retained resource would be caught there rather than here.
    func createContainer(
        request: Arca_Engine_V1_CreateContainerRequest
    ) async -> Arca_Engine_V1_CreateResponse {
        if let refusal = await reusedTopologyRefusal(request) {
            return Self.createFailed([], refusal)
        }

        let spec: SandboxContainerSpec
        switch await createSpec(for: request.create) {
        case .failure(let error):
            return Self.createFailed([], error)
        case .success(let translated):
            spec = translated
        }

        return await buildContainer(spec: spec, created: [])
    }

    /// Why this recreate may not reuse the topology it names, or nil.
    ///
    /// **It verifies what the container will actually mount, and the first version
    /// of this guard did not.** It checked `request.retained` -- a list the caller
    /// supplies -- while the binds are built from `request.create.volumes`
    /// (`EngineCreate.swift:106-123`) and the attachment from
    /// `request.create.network`. Those are independent fields, so a request with
    /// `retained: []` and populated `create.volumes` passed the guard untouched and
    /// built the container: **the exact silent failure the guard exists to prevent,
    /// reachable with the guard fully intact.** MEASURED by Task 1's review, which
    /// also found that the test written to prove the guard asserted that bypass as
    /// intended behaviour.
    ///
    /// So the topology is the subject and `retained` is an assertion the caller must
    /// match, rather than the sole source of truth. Each volume the container will
    /// mount, and the network it will attach to, must be:
    ///
    /// 1. named in `retained` -- the caller has to have declared it is reusing this,
    ///    because a topology entry the caller never claimed is one nobody has said
    ///    already exists;
    /// 2. held by this engine, and
    /// 3. owned by the caller, on the same three-tier comparison `Remove` uses.
    ///
    /// **This is not a contract change.** The wire format is untouched and
    /// `engine.proto` does not forbid an engine refusing more than the minimum.
    ///
    /// **The reverse direction is deliberately not checked**: a `retained` entry
    /// naming something outside the topology is ignored rather than refused. The
    /// engine's business here is the mount, and Gas Can's
    /// `validate_retained_resources` (`crates/gascan-core/src/runtime.rs:893-918`)
    /// already requires exact count equality client-side, so refusing extras would
    /// add a refusal no client can trigger and no test could keep honest.
    ///
    /// Containers are not in the topology this walks: the container is what this RPC
    /// builds, so one appearing in `retained` is the caller's error and
    /// `containerManager.createContainer` refuses it as a name conflict with a
    /// better message than this could give.
    private func reusedTopologyRefusal(
        _ request: Arca_Engine_V1_CreateContainerRequest
    ) async -> Arca_Engine_V1_EngineError? {
        for resource in Self.reusedTopology(of: request.create) {
            // `createSpec` refuses an unnamed volume with `invalid_resource_identity`
            // (`EngineCreate.swift:106-113`), and this guard now runs in front of it
            // -- so without this the same request answers `not_found` carrying an
            // EMPTY `resource` field and the message "this engine holds no volume
            // named ". "The `resource` field names the offender" is a stated rule of
            // this contract and an empty string names nothing. This preserves the
            // answer the caller used to get rather than inventing a new one.
            guard !resource.name.isEmpty else {
                return engineError(
                    .invalidResourceIdentity,
                    resource: SandboxIdentity.containerName(forSandboxId: request.create.sandboxID),
                    message: "a \(resource.kind.noun) in this request carries no name"
                )
            }

            // The KIND half of this comparison is as load-bearing as the name half:
            // without it a `retained` entry naming a volume would satisfy the
            // network's requirement, and vice versa. Gas Can's names make that
            // collision unlikely rather than impossible, and `resourceKind` exists
            // precisely so the comparison can be total.
            guard request.retained.contains(where: {
                $0.identity.kind == resource.kind.resourceKind && $0.identity.name == resource.name
            }) else {
                return engineError(
                    .invalidState,
                    resource: resource.name,
                    message: "this recreate mounts \(resource.kind.noun) \(resource.name) but "
                        + "does not retain it; every resource the container reuses must be named "
                        + "in retained"
                )
            }

            // `storedLabels` rather than a lookup written here, because it is the
            // one place that already distinguishes "this engine does not hold it"
            // from "I could not tell" -- it catches `VolumeError.notFound` alone
            // and turns any other throw into `command_io`. A blanket catch would
            // report a failed store read as `not_found`, which instructs a
            // reconciler to rebuild a volume that exists; that is the confusion
            // `NetworkManager.swift:707-714` records as having made prune delete
            // an in-use network.
            let stored: [String: String]?
            switch await storedLabels(kind: resource.kind, name: resource.name) {
            case .failure(let error): return error
            case .success(let labels): stored = labels
            }

            if let refusal = ownershipRefusal(
                kind: resource.kind,
                name: resource.name,
                storedLabels: stored,
                owner: request.create.owner,
                action: .reuse
            ) {
                return refusal
            }
        }
        return nil
    }

    /// The resources a recreate reuses: exactly what the rebuilt container mounts
    /// and attaches to, read from the same fields the spec is built from.
    ///
    /// Derived from `create` rather than from `retained` so that the guard and the
    /// container cannot come to disagree about what the topology is. An offline
    /// sandbox contributes no network, which is why the network is a `case` and not
    /// an unconditional append.
    private static func reusedTopology(
        of request: Arca_Engine_V1_CreateRequest
    ) -> [(kind: RemovableKind, name: String)] {
        var topology = request.volumes.map { (kind: RemovableKind.volume, name: $0.name) }
        if case .networkedName(let networkName) = request.network.mode {
            topology.append((kind: .network, name: networkName))
        }
        return topology
    }

    public func createContainer(
        request: Arca_Engine_V1_CreateContainerRequest,
        context: GRPCAsyncServerCallContext
    ) async throws -> Arca_Engine_V1_CreateResponse {
        await createContainer(request: request)
    }

    /// See the note on the `create(request:)` overload above.
    ///
    /// **What this deliberately does NOT do, and it is the whole reason `Start`
    /// is dangerous to write by looking at the daemon.** The daemon's other
    /// caller of `startContainer` is `applyRestartPolicies()`
    /// (`ContainerManager.swift:495`), which asks the store for every container
    /// whose policy says restart and starts each one (`:513`);
    /// `ArcaDaemon.swift:286` calls it, and `server.start()` is not until `:314`.
    /// Imported here, that would boot VMs for sandboxes the consumer believes
    /// stopped, at a moment before the socket exists, so the consumer could not
    /// even observe it happening. This method starts exactly the one container the
    /// request names and the engine runs no policy pass at all; `Create` leaves
    /// the default `no` policy in place (`ContainerManager.swift:1916`) so there
    /// is nothing for one to find.
    ///
    /// **The refusals run before `startContainer`, and the order is the point.**
    /// `startContainer` resolves the name at `:2071`, *then* guards on
    /// `nativeManager` at `:2080`. So the resolver's hex prefix match happens
    /// first, and by the time anything would refuse, the container this method is
    /// about is already the wrong one. See `containerNameRefusal`.
    func start(request: Arca_Engine_V1_StartRequest) async -> Arca_Engine_V1_AckResponse {
        await lifecycleAck(verb: "start", sandboxId: request.sandboxID) { name in
            try await self.containerManager.startContainer(id: name)
        }
    }

    public func start(
        request: Arca_Engine_V1_StartRequest,
        context: GRPCAsyncServerCallContext
    ) async throws -> Arca_Engine_V1_AckResponse {
        await start(request: request)
    }

    /// See the note on the `create(request:)` overload above.
    ///
    /// No timeout is passed because the contract carries none: `StopRequest` is a
    /// `sandbox_id` and nothing else (engine.proto:372-375), so
    /// `stopContainer(id:timeout:)` takes its own default rather than a number
    /// this engine would have invented.
    ///
    /// **`Stop` is idempotent below this seam and that is ContainerBridge's
    /// behaviour, not this method's.** `stopContainer` returns without acting for
    /// a container already `created`, `exited` or `dead`
    /// (`ContainerManager.swift:2701-2707`), so a second `Stop` answers `Ack`.
    /// That is the right answer for a reconciler -- "it is stopped" is what it
    /// asked for -- but note what it does *not* change: the early return at
    /// `:2706` never touches `info.state`, so a container that was created and
    /// never started stays `created`, and `sandboxState(fromStatus:)` maps that
    /// to `.creating` (`EngineTranslation.swift:129`). `Inspect` therefore
    /// reports `SANDBOX_STATE_CREATING` after a successful `Stop`. Recorded here
    /// because it is visible on the wire, and left alone because inventing an
    /// `exited` state for a container that never ran would be a report of a
    /// transition that did not happen.
    func stop(request: Arca_Engine_V1_StopRequest) async -> Arca_Engine_V1_AckResponse {
        await lifecycleAck(verb: "stop", sandboxId: request.sandboxID) { name in
            try await self.containerManager.stopContainer(id: name)
        }
    }

    public func stop(
        request: Arca_Engine_V1_StopRequest,
        context: GRPCAsyncServerCallContext
    ) async throws -> Arca_Engine_V1_AckResponse {
        await stop(request: request)
    }

    /// `Start` and `Stop`, which differ only in the verb and the call.
    ///
    /// One function rather than two, because the three gates in front of the call
    /// are the same three and the failure this shape prevents is one of them being
    /// added to `Start` and forgotten on `Stop`. See `lifecycleRefusal` for what
    /// each gate refuses and why `Start` and `Stop` cannot compare owner labels
    /// the way `Remove` does.
    ///
    /// The container is read through `getContainer` first, which resolves through
    /// the same `resolveContainerID` the call below will -- so this is a
    /// check-then-act and the two reads can in principle disagree. There is no
    /// engine-side lock that would make it otherwise, and the narrower race is
    /// much better than no gate: the same reasoning `create(request:)` records
    /// for its network-name check.
    private func lifecycleAck(
        verb: String,
        sandboxId: String,
        _ act: (String) async throws -> Void
    ) async -> Arca_Engine_V1_AckResponse {
        let name = SandboxIdentity.containerName(forSandboxId: sandboxId)
        if let refusal = containerNameRefusal(name) { return Self.ackFailed(refusal) }

        let found = await engineErrorCatching(.commandIo, resource: name) {
            try await self.containerManager.getContainer(id: name)
        }
        let container: Container?
        switch found {
        case .failure(let error): return Self.ackFailed(error)
        case .success(let read): container = read
        }
        if let refusal = lifecycleRefusal(
            verb: verb, sandboxId: name, storedLabels: container?.config.labels
        ) {
            return Self.ackFailed(refusal)
        }

        if case .failure(let error) = await Self.actCatching(resource: name, { try await act(name) }) {
            return Self.ackFailed(error)
        }
        return Arca_Engine_V1_AckResponse.with { $0.ok = Arca_Engine_V1_Ack() }
    }

    /// See the note on the `create(request:)` overload above.
    ///
    /// **Every named resource is authorised before any of them is deleted, and
    /// the two passes cannot be merged.** `AckResponse` is `ok` or `error`
    /// (engine.proto:76-82) -- there is no `CreateFailed.created` here, no field
    /// in which a partial teardown can report what it already destroyed. So a
    /// single pass that deleted a container and then refused its volume would
    /// leave the consumer with an error, a sandbox that is gone, and no way to
    /// learn which of the two happened. Refusing the whole call before touching
    /// anything is the only arrangement in which an error means "nothing
    /// changed".
    ///
    /// A delete that *fails* mid-pass still has that problem and it is not
    /// solvable here: the resources before it are already gone and the error
    /// names only the one that failed. That is the contract's shape rather than
    /// this method's choice, and `ListResources` is what the consumer has to
    /// reconcile with afterwards.
    ///
    /// **No `force`.** `removeContainer` refuses a running container without it
    /// (`ContainerManager.swift:3011-3013`) and that refusal is the useful one: a
    /// consumer removing a sandbox it believes stopped, over a sandbox that is
    /// running, has a disagreement worth hearing about rather than a VM worth
    /// killing. The sibling backend takes the same position -- `container delete
    /// <name>` with no `--force` (`crates/gascan-apple/src/backend.rs:513-515`).
    /// `Stop` is how a consumer means to stop something.
    ///
    /// **`removeVolumes` is not passed, and the reason is that it does nothing.**
    /// `removeContainer(id:force:removeVolumes:)` spans
    /// `ContainerManager.swift:2995-3202` and the identifier `removeVolumes`
    /// occurs exactly once inside it: on the signature line. The body never reads
    /// it, so passing `true` would name a control the code does not have -- the
    /// shape of claim this milestone has shipped eight defects of. What the body
    /// does unconditionally is call `cleanupVolumesForContainer` (`:3170`), which
    /// deletes the container's *anonymous* volume mounts and spares its named
    /// ones. That is the right behaviour for this contract either way: `Remove`
    /// names exact resources (engine.proto:377-379), so every volume Gas Can
    /// wants gone arrives as its own `ResourceIdentity` and is deleted by the
    /// volume pass below, while an anonymous volume is one no `ResourceIdentity`
    /// can ever name and would otherwise leak.
    func remove(request: Arca_Engine_V1_RemoveRequest) async -> Arca_Engine_V1_AckResponse {
        // An empty remove has an `Ack` that is true and useless -- "I deleted
        // everything you named" over nothing. It is refused because the way one
        // arrives is a caller that dropped its list, and that caller reads the
        // `Ack` as a teardown that happened. The consumer refuses to build one
        // itself (`crates/gascan-arca/src/translate.rs:255-256`), so this refuses
        // nothing it sends.
        guard !request.resources.isEmpty else {
            return Self.ackFailed(engineError(
                .invalidState,
                message: "a remove names the resources to delete and this one names none"
            ))
        }
        // The labels every resource below is checked against. A half-set owner
        // cannot be compared -- it would match only resources labelled equally
        // half-set -- so it is refused here rather than turned into an
        // `ownership_mismatch` for every resource in the call, which would read
        // as "these are not yours" when the truth is "you did not say who you
        // are".
        guard !request.owner.managedBy.isEmpty, !request.owner.sandboxID.isEmpty else {
            return Self.ackFailed(engineError(
                .invalidResourceIdentity,
                message: "remove requires both owner labels to compare against; this request "
                    + "carries managed_by '\(request.owner.managedBy)' and sandbox_id "
                    + "'\(request.owner.sandboxID)'"
            ))
        }

        var ordered: [(kind: RemovableKind, name: String)] = []
        for identity in request.resources {
            switch removableKind(identity) {
            case .failure(let error): return Self.ackFailed(error)
            case .success(let kind): ordered.append((kind: kind, name: identity.name))
            }
        }
        // `enumerated` as the tiebreaker because `sorted(by:)` is not documented
        // stable: without it, two volumes in one request could be deleted in
        // either order, and a failure on the second would report a different
        // resource run to run.
        ordered = ordered.enumerated()
            .sorted { ($0.element.kind.removalRank, $0.offset) < ($1.element.kind.removalRank, $1.offset) }
            .map(\.element)

        for resource in ordered {
            let held: [String: String]?
            switch await storedLabels(kind: resource.kind, name: resource.name) {
            case .failure(let error): return Self.ackFailed(error)
            case .success(let labels): held = labels
            }
            if let refusal = removalRefusal(
                kind: resource.kind, name: resource.name, storedLabels: held, owner: request.owner
            ) {
                return Self.ackFailed(refusal)
            }
        }

        for resource in ordered {
            if let error = await delete(kind: resource.kind, name: resource.name) {
                return Self.ackFailed(error)
            }
        }
        return Arca_Engine_V1_AckResponse.with { $0.ok = Arca_Engine_V1_Ack() }
    }

    /// The labels the engine stores for one named resource, or nil when it holds
    /// no such resource.
    ///
    /// Each kind's "absent" is expressed differently by its manager -- a nil
    /// `Container`, a thrown `VolumeError.notFound`, a nil `NetworkMetadata` --
    /// and collapsing the three into one optional here is what lets
    /// `removalRefusal` be a pure function with one absent case. A manager
    /// failure that is *not* absence stays a failure: a `command_io` that says
    /// "I could not tell" rather than a `not_found` that says "it is not there",
    /// because the consumer creates on the second and retries on the first.
    private func storedLabels(
        kind: RemovableKind,
        name: String
    ) async -> Result<[String: String]?, Arca_Engine_V1_EngineError> {
        switch kind {
        case .container:
            return await engineErrorCatching(.commandIo, resource: name) {
                try await self.containerManager.getContainer(id: name)?.config.labels
            }
        case .volume:
            do {
                return .success(try await volumeManager.inspectVolume(name: name).labels)
            } catch VolumeError.notFound {
                return .success(nil)
            } catch {
                return .failure(engineError(.commandIo, resource: name, message: "\(error)"))
            }
        case .network:
            return .success(await networkManager.getNetworkByName(name: name)?.labels)
        }
    }

    /// One authorised resource, deleted, or the failure that says why it was not.
    ///
    /// The network is looked up again rather than carried from the authorisation
    /// pass because `deleteNetwork` takes an id and the contract names a network
    /// by name (engine.proto:162-166). A network that vanished between the two
    /// passes is `not_found` here rather than a crash on a stale id.
    private func delete(kind: RemovableKind, name: String) async -> Arca_Engine_V1_EngineError? {
        switch kind {
        case .container:
            let done = await Self.actCatching(resource: name) {
                try await self.containerManager.removeContainer(id: name)
            }
            if case .failure(let error) = done { return error }
        case .volume:
            let done = await Self.actCatching(resource: name) {
                try await self.volumeManager.deleteVolume(name: name)
            }
            if case .failure(let error) = done { return error }
        case .network:
            guard let network = await networkManager.getNetworkByName(name: name) else {
                return engineError(
                    .notFound,
                    resource: name,
                    message: "this engine holds no network named \(name)"
                )
            }
            let done = await Self.actCatching(resource: name) {
                try await self.networkManager.deleteNetwork(id: network.id)
            }
            if case .failure(let error) = done { return error }
        }
        return nil
    }

    /// `engineErrorCatching` with the distinctions the acting methods have to
    /// preserve, the way `createCatching` carries `Create`'s.
    ///
    /// Three codes rather than one `command_failed`, because each tells a
    /// reconciler to do something different:
    ///
    /// - **`not_found`.** Every method here checks the store before it acts, so a
    ///   `containerNotFound` from the act itself means the container went away in
    ///   between. `command_failed` would have the consumer retry against a
    ///   sandbox that is gone; `not_found` has it create one.
    /// - **`invalid_state`.** `containerRunning` is `removeContainer` refusing to
    ///   destroy a running sandbox without `force`. Retrying is futile until
    ///   something stops it, which is what `invalid_state` says and what
    ///   `command_failed` does not.
    /// - **`command_failed`** for everything else, including the
    ///   `notInitialized` an unstarted engine raises: the engine tried and
    ///   something broke.
    private static func actCatching(
        resource: String,
        _ body: () async throws -> Void
    ) async -> Result<Void, Arca_Engine_V1_EngineError> {
        do {
            return .success(try await body())
        } catch {
            let code: EngineErrorCode
            switch error {
            case ContainerManagerError.containerNotFound, VolumeError.notFound,
                 NetworkManagerError.networkNotFound:
                code = .notFound
            case ContainerManagerError.containerRunning, VolumeError.inUse:
                code = .invalidState
            default:
                code = .commandFailed
            }
            return .failure(engineError(code, resource: resource, message: "\(error)"))
        }
    }

    /// The failure arm of an `AckResponse`, in one place.
    ///
    /// Every refusal in `Start`, `Stop` and `Remove` goes through it, for the
    /// reason `createFailed` exists: spelling the wrapper out at a dozen early
    /// returns is a dozen chances for one of them to leave the `oneof` unset, and
    /// an `AckResponse` with no outcome reads as neither success nor failure.
    private static func ackFailed(
        _ error: Arca_Engine_V1_EngineError
    ) -> Arca_Engine_V1_AckResponse {
        Arca_Engine_V1_AckResponse.with { $0.error = error }
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
