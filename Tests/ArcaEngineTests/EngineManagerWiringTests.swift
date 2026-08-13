import ContainerBridge
import Foundation
import Logging
import XCTest
@testable import ArcaEngine

/// `EngineManagers.wireCollaborators()`, one test per line it contains.
///
/// `ContainerManager` holds its `VolumeManager` and `NetworkManager` optionally,
/// set after construction because `NetworkManager.init` already takes a
/// `ContainerManager` and one of the two edges has to come later. Every use is
/// guarded by `if let` or `guard let ... else { return }`, so an unset
/// collaborator is not an error anywhere -- it is silence. `ArcaDaemon` sets
/// both (`ArcaDaemon.swift:236`, `:262`); the engine set neither until Task 6's
/// review found it.
///
/// Both tests assert on **behaviour reachable through a public method**, never
/// on the setter having been called. A test that read back the stored property
/// would pass over a `wireCollaborators()` that assigned the right object to the
/// wrong manager, and would prove nothing about what the omission costs.
///
/// Both are VM-free by construction: they drive `loadPersistedState()`,
/// `getContainer` and `removeContainer` over rows seeded into the StateStore.
/// Nothing here calls `initialize()` on any manager other than `VolumeManager`,
/// whose `initialize()` touches only the filesystem and the store --
/// `ContainerManager.initialize()` constructs a real `VmnetNetwork` and no test
/// in this target may call it.
final class EngineManagerWiringTests: XCTestCase {
    private static let unbootedKernel = URL(fileURLWithPath: "/opt/arca/vmlinux")
    private let logger = Logger(label: "arca-engine-tests")

    /// The `setVolumeManager` line, through the leak its absence causes.
    ///
    /// `cleanupVolumesForContainer` (`ContainerManager.swift:4128-4131`) is
    /// `guard let volumeManager = volumeManager else { return }` -- with no
    /// volume manager it deletes nothing and reports nothing, and
    /// `removeContainer` goes on to succeed. The container row is gone,
    /// CASCADE takes its `volume_mounts` row with it, and the anonymous volume
    /// is left on disk with nothing pointing at it. `Remove` answering success
    /// over a leak is exactly the report `ListResources` exists to prevent.
    ///
    /// The named volume is the second half of the assertion and is not
    /// decoration: `cleanupVolumesForContainer` deletes only mounts marked
    /// anonymous, so a cleanup that deleted every mounted volume would pass a
    /// single-volume form of this test while destroying user data on `Remove`.
    func testRemovingAContainerDeletesItsAnonymousVolumeAndSparesTheNamedOne() async throws {
        let managers = try Self.managers()
        try await managers.volumeManager.initialize()
        _ = try await managers.volumeManager.createVolume(
            name: "anon-vol", driver: "local", driverOpts: nil, labels: nil
        )
        _ = try await managers.volumeManager.createVolume(
            name: "named-vol", driver: "local", driverOpts: nil, labels: nil
        )

        try await Self.seedContainer(into: managers.stateStore, id: Self.containerID)
        try await managers.stateStore.saveVolumeMount(
            containerID: Self.containerID, volumeName: "anon-vol",
            containerPath: "/data", isAnonymous: true
        )
        try await managers.stateStore.saveVolumeMount(
            containerID: Self.containerID, volumeName: "named-vol",
            containerPath: "/named", isAnonymous: false
        )

        await managers.wireCollaborators()
        try await managers.containerManager.loadPersistedState()
        try await managers.containerManager.removeContainer(id: Self.containerID)

        let remaining = try await managers.volumeManager.listVolumes().map(\.name).sorted()
        XCTAssertEqual(
            remaining, ["named-vol"],
            "Remove must delete the container's anonymous volume and keep the named "
                + "one; without the volume manager wired it silently keeps both, and "
                + "the anonymous one is then unreachable"
        )
    }

    /// The `setNetworkManager` line, through what `Inspect` will read.
    ///
    /// `getContainer` builds `NetworkSettings.networks` inside
    /// `if let networkManager = networkManager` (`ContainerManager.swift:826`).
    /// Unwired, a container attached to a network reports an EMPTY networks
    /// dictionary -- not an error, not "unknown", but a confident "attached to
    /// nothing". Task 7 answers `Inspect` from this exact read.
    ///
    /// The network is created through `NetworkManager.createNetwork` with the
    /// `null` driver rather than seeded straight into the StateStore, and that
    /// is forced rather than stylistic. `getNetwork(id:)` resolves through
    /// `networkDrivers`, an in-memory map populated either by
    /// `NetworkManager.initialize()` -- which creates the vmnet `host` network
    /// and so is off limits here -- or by `createNetwork` itself
    /// (`NetworkManager.swift:467`). The `null` branch is the one driver whose
    /// create and whose read both touch nothing but the StateStore
    /// (`:443-472`, `:671-688`), which is what makes this assertable without a
    /// host resource.
    ///
    /// The assertion is an equality on the network's NAME, not a non-emptiness
    /// check, and the name is what makes it load-bearing: the attachment row
    /// carries only the network's id, so a dictionary keyed by `probe-none`
    /// exists only if the lookup through the network manager actually resolved.
    func testAnAttachedContainerReportsTheNetworkItIsOn() async throws {
        let managers = try Self.managers()
        let networkID = try await managers.networkManager.createNetwork(
            name: "probe-none",
            driver: "null",
            subnet: nil,
            gateway: nil,
            ipRange: nil,
            options: [:],
            labels: [:]
        )

        try await Self.seedContainer(into: managers.stateStore, id: Self.containerID)
        try await managers.stateStore.saveNetworkAttachment(
            containerID: Self.containerID,
            networkID: networkID,
            ipAddress: "172.18.0.2",
            macAddress: "02:42:ac:12:00:02",
            aliases: ["probe"]
        )

        await managers.wireCollaborators()
        try await managers.containerManager.loadPersistedState()

        let read = try await managers.containerManager.getContainer(id: Self.containerID)
        let container = try XCTUnwrap(read)
        let networks = container.networkSettings.networks
        XCTAssertEqual(
            networks.keys.sorted(), ["probe-none"],
            "a container on a network must report that network by name; unwired, "
                + "this dictionary is empty and Inspect reports it attached to nothing"
        )
        XCTAssertEqual(
            networks["probe-none"]?.ipAddress, "172.18.0.2",
            "the reported endpoint must carry the seeded attachment's address"
        )
        XCTAssertEqual(
            networks["probe-none"]?.networkID, networkID,
            "and must name the network it resolved, not some other attachment"
        )
    }

    // MARK: - Fixtures

    /// 64 characters, because `loadPersistedState()` keys `reverseMapping` on
    /// the first 32 and `listContainers` drops any container missing from it.
    private static let containerID = String(repeating: "a", count: 64)

    /// The engine's own managers over a throwaway state root -- the production
    /// factory, so what these tests wire is what `arca-engine` wires.
    private static func managers() throws -> EngineManagers {
        try EngineManagers(
            stateRoot: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("arca-wiring-tests-\(UUID().uuidString)"),
            kernelPath: unbootedKernel,
            logLevel: "info",
            logger: Logger(label: "arca-engine-tests")
        )
    }

    /// One exited container. Exited so that `removeContainer` needs no `force`,
    /// and database-only so that it takes the branch that touches no VM.
    private static func seedContainer(into store: StateStore, id: String) async throws {
        let encoder = JSONEncoder()
        try await store.saveContainer(
            id: id,
            name: "wiring-probe",
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
            finishedAt: Date(),
            stoppedByUser: false,
            entrypoint: nil,
            configJSON: String(
                decoding: try encoder.encode(
                    ContainerConfiguration(image: "arca/probe:latest")
                ),
                as: UTF8.self
            ),
            hostConfigJSON: String(decoding: try encoder.encode(HostConfig()), as: UTF8.self)
        )
    }
}
