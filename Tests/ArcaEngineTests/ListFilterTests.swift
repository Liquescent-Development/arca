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
