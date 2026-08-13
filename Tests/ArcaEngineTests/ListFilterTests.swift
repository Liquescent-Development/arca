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
    /// failures`). This drives a real container through the real restore loop
    /// and asks for it both ways.
    func testListContainersShowsAnInternalContainerOnlyWhenAskedTo() async throws {
        let manager = try await Self.managerWithInternalContainer(named: "arca-internal-probe")
        try await manager.loadPersistedState()

        let shown = try await manager.listContainers(all: true, includeInternal: true)
        XCTAssertEqual(
            shown.map(\.names),
            [["/arca-internal-probe"]],
            "includeInternal: true must list a container labelled com.arca.internal=true"
        )

        let hidden = try await manager.listContainers(all: true, includeInternal: false)
        XCTAssertTrue(
            hidden.isEmpty,
            "includeInternal: false must hide it; got \(hidden.map(\.names))"
        )
    }

    /// A `ContainerManager` over a throwaway state root whose StateStore already
    /// holds one container labelled `com.arca.internal=true`.
    ///
    /// The container is seeded through `StateStore.saveContainer` and read back
    /// by `loadPersistedState()` -- the same pair the daemon uses across a
    /// restart -- rather than by writing into `containers` through a test-only
    /// setter, so what the test exercises is the restore path itself.
    ///
    /// Paths come from `EnginePaths`, the derivation `arca-engine` calls, for
    /// the reason `TestSupport` gives: a copy of those `appendingPathComponent`
    /// lines makes the test a replica of the wiring rather than the wiring.
    private static func managerWithInternalContainer(named name: String) async throws -> ContainerManager {
        let logger = Logger(label: "arca-engine-tests")
        let paths = EnginePaths(
            stateRoot: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("arca-list-filter-tests-\(UUID().uuidString)")
        )

        let stateStore = try StateStore(path: paths.stateDatabase.path, logger: logger)

        // Docker IDs are 64 characters; loadPersistedState() derives the native
        // ID from the first 32, and listContainers drops any container whose
        // reverse mapping is missing, so the length matters.
        let dockerID = String(repeating: "a", count: 64)
        let config = ContainerConfiguration(
            image: "arca/probe:latest",
            labels: ["com.arca.internal": "true"]
        )
        let encoder = JSONEncoder()
        try await stateStore.saveContainer(
            id: dockerID,
            name: name,
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
