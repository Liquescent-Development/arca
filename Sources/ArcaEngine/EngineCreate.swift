import ContainerBridge
import SandboxEngineProto

/// Everything `ContainerManager.createContainer` is given for one sandbox,
/// translated once and in one place.
///
/// **This type exists to make the pure half of `Create` provable.**
/// `createContainer` guards on `nativeManager` (`ContainerManager.swift:1659`),
/// which is assigned only inside `initialize()`, which constructs a live
/// `Containerization.VmnetNetwork` and needs the virtualization entitlement --
/// so no test in this target may reach the call. Every decision that turns a
/// `CreateRequest` into these arguments is a decision that can be wrong
/// independently of whether a VM boots, and holding them in a value lets each
/// one be asserted directly rather than inferred from a sandbox that ran.
///
/// It is not a second construction path. `create(request:)` builds exactly one
/// of these and passes exactly these fields; there is no arrangement in which a
/// test's spec and the engine's spec can differ.
package struct SandboxContainerSpec {
    /// The reference `createContainer` resolves the image by AND records as
    /// `ContainerInfo.image`. One string doing both jobs is the constraint that
    /// decided Problem 1 -- see `heldImageReferences(for:)`.
    package let image: String
    package let name: String
    package let env: [String]
    package let labels: [String: String]
    package let networkMode: String
    package let binds: [String]
    package let portBindings: [String: [PortBinding]]
    package let memory: Int64?
    package let nanoCpus: Int64?
    package let user: String?
}

/// One create request as ContainerBridge arguments, or the first thing about it
/// this engine will not do.
///
/// **Every field of `CreateRequest` is either translated here or refused here.**
/// Silently dropping one is the failure this whole milestone is arranged
/// against: an engine that ignores `resources` reports a successful `Create`,
/// and `Inspect` -- which reports what the store holds -- then agrees with it,
/// so nothing downstream can tell that no limit was applied. The sibling backend
/// takes the same position and is the precedent for which fields are refused
/// rather than approximated (`crates/gascan-apple/src/translate.rs:172-233`).
///
/// The codes are chosen for what the consumer does with them
/// (`crates/gascan-arca/src/error.rs`): `invalid_resource_identity` for a name
/// this engine cannot accept as an identity, `invalid_state` for a request field
/// that is well-formed as a string but not as a request, and
/// `unsupported_capability` for the three things this engine cannot do at all.
/// A capability refusal is a final answer about the build; an identity refusal
/// is a final answer about the request. Collapsing them would make a consumer
/// retry the one it should give up on.
///
/// `image` is a parameter rather than something derived here because resolving
/// it requires the image store, and this function is deliberately pure.
package func sandboxContainerSpec(
    for request: Arca_Engine_V1_CreateRequest,
    image: String
) -> Result<SandboxContainerSpec, Arca_Engine_V1_EngineError> {
    let name = SandboxIdentity.containerName(forSandboxId: request.sandboxID)

    if let reason = SandboxIdentity.refusalReason(forSandboxId: request.sandboxID) {
        return .failure(engineError(
            .invalidResourceIdentity, resource: request.sandboxID, message: reason
        ))
    }

    // Well-formedness, not interpretation. The engine stores labels verbatim and
    // never decides whether a labelled resource is the caller's
    // (engine.proto:143-148), so there is deliberately NO comparison of
    // `owner.sandboxID` against `request.sandboxID` here -- that judgment is the
    // consumer's and it makes it itself (`translate.rs:421-425`). What this does
    // refuse is a half-set `OwnerLabels`, because every resource below is
    // reported back carrying these labels and gascan discards a created resource
    // whose ownership does not read as its own (`runtime.rs:962-975`). An
    // engine that created three volumes under empty labels would report them and
    // have the report thrown away -- a leak with a success next to it.
    guard !request.owner.managedBy.isEmpty, !request.owner.sandboxID.isEmpty else {
        return .failure(engineError(
            .invalidResourceIdentity,
            resource: name,
            message: "create requires both owner labels; this request carries "
                + "managed_by '\(request.owner.managedBy)' and sandbox_id "
                + "'\(request.owner.sandboxID)', and a resource created under a half-set "
                + "owner is one the consumer cannot recognise as its own"
        ))
    }
    let labels = SandboxIdentity.labels(from: request.owner)

    // The one mount, and it is not optional. `ProjectMount` is singular in the
    // contract because "a project root is permitted and nothing else"
    // (engine.proto:190-193); an unset message arrives with both paths empty,
    // which would silently create a sandbox with no project in it.
    guard request.project.hostPath.hasPrefix("/"), request.project.guestPath.hasPrefix("/") else {
        return .failure(engineError(
            .invalidState,
            resource: name,
            message: "the project mount needs an absolute host path and an absolute guest "
                + "path; this request carries '\(request.project.hostPath)' and "
                + "'\(request.project.guestPath)'"
        ))
    }
    var binds = ["\(request.project.hostPath):\(request.project.guestPath)"]

    for volume in request.volumes {
        guard !volume.name.isEmpty else {
            return .failure(engineError(
                .invalidResourceIdentity,
                resource: name,
                message: "a volume in this request carries no name"
            ))
        }
        guard volume.guestPath.hasPrefix("/") else {
            return .failure(engineError(
                .invalidState,
                resource: volume.name,
                message: "volume \(volume.name) needs an absolute guest path and carries "
                    + "'\(volume.guestPath)'"
            ))
        }
        binds.append("\(volume.name):\(volume.guestPath)")
    }

    // Keyed by guest port, so two mappings on one guest port would collapse into
    // whichever the iteration reached last -- a published port the consumer
    // asked for and never hears was dropped. The consumer refuses a repeated
    // HOST port on its own side (`translate.rs:120-125`) and says nothing about
    // the guest side, so this is the only place a guest-port collision can be
    // caught. Both directions are refused here rather than one.
    var portBindings: [String: [PortBinding]] = [:]
    var hostPorts: Set<UInt32> = []
    for port in request.ports {
        guard (1...65535).contains(port.guestPort), (1...65535).contains(port.hostPort) else {
            return .failure(engineError(
                .invalidState,
                resource: name,
                message: "port mapping \(port.hostPort):\(port.guestPort) names a number that "
                    + "is not a port"
            ))
        }
        guard hostPorts.insert(port.hostPort).inserted else {
            return .failure(engineError(
                .invalidState,
                resource: name,
                message: "host port \(port.hostPort) is mapped twice"
            ))
        }
        // Loopback is implied by the contract and is not a field
        // (engine.proto:207-209). It is also what makes the mapping work at all:
        // `PortMapManager.shouldSpawnProxy(for:)` spawns the userspace proxy
        // only for a loopback host address, so a binding recorded as 0.0.0.0 --
        // `PortBinding`'s own default (`Types.swift:303`) -- takes the
        // nftables-only path instead.
        let key = "\(port.guestPort)/tcp"
        guard portBindings[key] == nil else {
            return .failure(engineError(
                .invalidState,
                resource: name,
                message: "guest port \(port.guestPort) is mapped twice, and a container's "
                    + "port bindings are keyed by guest port, so one of the two would be lost"
            ))
        }
        portBindings[key] = [PortBinding(hostIp: "127.0.0.1", hostPort: "\(port.hostPort)")]
    }

    // `NAME=value` is the only shape ContainerBridge accepts, so a name that
    // already contains `=` would arrive in the guest as a different variable
    // than the one that was asked for.
    var env: [String] = []
    for variable in request.environment {
        guard !variable.name.isEmpty, !variable.name.contains("=") else {
            return .failure(engineError(
                .invalidState,
                resource: name,
                message: "environment variable name '\(variable.name)' is empty or contains "
                    + "'=', and environment is passed as NAME=value"
            ))
        }
        env.append("\(variable.name)=\(variable.value)")
    }

    // Two limits this engine applies and two it cannot. Refused rather than
    // dropped, and refused as `unsupported_capability` rather than as a bad
    // request, because the request is not wrong -- this build is short. The
    // Apple backend refuses the same two (`translate.rs:214-219`).
    if request.resources.hasDiskBytes {
        return .failure(engineError(
            .unsupportedCapability,
            resource: name,
            message: "this engine cannot apply a disk limit"
        ))
    }
    if request.resources.hasProcessCount {
        return .failure(engineError(
            .unsupportedCapability,
            resource: name,
            message: "this engine cannot apply a process-count limit"
        ))
    }

    // `nanoCpus` is Docker's unit and the one ContainerBridge takes: whole CPUs
    // times 1e9. Multiplied in Int64 after widening, because a `UInt32` count
    // times a billion leaves 32 bits far behind.
    let nanoCpus = request.resources.hasCpus ? Int64(request.resources.cpus) * 1_000_000_000 : nil
    let memory = request.resources.hasMemoryBytes ? Int64(request.resources.memoryBytes) : nil

    let user: String
    switch request.user {
    case .workspace: user = "workspace"
    case .root: user = "root"
    default:
        return .failure(engineError(
            .invalidState,
            resource: name,
            message: "create must name the user the workspace process runs as, and this "
                + "request names none"
        ))
    }

    // **`init: true` is honoured by Arca's architecture rather than by a flag,
    // and `init: false` is the case this engine cannot serve.** Every Arca
    // container is a VM whose PID 1 is vminitd (`ContainerManager.swift:1946`,
    // "Containers run as PID 1 in their VM"), so the workspace process already
    // runs under an init that reaps for it, and there is no parameter on
    // `createContainer` to switch off. Answering a request for no init with a
    // sandbox that has one is the silent divergence this file exists to avoid.
    // gascan only ever asks for `true` (`translate.rs:229-231` refuses to build
    // a create that does not), so this refuses nothing it sends.
    guard request.init_p else {
        return .failure(engineError(
            .unsupportedCapability,
            resource: name,
            message: "this engine runs every workspace process under vminitd as PID 1 and "
                + "cannot create a sandbox without an init"
        ))
    }

    // Offline is the absence of an attachment, expressed as the networkMode
    // `startContainer` skips auto-attachment for (`ContainerManager.swift:2356`)
    // -- "none" and "host" are the two it skips, and "none" is the one that also
    // means no vmnet interface.
    let networkMode: String
    switch request.network.mode {
    case .offline:
        networkMode = "none"
    case .networkedName(let networkName):
        guard !networkName.isEmpty else {
            return .failure(engineError(
                .invalidResourceIdentity,
                resource: name,
                message: "a networked sandbox must name its network and this one names none"
            ))
        }
        networkMode = networkName
    case nil:
        return .failure(engineError(
            .invalidState,
            resource: name,
            message: "create must state a network mode -- offline or a named network -- and "
                + "this request states neither"
        ))
    }

    return .success(SandboxContainerSpec(
        image: image,
        name: name,
        env: env,
        labels: labels,
        networkMode: networkMode,
        binds: binds,
        portBindings: portBindings,
        memory: memory,
        nanoCpus: nanoCpus,
        user: user
    ))
}

/// The driver options one requested volume needs.
///
/// `capacity_bytes` is the contract's only sizing field and ContainerBridge has
/// exactly one driver that can honour it: `block` formats an EXT4 image at
/// `driverOpts["size"]` (`VolumeManager.swift:165-195`), while `local` is a
/// VirtioFS directory share with no size at all (`:126-158`). So a capacity is
/// a block volume and no capacity is a local one. This mirrors the sibling
/// backend, which passes the same number as `container volume create -s`
/// (`crates/gascan-apple/src/backend.rs:300`).
///
/// Zero is "no capacity was declared", which is the only reading available: the
/// field is a bare `uint64` (engine.proto:200), so an unset one and a requested
/// zero are the same bytes on the wire, and a zero-byte volume is not a thing to
/// create in preference to an unsized one.
package func volumeDriver(forCapacityBytes bytes: UInt64) -> (driver: String, options: [String: String]?) {
    guard bytes > 0 else { return ("local", nil) }
    // `parseSizeString` reads a bare number as bytes (`VolumeManager.swift:552-557`),
    // which is the unit the contract carries, so no unit suffix is appended.
    return ("block", ["size": "\(bytes)"])
}
