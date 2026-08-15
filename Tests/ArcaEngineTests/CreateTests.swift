import ContainerBridge
import Foundation
import Logging
import SandboxEngineProto
import XCTest
@testable import ArcaEngine

/// `Create` driven through the engine's own managers: the order the steps run
/// in, and what a partial failure reports.
///
/// **What is proved here and what is not, stated plainly.** `createContainer`
/// guards on `nativeManager` (`ContainerManager.swift:1659`) and
/// `NetworkManager.createNetwork` on a WireGuard backend
/// (`NetworkManager.swift:396-398`); both are assigned only inside an
/// `initialize()` that constructs a live `Containerization.VmnetNetwork` and
/// needs the virtualization entitlement. So no test in this target can watch a
/// sandbox boot.
///
/// What that leaves is more useful than it sounds. Both guards throw *before*
/// doing any work, which means a real `create(request:)` over real managers runs
/// its steps in order and fails at a known one -- and the report it produces at
/// that point is exactly the thing `CreateFailed.created` exists for. So the
/// ordering, the evidence, and the refusals are all measured against production
/// code here; only the sandbox itself is out of reach:
///
/// - **Proved here:** volumes are created before the network, the network before
///   the container, an offline create makes no network at all, the resources
///   already created are reported as a set, and every refusal reports an empty
///   `created` because it happens before the first create.
/// - **Proved in `CreateTranslationTests`:** every argument `createContainer` is
///   handed, including the name, the labels, the network mode and the port
///   bindings.
/// - **Proved in `ImageResolutionTests`:** that the store resolves the reference
///   `Create` hands it.
/// - **NOT proved anywhere in this target:** that the container is created, that
///   it starts, and that its ports are published. Publication in particular is
///   routed to Task 13 -- see `EngineManagers.wireCollaborators()` for why no
///   VM-free test of it would mean anything.
final class CreateTests: XCTestCase {
    private let logger = Logger(label: "create-tests")
    private static let sandboxId = "gascan-sbx-4f2a-9c11"

    // MARK: - Ordering and the evidence a partial failure carries

    /// Volumes are created, the network step then fails, and the report names
    /// the volumes and nothing else.
    ///
    /// This is the ordering test and the `CreateFailed.created` test at once,
    /// because the two cannot be separated: the report is the only window onto
    /// the order. The network step fails here for a real reason --
    /// `createNetwork` needs a WireGuard backend that only `initialize()` builds
    /// -- and that is what makes the assertion sharp in both directions:
    ///
    /// - the two volumes are IN the report, so they were created before the
    ///   network step ran;
    /// - **`failed.error.resource` is the network's name**, so the run stopped
    ///   at the network step and the container step never ran. That is the
    ///   assertion which catches a reorder: moving the container block above the
    ///   network block makes the resource the sandbox id instead. MEASURED in
    ///   Task 11's review, which performed exactly that move and caught it here
    ///   and nowhere else.
    ///
    /// The `getContainer` check at the end is a **host cross-check, not the
    /// ordering proof**, and the distinction was a review finding: this doc
    /// comment used to credit it with the ordering. `createContainer` throws
    /// `notInitialized` before doing any work (`ContainerManager.swift:1659`),
    /// so `getContainer` returns nil whatever the order is, and that assertion
    /// cannot fail in this fixture. It stays because "the engine reported no
    /// container" and "no container is on the host" are different claims and
    /// both are worth making -- but it is credited only for what it shows.
    ///
    /// `created` is asserted as a whole set, not for non-emptiness. A create
    /// that reported only its first volume would pass any weaker check while
    /// leaving the second on the host with nothing that will ever name it --
    /// which is the precise failure `engine.proto:279-283` describes.
    func testAFailedNetworkStepReportsTheVolumesAlreadyCreatedAndNoContainer() async throws {
        let engine = try await preparedEngine()

        let response = await engine.service.create(request: engine.request(
            volumes: [
                (name: "gascan-cache-\(Self.sandboxId)", path: "/home/workspace/.cache"),
                (name: "gascan-config-\(Self.sandboxId)", path: "/home/workspace/.config"),
            ],
            network: .networkedName("sbx-net")
        ))

        guard case .failed(let failed) = response.outcome else {
            return XCTFail("the network step cannot succeed here, got \(response.outcome as Any)")
        }
        XCTAssertEqual(
            Self.described(failed.created),
            [
                "volume gascan-cache-\(Self.sandboxId) gascan/\(Self.sandboxId)",
                "volume gascan-config-\(Self.sandboxId) gascan/\(Self.sandboxId)",
            ],
            "a partial failure must report every resource it created and only those"
        )
        XCTAssertEqual(failed.error.resource, "sbx-net", "the failure must name the step that failed")

        let volumes = try await engine.managers.volumeManager.listVolumes().map(\.name).sorted()
        XCTAssertEqual(
            volumes,
            [
                "gascan-cache-\(Self.sandboxId)",
                "gascan-config-\(Self.sandboxId)",
            ],
            "the reported volumes must be the ones that are really on the host"
        )
        let container = try await engine.managers.containerManager.getContainer(id: Self.sandboxId)
        XCTAssertNil(
            container,
            "host cross-check: no container may be left behind by a create that failed before "
                + "the container step. This cannot fail in this fixture -- see the note above "
                + "-- so the ordering is proved by the error.resource assertion, not by this"
        )
    }

    /// **`create` hands `createContainer` the exact digest reference, not a
    /// stored tag.**
    ///
    /// This is the one assertion the whole of Problem 1 rests on. Widening
    /// `ImageManager.resolveImage` -- a resolver shared with Arca's Docker
    /// surface -- was justified by `create` needing to pass
    /// `repository@sha256:<hex>`, because that same string is what
    /// `createContainer` records as `ContainerInfo.image` (`:1901`), what
    /// `startContainer:2218` re-resolves after a restart, and what `Inspect`
    /// re-parses (`SandboxEngineService.swift:196`).
    ///
    /// **Nothing pinned it until now.** Task 11's review replaced the deciding
    /// line with `references.first ?? …` -- the arrangement Problem 1 explicitly
    /// rejected -- and all 123 tests passed. Every sandbox would have recorded
    /// `workspace:latest`, and `Inspect` would have answered `invalid_output`
    /// for every one of them, with a green suite.
    ///
    /// It goes through `createSpec(for:)`, which is the seam `create(request:)`
    /// itself calls -- not a reconstruction of what it might build -- so there
    /// is no second path this can drift onto. The digest is the store's own,
    /// read back from the loaded image, so a spec carrying any other string
    /// fails here.
    func testCreateHandsContainerBridgeTheExactDigestReferenceAndNotAStoredTag() async throws {
        let engine = try await preparedEngine()

        let spec: SandboxContainerSpec
        switch await engine.service.createSpec(for: engine.request()) {
        case .failure(let error):
            return XCTFail("the fixture must translate, got \(error.code): \(error.message)")
        case .success(let translated):
            spec = translated
        }

        XCTAssertEqual(
            spec.image, "workspace@sha256:\(engine.hex)",
            "createContainer must be handed the exact digest reference; a stored tag resolves "
                + "but makes Inspect answer invalid_output for every sandbox this engine creates"
        )
        // The store really does hold that content under a TAG, so this is not a
        // test that would pass by the two strings happening to coincide.
        let stored = try await engine.managers.imageManager.inspectImage(
            nameOrId: "workspace:latest"
        )
        XCTAssertEqual(
            stored?.repoTags, ["workspace:latest"],
            "the store's own reference is a tag, so the digest form above was constructed "
                + "rather than copied from the row"
        )
    }

    /// An offline create makes no network resource, and reaches the container
    /// step.
    ///
    /// Two things at once, and both matter. `created` holds the volume and no
    /// network, so the network step really was skipped rather than run and
    /// silently succeeded; and the failure comes from `createContainer` itself,
    /// which is how this test proves the container step is reached at all --
    /// without it, the test above could not tell "the container step is last"
    /// from "there is no container step".
    ///
    /// `listNetworks` is asserted as well as `created`, because those are
    /// different claims: one is what the engine reported, the other is what is
    /// on the host, and an offline sandbox that quietly created a network would
    /// leak one the consumer was never told about.
    func testAnOfflineCreateMakesNoNetworkAndReachesTheContainerStep() async throws {
        let engine = try await preparedEngine()

        let response = await engine.service.create(request: engine.request(
            volumes: [(name: "gascan-cache-\(Self.sandboxId)", path: "/home/workspace/.cache")],
            network: .offline(Arca_Engine_V1_Offline())
        ))

        guard case .failed(let failed) = response.outcome else {
            return XCTFail("the container step cannot succeed here, got \(response.outcome as Any)")
        }
        XCTAssertEqual(
            Self.described(failed.created),
            ["volume gascan-cache-\(Self.sandboxId) gascan/\(Self.sandboxId)"],
            "an offline create must report its volume and no network"
        )
        XCTAssertEqual(
            failed.error.resource, Self.sandboxId,
            "the failure must be the container step, named by the sandbox id"
        )
        XCTAssertEqual(
            failed.error.message, "ContainerManager not initialized",
            "and it must be the uninitialised-manager guard rather than an earlier refusal, "
                + "which is what shows the container step was actually reached"
        )

        let networks = try await engine.managers.networkManager.listNetworks()
        XCTAssertEqual(
            networks.map(\.name), [],
            "offline means no network attachment, so no network may be created for one"
        )
    }

    // MARK: - The refusals that happen before anything is created

    /// The image is resolved from the request's digest: one the store holds gets
    /// past the gate, one it does not is refused before a single resource is
    /// made.
    ///
    /// The pairing is what makes this a test of the lookup rather than of the
    /// error path. The two digests differ in one hex character and name the same
    /// repository, so an engine that refused everything fails the first half and
    /// one that refused nothing fails the second. The held half is recognised by
    /// how far it gets: past the image gate, through the volume step, and into
    /// `createContainer`'s own guard.
    ///
    /// The refused half asserts `created` is empty AND that no volume reached
    /// the host. Those are separate failures -- a create that made the volume
    /// and reported nothing is the leak, not the refusal.
    func testAHeldDigestPassesTheImageGateAndAnAbsentOneIsRefusedBeforeAnythingIsCreated() async throws {
        let engine = try await preparedEngine()
        let volumes = [(name: "gascan-cache-\(Self.sandboxId)", path: "/home/workspace/.cache")]

        // The refused half runs first, deliberately: it asserts that the host is
        // untouched, and that assertion is only worth making while the host is
        // known to be empty.
        let flipped = engine.hex.first == "0"
            ? "1" + engine.hex.dropFirst()
            : "0" + engine.hex.dropFirst()
        let absent = await engine.service.create(
            request: engine.request(volumes: volumes, hex: String(flipped))
        )
        guard case .failed(let refused) = absent.outcome else {
            return XCTFail("a digest the store lacks must be refused, got \(absent.outcome as Any)")
        }
        XCTAssertEqual(refused.error.code, "not_found")
        XCTAssertEqual(refused.error.resource, "workspace@sha256:\(flipped)")
        XCTAssertEqual(
            refused.created, [],
            "a create refused at the image gate must report nothing created"
        )
        let untouched = try await engine.managers.volumeManager.listVolumes().map(\.name)
        XCTAssertEqual(untouched, [], "and must not have created anything either")

        let held = await engine.service.create(request: engine.request(volumes: volumes))
        guard case .failed(let past) = held.outcome else {
            return XCTFail("expected the container-step failure, got \(held.outcome as Any)")
        }
        XCTAssertEqual(
            past.error.resource, Self.sandboxId,
            "a digest the store holds must get past the image gate and reach the container step"
        )
    }

    /// A hex sandbox id is refused before any resource is made.
    ///
    /// `CreateTranslationTests` proves the refusal itself; this proves it stands
    /// in front of the volume step in the real method, which is the only place
    /// the ordering can go wrong.
    func testAHexSandboxIdIsRefusedBeforeAnyVolumeIsCreated() async throws {
        let engine = try await preparedEngine()

        let response = await engine.service.create(request: engine.request(
            sandboxId: "deadbeefcafe",
            volumes: [(name: "gascan-cache-x", path: "/home/workspace/.cache")]
        ))

        guard case .failed(let failed) = response.outcome else {
            return XCTFail("a hex sandbox id must be refused, got \(response.outcome as Any)")
        }
        XCTAssertEqual(failed.error.code, "invalid_resource_identity")
        XCTAssertEqual(failed.created, [])
        let untouched = try await engine.managers.volumeManager.listVolumes().map(\.name)
        XCTAssertEqual(untouched, [], "the refusal must come before the volume step")
    }

    /// A retained volume the engine holds gets past the gate; one it does not
    /// hold is refused before anything is built.
    ///
    /// **The failure this prevents is silent.** A container attached to a volume
    /// the engine no longer holds starts anyway and the mount is simply absent --
    /// which is the exact shape of the named-volume defect of 2026-08-14, where
    /// three volumes were attached, mounted somewhere unreachable, and nothing
    /// refused. `not_found` naming the volume is the loud form of the same state.
    ///
    /// **Paired, for the reason
    /// `testAHeldDigestPassesTheImageGateAndAnAbsentOneIsRefusedBeforeAnythingIsCreated`
    /// is paired, and it is not decoration.** The refused half alone is passed by
    /// an engine that refuses EVERY retained resource -- a
    /// `firstRetainedResourceNotHeld` reduced to `return engineError(.notFound,
    /// resource: retained.first…)`, reading no store at all, satisfies every
    /// assertion in it. That mutation makes a recreate impossible while looking
    /// exactly like a working guard. The held half is what fails against it, so
    /// the two names differ in nothing but whether the volume was created, and
    /// the store read is what has to decide between them.
    ///
    /// The held half is recognised by how far it gets: past the retained gate,
    /// through `createSpec`, and into `createContainer`'s own uninitialised-manager
    /// guard -- the same recognition
    /// `testAnOfflineCreateMakesNoNetworkAndReachesTheContainerStep` uses, and the
    /// furthest this target can reach without a VM.
    ///
    /// **The refused half carries TWO volumes and the missing one is second**, and
    /// that ordering is the whole of the loop's coverage. With a single-element
    /// topology, narrowing the guard to `reusedTopology(...).prefix(1)` passes the
    /// entire suite -- MEASURED at 161/0 by Task 1's review, which is how this
    /// arrangement was arrived at. A real recreate carries four resources with the
    /// network appended last, so under that mutation the resource that goes
    /// unverified in production is the network. The existing
    /// `error.resource == "a-volume-nothing-holds"` assertion kills it with no new
    /// assertion: `prefix(1)` would verify only the held volume and the run would
    /// reach the container step instead.
    func testCreateContainerRefusesARetainedResourceTheEngineDoesNotHold() async throws {
        let engine = try await preparedEngine()
        let held = "gascan-cache-\(Self.sandboxId)"
        try await engine.hold(volume: held)

        // Two volumes, the held one FIRST. The guard must walk past it and reach
        // the second; a guard that checks only what it is handed first passes
        // this request.
        let absent = Self.recreate(engine.request(volumes: [
            (name: held, path: "/home/workspace/.cache"),
            (name: "a-volume-nothing-holds", path: "/home/workspace/.config"),
        ]))

        let refused = await engine.service.createContainer(request: absent)

        guard case .failed(let failure) = refused.outcome else {
            return XCTFail("a retained resource the engine does not hold must be refused")
        }
        XCTAssertEqual(failure.error.code, "not_found")
        XCTAssertEqual(
            failure.error.resource,
            "a-volume-nothing-holds",
            "the resource field names the offender, and its being the SECOND entry is what "
                + "says the guard is a loop rather than a check on the first element"
        )
        XCTAssertTrue(
            failure.created.isEmpty,
            "the refusal runs before anything is built, so there is nothing to report"
        )

        let present = Self.recreate(engine.request(volumes: [
            (name: held, path: "/home/workspace/.cache")
        ]))

        let accepted = await engine.service.createContainer(request: present)

        guard case .failed(let past) = accepted.outcome else {
            return XCTFail("expected the container-step failure, got \(accepted.outcome as Any)")
        }
        XCTAssertEqual(
            past.error.resource, Self.sandboxId,
            "a retained volume the engine DOES hold must get past the gate and reach the "
                + "container step; a guard that refused it read no store"
        )
        XCTAssertEqual(
            past.error.message, "ContainerManager not initialized",
            "and it must be the uninitialised-manager guard rather than an earlier refusal"
        )
    }

    /// A managed network the engine does not hold is refused, naming the network.
    ///
    /// **Its own test because the network branch had no coverage in either
    /// direction.** MEASURED by Task 1's review: replacing the entire network arm
    /// of the guard with `continue` passed the whole suite at 161/0, so the branch
    /// could be deleted and nothing noticed.
    ///
    /// **The failure it prevents is the worst-hidden one in this file.** A recreate
    /// whose network the engine no longer holds builds a container whose
    /// `networkMode` names a network that does not exist. `create(request:)`'s own
    /// comment records what happens next: bridge networks are WireGuard-backed, and
    /// `getWireGuardClient` returns nil for a container on no WireGuard network
    /// with **no `else`** around the publish. So the sandbox starts, `Inspect`
    /// reports the bindings the store holds, and nothing is published --
    /// the named-volume defect's shape on the resource where it is hardest to see.
    ///
    /// **Only the refused half is here, and it is not an omission.**
    /// `preparedEngine()` leaves `NetworkManager` uninitialised deliberately, so
    /// `getNetworkByName` returns nil for *every* name and "the engine holds this
    /// network" is unreachable in this target by construction. The held half is
    /// `recreate::a_recreate_reuses_its_retained_volumes_rather_than_rebuilding_them`
    /// in gascan's live tier, whose rebuilt container must both start and answer on
    /// a published port -- which per `ports.rs` requires a live WireGuard-backed
    /// network. That test's doc comment says so from its side.
    func testCreateContainerRefusesAManagedNetworkTheEngineDoesNotHold() async throws {
        let engine = try await preparedEngine()
        let held = "gascan-cache-\(Self.sandboxId)"
        try await engine.hold(volume: held)

        // The volume is held and retained, so the only thing left for the guard to
        // object to is the network. Without it the refusal below would be
        // ambiguous between the two.
        let request = Self.recreate(engine.request(
            volumes: [(name: held, path: "/home/workspace/.cache")],
            network: .networkedName("sbx-net")
        ))

        let response = await engine.service.createContainer(request: request)

        guard case .failed(let failed) = response.outcome else {
            return XCTFail("a managed network the engine does not hold must be refused")
        }
        XCTAssertEqual(failed.error.code, "not_found")
        XCTAssertEqual(
            failed.error.resource, "sbx-net",
            "the refusal must name the network, not the sandbox and not the volume it walked past"
        )
        XCTAssertTrue(failed.created.isEmpty)

        // Real, and it covers the half the refusal itself cannot: a
        // `createContainer` that built the network BEFORE consulting the guard
        // would leave it here and then refuse. Build-AFTER-guard is unreachable
        // from this request and is covered by
        // `testCreateContainerBuildsNoVolumeOrNetworkEvenWhenTheRequestNamesThem`.
        let networks = try await engine.managers.networkManager.listNetworks().map(\.name)
        XCTAssertEqual(
            networks, [],
            "and a refused recreate must not have created the network on its way to refusing"
        )
    }

    /// The retained-membership check compares kind as well as name.
    ///
    /// **Its own test because the kind half was decorative.** MEASURED by the
    /// re-review: dropping `$0.identity.kind == resource.kind.resourceKind` from
    /// the predicate passed the whole suite at 164/0, so half of a comparison that
    /// `RemovableKind.resourceKind` was added to make total was unpinned.
    ///
    /// The request retains a **volume** carrying the network's name, and nothing
    /// else changes. Name-only matching accepts it and the recreate proceeds;
    /// matching on both refuses, because the network the container will attach to
    /// is not in `retained` at all. Consequence in production terms: a caller that
    /// mislabelled one entry's kind would have the engine agree its topology was
    /// fully retained when one member of it was never declared.
    func testTheRetainedMembershipCheckComparesKindAndNotOnlyName() async throws {
        let engine = try await preparedEngine()
        let networkName = "sbx-net"
        let held = "gascan-cache-\(Self.sandboxId)"
        try await engine.hold(volume: held)
        try await engine.hold(network: networkName)

        var request = Arca_Engine_V1_CreateContainerRequest()
        request.create = engine.request(
            volumes: [(name: held, path: "/home/workspace/.cache")],
            network: .networkedName(networkName)
        )
        // The volume entry is correct; the second entry names the network but
        // calls it a volume. Under a name-only comparison it satisfies the
        // network's requirement.
        request.retained = [
            resourceMessage(kind: .volume, name: held, labels: [:]),
            resourceMessage(kind: .volume, name: networkName, labels: [:]),
        ]

        let response = await engine.service.createContainer(request: request)

        guard case .failed(let failed) = response.outcome else {
            return XCTFail("a retained entry of the wrong kind must not satisfy the topology")
        }
        XCTAssertEqual(failed.error.code, "invalid_state")
        XCTAssertEqual(
            failed.error.resource, networkName,
            "the network is the member that was never retained, whatever a volume of its "
                + "name might suggest"
        )
    }

    /// A volume in the request that carries no name is refused by identity, not by
    /// absence.
    ///
    /// **The guard moved in front of the validation that used to answer this.**
    /// `createSpec` refuses an unnamed volume with `invalid_resource_identity`
    /// (`EngineCreate.swift:106-113`), and since fix round 1 the topology guard
    /// runs first -- so the same request would otherwise answer `not_found` with an
    /// **empty** `resource` field and the message "this engine holds no volume
    /// named ". `engine.proto` makes `resource` the field that names the offender
    /// and an empty string names nothing, which is the difference between a
    /// consumer being told what is wrong and being told a blank.
    ///
    /// Unreachable from Gas Can -- `PolicyCompiler` emits no empty names -- so this
    /// is diagnostic quality on a malformed-input path rather than a correctness
    /// bug. It is pinned because the guard's position in front of `createSpec` is
    /// the kind of thing a later edit reorders.
    func testCreateContainerRefusesAVolumeThatCarriesNoName() async throws {
        let engine = try await preparedEngine()

        let response = await engine.service.createContainer(
            request: Self.recreate(engine.request(
                volumes: [(name: "", path: "/home/workspace/.cache")]
            ))
        )

        guard case .failed(let failed) = response.outcome else {
            return XCTFail("a volume carrying no name must be refused")
        }
        XCTAssertEqual(failed.error.code, "invalid_resource_identity")
        XCTAssertEqual(
            failed.error.resource, Self.sandboxId,
            "an unnamed volume cannot name itself, so the refusal names the sandbox -- which "
                + "is what createSpec answers for the same request"
        )
        XCTAssertEqual(failed.error.message, "a volume in this request carries no name")
    }

    /// A volume the container would mount but the caller did not retain is refused.
    ///
    /// **This is the bypass the first version of the guard shipped.** It verified
    /// `request.retained`; the binds are built from `request.create.volumes`
    /// (`EngineCreate.swift:106-123`). Two independent lists with nothing
    /// reconciling them, so `retained: []` with populated `create.volumes` passed
    /// untouched and built the container -- **the exact silent failure §2.2 exists
    /// to prevent, with the guard fully intact.** The test written to prove the
    /// guard sent precisely that request and asserted it reached the container
    /// step, encoding the bypass as intended behaviour.
    ///
    /// So the topology is the subject now and `retained` is an assertion the caller
    /// must match. The volume here is one the engine genuinely holds, which is what
    /// isolates this from the `not_found` tier: the only thing wrong with the
    /// request is that the caller never said it was reusing it.
    func testCreateContainerRefusesAVolumeItWouldMountThatTheCallerDidNotRetain() async throws {
        let engine = try await preparedEngine()
        let held = "gascan-cache-\(Self.sandboxId)"
        try await engine.hold(volume: held)

        var request = Arca_Engine_V1_CreateContainerRequest()
        request.create = engine.request(volumes: [
            (name: held, path: "/home/workspace/.cache")
        ])
        request.retained = []

        let response = await engine.service.createContainer(request: request)

        guard case .failed(let failed) = response.outcome else {
            return XCTFail("a mounted volume the caller did not retain must be refused")
        }
        XCTAssertEqual(failed.error.code, "invalid_state")
        XCTAssertEqual(failed.error.resource, held)
        XCTAssertTrue(
            failed.created.isEmpty,
            "the refusal runs before anything is built"
        )

        let volumes = try await engine.managers.volumeManager.listVolumes().map(\.name)
        XCTAssertEqual(
            volumes, [held],
            "and it must not have rebuilt the volume it refused to reuse"
        )
    }

    /// A retained volume this engine holds but that is not the caller's is refused,
    /// unlabelled and mislabelled alike.
    ///
    /// **Mounting another consumer's volume is the read-side of the hazard the
    /// owner field exists for.** `engine.proto:381-383` says it is there "so one
    /// consumer cannot be induced to delete another's resource"; being induced to
    /// *mount* one hands the caller data it was never entitled to see. This
    /// repository had already decided name-only identity is insufficient --
    /// `removalRefusal`'s comment spells out why comparing one label or neither is
    /// wrong -- and the first version of this guard checked presence only, which is
    /// the first of that rule's three tiers.
    ///
    /// Both remaining tiers are asserted because they are different states with
    /// different operator responses: unlabelled means the engine cannot establish
    /// whose it is, and mislabelled means it can and it is someone else's. A guard
    /// that collapsed them would still pass a test asserting only one.
    ///
    /// **Reachability, stated fairly:** Gas Can cannot send either request.
    /// `validate_retained_resources` requires `GasCanOwned` and a matching sandbox
    /// id. This is the clause of §2.2 that says the engine verifies rather than
    /// trusting the caller, and a guard that trusts the caller for ownership has
    /// not done that.
    func testCreateContainerRefusesARetainedVolumeThatIsNotTheCallers() async throws {
        let engine = try await preparedEngine()
        let unlabelled = "gascan-cache-\(Self.sandboxId)"
        let someoneElses = "gascan-config-\(Self.sandboxId)"

        try await engine.hold(volume: unlabelled, labels: [:])
        let other = Arca_Engine_V1_OwnerLabels.with {
            $0.managedBy = "gascan"
            $0.sandboxID = "gascan-sbx-0000-0000"
        }
        try await engine.hold(volume: someoneElses, ownedBy: other)

        let bare = await engine.service.createContainer(
            request: Self.recreate(engine.request(volumes: [
                (name: unlabelled, path: "/home/workspace/.cache")
            ]))
        )
        guard case .failed(let unowned) = bare.outcome else {
            return XCTFail("a volume carrying no owner labels must be refused")
        }
        XCTAssertEqual(unowned.error.code, "foreign_resource_refused")
        XCTAssertEqual(unowned.error.resource, unlabelled)
        // The one assertion that pins `OwnershipAction` doing anything. MEASURED
        // by the re-review: swapping this path's `action: .reuse` for `.remove`
        // passed the whole suite at 164/0, so the enum's entire reason for
        // existing -- not telling an operator the engine was about to DELETE a
        // volume it was about to MOUNT -- was unpinned in both directions.
        XCTAssertTrue(
            unowned.error.message.contains("will not mount it into a rebuilt container"),
            "a recreate's refusal must say what a recreate was about to do, not what a "
                + "remove would have: \(unowned.error.message)"
        )

        let foreign = await engine.service.createContainer(
            request: Self.recreate(engine.request(volumes: [
                (name: someoneElses, path: "/home/workspace/.config")
            ]))
        )
        guard case .failed(let mismatched) = foreign.outcome else {
            return XCTFail("a volume labelled to another sandbox must be refused")
        }
        XCTAssertEqual(mismatched.error.code, "ownership_mismatch")
        XCTAssertEqual(mismatched.error.resource, someoneElses)
    }

    /// `CreateContainer` builds the container and nothing else, even when the
    /// request it shares with `Create` names volumes and a network.
    ///
    /// **This test is the heir of a deleted one, and the risk it inherits has
    /// inverted rather than expired.** `SandboxEngineServiceTests
    /// .testCreateContainerAnswersUnsupportedCapabilityNamingTheRpc` held this
    /// method down while it was a stub, and its comment said why it was the one
    /// worth watching: `CreateContainer` "shares `CreateRequest` with `Create`
    /// and is a create in every respect except that its resources already exist,
    /// so it is the method most likely to be quietly satisfied by a change aimed
    /// at its neighbour". That test was removed when this method became real,
    /// which is the rule five other methods left it under -- but the hazard it
    /// named did not go with it. It turned around:
    ///
    /// - **Then:** `createContainer` accidentally made to *work* by a change to
    ///   `create`. The stub assertion caught that.
    /// - **Now:** `createContainer` accidentally made to do *everything*
    ///   `create` does -- creating the very volumes and network it was told to
    ///   reuse. Nothing caught that until this.
    ///
    /// `buildContainer` is shared by both paths deliberately, and sharing is
    /// correct -- see the note on it -- but it also puts the two methods one
    /// careless edit apart. `engine.proto:296-302` is the line being defended:
    /// everything named in `retained` already exists and is reused.
    ///
    /// **The assertion is on what the managers hold, not on what the response
    /// says.** A response arm is satisfied by a refusal for any reason at all. So
    /// the host is asked directly: the volume set is unchanged, and no network
    /// exists.
    ///
    /// **And it asserts the run reached the container step, because the absence
    /// check alone has the same hole in the same direction.** A
    /// `createContainer` that refused at `createSpec` or earlier also creates no
    /// volume and no network, and would pass on absence alone -- a green test
    /// against an engine that cannot recreate anything. Reaching
    /// `containerManager`'s uninitialised-manager guard is what says the volume
    /// loop and the network branch were *skipped* rather than never reached.
    /// Same three-part shape, and the same reason, as
    /// `testAnOfflineCreateMakesNoNetworkAndReachesTheContainerStep`.
    ///
    /// **REWRITTEN, and the old form is worth naming because it asserted a defect
    /// as intended behaviour.** It sent `retained: []` with `create.volumes` naming
    /// two volumes the engine did not hold, and asserted the run reached the
    /// container step -- which was true, and was exactly the bypass Task 1's review
    /// found: the guard verified `retained` while the container mounted
    /// `create.volumes`. Under the amended guard that request is refused, correctly,
    /// by `testCreateContainerRefusesAVolumeItWouldMountThatTheCallerDidNotRetain`.
    ///
    /// So the topology here is **fully held and fully retained** — the state a real
    /// recreate arrives in — and the property is unchanged: the run gets to the
    /// container step without having built anything. That is a stronger arrangement
    /// than the old one, not a weaker one, because "created nothing" is now measured
    /// against a store that already holds the topology rather than against an empty
    /// one: an engine that rebuilt a volume here would hit `VolumeError.alreadyExists`
    /// and answer `resource_conflict` naming it, which the reason assertion rejects.
    ///
    /// **The request names a managed network and the engine genuinely holds it,
    /// and getting that back was the point of fix round 2.** The first rewrite
    /// went offline, because the amended guard refuses any network the engine does
    /// not hold and `preparedEngine()` initialises no `NetworkManager`. That was
    /// forced but it cost the network half outright: MEASURED by the re-review,
    /// a `createContainer` that rebuilt the network it was told to reuse passed
    /// the whole suite at 164/0, where the same mutation was **caught** before the
    /// rewrite. Coverage went backwards.
    ///
    /// `PreparedEngine.hold(network:)` is what buys it back without a VM -- see
    /// its note for why the `null` driver answers the guard's two questions
    /// identically to a `bridge` one.
    ///
    /// **The REASON assertions are what carry the network half, not the
    /// `listNetworks` line**, and saying so precisely is a correction: the first
    /// rewrite's comment blamed the absence assertion, which had already been
    /// unfalsifiable before it. A `createContainer` that rebuilt the network
    /// answers `resource_conflict` naming `sbx-net` (the name is taken) or
    /// `command_failed` naming it (no WireGuard backend) -- either way
    /// `error.resource` stops being the sandbox id, and that is the assertion that
    /// fails. `listNetworks` staying equal is a weaker statement kept for the
    /// failure message.
    ///
    /// **The half this does NOT inherit is the response shape, and no test in this
    /// target can.** An engine that reused the retained resources correctly but
    /// *reported* them in `Created` would satisfy every assertion here -- MEASURED:
    /// seeding the response with `request.retained` passes the whole suite at
    /// 164/0, because every path in this target fails at the
    /// uninitialised-`ContainerManager` guard and the success payload is
    /// unreachable. That half is
    /// `backend_unary::a_recreate_answered_with_the_whole_topology_is_refused`
    /// (`crates/gascan-arca/tests/backend_unary.rs:740`), which feeds
    /// `create_container` a full `Created` payload and requires `invalid_state`.
    /// Named here so a later reader does not assume the Swift suite guards it.
    ///
    /// **That test proves the CLIENT refuses such an answer, not that the ENGINE
    /// never sends one, and the two are different facts.** What makes stopping
    /// there legitimate is the failure mode: an engine reporting the whole
    /// topology would make every recreate fail loudly at `for_recreate` rather
    /// than corrupt anything quietly. A loud failure guarded on the consumer's
    /// side is a defensible place to stop; a silent one would not be.
    func testCreateContainerBuildsNoVolumeOrNetworkEvenWhenTheRequestNamesThem() async throws {
        let engine = try await preparedEngine()
        let networkName = "sbx-net"
        let topology = [
            (name: "gascan-cache-\(Self.sandboxId)", path: "/home/workspace/.cache"),
            (name: "gascan-config-\(Self.sandboxId)", path: "/home/workspace/.config"),
        ]
        for volume in topology {
            try await engine.hold(volume: volume.name)
        }
        try await engine.hold(network: networkName)
        let volumesBefore = try await engine.managers.volumeManager.listVolumes().map(\.name).sorted()
        let networksBefore = try await engine.managers.networkManager.listNetworks().map(\.name)

        let response = await engine.service.createContainer(
            request: Self.recreate(engine.request(
                volumes: topology,
                network: .networkedName(networkName)
            ))
        )

        let volumesAfter = try await engine.managers.volumeManager.listVolumes().map(\.name).sorted()
        XCTAssertEqual(
            volumesAfter, volumesBefore,
            "a recreate reuses the volumes it was told about; building one is the defect "
                + "this exists for, and the host is what says whether it happened"
        )
        let networksAfter = try await engine.managers.networkManager.listNetworks().map(\.name)
        XCTAssertEqual(
            networksAfter, networksBefore,
            "and the network set must be unchanged -- the weaker of the two network "
                + "statements; the reason assertion below is the one that fails under a rebuild"
        )

        guard case .failed(let failed) = response.outcome else {
            return XCTFail("the container step cannot succeed here, got \(response.outcome as Any)")
        }
        XCTAssertEqual(
            failed.error.resource, Self.sandboxId,
            "the absences above must be a skipped volume loop AND a skipped network branch, "
                + "not a refusal that happened before either could run and not a conflict from "
                + "trying to rebuild one -- a rebuild names the resource it collided with"
        )
        XCTAssertEqual(
            failed.error.message, "ContainerManager not initialized",
            "and it must be the uninitialised-manager guard, which is as far as a VM-free "
                + "test can follow this method"
        )
    }

    // MARK: - Fixtures

    /// A resource as `kind name managed_by/sandbox_id`.
    ///
    /// Compared as strings so that the whole of `created` is one equality: kind,
    /// name and both owner labels for every resource, in order. Asserting the
    /// messages field by field would leave the owner unchecked on the resource
    /// nobody thought to check.
    private static func described(_ resources: [Arca_Engine_V1_Resource]) -> [String] {
        resources.map { resource in
            let kind = "\(resource.identity.kind)".replacingOccurrences(of: "RESOURCE_KIND_", with: "")
            return "\(kind.lowercased()) \(resource.identity.name) "
                + "\(resource.owner.managedBy)/\(resource.owner.sandboxID)"
        }
    }

    /// The owner every request in this file is made under.
    ///
    /// One value rather than a literal per call site, because the ownership tier
    /// of the retained guard compares it against what the store holds -- and two
    /// literals that drifted apart would make that comparison pass or fail for a
    /// reason no reader could see.
    private static let owner = Arca_Engine_V1_OwnerLabels.with {
        $0.managedBy = "gascan"
        $0.sandboxID = CreateTests.sandboxId
    }

    /// A recreate whose `retained` names exactly the topology `create` mounts.
    ///
    /// The shape `RetainedResources` guarantees on the consumer's side --
    /// `validate_retained_resources` (`crates/gascan-core/src/runtime.rs:893-918`)
    /// requires every retained resource to be an expected volume or the expected
    /// network and to be exactly count-equal to the topology -- and therefore the
    /// only shape a real recreate arrives in. Derived rather than written out per
    /// test, so a test that changes its topology cannot forget to change its
    /// retained set and start measuring the guard's other tier by accident.
    ///
    /// **The owner on these messages is left unset deliberately.** The guard does
    /// not read it: ownership is decided against the labels the STORE holds, which
    /// is what "verifies rather than trusting the caller" means. A test whose
    /// retained messages carried owner labels would pass identically against a
    /// guard that trusted them.
    private static func recreate(
        _ create: Arca_Engine_V1_CreateRequest
    ) -> Arca_Engine_V1_CreateContainerRequest {
        var retained = create.volumes.map {
            resourceMessage(kind: .volume, name: $0.name, labels: [:])
        }
        if case .networkedName(let networkName) = create.network.mode {
            retained.append(resourceMessage(kind: .network, name: networkName, labels: [:]))
        }
        var request = Arca_Engine_V1_CreateContainerRequest()
        request.create = create
        request.retained = retained
        return request
    }

    private struct PreparedEngine {
        let managers: EngineManagers
        let service: SandboxEngineService
        /// Read back from the store rather than computed: Containerization
        /// synthesizes an index during import, so the digest the store records
        /// is not one this test could state in advance.
        let hex: String

        /// Puts a volume on the host the way a previous `Create` would have left
        /// it, so a recreate finds what it expects to find.
        ///
        /// The labels default to the ones `create` itself writes --
        /// `sandboxContainerSpec` builds them with `SandboxIdentity.labels(from:)`
        /// from the request's owner -- so a volume made here is indistinguishable
        /// from a real leftover. The overrides exist for the two ownership tiers:
        /// `labels: [:]` is a resource carrying no gascan labels at all, and
        /// `ownedBy:` is one belonging to a different sandbox.
        func hold(
            volume name: String,
            ownedBy owner: Arca_Engine_V1_OwnerLabels = CreateTests.owner,
            labels overrideLabels: [String: String]? = nil
        ) async throws {
            _ = try await managers.volumeManager.createVolume(
                name: name,
                driver: "local",
                driverOpts: [:],
                labels: overrideLabels ?? SandboxIdentity.labels(from: owner)
            )
        }

        /// Puts a network on the host that this engine genuinely holds, under the
        /// caller's labels, without a VM.
        ///
        /// **`null` is the one driver that reaches the store without a backend,
        /// and that is the whole reason it is here.** `createNetwork`'s `bridge`
        /// arm needs `wireGuardBackend` and its `vmnet` arm constructs a live
        /// `VmnetNetworkBackend` (`NetworkManager.swift:393-440`), neither of
        /// which `preparedEngine()` has. The `null` arm (`:441-470`) persists to
        /// the `StateStore` and registers the name mapping, and `getNetworkByName`
        /// -> `getNetwork(id:)` reads that arm's networks straight back out of the
        /// store (`:671-687`).
        ///
        /// **What that buys is exactly what the guard reads and nothing more.**
        /// `reusedTopologyRefusal` asks two questions of a network -- does this
        /// engine hold one by that name, and whose labels does it carry -- and both
        /// are answered identically for a `null` network and a `bridge` one. The
        /// driver decides what the network *does*, which is a VM's business and is
        /// `recreate.rs`'s to prove; it decides nothing about what the guard sees.
        /// So this is a fixture for the guard, not a stand-in for a working
        /// network, and no test here should assert anything about connectivity.
        func hold(
            network name: String,
            ownedBy owner: Arca_Engine_V1_OwnerLabels = CreateTests.owner
        ) async throws {
            _ = try await managers.networkManager.createNetwork(
                name: name,
                driver: "null",
                subnet: nil,
                gateway: nil,
                ipRange: nil,
                options: [:],
                labels: SandboxIdentity.labels(from: owner)
            )
        }

        func request(
            sandboxId: String = CreateTests.sandboxId,
            volumes: [(name: String, path: String)] = [],
            network: Arca_Engine_V1_Network.OneOf_Mode = .offline(Arca_Engine_V1_Offline()),
            hex overrideHex: String? = nil
        ) -> Arca_Engine_V1_CreateRequest {
            var request = CreateTranslationTests.request(
                sandboxId: sandboxId,
                owner: CreateTests.owner,
                volumes: volumes.map { (name: $0.name, path: $0.path, capacity: UInt64(0)) },
                network: network
            )
            request.image = Arca_Engine_V1_ImageDigest.with {
                $0.repository = "workspace"
                $0.sha256Hex = overrideHex ?? hex
            }
            return request
        }
    }

    /// The engine's own managers over a throwaway state root, holding one real
    /// workspace image loaded through the path `arca-engine image load` uses.
    ///
    /// `VolumeManager.initialize()` is the only `initialize()` called: it
    /// touches the filesystem and the store and nothing else. `ContainerManager`
    /// and `NetworkManager` are left uninitialised deliberately -- theirs
    /// construct a live `VmnetNetwork` -- and their guards are what these tests
    /// fail against.
    private func preparedEngine() async throws -> PreparedEngine {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("arca-create-tests-\(UUID().uuidString)")
        let stateRoot = root.appendingPathComponent("state")
        _ = try await loadWorkspaceImages(
            fromOCILayout: try OCILayoutFixture.write(
                at: root.appendingPathComponent("workspace"),
                reference: "workspace:latest",
                payload: "pushed by the consumer, not by startup"
            ),
            stateRoot: stateRoot,
            logger: logger
        )

        let managers = try EngineManagers(
            stateRoot: stateRoot,
            kernelPath: URL(fileURLWithPath: "/opt/arca/vmlinux"),
            logLevel: "info",
            logger: logger
        )
        try await managers.volumeManager.initialize()
        await managers.wireCollaborators()

        let details = try await managers.imageManager.inspectImage(nameOrId: "workspace:latest")
        let digest = try XCTUnwrap(
            details?.repoDigests.first, "the store must report a digest for the image it loaded"
        )
        return PreparedEngine(
            managers: managers,
            service: managers.makeService(),
            hex: digest.replacingOccurrences(of: "sha256:", with: "")
        )
    }
}
