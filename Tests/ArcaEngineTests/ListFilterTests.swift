import ContainerBridge
import Foundation
import Logging
import XCTest
@testable import ArcaEngine

final class ListFilterTests: XCTestCase {
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
    /// that threw no matter what. Both mutations were run against this test, and
    /// `swift test --filter ArcaEngineTests` reported `Executed 37 tests, with 1
    /// failure` for each:
    ///
    /// - the append put back to `if let wgNetworks = try? await
    ///   lister.listNetworks()` -> `listNetworks() returned 0 networks instead
    ///   of reporting the backend failure`
    /// - `throw NetworkManagerError.networkNotFound(...)` as the first statement
    ///   of `listNetworks()` -> `caught error: "network guard-proving mutation
    ///   not found"`
    func testListNetworksReportsABackendFailureRatherThanAShortList() async throws {
        let failing = SandboxEngineService.forTesting().networkManager
        await failing.setBridgeNetworkLister(StubBridgeLister.failing)

        do {
            let swallowed = try await failing.listNetworks()
            XCTFail(
                "listNetworks() returned \(swallowed.count) networks instead of "
                    + "reporting the backend failure"
            )
        } catch is BridgeBackendUnreachable {
            // The backend's own error reached the caller, which is the point.
        }

        // The other side: the same seam, a lister that answers. Without this,
        // a `listNetworks()` that threw no matter what would pass the half above.
        let working = SandboxEngineService.forTesting().networkManager
        await working.setBridgeNetworkLister(StubBridgeLister.listing([Self.probeNetwork]))

        let networks = try await working.listNetworks()
        XCTAssertEqual(
            networks.map(\.name),
            ["probe-bridge"],
            "listNetworks() must return what the bridge lister reports"
        )
    }

    /// The one bridge network the succeeding half of the test above expects
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
            kernelPath: paths.kernel.path,
            imageStoreRoot: paths.imageStoreRoot,
            layerCachePath: paths.layerCache,
            stateStore: stateStore,
            logger: logger
        )
    }
}

/// The error a failing bridge backend reports.
///
/// At file scope, not nested inside `ListFilterTests`, and not nested inside
/// `StubBridgeLister` either. MEASURED: nested, `catch is
/// StubBridgeLister.BackendUnreachable` crashed the test binary --
/// `swift test --filter ArcaEngineTests` reported `exited with unexpected
/// signal code 11`, and driving the one test straight through `xctest` exited
/// 139 on three runs out of three, faulting in `lookUpImpOrForward` in libobjc
/// reached from that `catch` (`ListFilterTests.swift:82:17` in the backtrace).
/// Moving these two declarations out, with nothing else changed, made the same
/// test pass.
struct BridgeBackendUnreachable: Error {}

/// A bridge-network source that either fails or answers. This is the seam the
/// network test needs and the container tests did not: `NetworkManager`
/// populates its real backend only inside `initialize()`, which also creates the
/// default `host` network over vmnet and so cannot run in a unit test.
struct StubBridgeLister: BridgeNetworkLister {
    let result: Result<[NetworkMetadata], BridgeBackendUnreachable>

    static let failing = StubBridgeLister(result: .failure(BridgeBackendUnreachable()))

    static func listing(_ networks: [NetworkMetadata]) -> StubBridgeLister {
        StubBridgeLister(result: .success(networks))
    }

    func listNetworks() async throws -> [NetworkMetadata] {
        try result.get()
    }
}
