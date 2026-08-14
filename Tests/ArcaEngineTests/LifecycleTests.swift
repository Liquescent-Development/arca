import ContainerBridge
import Foundation
import Logging
import SandboxEngineProto
import XCTest
@testable import ArcaEngine

/// `Start`, `Stop` and `Remove` driven through the engine's own managers.
///
/// **What is reachable without a VM, established before these tests were
/// written rather than assumed while writing them. Each claim below names the
/// test that holds it, so none of them is only prose:**
///
/// - **`startContainer` is NOT.** It resolves the name at
///   `ContainerManager.swift:2071` and then guards on `nativeManager` at
///   `:2080`, which is assigned only inside an `initialize()` that constructs a
///   live `Containerization.VmnetNetwork`. So **nothing here proves a sandbox
///   starts**, and the one test that drives `Start` all the way to the call says
///   so in its own name and asserts the `notInitialized` it stops at. Proving a
///   start is Task 13's live tier.
/// - **`stopContainer` IS**, for a container that is `created`, `exited` or
///   `dead`: it returns without acting (`:2701-2707`). So `Stop`'s success arm
///   is a real success over production code --
///   `testStopOfAnOwnedSandboxSucceedsAndLeavesTheContainerInPlace` -- and every
///   refusal below it is a refusal of something that would otherwise have been
///   `Ack`ed.
/// - **`removeContainer` IS**, in full, for a container with no native object --
///   which is every container `loadPersistedState()` restores. It takes the
///   database-only branch at `:3050`, clears the store, and calls
///   `cleanupVolumesForContainer` (`:3170`). So `Remove` is measured end to end
///   here, deletion included and asserted on the host.
/// - **A container in state `running` is NOT reachable at all.**
///   `loadPersistedState()` recovers every persisted `running` row as exited 137
///   before anything can read it (`:371-393`) -- which is exactly what
///   `CrashRecoveryTests` pins -- and only `startContainer` sets the state
///   otherwise. So `removeContainer`'s `containerRunning` refusal
///   (`:3011-3013`) has no VM-free fixture, is not asserted here, and belongs to
///   Task 13. Seeding a row as `running` does **not** produce one: it produces an
///   exited container, and a test written that way would prove nothing while
///   reading as though it proved the refusal.
///
/// Every fixture is seeded through `StateStore` and `loadPersistedState()`, the
/// restore path the engine itself runs, and never through a double.
final class LifecycleTests: XCTestCase {

    // MARK: - Start

    /// `Start` will not boot a container it cannot establish is gascan's.
    ///
    /// Container names are a flat namespace this engine does not own, so a
    /// sandbox id can resolve to something the consumer never created. `Inspect`
    /// declines to *report* such a container as the sandbox; this declines to
    /// *run* it, which is the same refusal over a much larger consequence -- a VM
    /// the consumer did not ask for, running work it cannot see.
    ///
    /// The code is asserted, not just the failure arm: `foreign_resource_refused`
    /// tells the consumer something else holds the name, while the `not_found`
    /// one refusal up tells it to create a sandbox. Answering the second here
    /// would have a reconciler create a duplicate.
    func testStartRefusesAnUnlabelledContainerRatherThanBootingIt() async throws {
        let managers = try Self.managers()
        try await Self.seed(
            into: managers.stateStore, id: Self.ownedContainerID,
            name: Self.sandboxID, status: "created", labels: [:]
        )
        try await managers.containerManager.loadPersistedState()

        let response = await managers.makeService().start(
            request: Arca_Engine_V1_StartRequest.with { $0.sandboxID = Self.sandboxID }
        )
        Self.assertRefused(
            response, code: .foreignResourceRefused, resource: Self.sandboxID,
            "an unlabelled container under the sandbox's name is not the sandbox"
        )
    }

    /// A sandbox the engine does not hold is `not_found`, which is what has a
    /// reconciler create it. `command_failed` would have it retry forever.
    func testStartOfASandboxTheEngineDoesNotHoldIsNotFound() async throws {
        let managers = try Self.managers()
        let response = await managers.makeService().start(
            request: Arca_Engine_V1_StartRequest.with { $0.sandboxID = Self.sandboxID }
        )
        Self.assertRefused(
            response, code: .notFound, resource: Self.sandboxID,
            "nothing is seeded, so the engine holds no such container"
        )
    }

    /// **This test does NOT prove a sandbox starts, and is named so it cannot be
    /// read as if it does.**
    ///
    /// What it proves is that an owned, correctly named container passes all
    /// three gates and that `startContainer` is really called -- the failure it
    /// asserts on is `nativeManager`'s, raised *inside* the call, and no gate in
    /// this method can produce it. A `start` that returned early for any reason
    /// would answer one of the other three codes instead.
    ///
    /// The message is asserted as well as the code because `command_failed` is
    /// also what a broken call would answer; "not initialized" is the specific
    /// thing that says the call happened and stopped at the VM.
    func testStartOfAnOwnedSandboxReachesStartContainerAndStopsOnlyForWantOfAVM() async throws {
        let managers = try Self.managers()
        try await Self.seed(
            into: managers.stateStore, id: Self.ownedContainerID,
            name: Self.sandboxID, status: "created", labels: Self.ownedLabels
        )
        try await managers.containerManager.loadPersistedState()

        let response = await managers.makeService().start(
            request: Arca_Engine_V1_StartRequest.with { $0.sandboxID = Self.sandboxID }
        )
        guard case .error(let error) = response.outcome else {
            return XCTFail("no VM is reachable here, so this cannot succeed: "
                + "\(String(describing: response.outcome))")
        }
        XCTAssertEqual(error.code, EngineErrorCode.commandFailed.rawValue)
        XCTAssertEqual(error.resource, Self.sandboxID)
        XCTAssertTrue(
            error.message.contains("not initialized"),
            "the gates must have passed and startContainer must have been entered; "
                + "its nativeManager guard is the only thing that can say this. Got: "
                + error.message
        )
    }

    // MARK: - Stop

    /// The one lifecycle success this target can measure, and it is a real one:
    /// `stopContainer` returns without acting for a container that is already
    /// `created`, so `Stop` completes over production code.
    ///
    /// The container is asserted still present afterwards, which is not
    /// decoration: `Stop` and `Remove` are one line apart in this file and both
    /// answer `Ack`, so an implementation that stopped by removing would pass any
    /// test that only checked the outcome arm.
    func testStopOfAnOwnedSandboxSucceedsAndLeavesTheContainerInPlace() async throws {
        let managers = try Self.managers()
        try await Self.seed(
            into: managers.stateStore, id: Self.ownedContainerID,
            name: Self.sandboxID, status: "created", labels: Self.ownedLabels
        )
        try await managers.containerManager.loadPersistedState()

        let response = await managers.makeService().stop(
            request: Arca_Engine_V1_StopRequest.with { $0.sandboxID = Self.sandboxID }
        )
        guard case .ok = response.outcome else {
            return XCTFail("stopping an already-created container is a no-op that succeeds: "
                + "\(String(describing: response.outcome))")
        }
        let after = try await managers.containerManager.getContainer(id: Self.sandboxID)
        XCTAssertNotNil(after, "Stop must not remove the container it stopped")
    }

    /// The refusal, measured against what the engine would otherwise have done.
    ///
    /// This fixture is the success test's fixture with the labels taken off, and
    /// that is what makes it sharp: without the ownership gate `stopContainer`
    /// runs, returns its idempotent no-op, and the engine answers `Ack` for a
    /// container it has no reason to believe is the caller's. The two outcomes
    /// differ by the gate alone.
    func testStopRefusesAnUnlabelledContainerItWouldOtherwiseHaveAcked() async throws {
        let managers = try Self.managers()
        try await Self.seed(
            into: managers.stateStore, id: Self.ownedContainerID,
            name: Self.sandboxID, status: "created", labels: [:]
        )
        try await managers.containerManager.loadPersistedState()

        let response = await managers.makeService().stop(
            request: Arca_Engine_V1_StopRequest.with { $0.sandboxID = Self.sandboxID }
        )
        Self.assertRefused(
            response, code: .foreignResourceRefused, resource: Self.sandboxID,
            "an unlabelled container is not the sandbox, and stopping it would Ack"
        )
    }

    /// **The resolver hazard, on the read-modify verb.**
    ///
    /// `resolveContainerID` prefix-matches any pure-hex name of four or more
    /// characters against Docker ids *before* it tries the name lookup
    /// (`ContainerManager.swift:2005-2023`). The container seeded here is named
    /// `unrelated-container` and has nothing to do with the request; only its
    /// Docker id happens to begin `beef`.
    ///
    /// Without the gate the engine resolves `beef` to it and answers `Ack` for
    /// having stopped a sandbox it never touched. With the gate the request never
    /// reaches the resolver.
    func testStopRefusesAHexSandboxIdItWouldOtherwiseHaveAckedForAnUnrelatedContainer() async throws {
        let managers = try Self.managers()
        try await Self.seed(
            into: managers.stateStore, id: Self.hexPrefixedContainerID,
            name: Self.unrelatedContainerName, status: "created", labels: Self.ownedLabels
        )
        try await managers.containerManager.loadPersistedState()

        let response = await managers.makeService().stop(
            request: Arca_Engine_V1_StopRequest.with { $0.sandboxID = "beef" }
        )
        Self.assertRefused(
            response, code: .invalidResourceIdentity, resource: "beef",
            "a pure-hex sandbox id is a Docker id prefix to the resolver, and a gascan "
                + "sandbox id always contains a hyphen"
        )
    }

    // MARK: - Remove

    /// **The resolver hazard, on the verb that destroys.**
    ///
    /// MEASURED with `containerNameRefusal`'s call deleted from `removableKind`:
    /// `swift test --filter ArcaEngineTests` reports this test as its only
    /// failure, and it fails on the survival assertion below -- the engine
    /// resolved `beef` to the Docker id `beef111…`, found a container it was
    /// authorised to delete, and deleted it. That is the whole reason Task 7's
    /// Minor 4 was routed to this task: harmless while every method was
    /// read-only, and a deletion the moment one was not.
    ///
    /// The container's labels are the caller's own, deliberately, so that the
    /// ownership gate cannot be what saves it -- without the identity gate this
    /// request is authorised and the deletion goes through.
    ///
    /// The second assertion is the one that matters. A refusal that arrived after
    /// the deletion would satisfy the first.
    func testARemoveNamingAHexPrefixRefusesAndDeletesNothing() async throws {
        let managers = try Self.managers()
        try await Self.seed(
            into: managers.stateStore, id: Self.hexPrefixedContainerID,
            name: Self.unrelatedContainerName, status: "exited", labels: Self.ownedLabels
        )
        await managers.wireCollaborators()
        try await managers.containerManager.loadPersistedState()

        let response = await managers.makeService().remove(
            request: Self.removeRequest([(.container, "beef")])
        )
        Self.assertRefused(
            response, code: .invalidResourceIdentity, resource: "beef",
            "a pure-hex resource name is a Docker id prefix to the resolver"
        )
        let survivor = try await managers.containerManager.getContainer(
            id: Self.unrelatedContainerName
        )
        XCTAssertNotNil(
            survivor,
            "the unrelated container must still be on the host; measured without this "
                + "gate, `removeContainer(id: \"beef\")` deleted it"
        )
    }

    /// A container, the volume it mounts and its network, deleted in one call --
    /// and the request lists them in the order that cannot work.
    ///
    /// **The wire order is volume, network, container on purpose.**
    /// `deleteVolume` refuses a volume a container still mounts
    /// (`VolumeManager.swift:317-327`, `VolumeError.inUse`), and the
    /// `volume_mounts` row that makes it "in use" is cleared by CASCADE when the
    /// container row goes (`ContainerManager.swift:3173`). So an implementation
    /// that honoured the request's order, or sorted the other way, answers
    /// `invalid_state` here instead of `Ack`. MEASURED with the sort deleted from
    /// `remove(request:)`: `swift test --filter ArcaEngineTests` reports this
    /// test as its only failure.
    ///
    /// All three deletions are asserted on the host, by exact contents rather
    /// than by count: an `Ack` is what a `Remove` that deleted nothing would also
    /// return.
    func testRemoveDeletesAContainerTheVolumeItMountsAndItsNetworkInOneCall() async throws {
        let managers = try Self.managers()
        try await managers.volumeManager.initialize()
        _ = try await managers.volumeManager.createVolume(
            name: Self.mountedVolume, driver: "local", driverOpts: nil, labels: Self.ownedLabels
        )
        let networkID = try await managers.networkManager.createNetwork(
            name: Self.networkName, driver: "null", subnet: nil, gateway: nil,
            ipRange: nil, options: [:], labels: Self.ownedLabels
        )
        try await Self.seed(
            into: managers.stateStore, id: Self.ownedContainerID,
            name: Self.sandboxID, status: "exited", labels: Self.ownedLabels
        )
        try await managers.stateStore.saveVolumeMount(
            containerID: Self.ownedContainerID, volumeName: Self.mountedVolume,
            containerPath: "/home/workspace/.cache", isAnonymous: false
        )
        await managers.wireCollaborators()
        try await managers.containerManager.loadPersistedState()

        let response = await managers.makeService().remove(
            request: Self.removeRequest([
                (.volume, Self.mountedVolume),
                (.network, Self.networkName),
                (.container, Self.sandboxID),
            ])
        )
        guard case .ok = response.outcome else {
            return XCTFail("all three are the caller's and all three can be deleted here: "
                + "\(String(describing: response.outcome))")
        }
        let container = try await managers.containerManager.getContainer(id: Self.sandboxID)
        XCTAssertNil(container, "the container must be gone from the host")
        let volumes = try await managers.volumeManager.listVolumes().map(\.name).sorted()
        XCTAssertEqual(volumes, [], "the volume must be gone from the host")
        let networks = try await managers.networkManager.listNetworks().map(\.name).sorted()
        XCTAssertEqual(networks, [], "the network must be gone from the host")
        XCTAssertNotNil(networkID, "the fixture really created a network to delete")
    }

    /// **Nothing is deleted until everything is authorised.**
    ///
    /// The container is the caller's and would be deleted; the volume carries no
    /// labels and must be refused. `AckResponse` has no field in which a partial
    /// teardown could report what it destroyed (engine.proto:76-82), so an
    /// implementation that authorised and deleted in one pass would answer this
    /// exact error having already removed the sandbox -- an error the consumer
    /// reads as "nothing happened".
    ///
    /// The container's survival is therefore the assertion; the code is the
    /// lesser half. Deletion order puts the container first, so a merged pass
    /// really would take it.
    func testRemoveRefusesAnUnlabelledResourceBeforeDeletingTheAuthorisedOne() async throws {
        let managers = try Self.managers()
        try await managers.volumeManager.initialize()
        _ = try await managers.volumeManager.createVolume(
            name: Self.mountedVolume, driver: "local", driverOpts: nil, labels: [:]
        )
        try await Self.seed(
            into: managers.stateStore, id: Self.ownedContainerID,
            name: Self.sandboxID, status: "exited", labels: Self.ownedLabels
        )
        await managers.wireCollaborators()
        try await managers.containerManager.loadPersistedState()

        let response = await managers.makeService().remove(
            request: Self.removeRequest([
                (.container, Self.sandboxID),
                (.volume, Self.mountedVolume),
            ])
        )
        Self.assertRefused(
            response, code: .foreignResourceRefused, resource: Self.mountedVolume,
            "a volume carrying no gascan labels is not one this engine may delete"
        )
        let container = try await managers.containerManager.getContainer(id: Self.sandboxID)
        XCTAssertNotNil(
            container,
            "the authorised container must survive a call that was refused: an Ack-less "
                + "response with the sandbox already gone is unreportable"
        )
        let volumes = try await managers.volumeManager.listVolumes().map(\.name)
        XCTAssertEqual(volumes, [Self.mountedVolume], "and the refused volume must survive")
    }

    /// Both owner labels are compared, and each half is load-bearing on its own.
    ///
    /// Two volumes, two calls. The first disagrees on `managed_by` only: a
    /// comparison that looked at `sandbox_id` alone would delete another tool's
    /// volume that happened to carry a colliding id. The second disagrees on
    /// `sandbox_id` only: a comparison that looked at `managed_by` alone would let
    /// every gascan sandbox delete every other gascan sandbox's resources, which
    /// is precisely what `engine.proto:381-383` says this field exists to stop.
    /// Either half dropped leaves one of these two green and the other red.
    func testRemoveRefusesAResourceThatDisagreesOnEitherOwnerLabel() async throws {
        let managers = try Self.managers()
        try await managers.volumeManager.initialize()
        _ = try await managers.volumeManager.createVolume(
            name: "other-tool-vol", driver: "local", driverOpts: nil,
            labels: SandboxIdentity.labels(from: Arca_Engine_V1_OwnerLabels.with {
                $0.managedBy = "another-tool"
                $0.sandboxID = Self.sandboxID
            })
        )
        _ = try await managers.volumeManager.createVolume(
            name: "other-sandbox-vol", driver: "local", driverOpts: nil,
            labels: SandboxIdentity.labels(from: Arca_Engine_V1_OwnerLabels.with {
                $0.managedBy = "gascan"
                $0.sandboxID = "other-e1f2a3b4c5d6"
            })
        )
        let service = managers.makeService()

        Self.assertRefused(
            await service.remove(request: Self.removeRequest([(.volume, "other-tool-vol")])),
            code: .ownershipMismatch, resource: "other-tool-vol",
            "same sandbox_id, different managed_by: still not the caller's"
        )
        Self.assertRefused(
            await service.remove(request: Self.removeRequest([(.volume, "other-sandbox-vol")])),
            code: .ownershipMismatch, resource: "other-sandbox-vol",
            "same managed_by, different sandbox_id: another sandbox's resource"
        )
        let volumes = try await managers.volumeManager.listVolumes().map(\.name).sorted()
        XCTAssertEqual(
            volumes, ["other-sandbox-vol", "other-tool-vol"],
            "neither refused volume may have been deleted"
        )
    }

    /// A resource the engine does not hold is `not_found`, and the resources
    /// named beside it are untouched.
    ///
    /// `not_found` rather than a silent `Ack`: the consumer removes exactly what
    /// it recorded, so "you named something I do not have" is a disagreement
    /// about state worth surfacing, and an `Ack` over it would hide a resource
    /// that was deleted by something else.
    func testRemoveOfAResourceTheEngineDoesNotHoldIsNotFoundAndDeletesNothing() async throws {
        let managers = try Self.managers()
        try await Self.seed(
            into: managers.stateStore, id: Self.ownedContainerID,
            name: Self.sandboxID, status: "exited", labels: Self.ownedLabels
        )
        await managers.wireCollaborators()
        try await managers.containerManager.loadPersistedState()

        let response = await managers.makeService().remove(
            request: Self.removeRequest([
                (.container, Self.sandboxID),
                (.volume, "never-created-vol"),
            ])
        )
        Self.assertRefused(
            response, code: .notFound, resource: "never-created-vol",
            "the engine holds no such volume"
        )
        let container = try await managers.containerManager.getContainer(id: Self.sandboxID)
        XCTAssertNotNil(container, "the container named beside it must survive")
    }

    /// **The volume-manager wiring, driven through the RPC rather than asserted
    /// as a wiring.**
    ///
    /// `cleanupVolumesForContainer` (`ContainerManager.swift:4140-4143`) is
    /// `guard let volumeManager = volumeManager else { return }`. Unwired, it
    /// deletes nothing, `removeContainer` succeeds anyway, CASCADE takes the
    /// `volume_mounts` row with the container, and the anonymous volume is left on
    /// disk with nothing pointing at it -- a leak underneath an `Ack`.
    /// `EngineManagerWiringTests` proves the same thing one layer down, over
    /// `ContainerManager` directly; this proves that `Remove` itself reaches it.
    ///
    /// **The remove names only the container.** The anonymous volume is one no
    /// `ResourceIdentity` can name -- that is what makes it anonymous -- so if it
    /// is not deleted here it is not deleted at all.
    ///
    /// The named volume is the second half and is not decoration: it is mounted
    /// too, and a cleanup that deleted every mounted volume would pass a
    /// one-volume form of this test while destroying data the consumer never
    /// asked to lose.
    func testRemovingAContainerThroughTheRPCDeletesItsAnonymousVolumeAndSparesTheNamedOne() async throws {
        let managers = try Self.managers()
        try await managers.volumeManager.initialize()
        _ = try await managers.volumeManager.createVolume(
            name: "anon-vol", driver: "local", driverOpts: nil, labels: Self.ownedLabels
        )
        _ = try await managers.volumeManager.createVolume(
            name: "named-vol", driver: "local", driverOpts: nil, labels: Self.ownedLabels
        )
        try await Self.seed(
            into: managers.stateStore, id: Self.ownedContainerID,
            name: Self.sandboxID, status: "exited", labels: Self.ownedLabels
        )
        try await managers.stateStore.saveVolumeMount(
            containerID: Self.ownedContainerID, volumeName: "anon-vol",
            containerPath: "/scratch", isAnonymous: true
        )
        try await managers.stateStore.saveVolumeMount(
            containerID: Self.ownedContainerID, volumeName: "named-vol",
            containerPath: "/named", isAnonymous: false
        )
        await managers.wireCollaborators()
        try await managers.containerManager.loadPersistedState()

        let response = await managers.makeService().remove(
            request: Self.removeRequest([(.container, Self.sandboxID)])
        )
        guard case .ok = response.outcome else {
            return XCTFail("removing an owned, exited container succeeds here: "
                + "\(String(describing: response.outcome))")
        }
        let remaining = try await managers.volumeManager.listVolumes().map(\.name).sorted()
        XCTAssertEqual(
            remaining, ["named-vol"],
            "Remove must delete the container's anonymous volume and keep the named one"
        )
    }

    /// A remove that names nothing is refused rather than `Ack`ed.
    ///
    /// The `Ack` would be true -- everything named was deleted -- and it is the
    /// answer a caller that dropped its list reads as a completed teardown. The
    /// consumer refuses to build one itself
    /// (`crates/gascan-arca/src/translate.rs:255-256`), so this refuses nothing it
    /// sends.
    func testARemoveThatNamesNoResourcesIsRefused() async throws {
        let response = await (try Self.managers()).makeService().remove(
            request: Arca_Engine_V1_RemoveRequest.with { $0.owner = Self.ownerLabels }
        )
        Self.assertRefused(
            response, code: .invalidState, resource: "",
            "an empty remove is a caller that lost its list"
        )
    }

    /// A remove under half-set owner labels is refused before any comparison.
    ///
    /// Compared as-is, a half-set owner matches only resources labelled equally
    /// half-set, so every resource in the call would come back
    /// `ownership_mismatch` -- "these are not yours", when the truth is "you did
    /// not say who you are". The two demand different fixes.
    func testARemoveUnderHalfSetOwnerLabelsIsRefusedBeforeAnyComparison() async throws {
        let managers = try Self.managers()
        try await Self.seed(
            into: managers.stateStore, id: Self.ownedContainerID,
            name: Self.sandboxID, status: "exited", labels: Self.ownedLabels
        )
        await managers.wireCollaborators()
        try await managers.containerManager.loadPersistedState()

        let response = await managers.makeService().remove(
            request: Arca_Engine_V1_RemoveRequest.with {
                $0.owner = Arca_Engine_V1_OwnerLabels.with { $0.sandboxID = Self.sandboxID }
                $0.resources = [Arca_Engine_V1_ResourceIdentity.with {
                    $0.kind = .container
                    $0.name = Self.sandboxID
                }]
            }
        )
        Self.assertRefused(
            response, code: .invalidResourceIdentity, resource: "",
            "managed_by is empty, so there is nothing to compare against"
        )
        let container = try await managers.containerManager.getContainer(id: Self.sandboxID)
        XCTAssertNotNil(container, "and the resource it named must survive")
    }

    /// An unset `kind` is a request to delete "a resource" without saying from
    /// which of three namespaces, and the engine will not guess.
    ///
    /// The container seeded here shares the requested name, so a guess of
    /// `container` would find something and delete it.
    func testARemoveNamingAResourceOfUnspecifiedKindIsRefused() async throws {
        let managers = try Self.managers()
        try await Self.seed(
            into: managers.stateStore, id: Self.ownedContainerID,
            name: Self.sandboxID, status: "exited", labels: Self.ownedLabels
        )
        await managers.wireCollaborators()
        try await managers.containerManager.loadPersistedState()

        let response = await managers.makeService().remove(
            request: Self.removeRequest([(.unspecified, Self.sandboxID)])
        )
        Self.assertRefused(
            response, code: .invalidResourceIdentity, resource: Self.sandboxID,
            "kind is unset, and container, volume and network are three namespaces"
        )
        let container = try await managers.containerManager.getContainer(id: Self.sandboxID)
        XCTAssertNotNil(container, "the container that shares the name must survive")
    }

    // MARK: - Fixtures

    /// 64 characters, and the two must not share their first 32:
    /// `loadPersistedState()` derives the native id from `String(id.prefix(32))`
    /// and keys `reverseMapping` on it, so a collision makes one seed vanish.
    private static let ownedContainerID = String(repeating: "a", count: 64)

    /// A Docker id that begins with a hex string a caller could send as a name.
    /// The container it belongs to is named something else entirely.
    private static let hexPrefixedContainerID = "beef" + String(repeating: "1", count: 60)
    private static let unrelatedContainerName = "unrelated-container"

    /// `SandboxIdentity.containerName(forSandboxId:)` is the identity function, so
    /// this is both the sandbox id and the seeded container name. It contains a
    /// hyphen, which is what keeps a well-formed id away from the hex arm of
    /// `resolveContainerID`.
    private static let sandboxID = "web-a1b2c3d4e5f6"
    private static let mountedVolume = "gascan-cache-web-a1b2c3d4e5f6"
    private static let networkName = "sbx-net-web-a1b2c3d4e5f6"

    private static let ownerLabels = Arca_Engine_V1_OwnerLabels.with {
        $0.managedBy = "gascan"
        $0.sandboxID = sandboxID
    }
    private static let ownedLabels = SandboxIdentity.labels(from: ownerLabels)

    /// The engine's own managers over a throwaway state root -- the production
    /// factory, so what these tests drive is what `arca-engine` serves.
    private static func managers() throws -> EngineManagers {
        try EngineManagers(
            stateRoot: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("arca-lifecycle-tests-\(UUID().uuidString)"),
            kernelPath: URL(fileURLWithPath: "/opt/arca/vmlinux"),
            logLevel: "info",
            logger: Logger(label: "arca-engine-tests")
        )
    }

    /// One container row, through `StateStore` and then `loadPersistedState()` --
    /// the restore path the engine itself runs -- rather than through a double.
    /// `initialize()` is the normal caller and constructs a real `VmnetNetwork`,
    /// which no test in this target may do.
    private static func seed(
        into store: StateStore,
        id: String,
        name: String,
        status: String,
        labels: [String: String]
    ) async throws {
        let encoder = JSONEncoder()
        let image = "arca/probe@sha256:" + String(repeating: "1", count: 64)
        try await store.saveContainer(
            id: id, name: name, image: image, imageID: "sha256:probe",
            createdAt: Date(), status: status, running: false, paused: false,
            restarting: false, pid: 0, exitCode: 0, startedAt: nil,
            finishedAt: Date(), stoppedByUser: false, entrypoint: nil,
            configJSON: String(
                decoding: try encoder.encode(
                    ContainerConfiguration(image: image, labels: labels)
                ),
                as: UTF8.self
            ),
            hostConfigJSON: String(decoding: try encoder.encode(HostConfig()), as: UTF8.self)
        )
    }

    /// A remove under `ownerLabels`, naming exactly what it is given and in the
    /// order it is given -- the wire order, so a test can put it deliberately
    /// wrong.
    private static func removeRequest(
        _ resources: [(Arca_Engine_V1_ResourceKind, String)]
    ) -> Arca_Engine_V1_RemoveRequest {
        Arca_Engine_V1_RemoveRequest.with { request in
            request.owner = ownerLabels
            request.resources = resources.map { kind, name in
                Arca_Engine_V1_ResourceIdentity.with {
                    $0.kind = kind
                    $0.name = name
                }
            }
        }
    }

    /// The error arm with its code and the resource it names, both asserted.
    ///
    /// `resource` as well as `code` because they are not interchangeable
    /// (`EngineErrors.swift:32-35`) and because in a multi-resource remove the
    /// resource is what says *which* one was refused -- a call that refused the
    /// wrong member would carry the right code.
    private static func assertRefused(
        _ response: Arca_Engine_V1_AckResponse,
        code: EngineErrorCode,
        resource: String,
        _ why: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .error(let error) = response.outcome else {
            return XCTFail(
                "expected a refusal -- \(why): \(String(describing: response.outcome))",
                file: file, line: line
            )
        }
        XCTAssertEqual(error.code, code.rawValue, why, file: file, line: line)
        XCTAssertEqual(error.resource, resource, why, file: file, line: line)
    }
}
