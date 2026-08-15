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

    private struct PreparedEngine {
        let managers: EngineManagers
        let service: SandboxEngineService
        /// Read back from the store rather than computed: Containerization
        /// synthesizes an index during import, so the digest the store records
        /// is not one this test could state in advance.
        let hex: String

        func request(
            sandboxId: String = CreateTests.sandboxId,
            volumes: [(name: String, path: String)] = [],
            network: Arca_Engine_V1_Network.OneOf_Mode = .offline(Arca_Engine_V1_Offline()),
            hex overrideHex: String? = nil
        ) -> Arca_Engine_V1_CreateRequest {
            var request = CreateTranslationTests.request(
                sandboxId: sandboxId,
                owner: Arca_Engine_V1_OwnerLabels.with {
                    $0.managedBy = "gascan"
                    $0.sandboxID = CreateTests.sandboxId
                },
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
