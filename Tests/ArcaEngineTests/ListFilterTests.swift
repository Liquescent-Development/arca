import ContainerBridge
import Foundation
import Logging
import XCTest
@testable import ArcaEngine

final class ListFilterTests: XCTestCase {
    /// A kernel path for services whose sandboxes are never booted. Nothing in
    /// this suite starts a VM, so the value is never read; it is named rather
    /// than derived from the state root so that no test here quietly reasserts
    /// the derivation `--kernel-path` replaced.
    private static let unbootedKernel = URL(fileURLWithPath: "/opt/arca/vmlinux")

    /// gascan's drift and leak detection reads ListResources. A container that
    /// exists but is not listed is a leak the consumer can never see, so the
    /// engine asks for everything explicitly.
    func testInternalContainersAreRequestedByAnExplicitFlagNotASubstring() {
        XCTAssertFalse(ContainerManager.internalContainersRequested(in: [:]))
        XCTAssertFalse(
            ContainerManager.internalContainersRequested(in: ["label": ["com.example.other"]])
        )
        XCTAssertTrue(
            ContainerManager.internalContainersRequested(in: ["label": ["com.arca.internal"]])
        )
    }

    /// The assertion the helper test above cannot make. Asserting on
    /// `internalContainersRequested(in:)` alone proves the rule computes the
    /// right answer, not that `listContainers` obeys the answer it is handed:
    /// with the `includeInternal` guard reverted to the old filter-derived
    /// `showInternal`, the helper test and the whole suite stayed green
    /// (`swift test --filter ArcaEngineTests` -> `Executed 35 tests, with 0
    /// failures`, before this test existed).
    ///
    /// Two containers are seeded, not one, and the negative case asserts an
    /// equality rather than `isEmpty`. With a single internal container,
    /// `hidden.isEmpty` passes just as well when the guard hides *every*
    /// container as when it hides the right one -- and hiding everything is the
    /// direction that reaches users, because `includeInternal: false` is what
    /// three of the four Docker call sites pass, `docker ps` among the paths
    /// that would go blank. MEASURED: with the guard widened to
    /// `if !includeInternal { return nil }`, the one-container form of this test
    /// still reported `Executed 2 tests, with 0 failures`.
    func testListContainersHidesOnlyTheInternalContainerAndOnlyWhenAsked() async throws {
        let manager = try await Self.seededManager()
        try await manager.loadPersistedState()

        let shown = try await manager.listContainers(all: true, includeInternal: true)
        XCTAssertEqual(
            Self.names(of: shown),
            ["/arca-internal-probe", "/plain-probe"],
            "includeInternal: true must list both containers, the labelled one included"
        )

        let hidden = try await manager.listContainers(all: true, includeInternal: false)
        XCTAssertEqual(
            Self.names(of: hidden),
            ["/plain-probe"],
            "includeInternal: false must hide the internal container and keep the plain one"
        )
    }

    /// The network half of the same rule. `listNetworks()` swallowed a
    /// WireGuard-backend failure with `try?` and returned the networks it had
    /// managed to collect, so a backend that could not answer read to gascan as
    /// a host with no bridge networks -- the answer that hides a leak instead of
    /// reporting one.
    ///
    /// Two-sided for the reason the container test above is. Asserting only
    /// that the signature says `throws` would pass against the unfixed body the
    /// moment someone wrote `throws` without deleting the `try?`, and asserting
    /// only that the failing lister throws would pass against a `listNetworks()`
    /// that threw no matter what. Both mutations were run against this test:
    ///
    /// - the source loop swallowing again, `if let listed = try? await
    ///   lister.listNetworks()` -> `Executed 39 tests, with 2 failures`, this
    ///   one on `listNetworks() returned 0 networks instead of reporting the
    ///   backend failure` (the null-driver test below is the other)
    /// - `throw NetworkManagerError.networkNotFound(...)` as the first statement
    ///   of `listNetworks()` -> `Executed 37 tests, with 1 failure`, `caught
    ///   error: "network guard-proving mutation not found"` (measured when the
    ///   suite stood at 37, before the null-driver tests below existed)
    func testListNetworksReportsABackendFailureRatherThanAShortList() async throws {
        let failing = SandboxEngineService.forTesting().networkManager
        await failing.setBridgeNetworkLister(StubNetworkLister.failing)

        do {
            let swallowed = try await failing.listNetworks()
            XCTFail(
                "listNetworks() returned \(swallowed.count) networks instead of "
                    + "reporting the backend failure"
            )
        } catch is NetworkListerUnreachable {
            // The backend's own error reached the caller, which is the point.
        }

        // The other side: the same seam, a lister that answers. Without this,
        // a `listNetworks()` that threw no matter what would pass the half above.
        let working = SandboxEngineService.forTesting().networkManager
        await working.setBridgeNetworkLister(StubNetworkLister.listing([Self.probeNetwork]))

        let networks = try await working.listNetworks()
        XCTAssertEqual(
            networks.map(\.name),
            ["probe-bridge"],
            "listNetworks() must return what the bridge lister reports"
        )
    }

    /// The same rule for the other source `listNetworks()` reads. The
    /// null-driver networks used to be read back one at a time through
    /// `getNetwork(id:)`, whose `catch` logs and returns `nil`, so a StateStore
    /// failure dropped every `--driver null` network from the answer and still
    /// reported success -- the same short list one branch over.
    ///
    /// Failing the null source specifically, not "some source", is what makes
    /// this test able to see that regression: it is why the two sources have
    /// separate setters. MEASURED: with `NullDriverNetworks` dropped from
    /// `networkListers` and the old branch restored to
    ///
    ///     let nullNetworkIDs = networkDrivers.filter { $0.value == "null" }.keys
    ///     for networkID in nullNetworkIDs {
    ///         if let network = await getNetwork(id: networkID) { ... }
    ///     }
    ///
    /// `swift test --filter ArcaEngineTests` reported `Executed 39 tests, with 2
    /// failures`, this test on `listNetworks() returned 0 networks instead of
    /// reporting the null-driver store failure` and
    /// `testNullDriverNetworksAreListedFromTheStore` on `("[]") is not equal to
    /// ("["probe-none"]")`. Dropping only the source from `networkListers`, with
    /// the old branch left out, reported the same two failures.
    func testListNetworksReportsANullDriverStoreFailureRatherThanAShortList() async throws {
        let failing = SandboxEngineService.forTesting().networkManager
        await failing.setNullNetworkLister(StubNetworkLister.failing)

        do {
            let swallowed = try await failing.listNetworks()
            XCTFail(
                "listNetworks() returned \(swallowed.count) networks instead of "
                    + "reporting the null-driver store failure"
            )
        } catch is NetworkListerUnreachable {
            // The store's failure reached the caller rather than a short list.
        }
    }

    /// The half the stub cannot prove: that the source `listNetworks()` derives
    /// for null-driver networks really is the StateStore, and really is read.
    ///
    /// Nothing is installed here -- the manager runs its own
    /// `NullDriverNetworks` over the real store the seed was written to, so
    /// dropping that source from the derivation makes this go red while the
    /// stub-driven test above stays green. The network is seeded through
    /// `StateStore.saveNetwork`, the call `createNetwork` itself makes for
    /// `driver: "null"`, rather than through a test-only setter.
    func testNullDriverNetworksAreListedFromTheStore() async throws {
        let stateRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("arca-null-network-tests-\(UUID().uuidString)")
        let paths = EnginePaths(stateRoot: stateRoot)
        let logger = Logger(label: "arca-engine-tests")

        let seedStore = try StateStore(path: paths.stateDatabase.path, logger: logger)
        try await seedStore.saveNetwork(
            id: String(repeating: "d", count: 64),
            name: "probe-none",
            driver: "null",
            scope: "local",
            createdAt: Date(),
            subnet: "",
            gateway: "",
            ipRange: nil,
            optionsJSON: nil,
            labelsJSON: nil,
            isDefault: true
        )

        let manager = SandboxEngineService
            .forTesting(stateRoot: stateRoot, kernelPath: Self.unbootedKernel)
            .networkManager

        let networks = try await manager.listNetworks()
        XCTAssertEqual(
            networks.map(\.name),
            ["probe-none"],
            "listNetworks() must read the null-driver networks out of the StateStore"
        )
    }

    /// The production derivation behind `getNetworkAttachments`, with nothing
    /// installed.
    ///
    /// This is the test the stub-driven one below cannot replace. A stub proves
    /// the seam carries a failure; it says nothing about whether the source
    /// production actually reads is wired up. MEASURED, mutating the production
    /// default and leaving the seam intact -- `attachmentSource` reduced to
    ///
    ///     private var attachmentSource: any NetworkAttachmentSource {
    ///         installedAttachmentSource ?? EmptyAttachments()
    ///     }
    ///
    /// with `EmptyAttachments` answering `[:]` and `[]`:
    /// `swift test --filter ArcaEngineTests` -> `Executed 43 tests, with 4
    /// failures`, this test on `("[]") is not equal to
    /// ("["ffff…ffff"]") - getNetworkAttachments must read the attachment out
    /// of the StateStore` and `testContainerNetworksAreReadFromTheStore` on
    /// `("[]") is not equal to ("["probe-attached"]")` -- two failing tests,
    /// two assertions each. Both stub-driven tests below stayed green through
    /// it (`testGetNetworkAttachmentsReportsAStoreFailureRatherThanNoAttachments
    /// … passed`, `testGetContainerNetworksReportsAStoreFailureRatherThanNoNetworks
    /// … passed`), and so did `NetworkPruneGateTests`, whose 2 tests still
    /// reported `Test run with 2 tests in 1 suite passed`. This is the mutation
    /// a seam-only test cannot see.
    func testNetworkAttachmentsAreReadFromTheStore() async throws {
        let fixture = try await Self.attachmentFixture()

        let attachments = try await fixture.manager.getNetworkAttachments(
            networkID: Self.attachedNetworkID
        )

        XCTAssertEqual(
            attachments.keys.sorted(),
            [Self.attachedContainerID],
            "getNetworkAttachments must read the attachment out of the StateStore"
        )
        XCTAssertEqual(
            attachments[Self.attachedContainerID]?.ip,
            "172.18.0.2",
            "the attachment must carry the stored address, not a placeholder"
        )
    }

    /// The failure half for the same method, and the one that gates a deletion.
    ///
    /// `[:]` is what "nothing is attached" looks like, so a swallowed store
    /// failure told `docker network prune` every network was unused.
    /// `NetworkPruneGateTests` in `ArcaTests` asserts on the deletion itself;
    /// this asserts the read that gate depends on reports rather than returns
    /// empty.
    ///
    /// MEASURED, restoring the swallow -- `getNetworkAttachments`' body
    /// returned to `if let attachments = try? await
    /// attachmentSource.getNetworkAttachments(networkID: networkID) { return
    /// attachments }; return [:]`: `swift test --filter ArcaEngineTests` ->
    /// `Executed 43 tests, with 1 failure`, this test on `getNetworkAttachments
    /// returned 0 attachments instead of reporting the store failure`. The
    /// three other tests added here stayed green through it, including
    /// `testGetContainerNetworksReportsAStoreFailureRatherThanNoNetworks` --
    /// which is why that one exists separately.
    func testGetNetworkAttachmentsReportsAStoreFailureRatherThanNoAttachments() async throws {
        let manager = SandboxEngineService.forTesting().networkManager
        await manager.setNetworkAttachmentSource(StubNetworkAttachmentSource.failing)

        do {
            let swallowed = try await manager.getNetworkAttachments(
                networkID: Self.attachedNetworkID
            )
            XCTFail(
                "getNetworkAttachments returned \(swallowed.count) attachments instead of "
                    + "reporting the store failure"
            )
        } catch is NetworkAttachmentsUnreachable {
            // The store's failure reached the caller, which is the point.
        }
    }

    /// The production derivation behind `getContainerNetworks`, with nothing
    /// installed. The other half of the mutation measured above: proving one of
    /// these two methods leaves the other unproven, because each reads its own
    /// direction of the attachment table.
    func testContainerNetworksAreReadFromTheStore() async throws {
        let fixture = try await Self.attachmentFixture()

        let networks = try await fixture.manager.getContainerNetworks(
            containerID: Self.attachedContainerID
        )

        XCTAssertEqual(
            networks.map(\.name),
            ["probe-attached"],
            "getContainerNetworks must read the container's networks out of the StateStore"
        )
        XCTAssertEqual(
            networks.first?.containers,
            [Self.attachedContainerID],
            "the network must carry its attached containers, as the backend's copy did"
        )
    }

    /// The failure half for `getContainerNetworks`, proved separately from
    /// `getNetworkAttachments` above.
    ///
    /// An empty answer here reads to `getWireGuardClient` as "not attached to
    /// any WireGuard network", and its caller publishes no port mappings on the
    /// strength of that -- a container that comes up with its ports silently
    /// unmapped.
    ///
    /// MEASURED, restoring the swallow to this method alone -- `return (try?
    /// await attachmentSource.getContainerNetworks(containerID: containerID))
    /// ?? []`: `swift test --filter ArcaEngineTests` -> `Executed 43 tests,
    /// with 1 failure`, this test on `getContainerNetworks returned 0 networks
    /// instead of reporting the store failure`.
    /// `testGetNetworkAttachmentsReportsAStoreFailureRatherThanNoAttachments`
    /// stayed green through it (`… passed (0.009 seconds)`), which is why both
    /// exist.
    func testGetContainerNetworksReportsAStoreFailureRatherThanNoNetworks() async throws {
        let manager = SandboxEngineService.forTesting().networkManager
        await manager.setNetworkAttachmentSource(StubNetworkAttachmentSource.failing)

        do {
            let swallowed = try await manager.getContainerNetworks(
                containerID: Self.attachedContainerID
            )
            XCTFail(
                "getContainerNetworks returned \(swallowed.count) networks instead of "
                    + "reporting the store failure"
            )
        } catch is NetworkAttachmentsUnreachable {
            // The store's failure reached the caller rather than an empty list.
        }
    }

    private static let attachedNetworkID = String(repeating: "e", count: 64)
    private static let attachedContainerID = String(repeating: "f", count: 64)

    /// A manager over a throwaway state root holding one network, one
    /// container, and the attachment joining them.
    ///
    /// The rows go in through `StateStore`'s own writers -- the ones
    /// `createNetwork` and `attachContainerToNetwork` call -- so what the two
    /// tests above exercise is the real read path over real rows. The
    /// `StateStore` is returned alongside the manager so it stays alive for the
    /// test's duration.
    private static func attachmentFixture() async throws -> (
        manager: NetworkManager, store: StateStore
    ) {
        let stateRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("arca-attachment-tests-\(UUID().uuidString)")
        let paths = EnginePaths(stateRoot: stateRoot)
        let logger = Logger(label: "arca-engine-tests")

        let seedStore = try StateStore(path: paths.stateDatabase.path, logger: logger)
        try await seedStore.saveNetwork(
            id: attachedNetworkID,
            name: "probe-attached",
            driver: "bridge",
            scope: "local",
            createdAt: Date(),
            subnet: "172.18.0.0/16",
            gateway: "172.18.0.1",
            ipRange: nil,
            optionsJSON: nil,
            labelsJSON: nil,
            isDefault: false
        )

        // The attachment row carries foreign keys to both tables, so the
        // container has to exist before it can be attached.
        let encoder = JSONEncoder()
        try await seedStore.saveContainer(
            id: attachedContainerID,
            name: "attached-probe",
            image: "arca/probe:latest",
            imageID: "sha256:probe",
            createdAt: Date(),
            status: "running",
            running: true,
            paused: false,
            restarting: false,
            pid: 0,
            exitCode: 0,
            startedAt: Date(),
            finishedAt: nil,
            stoppedByUser: false,
            entrypoint: nil,
            configJSON: String(
                decoding: try encoder.encode(ContainerConfiguration(image: "arca/probe:latest")),
                as: UTF8.self
            ),
            hostConfigJSON: String(decoding: try encoder.encode(HostConfig()), as: UTF8.self)
        )

        try await seedStore.saveNetworkAttachment(
            containerID: attachedContainerID,
            networkID: attachedNetworkID,
            ipAddress: "172.18.0.2",
            macAddress: "02:42:ac:12:00:02",
            aliases: ["attached-probe"]
        )

        return (
            SandboxEngineService
                .forTesting(stateRoot: stateRoot, kernelPath: unbootedKernel)
                .networkManager,
            seedStore
        )
    }

    /// The one bridge network the succeeding half of the first test expects
    /// back, so the assertion is an equality rather than a non-emptiness check.
    private static let probeNetwork = NetworkMetadata(
        id: String(repeating: "c", count: 64),
        name: "probe-bridge",
        driver: "bridge",
        subnet: "172.18.0.0/16",
        gateway: "172.18.0.1"
    )

    /// Container names in a stable order. `listContainers` maps over
    /// `containers.values`, and a Dictionary's iteration order is not
    /// guaranteed, so an order-sensitive assertion would flake.
    private static func names(of containers: [ContainerSummary]) -> [String] {
        containers.flatMap(\.names).sorted()
    }

    /// One container to seed into the StateStore before the manager restores.
    private struct Seed {
        let name: String
        let labels: [String: String]

        /// The character the 64-character Docker ID is built from. Distinct per
        /// seed: `loadPersistedState()` derives the native ID from the first 32
        /// characters, and two containers sharing a native ID would overwrite
        /// each other in `reverseMapping`.
        let idCharacter: Character
    }

    /// A `ContainerManager` over a throwaway state root whose StateStore holds
    /// one container labelled `com.arca.internal=true` and one with no labels at
    /// all. The unlabelled one is what makes the negative case meaningful: it is
    /// the container that must survive `includeInternal: false`.
    ///
    /// Containers are seeded through `StateStore.saveContainer` and read back by
    /// `loadPersistedState()` -- the same pair the daemon uses across a restart
    /// -- rather than by writing into `containers` through a test-only setter,
    /// so what the test exercises is the restore path itself.
    ///
    /// Paths come from `EnginePaths`, the derivation `arca-engine` calls, for
    /// the reason `TestSupport` gives: a copy of those `appendingPathComponent`
    /// lines makes the test a replica of the wiring rather than the wiring.
    private static func seededManager() async throws -> ContainerManager {
        let logger = Logger(label: "arca-engine-tests")
        let paths = EnginePaths(
            stateRoot: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("arca-list-filter-tests-\(UUID().uuidString)")
        )

        let stateStore = try StateStore(path: paths.stateDatabase.path, logger: logger)
        let encoder = JSONEncoder()

        let seeds = [
            Seed(
                name: "arca-internal-probe",
                labels: ["com.arca.internal": "true"],
                idCharacter: "a"
            ),
            Seed(name: "plain-probe", labels: [:], idCharacter: "b")
        ]

        for seed in seeds {
            let config = ContainerConfiguration(image: "arca/probe:latest", labels: seed.labels)

            // Docker IDs are 64 characters. listContainers drops any container
            // whose reverse mapping is missing, and that mapping is keyed on the
            // first 32, so the length is load-bearing rather than cosmetic.
            try await stateStore.saveContainer(
                id: String(repeating: String(seed.idCharacter), count: 64),
                name: seed.name,
                image: "arca/probe:latest",
                imageID: "sha256:probe",
                createdAt: Date(),
                status: "exited",
                running: false,
                paused: false,
                restarting: false,
                pid: 0,
                exitCode: 0,
                startedAt: nil,
                finishedAt: nil,
                stoppedByUser: false,
                entrypoint: nil,
                configJSON: String(decoding: try encoder.encode(config), as: UTF8.self),
                hostConfigJSON: String(decoding: try encoder.encode(HostConfig()), as: UTF8.self)
            )
        }

        return ContainerManager(
            imageManager: try ImageManager(logger: logger, imageStorePath: paths.imageStoreRoot),
            kernelPath: unbootedKernel.path,
            imageStoreRoot: paths.imageStoreRoot,
            layerCachePath: paths.layerCache,
            stateStore: stateStore,
            logger: logger
        )
    }
}

/// The error a failing network source reports.
///
/// At file scope, not nested inside `ListFilterTests`, and not nested inside
/// `StubNetworkLister` either. MEASURED: nested, `catch is
/// StubBridgeLister.BackendUnreachable` crashed the test binary --
/// `swift test --filter ArcaEngineTests` reported `exited with unexpected
/// signal code 11`, and driving the one test straight through `xctest` exited
/// 139 on three runs out of three, faulting in `lookUpImpOrForward` in libobjc
/// reached from that `catch` (`ListFilterTests.swift:82:17` in the backtrace).
/// Moving these two declarations out, with nothing else changed, made the same
/// test pass.
struct NetworkListerUnreachable: Error {}

/// A network source that either fails or answers. This is the seam the network
/// tests need and the container tests did not: `NetworkManager` populates its
/// WireGuard backend only inside `initialize()`, which also creates the default
/// `host` network over vmnet and so cannot run in a unit test, and `StateStore`
/// is a concrete actor whose SQLite connection a test cannot break on demand.
struct StubNetworkLister: NetworkLister {
    let result: Result<[NetworkMetadata], NetworkListerUnreachable>

    static let failing = StubNetworkLister(result: .failure(NetworkListerUnreachable()))

    static func listing(_ networks: [NetworkMetadata]) -> StubNetworkLister {
        StubNetworkLister(result: .success(networks))
    }

    func listNetworks() async throws -> [NetworkMetadata] {
        try result.get()
    }
}

/// The error a failing attachment source reports. At file scope for the reason
/// `NetworkListerUnreachable` is, and distinct from it so a test cannot pass by
/// catching the wrong seam's failure.
struct NetworkAttachmentsUnreachable: Error {}

/// An attachment source that cannot reach the store.
///
/// Only the failing direction is offered: the answering direction is what the
/// production `StoredNetworkAttachments` already does over a real StateStore,
/// and the tests that need it install nothing rather than stand a stub in its
/// place. A stub that answers would only prove the stub answers.
struct StubNetworkAttachmentSource: NetworkAttachmentSource {
    static let failing = StubNetworkAttachmentSource()

    func getNetworkAttachments(networkID: String) async throws -> [String: NetworkAttachment] {
        throw NetworkAttachmentsUnreachable()
    }

    func getContainerNetworks(containerID: String) async throws -> [NetworkMetadata] {
        throw NetworkAttachmentsUnreachable()
    }
}
