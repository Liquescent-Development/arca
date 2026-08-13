import ContainerBridge
import Foundation
import GRPC
import Logging
import SandboxEngineProto
import XCTest
@testable import ArcaEngine

final class ListResourcesTests: XCTestCase {
    // MARK: - Every resource the engine holds

    /// The contract is "every resource the engine holds, labelled or not"
    /// (engine.proto:387-391), asserted against **the whole response** -- all
    /// three kinds in one list, not a projection of it.
    ///
    /// **Unfiltered, and that is the point of this test.** Every other
    /// assertion in this file narrows to one kind first, and a per-kind
    /// assertion cannot see a walk that stops early. MEASURED: with
    ///
    ///     if resources.count >= 3 { return resources }
    ///
    /// after the container loop, an engine holding three or more containers
    /// reports no volumes and no networks at all -- the silently incomplete list
    /// `listResources`' own doc comment calls worse than no list -- and the
    /// suite stayed green at `Executed 75 tests, with 0 failures`. Comparing
    /// against a list holding every kind is what closes that: a walk that stops
    /// after any source fails here, whichever source it was.
    ///
    /// **Five resources, three kinds, mixed ownership.** This is also the
    /// eighth-finding shape: a membership or non-emptiness assertion cannot tell
    /// "dropped the right one" from "dropped everything", which is the defect
    /// `XCTAssertTrue(hidden.isEmpty)` shipped in Task 2. Comparing the full
    /// sorted list against a list written out in full fails differently for the
    /// two -- an `includeInternal: false` regression leaves the other four
    /// standing, and a walk that collected nothing leaves none.
    ///
    /// The internal and unlabelled resources come back with `owner` unset, which
    /// is how a consumer sees a resource it does not own (engine.proto:169-173).
    /// That is deliberately not `inspect`'s answer for the same row -- there an
    /// unlabelled container is `foreign_resource_refused`
    /// (`InspectTests.testAnUnlabelledContainerIsRefusedAsForeignRatherThanReturnedWithoutAnOwner`).
    /// The two methods answer different questions and the difference is load-bearing.
    ///
    /// Names are asserted bare. ContainerBridge stores them slashed
    /// (`ContainerManager.swift:788`), so this is also the end-to-end proof that
    /// `containerResourceName` is on the call path and not merely unit-tested
    /// below: an unstripped slash makes every owned container look unrelated to
    /// its sandbox and drift detection silently sees nothing.
    func testTheWholeResponseHoldsEveryKindIncludingInternalAndUnlabelledResources() async throws {
        let managers = try Self.managers()
        try await Self.seedContainer(
            into: managers.stateStore,
            id: Self.ownedContainerID,
            name: Self.ownedSandboxID,
            labels: SandboxIdentity.labels(from: Self.ownerLabels)
        )
        try await Self.seedContainer(
            into: managers.stateStore,
            id: Self.internalContainerID,
            name: Self.internalContainerName,
            labels: ["com.arca.internal": "true"]
        )
        try await Self.seedContainer(
            into: managers.stateStore,
            id: Self.unlabelledContainerID,
            name: Self.unlabelledContainerName,
            labels: [:]
        )
        // One of each remaining kind, so the assertion below spans all three.
        // Labelled volume, unlabelled network: the owner field is exercised in
        // both directions across kinds rather than only across containers.
        try await Self.seedVolume(
            into: managers.stateStore,
            name: Self.ownedVolumeName,
            labels: SandboxIdentity.labels(from: Self.ownerLabels)
        )
        try await Self.seedNetwork(
            into: managers.stateStore,
            id: Self.foreignNetworkID,
            name: Self.foreignNetworkName,
            labels: [:]
        )
        try await managers.containerManager.loadPersistedState()
        try await managers.volumeManager.initialize()

        let resources = try await Self.listedResources(managers)

        XCTAssertEqual(
            Self.sorted(resources),
            Self.sorted([
                Arca_Engine_V1_Resource.with {
                    $0.identity = Arca_Engine_V1_ResourceIdentity.with {
                        $0.kind = .container
                        $0.name = Self.ownedSandboxID
                    }
                    $0.owner = Self.ownerLabels
                },
                // No `owner` assigned: an internal container carries no gascan
                // owner labels, and the consumer must be told that rather than
                // not told about the container.
                Arca_Engine_V1_Resource.with {
                    $0.identity = Arca_Engine_V1_ResourceIdentity.with {
                        $0.kind = .container
                        $0.name = Self.internalContainerName
                    }
                },
                Arca_Engine_V1_Resource.with {
                    $0.identity = Arca_Engine_V1_ResourceIdentity.with {
                        $0.kind = .container
                        $0.name = Self.unlabelledContainerName
                    }
                },
                Arca_Engine_V1_Resource.with {
                    $0.identity = Arca_Engine_V1_ResourceIdentity.with {
                        $0.kind = .volume
                        $0.name = Self.ownedVolumeName
                    }
                    $0.owner = Self.ownerLabels
                },
                Arca_Engine_V1_Resource.with {
                    $0.identity = Arca_Engine_V1_ResourceIdentity.with {
                        $0.kind = .network
                        $0.name = Self.foreignNetworkName
                    }
                },
            ]),
            "the response must hold all five seeded resources across all three "
                + "kinds. Dropping only the internal container is an includeInternal "
                + "regression; dropping every volume and network is a walk that "
                + "stopped after the containers; dropping all five is a walk that "
                + "read nothing, and these are three different defects"
        )
    }

    /// The volume and network halves of the same rule, read back through the
    /// real path with **nothing installed**.
    ///
    /// Two of each kind, one labelled and one not, for the reason the container
    /// test seeds three: a list that drops the unlabelled resources and a list
    /// that drops the kind entirely are different regressions and must produce
    /// different failures.
    ///
    /// Nothing is installed on `NetworkManager` here, deliberately. Task 3's
    /// review measured that a stub-driven test stays green through the mutation
    /// that matters -- dropping the production default while leaving the
    /// installed-stub path intact -- so the network half of this method is only
    /// proved by a test that runs the manager's own `NullDriverNetworks` over
    /// the store the seed was written to.
    func testALabelledAndAnUnlabelledVolumeAndNetworkAreAllReported() async throws {
        let managers = try Self.managers()
        try await Self.seedVolume(
            into: managers.stateStore,
            name: Self.ownedVolumeName,
            labels: SandboxIdentity.labels(from: Self.ownerLabels)
        )
        try await Self.seedVolume(
            into: managers.stateStore, name: Self.foreignVolumeName, labels: [:]
        )
        try await Self.seedNetwork(
            into: managers.stateStore,
            id: Self.ownedNetworkID,
            name: Self.ownedNetworkName,
            labels: SandboxIdentity.labels(from: Self.ownerLabels)
        )
        try await Self.seedNetwork(
            into: managers.stateStore,
            id: Self.foreignNetworkID,
            name: Self.foreignNetworkName,
            labels: [:]
        )
        try await managers.volumeManager.initialize()

        let resources = try await Self.listedResources(managers)

        XCTAssertEqual(
            Self.sorted(resources.filter { $0.identity.kind == .volume }),
            Self.sorted([
                Arca_Engine_V1_Resource.with {
                    $0.identity = Arca_Engine_V1_ResourceIdentity.with {
                        $0.kind = .volume
                        $0.name = Self.ownedVolumeName
                    }
                    $0.owner = Self.ownerLabels
                },
                Arca_Engine_V1_Resource.with {
                    $0.identity = Arca_Engine_V1_ResourceIdentity.with {
                        $0.kind = .volume
                        $0.name = Self.foreignVolumeName
                    }
                },
            ]),
            "both seeded volumes must be reported, the unlabelled one with no owner"
        )
        XCTAssertEqual(
            Self.sorted(resources.filter { $0.identity.kind == .network }),
            Self.sorted([
                Arca_Engine_V1_Resource.with {
                    $0.identity = Arca_Engine_V1_ResourceIdentity.with {
                        $0.kind = .network
                        $0.name = Self.ownedNetworkName
                    }
                    $0.owner = Self.ownerLabels
                },
                Arca_Engine_V1_Resource.with {
                    $0.identity = Arca_Engine_V1_ResourceIdentity.with {
                        $0.kind = .network
                        $0.name = Self.foreignNetworkName
                    }
                },
            ]),
            "both seeded networks must be reported, read through the manager's own "
                + "source over the real store rather than through an installed stub"
        )
    }

    // MARK: - The error arm, and the empty arm it must not be confused with

    /// A network-backend failure is the error arm, not a shorter list.
    ///
    /// Containers and volumes are seeded and **would** have been collected, so
    /// the answer this refuses is not "nothing found" -- it is the partial
    /// answer, the one that reports a host holding two containers and two
    /// volumes and no networks at all. gascan has no way to see a silently short
    /// list; it maps a thrown failure to `command_io` and can act on that.
    ///
    /// Driven through `setBridgeNetworkLister`, the seam Task 3 built so a
    /// backend can fail without standing in for the rest of
    /// `WireGuardNetworkBackend`. What this seam cannot prove is that the
    /// production source is wired up at all; that is the previous test's job,
    /// and the two are guard-proved against different mutations.
    func testANetworkBackendFailureIsTheErrorArmRatherThanAShortList() async throws {
        let managers = try Self.managers()
        try await Self.seedContainer(
            into: managers.stateStore,
            id: Self.ownedContainerID,
            name: Self.ownedSandboxID,
            labels: SandboxIdentity.labels(from: Self.ownerLabels)
        )
        try await Self.seedContainer(
            into: managers.stateStore,
            id: Self.unlabelledContainerID,
            name: Self.unlabelledContainerName,
            labels: [:]
        )
        try await Self.seedVolume(
            into: managers.stateStore,
            name: Self.ownedVolumeName,
            labels: SandboxIdentity.labels(from: Self.ownerLabels)
        )
        try await Self.seedVolume(
            into: managers.stateStore, name: Self.foreignVolumeName, labels: [:]
        )
        try await managers.containerManager.loadPersistedState()
        try await managers.volumeManager.initialize()
        await managers.networkManager.setBridgeNetworkLister(StubNetworkLister.failing)

        let response = await managers.makeService().listResources(request: .init())

        if case .resources(let list) = response.outcome {
            return XCTFail(
                "a backend that cannot list networks must not be answered with a "
                    + "list of \(list.resources.count) resources holding no networks: "
                    + "\(list.resources.map(\.identity.name))"
            )
        }
        guard case .error(let error) = response.outcome else {
            return XCTFail("ListResources must answer: \(String(describing: response.outcome))")
        }
        XCTAssertEqual(error.code, "command_io")
        XCTAssertEqual(
            error.resource, "",
            "the failure is not about one named resource; a name here would send "
                + "the consumer looking for a resource that is not the problem"
        )
        XCTAssertEqual(
            error.message, "the bridge network source could not be reached",
            "the backend's own failure is carried out verbatim rather than replaced "
                + "with prose that hides which source could not answer"
        )
    }

    /// An engine holding nothing answers an empty list, and the failing engine
    /// beside it answers the error arm -- over state that is empty in both.
    ///
    /// The two arms are asserted in one test on purpose, because the property is
    /// that they are *distinguishable* and no single-arm assertion states it. An
    /// empty `ResourceList` is a confident report of a clean host, which is the
    /// report that hides a leak, so an implementation that answered emptiness
    /// where it could not answer at all would be the whole defect this method
    /// exists to prevent -- and against two engines that hold identically
    /// nothing, only the arm tells them apart.
    ///
    /// This replaces an earlier test that asserted `unsupported_capability` and
    /// then, before that, `list.resources.isEmpty` against a service whose three
    /// managers were empty under every input.
    func testAnEngineHoldingNothingAnswersAnEmptyListAndAFailingOneAnswersTheErrorArm() async throws {
        let clean = try Self.managers()
        let cleanResponse = await clean.makeService().listResources(request: .init())

        guard case .resources(let list) = cleanResponse.outcome else {
            return XCTFail(
                "an engine that holds nothing has observed a clean host and must say "
                    + "so: \(String(describing: cleanResponse.outcome))"
            )
        }
        XCTAssertEqual(
            list.resources, [],
            "a host holding nothing reports no resources, not an error"
        )

        // The same emptiness, one source unable to answer. Nothing is seeded
        // here either, so the ONLY difference between the two responses is
        // whether the engine could look.
        let failing = try Self.managers()
        await failing.networkManager.setBridgeNetworkLister(StubNetworkLister.failing)
        let failingResponse = await failing.makeService().listResources(request: .init())

        if case .resources(let reported) = failingResponse.outcome {
            return XCTFail(
                "an engine that could not list networks must not answer the same "
                    + "empty list a clean engine answers: "
                    + "\(reported.resources.count) resources"
            )
        }
        guard case .error(let error) = failingResponse.outcome else {
            return XCTFail(
                "ListResources must answer: \(String(describing: failingResponse.outcome))"
            )
        }
        XCTAssertEqual(
            error.code, "command_io",
            "\"I could not look\" and \"I looked and there is nothing\" are different "
                + "answers, and a consumer's leak detection acts on the difference"
        )
    }

    // MARK: - The mapping helpers, driven directly

    /// Unlabelled resources are NOT filtered out. gascan's drift detection
    /// depends on seeing them, and hiding them engine-side would break it
    /// silently (engine.proto:389-391). Asserted here on the mapping helper,
    /// and again against a real engine in the live tier.
    func testAnUnlabelledResourceMapsToOneWithNoOwner() {
        let resource = resourceMessage(kind: .volume, name: "someone-elses-volume", labels: [:])
        XCTAssertEqual(resource.identity.name, "someone-elses-volume")
        XCTAssertEqual(resource.identity.kind, .volume)
        XCTAssertFalse(resource.hasOwner)
    }

    func testALabelledResourceCarriesItsOwnerBack() {
        let resource = resourceMessage(
            kind: .container,
            name: "web-a1b2c3d4e5f6",
            labels: [
                SandboxIdentity.managedByLabelKey: "gascan",
                SandboxIdentity.sandboxIdLabelKey: "web-a1b2c3d4e5f6",
            ]
        )
        XCTAssertTrue(resource.hasOwner)
        XCTAssertEqual(resource.owner.managedBy, "gascan")
        XCTAssertEqual(resource.owner.sandboxID, "web-a1b2c3d4e5f6")
    }

    /// ContainerBridge reports Docker-style names with a leading slash
    /// (Sources/ContainerBridge/ContainerManager.swift:725), but the consumer
    /// compares a container resource's name against the bare sandbox id
    /// (crates/gascan-core/src/runtime.rs:829-832). This is the highest-risk
    /// line in this task: an unstripped slash makes every owned container
    /// look unrelated to the sandbox that owns it.
    func testContainerResourceNameStripsTheLeadingSlash() {
        XCTAssertEqual(
            containerResourceName(names: ["/web-a1b2c3d4e5f6"], id: "abc"),
            "web-a1b2c3d4e5f6"
        )
    }

    func testContainerResourceNameLeavesAnAlreadyBareNameUnchanged() {
        XCTAssertEqual(
            containerResourceName(names: ["web-a1b2c3d4e5f6"], id: "abc"),
            "web-a1b2c3d4e5f6"
        )
    }

    func testContainerResourceNameFallsBackToTheIdWhenThereAreNoNames() {
        XCTAssertEqual(containerResourceName(names: [], id: "abc"), "abc")
    }

    func testContainerResourceNameFallsBackToTheIdWhenTheOnlyNameIsBareSlash() {
        XCTAssertEqual(containerResourceName(names: ["/"], id: "abc"), "abc")
    }

    func testContainerResourceNameStripsOnlyOneLeadingSlash() {
        XCTAssertEqual(containerResourceName(names: ["//x"], id: "abc"), "/x")
    }

    // MARK: - Fixtures

    /// Container ids are 64 characters and must not share their first 32:
    /// `loadPersistedState()` derives the native id from `String(id.prefix(32))`
    /// and keys `reverseMapping` on it, so a collision makes one seed vanish.
    private static let ownedContainerID = String(repeating: "a", count: 64)
    private static let internalContainerID = String(repeating: "b", count: 64)
    private static let unlabelledContainerID = String(repeating: "c", count: 64)

    private static let ownedNetworkID = String(repeating: "d", count: 64)
    private static let foreignNetworkID = String(repeating: "e", count: 64)

    /// Every name below is asserted somewhere in this file, and no one of them
    /// is a substring of another. Finding #7 shipped a dead conjunct that way:
    /// an assertion satisfied by a substring of a string another assertion
    /// already pinned proves nothing on its own.
    ///
    /// Each container name contains a hyphen, which keeps `resolveContainerID`
    /// from reading it as a hex short id (`ContainerManager.swift:2005-2023`).
    private static let ownedSandboxID = "web-a1b2c3d4e5f6"
    private static let internalContainerName = "helper-b1c2d3e4f5a6"
    private static let unlabelledContainerName = "foreign-c1d2e3f4a5b6"

    private static let ownedVolumeName = "gascan-store-d1e2f3a4b5c6"
    private static let foreignVolumeName = "unclaimed-e1f2a3b4c5d6"
    private static let ownedNetworkName = "gascan-bridge-f1a2b3c4d5e6"
    private static let foreignNetworkName = "unclaimed-a2b3c4d5e6f1"

    private static let workspaceImage =
        "ghcr.io/liquescent-development/gascan/workspace@sha256:" + String(repeating: "1", count: 64)

    private static let ownerLabels = Arca_Engine_V1_OwnerLabels.with {
        $0.managedBy = "gascan"
        $0.sandboxID = ownedSandboxID
    }

    /// The engine's own managers over a throwaway state root -- the production
    /// factory, so what these tests list is what `arca-engine` serves.
    ///
    /// `wireCollaborators()` is deliberately not called. `ListResources` reads
    /// three list calls and none of them consults either collaborator:
    /// `listContainers` builds its summaries without `NetworkSettings` (that is
    /// `ContainerManager.swift:826`, on the `getContainer` path `Inspect` uses),
    /// `listVolumes` reads `VolumeManager`'s own dictionary, and `listNetworks`
    /// reads `NetworkManager`'s own sources. Wiring them would add a dependency
    /// these assertions cannot see, which is the kind of fixture step that
    /// survives long after the thing it was for. What the collaborators cost
    /// when unset is asserted in `EngineManagerWiringTests`.
    private static func managers() throws -> EngineManagers {
        try EngineManagers(
            stateRoot: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("arca-list-resources-tests-\(UUID().uuidString)"),
            kernelPath: URL(fileURLWithPath: "/opt/arca/vmlinux"),
            logLevel: "info",
            logger: Logger(label: "arca-engine-tests")
        )
    }

    /// One container row, through `StateStore` and then `loadPersistedState()`
    /// -- the restore path the engine itself runs -- rather than through a
    /// double. `initialize()` is the normal caller and constructs a real
    /// `VmnetNetwork`, which no test in this target may do.
    ///
    /// Labels ride in the config JSON because that is the column the restore
    /// path decodes them out of (`ContainerManager.swift:329-344`). The image is
    /// the same digest reference for every row: `ListResources` does not read
    /// it, and varying it would suggest it did.
    private static func seedContainer(
        into store: StateStore,
        id: String,
        name: String,
        labels: [String: String]
    ) async throws {
        try await store.saveContainer(
            id: id,
            name: name,
            image: workspaceImage,
            imageID: "sha256:probe",
            createdAt: Date(),
            status: "exited",
            running: false,
            paused: false,
            restarting: false,
            pid: 0,
            exitCode: 0,
            startedAt: nil,
            finishedAt: Date(),
            stoppedByUser: false,
            entrypoint: nil,
            configJSON: String(
                decoding: try JSONEncoder().encode(
                    ContainerConfiguration(image: workspaceImage, labels: labels)
                ),
                as: UTF8.self
            ),
            hostConfigJSON: String(
                decoding: try JSONEncoder().encode(HostConfig()), as: UTF8.self
            )
        )
    }

    /// One volume row, through the same `StateStore` write `VolumeManager` makes
    /// itself, then read back by `VolumeManager.initialize()` -- which creates
    /// the volumes directory and loads the table, and boots nothing.
    private static func seedVolume(
        into store: StateStore, name: String, labels: [String: String]
    ) async throws {
        try await store.saveVolume(
            name: name,
            driver: "local",
            format: "ext4",
            mountpoint: "/dev/null",
            createdAt: Date(),
            labelsJSON: String(decoding: try JSONEncoder().encode(labels), as: UTF8.self),
            optionsJSON: nil
        )
    }

    /// One network row, `driver: "null"` -- the call `createNetwork` itself
    /// makes for that driver, and the rows `NullDriverNetworks` reads. A bridge
    /// network would need the WireGuard backend `initialize()` builds, and
    /// `initialize()` also creates the default `host` network over vmnet.
    private static func seedNetwork(
        into store: StateStore, id: String, name: String, labels: [String: String]
    ) async throws {
        try await store.saveNetwork(
            id: id,
            name: name,
            driver: "null",
            scope: "local",
            createdAt: Date(),
            subnet: "",
            gateway: "",
            ipRange: nil,
            optionsJSON: nil,
            labelsJSON: String(decoding: try JSONEncoder().encode(labels), as: UTF8.self),
            isDefault: false
        )
    }

    /// The resources arm, or a failure naming the arm that came back instead.
    ///
    /// Calls the context-free `listResources(request:)` overload rather than the
    /// protocol-conforming `listResources(request:context:)`, as every direct
    /// call in this file does: grpc-swift's `GRPCAsyncServerCallContext` has no
    /// public initialiser reachable from outside the GRPC module, so a test
    /// target cannot construct one. See the note on the `create(request:)`
    /// overload in `SandboxEngineService.swift`. The forwarding overload is
    /// therefore driven only by gascan's live tier, over a real socket.
    private static func listedResources(
        _ managers: EngineManagers,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> [Arca_Engine_V1_Resource] {
        let response = await managers.makeService().listResources(request: .init())
        guard case .resources(let list) = response.outcome else {
            XCTFail(
                "expected the resources arm: \(String(describing: response.outcome))",
                file: file, line: line
            )
            throw XCTSkip("no resource list to assert on")
        }
        return list.resources
    }

    /// Both sides of every collection assertion go through this.
    ///
    /// `ListResources` does not sort, and two of its three sources cannot
    /// promise an order: `listContainers` and `listVolumes` both map a
    /// Dictionary's `values`, whose iteration order is seeded per process.
    /// Comparing raw would be a test that fails on a run rather than on a
    /// regression. Sorting both sides keeps the assertion a whole-set equality
    /// -- it still fails when an element is dropped, added, or has the wrong
    /// owner -- while dropping only the one property the method does not have.
    private static func sorted(
        _ resources: [Arca_Engine_V1_Resource]
    ) -> [Arca_Engine_V1_Resource] {
        resources.sorted {
            ($0.identity.kind.rawValue, $0.identity.name)
                < ($1.identity.kind.rawValue, $1.identity.name)
        }
    }
}
