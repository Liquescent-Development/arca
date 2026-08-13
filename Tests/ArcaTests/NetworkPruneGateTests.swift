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

    /// The gate's normal path: the read succeeds, says a container is attached,
    /// and the network is kept.
    ///
    /// Added after review. The two tests either side of this one both pin "the
    /// read *failed* -> do not delete"; neither pins "the read *succeeded and
    /// was non-empty* -> do not delete", which is the whole reason the gate is
    /// there. MEASURED, with `if !attachments.isEmpty { continue }` deleted
    /// outright from `handlePruneNetworks` and nothing else changed:
    /// `swift test --filter ArcaEngineTests` -> `Executed 43 tests, with 0
    /// failures`, and `swift test --filter NetworkPruneGateTests` -> `Test run
    /// with 3 tests in 1 suite failed after 0.013 seconds with 2 issues`, this
    /// test alone, on `prune deleted probe-prune despite a container being
    /// attached to it: success(DockerAPI.NetworkPruneResponse(networksDeleted:
    /// ["probe-prune"]))` and on `remaining.contains { $0.id == networkID }`.
    /// The other two tests in this suite stayed green. Before this test
    /// existed that same deletion left the entire diff green.
    ///
    /// A stub answers here, unlike the store-backed tests in `ArcaEngineTests`.
    /// That is the right call at this level and the wrong one at that one: here
    /// the thing under test is `handlePruneNetworks`' use of the answer, so the
    /// answer is an input; there the thing under test was the derivation that
    /// produces it, which a stub would have replaced.
    @Test("A network with an attached container is not pruned")
    func attachedNetworkIsNotPruned() async throws {
        let fixture = try await PruneFixture()
        let networkID = try await fixture.createPrunableNetwork()
        await fixture.networkManager.setNetworkAttachmentSource(
            AttachedSource(networkID: networkID)
        )

        let result = await fixture.handlers.handlePruneNetworks()

        guard case .success(let response) = result else {
            Issue.record("prune failed on a healthy attachment read: \(result)")
            return
        }
        #expect(
            response.networksDeleted.isEmpty,
            "prune deleted probe-prune despite a container being attached to it: \(result)"
        )

        let remaining = try await fixture.networkManager.listNetworks()
        #expect(
            remaining.contains { $0.id == networkID },
            "the in-use network must still exist after the prune"
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
    /// 1 suite failed after 0.014 seconds with 1 issue` (measured when this
    /// suite stood at 2 tests), this test on `prune deleted probe-prune despite
    /// being unable to read its attachments:
    /// success(DockerAPI.NetworkPruneResponse(networksDeleted:
    /// ["probe-prune"]))`. The control stayed green. The deletion is named in
    /// that output, which is the point: the assertion is on the deletion, not
    /// on the thrown error.
    ///
    /// The same bug reachable from the handler side rather than the manager
    /// side, found in review: the `catch` above **cannot** be removed -- this
    /// method is non-throwing, so that is a compile error -- but its body can
    /// be replaced with `attachments = [:]`, which compiles and restores the
    /// original bug verbatim. MEASURED: `swift test --filter ArcaEngineTests`
    /// -> `Executed 43 tests, with 0 failures`, while `swift test --filter
    /// NetworkPruneGateTests` -> `Test run with 3 tests in 1 suite failed after
    /// 0.013 seconds with 1 issue`, this test alone. Nothing in
    /// `ArcaEngineTests` can see that mutation; this suite is the only thing
    /// standing between it and a released deletion.
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

/// One container attached to the network under test, reported without error.
/// The healthy answer the gate is supposed to act on.
private struct AttachedSource: NetworkAttachmentSource {
    let networkID: String

    func getNetworkAttachments(networkID: String) async throws -> [String: NetworkAttachment] {
        guard networkID == self.networkID else {
            return [:]
        }
        let containerID = String(repeating: "a", count: 64)
        return [
            containerID: NetworkAttachment(
                networkID: networkID,
                ip: "172.18.0.2",
                mac: "02:42:ac:12:00:02",
                aliases: ["attached-probe"]
            )
        ]
    }

    func getContainerNetworks(containerID: String) async throws -> [NetworkMetadata] {
        []
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
