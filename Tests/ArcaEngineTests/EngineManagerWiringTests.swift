import ContainerBridge
import Foundation
import Logging
import XCTest
@testable import ArcaEngine

/// The engine's manager graph, one test per edge that nothing else asserts.
///
/// Two of the three cover `EngineManagers.wireCollaborators()`, one per line it
/// contains. The third covers the `ExecManager(containerManager:)` edge in
/// `EngineManagers.init`, which is not a `wireCollaborators()` line at all: it
/// was guaranteed by the type system until `ExecManager.init` was widened to
/// `any ExecContainerSource`, and it needs a test for exactly the reason the
/// other two do -- the failure is silent and the release gate cannot see it.
///
/// `ContainerManager` holds its `VolumeManager` and `NetworkManager` optionally,
/// set after construction because `NetworkManager.init` already takes a
/// `ContainerManager` and one of the two edges has to come later. Every use is
/// guarded by `if let` or `guard let ... else { return }`, so an unset
/// collaborator is not an error anywhere -- it is silence. `ArcaDaemon` sets
/// both (`ArcaDaemon.swift:236`, `:262`); the engine set neither until Task 6's
/// review found it.
///
/// All three assert on **behaviour reachable through a public method**, never on
/// the setter having been called or the property having been assigned. A test
/// that read back the stored property would pass over a `wireCollaborators()`
/// that assigned the right object to the wrong manager, and would prove nothing
/// about what the omission costs.
///
/// All three are VM-free by construction: they drive `loadPersistedState()`,
/// `getContainer`, `removeContainer` and `createExec` over rows seeded into the
/// StateStore.
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

    /// The `ExecManager(containerManager:)` line, which stopped being guaranteed
    /// by the compiler.
    ///
    /// `ExecManager.init` used to take a concrete `ContainerManager`, so wiring
    /// it to anything else was a compile error and no test was needed. It now
    /// takes `any ExecContainerSource` (`ExecManager.swift:54-59`) so that
    /// `signalExec`'s guards are reachable without a VM. That trade bought
    /// testability by giving up a compile-time guarantee, and this test is what
    /// replaces it -- the third line of engine wiring nothing else asserts.
    ///
    /// The assertion is `containerNotRunning` and **not** `containerNotFound`,
    /// and that difference is the whole test. `containerNotRunning`
    /// (`ExecManager.swift:132`) is reachable only by an `ExecManager` that
    /// looked this id up and found the engine's own restored row;
    /// `containerNotFound` (`:129`) is what an `ExecManager` wired to some other
    /// source returns. A test asserting merely "createExec threw" would pass in
    /// both worlds, which is the failure mode this suite exists to avoid.
    ///
    /// The seeded container is `exited`, so this stops one guard short of
    /// success. That ceiling is not a weakness of the test but the same fact
    /// that forced the seam: `loadPersistedState()` reconciles a stored
    /// `running` to `exited` (`ContainerManager.swift:395-401`), so no VM-free
    /// path yields a running container. Reaching the *second* guard already
    /// proves the lookup crossed the wiring, which is the property under test.
    ///
    /// MEASURED, with `EngineManagers.swift:86` rewired to
    /// `ExecManager(containerManager: ZZHollowExecSource(), logger: logger)`,
    /// where the stub answers `nil` to both protocol members, and nothing else
    /// changed: `swift test --filter EngineManagerWiringTests` -> `Executed 3
    /// tests, with 1 failure`, this test alone, on `execManager does not see the
    /// engine's own containers: expected containerNotRunning, got No such
    /// container: aaaa...`; and `swift test --filter ArcaEngineTests` ->
    /// `Executed 177 tests, with 1 failure` against a baseline of 177 with 0.
    ///
    /// The counterfactual is why this is worth thirty lines, and it was run
    /// rather than reasoned: with that same rewiring in place and **this test
    /// deleted**, `swift test --filter ArcaEngineTests` -> `Executed 176 tests,
    /// with 0 failures`. A fully green release gate over an engine whose every
    /// `exec` -- and every `docker exec` -- fails `No such container` against a
    /// container it is holding.
    func testTheExecManagerSeesTheEngineSOwnContainers() async throws {
        let managers = try Self.managers()
        try await Self.seedContainer(into: managers.stateStore, id: Self.containerID)
        try await managers.containerManager.loadPersistedState()

        do {
            _ = try await managers.execManager.createExec(
                containerID: Self.containerID,
                cmd: ["/bin/sh"],
                env: nil,
                workingDir: nil,
                user: nil,
                tty: false,
                attachStdin: false,
                attachStdout: true,
                attachStderr: true
            )
            XCTFail("createExec succeeded against a container restored as exited")
        } catch let error as ExecManagerError {
            guard case .containerNotRunning = error else {
                XCTFail(
                    "execManager does not see the engine's own containers: expected "
                        + "containerNotRunning, got \(error)"
                )
                return
            }
        }
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
