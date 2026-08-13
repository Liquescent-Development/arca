import ContainerBridge
import DockerAPI
import Foundation
import Logging
import Testing

/// `docker network prune` reads `getNetworkAttachments` as its "skip networks
/// with active containers" gate, and then deletes on the answer.
///
/// The rest of this task's tests live in `ArcaEngineTests` and assert that the
/// read reports a store failure rather than returning `[:]`. They cannot assert
/// the property that actually matters: proving `getNetworkAttachments` throws
/// does not prove prune declines to delete. `NetworkHandlers` is in `DockerAPI`,
/// which `ArcaEngineTests` deliberately does not depend on, so the deletion
/// assertion lives here -- in the target that already has both `DockerAPI` and
/// `ContainerBridge` -- rather than being quietly downgraded to the weaker one.
///
/// Not `@Suite(.serialized)` and no daemon: every test below runs against a
/// fresh state root under `NSTemporaryDirectory()` and starts no VM.
@Suite("Network prune attachment gate")
struct NetworkPruneGateTests {
    /// The control. Without it the survival test below proves nothing: a prune
    /// that never deletes anything -- because the network was default, or
    /// filtered out, or `deleteNetwork` refused it -- would pass the survival
    /// assertion just as well as a working gate.
    @Test("An unused network is pruned, so the survival assertion has teeth")
    func unusedNetworkIsPruned() async throws {
        let fixture = try await PruneFixture()
        let networkID = try await fixture.createPrunableNetwork()

        let result = await fixture.handlers.handlePruneNetworks()

        guard case .success(let response) = result else {
            Issue.record("prune failed on a network with no attachments: \(result)")
            return
        }
        #expect(response.networksDeleted == ["probe-prune"])

        let remaining = try await fixture.networkManager.listNetworks()
        #expect(
            !remaining.contains { $0.id == networkID },
            "the pruned network must be gone from the store"
        )
    }

    /// The property this task exists for: an in-use network survives a partial
    /// store failure.
    ///
    /// "Partial" is the case Task 3 left open. `listNetworks()` succeeds -- the
    /// network is read straight out of the store -- while the attachment read
    /// for that same network fails. Swallowed by `try?`, that combination made
    /// the network look unused and prune deleted it and reported success.
    ///
    /// The assertion is on the network still being there afterwards, not on the
    /// returned error. MEASURED, restoring the swallow in
    /// `NetworkManager.getNetworkAttachments` --
    ///
    ///     if let attachments = try? await attachmentSource
    ///         .getNetworkAttachments(networkID: networkID) { return attachments }
    ///     return [:]
    ///
    /// -- and leaving the `catch` in `handlePruneNetworks` in place:
    /// `swift test --filter NetworkPruneGateTests` -> `Test run with 2 tests in
    /// 1 suite failed after 0.014 seconds with 1 issue`, this test on `prune
    /// deleted probe-prune despite being unable to read its attachments:
    /// success(DockerAPI.NetworkPruneResponse(networksDeleted:
    /// ["probe-prune"]))`. The control above stayed green. The deletion is
    /// named in that output, which is the point: the assertion is on the
    /// deletion, not on the thrown error.
    @Test("An in-use network survives a partial store failure during prune")
    func inUseNetworkSurvivesAttachmentReadFailure() async throws {
        let fixture = try await PruneFixture()
        let networkID = try await fixture.createPrunableNetwork()
        await fixture.networkManager.setNetworkAttachmentSource(FailingAttachmentSource())

        let result = await fixture.handlers.handlePruneNetworks()

        guard case .failure = result else {
            Issue.record(
                "prune deleted probe-prune despite being unable to read its attachments: \(result)"
            )
            return
        }

        // Read back through the real store, not through the returned response:
        // a handler that reported nothing deleted while deleting the row is
        // exactly the shape of failure this test is here to catch.
        // `listNetworks()` reads `--driver null` networks straight out of the
        // StateStore and never consults the attachment source, so the source
        // the test broke cannot answer this.
        let remaining = try await fixture.networkManager.listNetworks()
        #expect(
            remaining.contains { $0.id == networkID },
            "the in-use network must still exist after a failed attachment read"
        )
    }
}

/// A `NetworkManager` and the `NetworkHandlers` over it, against a throwaway
/// state root. Real managers over a real SQLite file; nothing is stubbed except
/// where a test installs a failing attachment source.
private struct PruneFixture {
    let networkManager: NetworkManager
    let handlers: NetworkHandlers

    init() async throws {
        let logger = Logger(label: "arca-prune-gate-tests")
        let stateRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("arca-prune-gate-tests-\(UUID().uuidString)")

        let stateStore = try StateStore(
            path: stateRoot.appendingPathComponent("state.db").path,
            logger: logger
        )
        let imageManager = try ImageManager(
            logger: logger,
            imageStorePath: stateRoot.appendingPathComponent("images")
        )
        let containerManager = ContainerManager(
            imageManager: imageManager,
            kernelPath: stateRoot.appendingPathComponent("vmlinux").path,
            imageStoreRoot: stateRoot.appendingPathComponent("images"),
            layerCachePath: stateRoot.appendingPathComponent("layers"),
            stateStore: stateStore,
            logger: logger
        )
        let networkManager = NetworkManager(
            config: ArcaConfig(
                kernelPath: stateRoot.appendingPathComponent("vmlinux").path,
                socketPath: stateRoot.appendingPathComponent("arca.sock").path,
                logLevel: "info"
            ),
            stateStore: stateStore,
            containerManager: containerManager,
            logger: logger
        )

        self.networkManager = networkManager
        self.handlers = NetworkHandlers(
            networkManager: networkManager,
            containerManager: containerManager,
            logger: logger
        )
    }

    /// One network prune is willing to consider: not default, no `until` or
    /// `label` filter standing between it and deletion.
    ///
    /// `driver: "null"` because that is the one driver whose whole lifecycle --
    /// create, list, delete -- is the StateStore, with no backend that
    /// `NetworkManager.initialize()` alone can install and no VM. The gate under
    /// test is driver-independent: `handlePruneNetworks` calls
    /// `getNetworkAttachments` for every network it walks.
    func createPrunableNetwork() async throws -> String {
        try await networkManager.createNetwork(
            name: "probe-prune",
            driver: "null",
            subnet: nil,
            gateway: nil,
            ipRange: nil,
            options: [:],
            labels: [:],
            isDefault: false
        )
    }
}

/// The store failure a test cannot induce by breaking SQLite on demand.
private struct AttachmentsUnreachable: Error {}

private struct FailingAttachmentSource: NetworkAttachmentSource {
    func getNetworkAttachments(networkID: String) async throws -> [String: NetworkAttachment] {
        throw AttachmentsUnreachable()
    }

    func getContainerNetworks(containerID: String) async throws -> [NetworkMetadata] {
        throw AttachmentsUnreachable()
    }
}
