import ContainerBridge
import SandboxEngineProto
import XCTest
@testable import ArcaEngine

/// `sandboxContainerSpec(for:image:)`: every `CreateRequest` field translated or
/// refused.
///
/// **These are the half of `Create` that a VM cannot help with, and the half a
/// VM would hide.** `createContainer` guards on `nativeManager`
/// (`ContainerManager.swift:1659`), which `initialize()` assigns and
/// `initialize()` builds a live `Containerization.VmnetNetwork`, so no test in
/// this target reaches the call. That is not the reason these exist, though: a
/// test that booted a sandbox and then read its config back would prove the
/// translation only where ContainerBridge chose to store it, and would say
/// nothing at all about the fields that are refused -- a refusal produces no
/// sandbox to inspect.
///
/// So the arguments `createContainer` is handed are asserted as a value, here,
/// and what ContainerBridge does with them afterwards is ContainerBridge's own
/// behaviour. `create(request:)` builds exactly one of these and passes exactly
/// these fields; there is no parallel path in which the two could differ.
final class CreateTranslationTests: XCTestCase {
    private static let sandboxId = "gascan-sbx-4f2a-9c11"
    private static let image = "workspace@sha256:" + String(repeating: "a", count: 64)

    // MARK: - The identity the container is created under

    /// The container is named the sandbox id and carries the owner labels
    /// verbatim.
    ///
    /// Both halves are exact equalities rather than "contains": gascan builds
    /// the expected container identity as the request id itself
    /// (`crates/gascan-core/src/runtime.rs:954`) and discards any created
    /// resource whose ownership is not its own (`:962-975`), so a prefix, a
    /// suffix, or a third label makes every create fail on the consumer's side
    /// rather than degrade.
    ///
    /// The label values are deliberately NOT the sandbox id here. The engine
    /// stores what it is given and never interprets it (engine.proto:143-148),
    /// and a fixture whose `sandbox_id` label happened to equal the request's
    /// `sandbox_id` field would pass just as well against an engine that
    /// synthesised the labels from the request and ignored `owner` entirely.
    func testTheContainerIsNamedTheSandboxIdAndCarriesTheOwnerLabelsVerbatim() throws {
        let spec = try translated(Self.request(owner: Self.owner(
            managedBy: "some-other-manager", sandboxId: "some-other-id"
        )))

        XCTAssertEqual(spec.name, Self.sandboxId)
        XCTAssertEqual(spec.labels, [
            "dev.gascan.managed-by": "some-other-manager",
            "dev.gascan.sandbox-id": "some-other-id",
        ])
    }

    /// A half-set `OwnerLabels` is refused rather than stored.
    ///
    /// An engine that created three volumes and a container under an empty
    /// `managed_by` would report them all and have the whole report discarded
    /// by the consumer (`runtime.rs:962-975`) -- four resources on the host and
    /// a failure that names none of them.
    func testAHalfSetOwnerIsRefused() {
        let refusal = Self.refusal(of: Self.request(owner: Self.owner(
            managedBy: "gascan", sandboxId: ""
        )))
        XCTAssertEqual(refusal?.code, "invalid_resource_identity")
        XCTAssertEqual(refusal?.resource, Self.sandboxId)
    }

    /// The carried-over finding from Task 7: a pure-hex sandbox id is refused.
    ///
    /// `resolveContainerID` prefix-matches any hex string of four or more
    /// characters against every container the engine holds and returns
    /// `matches.sorted().first` on more than one hit
    /// (`ContainerManager.swift:2005-2023`). While every method was read-only
    /// that cost a wrong report; `Create` acts on the match.
    ///
    /// The second half is what makes the first mean something: one hyphen is the
    /// only difference between the two ids, and it is exactly the character that
    /// takes a real gascan id off that path.
    func testAPureHexSandboxIdIsRefusedAndOneHyphenIsEnoughToBeAccepted() throws {
        let hex = "deadbeefcafe"
        let refusal = Self.refusal(of: Self.request(sandboxId: hex))
        XCTAssertEqual(refusal?.code, "invalid_resource_identity")
        XCTAssertEqual(refusal?.resource, hex)

        let hyphenated = "deadbeef-cafe"
        let spec = try translated(Self.request(sandboxId: hyphenated))
        XCTAssertEqual(spec.name, hyphenated)
    }

    // MARK: - Network

    /// Offline means no network attachment, and `none` is the mode that means
    /// it.
    ///
    /// The pairing is the assertion. `startContainer` skips auto-attachment for
    /// exactly two modes, `none` and `host` (`ContainerManager.swift:2356`), and
    /// auto-attaches to `bridge` for everything else including the empty string
    /// and `default` (`:2359-2363`). So "offline" and "networked" must land on
    /// different sides of that test, and a translation that emitted `""` for
    /// offline would attach it to the default bridge -- an offline sandbox with
    /// egress, reported as created.
    func testOfflineAttachesNoNetworkAndANamedNetworkIsAttachedByName() throws {
        let offline = try translated(Self.request(network: .offline(Arca_Engine_V1_Offline())))
        XCTAssertEqual(offline.networkMode, "none")

        let named = try translated(Self.request(network: .networkedName("sbx-net")))
        XCTAssertEqual(named.networkMode, "sbx-net")
    }

    /// A request that states no network mode is refused rather than defaulted.
    ///
    /// An unset `oneof` arrives as nil, and the tempting default is offline --
    /// which would silently give a sandbox that asked for a network no egress,
    /// or, if the default went the other way, give an offline sandbox egress.
    func testAnUnsetNetworkModeIsRefused() {
        var request = Self.request()
        request.network.mode = nil
        XCTAssertEqual(Self.refusal(of: request)?.code, "invalid_state")
    }

    // MARK: - Ports

    /// Ports publish on loopback, and the binding is written in the form the
    /// publisher needs.
    ///
    /// `127.0.0.1` is not cosmetic here: `PortMapManager` spawns the userspace
    /// proxy that makes a host port reachable only for a loopback host address
    /// (`PortMapManager.swift:105-107`), and `PortBinding`'s own default is
    /// `0.0.0.0` (`Types.swift:303`) -- so a translation that omitted the
    /// address would take the nftables-only path and publish nothing a host
    /// process could connect to.
    ///
    /// This asserts the INPUT to publication and nothing more. Whether a port is
    /// then actually published passes through two further gates that need a
    /// booted VM to see; see `EngineManagers.wireCollaborators()`.
    func testPortsAreWrittenAsLoopbackBindingsKeyedByGuestPort() throws {
        let spec = try translated(Self.request(ports: [(host: 18080, guest: 8080)]))

        XCTAssertEqual(spec.portBindings.keys.sorted(), ["8080/tcp"])
        let binding = try XCTUnwrap(spec.portBindings["8080/tcp"]?.first)
        XCTAssertEqual(binding.hostIp, "127.0.0.1")
        XCTAssertEqual(binding.hostPort, "18080")
    }

    /// A guest port mapped twice is refused rather than silently collapsed.
    ///
    /// The bindings are a dictionary keyed by guest port, so the second mapping
    /// would overwrite the first and the consumer would never hear that one of
    /// the ports it asked for was dropped. The consumer refuses a repeated HOST
    /// port itself (`crates/gascan-arca/src/translate.rs:120-125`) and says
    /// nothing about the guest side, so this is the only place it can be caught.
    func testAGuestPortMappedTwiceIsRefused() {
        let refusal = Self.refusal(of: Self.request(ports: [
            (host: 18080, guest: 8080), (host: 18081, guest: 8080),
        ]))
        XCTAssertEqual(refusal?.code, "invalid_state")
        XCTAssertEqual(
            refusal?.message,
            "guest port 8080 is mapped twice, and a container's port bindings are keyed by "
                + "guest port, so one of the two would be lost"
        )
    }

    /// And a host port mapped twice, which would collide in the publisher's own
    /// allocation table (`PortMapManager.swift:93-101`).
    func testAHostPortMappedTwiceIsRefused() {
        let refusal = Self.refusal(of: Self.request(ports: [
            (host: 18080, guest: 8080), (host: 18080, guest: 9090),
        ]))
        XCTAssertEqual(refusal?.code, "invalid_state")
        XCTAssertEqual(refusal?.message, "host port 18080 is mapped twice")
    }

    /// Zero is not a port. `PortMapping` is `uint32` on the wire, so it is
    /// representable, and `UInt16(0)` would convert cleanly into a binding that
    /// means nothing.
    func testPortZeroIsRefused() {
        XCTAssertEqual(
            Self.refusal(of: Self.request(ports: [(host: 0, guest: 8080)]))?.code, "invalid_state"
        )
        XCTAssertEqual(
            Self.refusal(of: Self.request(ports: [(host: 18080, guest: 0)]))?.code, "invalid_state"
        )
    }

    // MARK: - Mounts and volumes

    /// The project mount and the named volumes become binds, project first.
    func testTheProjectMountAndTheVolumesBecomeBinds() throws {
        let spec = try translated(Self.request(volumes: [
            (name: "gascan-cache-x", path: "/home/workspace/.cache", capacity: 1 << 30),
        ]))
        XCTAssertEqual(spec.binds, [
            "/Users/someone/project:/workspace",
            "gascan-cache-x:/home/workspace/.cache",
        ])
    }

    /// A guest path that is not absolute is refused.
    ///
    /// `parseVolumeMounts` splits a bind on `:` and decides "named volume or
    /// host path" by whether the source looks like a path
    /// (`ContainerManager.swift:3767`); a relative guest path would be accepted
    /// there and mounted somewhere the consumer did not ask for.
    func testARelativeGuestPathIsRefused() {
        let refusal = Self.refusal(of: Self.request(volumes: [
            (name: "gascan-cache-x", path: "home/workspace/.cache", capacity: 1 << 30),
        ]))
        XCTAssertEqual(refusal?.code, "invalid_state")
        XCTAssertEqual(refusal?.resource, "gascan-cache-x")
    }

    /// A request with no project mount is refused rather than creating a
    /// sandbox with no project in it.
    ///
    /// `ProjectMount` is a message, so an unset one arrives with both paths
    /// empty and is indistinguishable from one that was never set.
    func testAMissingProjectMountIsRefused() {
        var request = Self.request()
        request.project = Arca_Engine_V1_ProjectMount()
        XCTAssertEqual(Self.refusal(of: request)?.code, "invalid_state")
    }

    /// A capacity picks the one driver that can honour it; no capacity picks the
    /// one that cannot.
    ///
    /// `local` is a VirtioFS directory share with no size at all
    /// (`VolumeManager.swift:126-158`), so a sized volume created on it would be
    /// a limit the consumer asked for and nothing enforces.
    func testACapacityPicksTheBlockDriverAndNoCapacityPicksLocal() {
        let sized = volumeDriver(forCapacityBytes: 1 << 30)
        XCTAssertEqual(sized.driver, "block")
        XCTAssertEqual(sized.options, ["size": "1073741824"])

        let unsized = volumeDriver(forCapacityBytes: 0)
        XCTAssertEqual(unsized.driver, "local")
        XCTAssertNil(unsized.options)
    }

    // MARK: - Environment, user, limits, init

    /// Environment arrives as `NAME=value`, and a name carrying `=` is refused.
    ///
    /// Accepting it would put a different variable in the guest than the one the
    /// consumer named, with no error anywhere.
    func testEnvironmentIsNameEqualsValueAndANameCarryingEqualsIsRefused() throws {
        let spec = try translated(Self.request(environment: [("TERM", "xterm"), ("LANG", "")]))
        XCTAssertEqual(spec.env, ["TERM=xterm", "LANG="])

        XCTAssertEqual(
            Self.refusal(of: Self.request(environment: [("A=B", "c")]))?.code, "invalid_state"
        )
    }

    /// The two limits this engine applies, in the units ContainerBridge takes.
    ///
    /// `nanoCpus` is whole CPUs times 1e9, which overflows 32 bits at five CPUs,
    /// so the widening is asserted with a value that would be wrong if the
    /// multiply happened before it.
    func testCpusAndMemoryReachContainerBridgeInItsOwnUnits() throws {
        var request = Self.request()
        request.resources.cpus = 8
        request.resources.memoryBytes = 4 << 30
        let spec = try translated(request)

        XCTAssertEqual(spec.nanoCpus, 8_000_000_000)
        XCTAssertEqual(spec.memory, 4_294_967_296)
    }

    /// Unset limits stay unset rather than becoming zero.
    ///
    /// `createContainer` writes `memory ?? 0` into the stored `HostConfig`
    /// (`ContainerManager.swift:1918`) and treats a zero as "unspecified"
    /// (`:1666`), so the distinction only survives if nil arrives as nil.
    func testUnsetLimitsAreNotTranslatedAsZero() throws {
        let spec = try translated(Self.request())
        XCTAssertNil(spec.nanoCpus)
        XCTAssertNil(spec.memory)
    }

    /// The two limits this engine cannot apply are refused, not dropped.
    ///
    /// `unsupported_capability` rather than a bad-request code: the request is
    /// not wrong, this build is short, and the two codes tell a consumer
    /// opposite things about whether to change the request or give up. The
    /// sibling backend refuses the same two
    /// (`crates/gascan-apple/src/translate.rs:214-219`).
    func testADiskOrProcessLimitIsRefusedAsUnsupported() {
        var disk = Self.request()
        disk.resources.diskBytes = 1 << 40
        XCTAssertEqual(Self.refusal(of: disk)?.code, "unsupported_capability")

        var processes = Self.request()
        processes.resources.processCount = 512
        XCTAssertEqual(Self.refusal(of: processes)?.code, "unsupported_capability")
    }

    /// Both users the contract names are translated; an unspecified one is
    /// refused rather than defaulted to root.
    func testBothUsersTranslateAndAnUnspecifiedUserIsRefused() throws {
        XCTAssertEqual(try translated(Self.request(user: .workspace)).user, "workspace")
        XCTAssertEqual(try translated(Self.request(user: .root)).user, "root")
        XCTAssertEqual(Self.refusal(of: Self.request(user: .unspecified))?.code, "invalid_state")
    }

    /// `init: false` is refused, because this engine cannot serve it.
    ///
    /// Every Arca container is a VM whose PID 1 is vminitd
    /// (`ContainerManager.swift:1946`), so there is no init to switch off and no
    /// parameter on `createContainer` that would switch it off. Accepting the
    /// request and creating a sandbox with an init anyway is the silent
    /// divergence the refusal exists to prevent.
    func testACreateWithoutAnInitIsRefused() {
        var request = Self.request()
        request.init_p = false
        let refusal = Self.refusal(of: request)
        XCTAssertEqual(refusal?.code, "unsupported_capability")
        XCTAssertEqual(
            refusal?.message,
            "this engine runs every workspace process under vminitd as PID 1 and cannot "
                + "create a sandbox without an init"
        )
    }

    // MARK: - Fixtures

    private func translated(
        _ request: Arca_Engine_V1_CreateRequest
    ) throws -> SandboxContainerSpec {
        switch sandboxContainerSpec(for: request, image: Self.image) {
        case .success(let spec):
            return spec
        case .failure(let error):
            XCTFail("expected a translation, got \(error.code): \(error.message)")
            throw error
        }
    }

    private static func refusal(
        of request: Arca_Engine_V1_CreateRequest
    ) -> Arca_Engine_V1_EngineError? {
        switch sandboxContainerSpec(for: request, image: image) {
        case .success: return nil
        case .failure(let error): return error
        }
    }

    private static func owner(
        managedBy: String = "gascan", sandboxId: String = CreateTranslationTests.sandboxId
    ) -> Arca_Engine_V1_OwnerLabels {
        Arca_Engine_V1_OwnerLabels.with {
            $0.managedBy = managedBy
            $0.sandboxID = sandboxId
        }
    }

    /// A create every field of which is valid, so that each test above changes
    /// exactly the one thing it is about.
    static func request(
        sandboxId: String = CreateTranslationTests.sandboxId,
        owner: Arca_Engine_V1_OwnerLabels = CreateTranslationTests.owner(),
        volumes: [(name: String, path: String, capacity: UInt64)] = [],
        ports: [(host: UInt32, guest: UInt32)] = [],
        environment: [(String, String)] = [],
        network: Arca_Engine_V1_Network.OneOf_Mode = .offline(Arca_Engine_V1_Offline()),
        user: Arca_Engine_V1_User = .workspace
    ) -> Arca_Engine_V1_CreateRequest {
        Arca_Engine_V1_CreateRequest.with { request in
            request.sandboxID = sandboxId
            request.owner = owner
            request.project = Arca_Engine_V1_ProjectMount.with {
                $0.hostPath = "/Users/someone/project"
                $0.guestPath = "/workspace"
            }
            request.volumes = volumes.map { volume in
                Arca_Engine_V1_Volume.with {
                    $0.name = volume.name
                    $0.guestPath = volume.path
                    $0.capacityBytes = volume.capacity
                }
            }
            request.ports = ports.map { port in
                Arca_Engine_V1_PortMapping.with {
                    $0.hostPort = port.host
                    $0.guestPort = port.guest
                }
            }
            request.environment = environment.map { variable in
                Arca_Engine_V1_EnvironmentVariable.with {
                    $0.name = variable.0
                    $0.value = variable.1
                }
            }
            request.network = Arca_Engine_V1_Network.with { $0.mode = network }
            request.user = user
            request.init_p = true
        }
    }
}
