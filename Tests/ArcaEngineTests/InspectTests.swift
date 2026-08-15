import ContainerBridge
import Foundation
import GRPC
import Logging
import SandboxEngineProto
import XCTest
@testable import ArcaEngine

final class InspectTests: XCTestCase {
    /// gascan reassembles the canonical reference and asserts it is one, which
    /// is what lets the daemon compare one observation against another by exact
    /// string (crates/gascan-arca/src/translate.rs:333-336). A tag, or a digest
    /// in another form, breaks reconciliation rather than looking untidy.
    func testImageDigestSplitsRepositoryFromBareLowercaseHex() {
        let digest = imageDigest(
            fromReference: "ghcr.io/liquescent-development/gascan/workspace@sha256:"
                + String(repeating: "a", count: 64)
        )
        XCTAssertEqual(digest?.repository, "ghcr.io/liquescent-development/gascan/workspace")
        XCTAssertEqual(digest?.sha256Hex, String(repeating: "a", count: 64))
    }

    func testImageDigestRefusesAnythingThatIsNotAnExactDigestReference() {
        XCTAssertNil(imageDigest(fromReference: "ubuntu:latest"))
        XCTAssertNil(imageDigest(fromReference: "ubuntu"))
        XCTAssertNil(imageDigest(fromReference: "ubuntu@sha256:abc"))
        XCTAssertNil(imageDigest(fromReference: "ubuntu@sha512:" + String(repeating: "a", count: 64)))
        XCTAssertNil(imageDigest(fromReference: "ubuntu@sha256:" + String(repeating: "A", count: 64)))
    }

    /// A paused or restarting sandbox is neither running nor stopped.
    /// UNSPECIFIED reaches the consumer as a hard UnknownActualState error
    /// naming the state (crates/gascan-arca/src/translate.rs:399-409) rather
    /// than a guess that could have a reconciler destroy live work.
    func testSandboxStateIsUnspecifiedForPausedAndRestarting() {
        XCTAssertEqual(sandboxState(fromStatus: "paused"), .unspecified)
        XCTAssertEqual(sandboxState(fromStatus: "restarting"), .unspecified)
    }

    // MARK: - The sandbox arm

    /// The whole `Sandbox`, asserted as one value.
    ///
    /// Field by field, an assertion per field passes over a method that fills in
    /// the two fields the test names and leaves the rest at their proto
    /// defaults, and every one of those defaults is a lie a reconciler acts on:
    /// an unset `state` is `UNSPECIFIED`, an unset `owner` is "not gascan's",
    /// and an empty `ports` is "publishes nothing". Comparing the built message
    /// against a message written out in full is the only form that fails when a
    /// field is dropped rather than mis-set.
    ///
    /// Seeded as `created`, not `exited`, so the expected state is `.creating`
    /// -- a non-zero enum case. Against `exited` an implementation that never
    /// assigned `state` at all would still have to be caught by the raw value,
    /// and `.stopped` is not the proto default either, but `created` also
    /// exercises the one status `loadPersistedState()` leaves untouched without
    /// going through crash recovery.
    func testAnOwnedSandboxRoundTripsWithItsDigestOwnerStateAndPorts() async throws {
        let managers = try Self.managers()
        try await Self.seed(
            into: managers.stateStore,
            id: Self.ownedContainerID,
            name: Self.ownedSandboxID,
            image: Self.workspaceRepository + "@sha256:" + Self.ownedDigestHex,
            status: "created",
            labels: SandboxIdentity.labels(from: Self.ownerLabels),
            portBindings: ["80/tcp": [PortBinding(hostPort: "8080")]]
        )
        try await managers.containerManager.loadPersistedState()

        let response = await managers.makeService().inspect(
            request: Arca_Engine_V1_InspectRequest.with { $0.sandboxID = Self.ownedSandboxID }
        )

        guard case .sandbox(let sandbox) = response.outcome else {
            return XCTFail("a seeded, labelled sandbox must answer the sandbox arm: "
                + "\(String(describing: response.outcome))")
        }
        XCTAssertEqual(
            sandbox,
            Arca_Engine_V1_Sandbox.with {
                $0.sandboxID = Self.ownedSandboxID
                $0.image = Arca_Engine_V1_ImageDigest.with {
                    $0.repository = Self.workspaceRepository
                    $0.sha256Hex = Self.ownedDigestHex
                }
                $0.state = .creating
                $0.owner = Self.ownerLabels
                $0.ports = [
                    Arca_Engine_V1_PortMapping.with {
                        $0.hostPort = 8080
                        $0.guestPort = 80
                    }
                ]
            },
            "every field of the reported sandbox comes from the seeded row"
        )
    }

    /// I4, at the seam where it was found: the removed body assigned
    /// `sandbox.ports = []` unconditionally.
    ///
    /// The assertion is the full mapping list, not `count == 1` and not
    /// `contains`. gascan reads this list as complete
    /// (crates/gascan-arca/src/translate.rs:353-389) and compares it for port
    /// drift, so a count is satisfied by one mapping with the two numbers
    /// transposed -- which is a different published port and a different
    /// reconciliation.
    ///
    /// The `state` assertion is not decoration and does not belong to the ports
    /// finding. It is the SECOND status this file pins: the round-trip test
    /// above seeds `created` and expects `.creating`, this row seeds `exited`
    /// and expects `.stopped`. One asserted status is satisfied by a hardcoded
    /// constant -- MEASURED, `sandbox.state = .creating` in place of the
    /// `sandboxState(fromStatus:)` call left `Executed 71 tests, with 0
    /// failures`, so nothing proved the call site called it. Two statuses
    /// mapping to two cases cannot be met by any constant. The consumer
    /// switches on this field directly
    /// (crates/gascan-arca/src/translate.rs:399-409), so a wrong case sends a
    /// reconciler at the wrong action.
    func testASandboxPublishingEightyEightyToEightyReportsThatOneMapping() async throws {
        let managers = try Self.managers()
        try await Self.seed(
            into: managers.stateStore,
            id: Self.ownedContainerID,
            name: Self.ownedSandboxID,
            image: Self.workspaceRepository + "@sha256:" + Self.ownedDigestHex,
            status: "exited",
            labels: SandboxIdentity.labels(from: Self.ownerLabels),
            portBindings: ["80/tcp": [PortBinding(hostPort: "8080")]]
        )
        try await managers.containerManager.loadPersistedState()

        let sandbox = try await Self.inspectedSandbox(managers, Self.ownedSandboxID)
        XCTAssertEqual(
            sandbox.ports,
            [
                Arca_Engine_V1_PortMapping.with {
                    $0.hostPort = 8080
                    $0.guestPort = 80
                }
            ],
            "the stored binding 8080->80 is one mapping; an empty list reads as "
                + "'publishes nothing' and a transposed one reads as a different port"
        )
        XCTAssertEqual(
            sandbox.state, .stopped,
            "this row is seeded exited, and the round-trip test seeds created; a "
                + "hardcoded state satisfies one of the two and cannot satisfy both"
        )
    }

    /// `repeated` is ordered on the wire, and the bindings come out of a
    /// Dictionary whose iteration order is seeded per process
    /// (`ContainerManager.swift:959`). Unsorted, two Inspects of one unchanged
    /// sandbox can report its ports in different orders.
    ///
    /// **Six bindings, not two, and the count is the guard.** A random order
    /// matches the sorted one with probability 1/N!, so a two-binding fixture
    /// catches a missing sort only about half the time. MEASURED with the sort
    /// removed, `swift test --filter …/testPortsAreReportedInAStableOrder…`:
    /// two bindings gave **3 RED / 10 runs**, six bindings gave **10 RED / 10**.
    /// With the sort restored, six bindings gave **10 GREEN / 10**. The earlier
    /// two-binding form of this test was a guard that missed 70% of the time.
    ///
    /// The host ports deliberately do not ascend with the guest ports
    /// (62222, 8080, 8443, 13000, 25432, 19090 against 22, 80, 443, 3000, 5432,
    /// 9090), so a sort keyed on the host port produces a different list and
    /// fails. Sorting by `(guestPort, hostPort)` is the ordering asserted, not
    /// merely "some deterministic ordering".
    func testPortsAreReportedInAStableOrderRatherThanDictionaryOrder() async throws {
        let managers = try Self.managers()
        try await Self.seed(
            into: managers.stateStore,
            id: Self.ownedContainerID,
            name: Self.ownedSandboxID,
            image: Self.workspaceRepository + "@sha256:" + Self.ownedDigestHex,
            status: "exited",
            labels: SandboxIdentity.labels(from: Self.ownerLabels),
            portBindings: [
                "5432/tcp": [PortBinding(hostPort: "25432")],
                "80/tcp": [PortBinding(hostPort: "8080")],
                "9090/tcp": [PortBinding(hostPort: "19090")],
                "22/tcp": [PortBinding(hostPort: "62222")],
                "443/tcp": [PortBinding(hostPort: "8443")],
                "3000/tcp": [PortBinding(hostPort: "13000")],
            ]
        )
        try await managers.containerManager.loadPersistedState()

        let sandbox = try await Self.inspectedSandbox(managers, Self.ownedSandboxID)
        XCTAssertEqual(
            sandbox.ports,
            [
                Arca_Engine_V1_PortMapping.with {
                    $0.hostPort = 62222
                    $0.guestPort = 22
                },
                Arca_Engine_V1_PortMapping.with {
                    $0.hostPort = 8080
                    $0.guestPort = 80
                },
                Arca_Engine_V1_PortMapping.with {
                    $0.hostPort = 8443
                    $0.guestPort = 443
                },
                Arca_Engine_V1_PortMapping.with {
                    $0.hostPort = 13000
                    $0.guestPort = 3000
                },
                Arca_Engine_V1_PortMapping.with {
                    $0.hostPort = 25432
                    $0.guestPort = 5432
                },
                Arca_Engine_V1_PortMapping.with {
                    $0.hostPort = 19090
                    $0.guestPort = 9090
                },
            ],
            "ports must come back in guest-port order every time, not in whatever "
                + "order this process's Dictionary seed produced"
        )
    }

    // MARK: - The foreign arm, and the order that produces it

    /// I5, first half: an unlabelled container is refused, not returned.
    ///
    /// Returning a `Sandbox` with no owner -- what the removed body's
    /// `if let owner` did -- reaches gascan as
    /// `invalid_output("sandbox {id} carries no owner labels")`
    /// (crates/gascan-arca/src/translate.rs:412-414), the code reserved for "the
    /// engine sent me something I cannot interpret". That reports a broken
    /// engine when the truth is a foreign resource.
    ///
    /// The image here is a valid digest reference on purpose: this test must
    /// fail when the label guard goes, and must NOT depend on which of the two
    /// guards runs first. The ordering is the next test's job.
    func testAnUnlabelledContainerIsRefusedAsForeignRatherThanReturnedWithoutAnOwner() async throws {
        let managers = try Self.managers()
        try await Self.seed(
            into: managers.stateStore,
            id: Self.foreignContainerID,
            name: Self.foreignSandboxID,
            image: Self.workspaceRepository + "@sha256:" + Self.foreignDigestHex,
            status: "exited",
            labels: [:],
            portBindings: [:]
        )
        try await managers.containerManager.loadPersistedState()

        let response = await managers.makeService().inspect(
            request: Arca_Engine_V1_InspectRequest.with { $0.sandboxID = Self.foreignSandboxID }
        )

        guard case .error(let error) = response.outcome else {
            return XCTFail("an unlabelled container must be refused, not reported: "
                + "\(String(describing: response.outcome))")
        }
        XCTAssertEqual(error.code, "foreign_resource_refused")
        XCTAssertEqual(error.resource, Self.foreignSandboxID)
        XCTAssertEqual(
            error.message,
            "container \(Self.foreignSandboxID) carries no gascan owner labels, so this "
                + "engine cannot assert it is the sandbox that was asked for"
        )
    }

    /// I5, and the reason the label read comes first.
    ///
    /// A container this engine did not create is very likely created from a tag,
    /// and `imageDigest(fromReference:)` refuses a tag. With the digest check in
    /// front of the label read -- which is what the removed body did -- this
    /// container answers `invalid_output`, and gascan reads that as a broken
    /// engine rather than as a name collision with something that is not a
    /// sandbox.
    ///
    /// **This test is the ordering, and nothing else.** It differs from the one
    /// above only in the image: unlabelled and tagged, so it takes the label arm
    /// only when the label read runs first. Moving the digest guard back in
    /// front leaves the previous test green and this one red.
    func testAContainerFromATagUnderACollidingNameTakesTheForeignArmNotInvalidOutput() async throws {
        let managers = try Self.managers()
        try await Self.seed(
            into: managers.stateStore,
            id: Self.taggedContainerID,
            name: Self.taggedSandboxID,
            image: "ubuntu:latest",
            status: "exited",
            labels: [:],
            portBindings: [:]
        )
        try await managers.containerManager.loadPersistedState()

        let response = await managers.makeService().inspect(
            request: Arca_Engine_V1_InspectRequest.with { $0.sandboxID = Self.taggedSandboxID }
        )

        guard case .error(let error) = response.outcome else {
            return XCTFail("a foreign container must be refused, not reported: "
                + "\(String(describing: response.outcome))")
        }
        XCTAssertEqual(
            error.code, "foreign_resource_refused",
            "a container with no gascan labels is foreign whatever its image is; "
                + "invalid_output here would tell the consumer this engine is broken"
        )
        XCTAssertEqual(error.resource, Self.taggedSandboxID)
        XCTAssertEqual(
            error.message,
            "container \(Self.taggedSandboxID) carries no gascan owner labels, so this "
                + "engine cannot assert it is the sandbox that was asked for"
        )
    }

    /// I5's other half: the labels that ARE present are echoed, not invented.
    ///
    /// The brief's ruling is "labels present -> return the Sandbox with them and
    /// let the consumer judge", and `inspect`'s doc comment states it as a
    /// behavioural claim. Nothing pinned it: every other fixture reaching the
    /// sandbox arm carries `gascan` / `ownedSandboxID` and is inspected under
    /// `ownedSandboxID`, so stored labels and labels fabricated from the request
    /// were indistinguishable. MEASURED -- replacing the echo with
    /// `managedBy = "gascan"; sandboxID = sandboxId` left `Executed 71 tests,
    /// with 0 failures`.
    ///
    /// What that fabrication costs is worse than either finding this task fixed.
    /// A container labelled for sandbox B, inspected as sandbox A, would report
    /// `owner.sandbox_id = A`; the consumer's `sandbox_id != id` check
    /// (crates/gascan-arca/src/translate.rs:421-425) never fires, and it adopts
    /// and reconciles another sandbox's container.
    ///
    /// **Both label fields differ from any plausible fabrication, deliberately.**
    /// `managed_by` is a tool this engine has never heard of, because the
    /// contract says the engine stores labels verbatim and NEVER INTERPRETS THEM
    /// (engine.proto:143-148) -- and because the consumer classifies a
    /// `managed_by` that is not `gascan` as `Foreign` on its own
    /// (crates/gascan-core/src/runtime.rs:100). An engine that hardcoded
    /// `"gascan"` would report another tool's container as gascan's and delete
    /// that classification before the consumer could make it.
    ///
    /// The two ids asserted here are `web-a1b2c3d4e5f6` (the envelope, which is
    /// the REQUEST's) and `other-e1f2a3b4c5d6` (the label, which is the STORE's).
    /// Neither is a substring of the other, and the test's whole point is that
    /// they must not be equal.
    func testAContainerLabelledForAnotherSandboxIsReturnedWithTheLabelsTheStoreHolds() async throws {
        let managers = try Self.managers()
        try await Self.seed(
            into: managers.stateStore,
            id: Self.mismatchedContainerID,
            // The NAME is the sandbox id that will be asked for; the LABEL below
            // names a different one. That is the collision under test.
            name: Self.ownedSandboxID,
            image: Self.workspaceRepository + "@sha256:" + Self.ownedDigestHex,
            status: "exited",
            labels: SandboxIdentity.labels(from: Self.mismatchedOwnerLabels),
            portBindings: [:]
        )
        try await managers.containerManager.loadPersistedState()

        let sandbox = try await Self.inspectedSandbox(managers, Self.ownedSandboxID)
        XCTAssertEqual(
            sandbox.owner, Self.mismatchedOwnerLabels,
            "the owner must be the labels the store holds, verbatim; labels built "
                + "from the request would make an ownership mismatch invisible to "
                + "the only component allowed to judge it"
        )
        XCTAssertEqual(
            sandbox.sandboxID, Self.ownedSandboxID,
            "the envelope still answers the id that was asked for -- it is the "
                + "owner labels that disagree with it, and that disagreement is "
                + "the whole signal the consumer acts on"
        )
    }

    // MARK: - The three arms, told apart

    /// `absent`, proved against a service that demonstrably sees state.
    ///
    /// Asserting `.absent` alone is what the version this replaces did, against
    /// a build whose backing state was empty under every input -- so `.absent`
    /// was the only answer it could give and the assertion distinguished
    /// nothing. Here the same service, over the same loaded state, answers all
    /// three arms in one test: a seeded labelled row is the sandbox arm, a
    /// seeded unlabelled row is the error arm, and only the id that was never
    /// seeded is `absent`.
    ///
    /// `absent` is the arm a reconciler reads as "create it", so the error and
    /// absent answers being different messages is the property that keeps a
    /// running sandbox from acquiring a duplicate.
    func testAbsentIsAnsweredOnlyForAnIdTheLoadedStateDoesNotHold() async throws {
        let managers = try Self.managers()
        try await Self.seed(
            into: managers.stateStore,
            id: Self.ownedContainerID,
            name: Self.ownedSandboxID,
            image: Self.workspaceRepository + "@sha256:" + Self.ownedDigestHex,
            status: "exited",
            labels: SandboxIdentity.labels(from: Self.ownerLabels),
            portBindings: [:]
        )
        try await Self.seed(
            into: managers.stateStore,
            id: Self.foreignContainerID,
            name: Self.foreignSandboxID,
            image: Self.workspaceRepository + "@sha256:" + Self.foreignDigestHex,
            status: "exited",
            labels: [:],
            portBindings: [:]
        )
        try await managers.containerManager.loadPersistedState()
        let service = managers.makeService()

        let present = await service.inspect(
            request: Arca_Engine_V1_InspectRequest.with { $0.sandboxID = Self.ownedSandboxID }
        )
        guard case .sandbox(let sandbox) = present.outcome else {
            return XCTFail("this service can see loaded state, or the absent assertion "
                + "below proves nothing: \(String(describing: present.outcome))")
        }
        XCTAssertEqual(sandbox.sandboxID, Self.ownedSandboxID)

        let foreign = await service.inspect(
            request: Arca_Engine_V1_InspectRequest.with { $0.sandboxID = Self.foreignSandboxID }
        )
        guard case .error(let error) = foreign.outcome else {
            return XCTFail("the error arm must be reachable, or 'absent is not the error "
                + "arm' is untested: \(String(describing: foreign.outcome))")
        }
        XCTAssertEqual(error.code, "foreign_resource_refused")

        let missing = await service.inspect(
            request: Arca_Engine_V1_InspectRequest.with { $0.sandboxID = Self.absentSandboxID }
        )
        guard case .absent = missing.outcome else {
            return XCTFail("an id the loaded state does not hold is absent, not an error "
                + "and not a sandbox: \(String(describing: missing.outcome))")
        }
    }

    // MARK: - Bindings the contract cannot carry

    /// A stored binding with no host port is refused, not reported as port 0 and
    /// not dropped.
    ///
    /// `docker run -p 80` records `HostPort: ""`, which
    /// `convertPortBindingsToMappings` parses to a nil `publicPort`. `hostPort =
    /// 0` fabricates a value the store never held, and gascan rejects it as
    /// `port 0 is not a mapping` (crates/gascan-arca/src/translate.rs:370-375)
    /// while blaming the engine's output. Dropping the entry is the other
    /// fabrication: the list gascan compares for drift would then say this
    /// sandbox publishes nothing at all.
    func testAStoredBindingWithNoHostPortIsRefusedRatherThanReportedAsPortZero() async throws {
        let managers = try Self.managers()
        try await Self.seed(
            into: managers.stateStore,
            id: Self.ownedContainerID,
            name: Self.ownedSandboxID,
            image: Self.workspaceRepository + "@sha256:" + Self.ownedDigestHex,
            status: "exited",
            labels: SandboxIdentity.labels(from: Self.ownerLabels),
            portBindings: ["80/tcp": [PortBinding(hostIp: "", hostPort: "")]]
        )
        try await managers.containerManager.loadPersistedState()

        let response = await managers.makeService().inspect(
            request: Arca_Engine_V1_InspectRequest.with { $0.sandboxID = Self.ownedSandboxID }
        )

        guard case .error(let error) = response.outcome else {
            return XCTFail("a binding with no host port has no representation and must be "
                + "refused: \(String(describing: response.outcome))")
        }
        XCTAssertEqual(error.code, "invalid_output")
        XCTAssertEqual(error.resource, Self.ownedSandboxID)
        XCTAssertEqual(
            error.message,
            "port binding <none>:80/tcp is stored with no host port, and the contract "
                + "has no way to report a binding that has none"
        )
    }

    /// A udp binding is refused, not emitted as a tcp publication.
    ///
    /// `PortMapping` is two numbers and no protocol field
    /// (engine.proto:211-217), so a udp binding put on the wire reads as a tcp
    /// publication that does not exist -- and a tcp and a udp binding on the
    /// same two numbers arrive as a duplicate gascan rejects outright
    /// (crates/gascan-arca/src/translate.rs:376-381).
    func testAUdpBindingIsRefusedRatherThanReportedAsATcpPublication() async throws {
        let managers = try Self.managers()
        try await Self.seed(
            into: managers.stateStore,
            id: Self.ownedContainerID,
            name: Self.ownedSandboxID,
            image: Self.workspaceRepository + "@sha256:" + Self.ownedDigestHex,
            status: "exited",
            labels: SandboxIdentity.labels(from: Self.ownerLabels),
            portBindings: ["53/udp": [PortBinding(hostPort: "5353")]]
        )
        try await managers.containerManager.loadPersistedState()

        let response = await managers.makeService().inspect(
            request: Arca_Engine_V1_InspectRequest.with { $0.sandboxID = Self.ownedSandboxID }
        )

        guard case .error(let error) = response.outcome else {
            return XCTFail("a udp binding has no representation and must be refused: "
                + "\(String(describing: response.outcome))")
        }
        XCTAssertEqual(error.code, "invalid_output")
        XCTAssertEqual(error.resource, Self.ownedSandboxID)
        XCTAssertEqual(
            error.message,
            "port binding 5353:53/udp is not tcp, and the contract's PortMapping "
                + "carries no protocol field to say otherwise"
        )
    }

    /// Three stored numbers that are not ports, none of which may reach the wire.
    ///
    /// 70000 and 0 both convert to `UInt32` without complaint, which is why a
    /// bare `UInt32(exactly:)` is not the guard: 0 arrives at gascan as `port 0
    /// is not a mapping` and 70000 as `host port 70000 is out of range`
    /// (crates/gascan-arca/src/translate.rs:358-375), both blaming the engine's
    /// output. -1 is the one that wraps, to 4294967295, under
    /// `UInt32(truncatingIfNeeded:)`.
    ///
    /// Driven against the helper directly because the three cases differ only in
    /// one integer; the path from a stored row to this helper is what the two
    /// tests above prove.
    func testAPortNumberOutsideOneToSixtyFiveThousandFiveHundredAndThirtyFiveIsRefused() {
        XCTAssertEqual(
            sandboxPorts(fromBindings: [PortMapping(privatePort: 70000, publicPort: 8080)]),
            .failure(UnrepresentablePortBinding(
                reason: "port binding 8080:70000/tcp names a number that is not a port"
            ))
        )
        XCTAssertEqual(
            sandboxPorts(fromBindings: [PortMapping(privatePort: 80, publicPort: 0)]),
            .failure(UnrepresentablePortBinding(
                reason: "port binding 0:80/tcp names a number that is not a port"
            ))
        )
        XCTAssertEqual(
            sandboxPorts(fromBindings: [PortMapping(privatePort: -1, publicPort: 8080)]),
            .failure(UnrepresentablePortBinding(
                reason: "port binding 8080:-1/tcp names a number that is not a port"
            ))
        )
    }

    // MARK: - Fixtures

    /// Container ids are 64 characters and must not share their first 32:
    /// `loadPersistedState()` derives the native id from `String(id.prefix(32))`
    /// and keys `reverseMapping` on it, so a collision makes one seed vanish.
    private static let ownedContainerID = String(repeating: "a", count: 64)
    private static let foreignContainerID = String(repeating: "b", count: 64)
    private static let taggedContainerID = String(repeating: "c", count: 64)
    private static let mismatchedContainerID = String(repeating: "d", count: 64)

    /// `SandboxIdentity.containerName(forSandboxId:)` is the identity function,
    /// so these are both the sandbox ids and the seeded container names. Each
    /// contains a hyphen, which keeps `resolveContainerID` from reading it as a
    /// hex short id (`ContainerManager.swift:2005-2023`).
    private static let ownedSandboxID = "web-a1b2c3d4e5f6"
    private static let foreignSandboxID = "foreign-b1c2d3e4f5a6"
    private static let taggedSandboxID = "tagged-c1d2e3f4a5b6"
    private static let absentSandboxID = "missing-d1e2f3a4b5c6"

    private static let workspaceRepository = "ghcr.io/liquescent-development/gascan/workspace"
    private static let ownedDigestHex = String(repeating: "1", count: 64)
    private static let foreignDigestHex = String(repeating: "2", count: 64)

    private static let ownerLabels = Arca_Engine_V1_OwnerLabels.with {
        $0.managedBy = "gascan"
        $0.sandboxID = ownedSandboxID
    }

    /// Labels that agree with nothing the engine could invent: a `managed_by`
    /// this engine has never heard of, and a `sandbox_id` naming a sandbox other
    /// than the one the request asks for.
    private static let mismatchedOwnerLabels = Arca_Engine_V1_OwnerLabels.with {
        $0.managedBy = "another-tool"
        $0.sandboxID = "other-e1f2a3b4c5d6"
    }

    /// The engine's own managers over a throwaway state root -- the production
    /// factory, so what these tests inspect is what `arca-engine` serves.
    ///
    /// `wireCollaborators()` is deliberately not called: `Inspect` reads no
    /// field these tests assert on that needs either collaborator, and leaving
    /// them unset keeps this fixture free of `NetworkManager`. What the network
    /// collaborator costs when unset is asserted in `EngineManagerWiringTests`.
    private static func managers() throws -> EngineManagers {
        try EngineManagers(
            stateRoot: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("arca-inspect-tests-\(UUID().uuidString)"),
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
    /// Labels ride in the config JSON and bindings in the host config JSON,
    /// because those are the two columns the restore path decodes them out of
    /// (`ContainerManager.swift:329-344`).
    private static func seed(
        into store: StateStore,
        id: String,
        name: String,
        image: String,
        status: String,
        labels: [String: String],
        portBindings: [String: [PortBinding]]
    ) async throws {
        let encoder = JSONEncoder()
        try await store.saveContainer(
            id: id,
            name: name,
            image: image,
            imageID: "sha256:probe",
            createdAt: Date(),
            status: status,
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
                    ContainerConfiguration(image: image, labels: labels)
                ),
                as: UTF8.self
            ),
            hostConfigJSON: String(
                decoding: try encoder.encode(HostConfig(portBindings: portBindings)),
                as: UTF8.self
            )
        )
    }

    /// The sandbox arm, or a failure naming the arm that came back instead.
    private static func inspectedSandbox(
        _ managers: EngineManagers,
        _ sandboxID: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> Arca_Engine_V1_Sandbox {
        let response = await managers.makeService().inspect(
            request: Arca_Engine_V1_InspectRequest.with { $0.sandboxID = sandboxID }
        )
        guard case .sandbox(let sandbox) = response.outcome else {
            XCTFail(
                "expected the sandbox arm: \(String(describing: response.outcome))",
                file: file, line: line
            )
            throw XCTSkip("no sandbox arm to assert on")
        }
        return sandbox
    }
}
