import ContainerBridge
import SandboxEngineProto

/// Reads the leading `major.minor.patch` of a version string.
///
/// Returns nil rather than guessing: Gas Can refuses to drive an engine version
/// it does not recognise (contract §9), and a version invented from an
/// unparseable string would defeat that refusal by making every engine look
/// recognisable.
public func engineVersion(from string: String) -> Arca_Engine_V1_Version? {
    let core = string.split(separator: "-", maxSplits: 1).first.map(String.init) ?? string
    let parts = core.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 3 else { return nil }
    guard let major = UInt32(parts[0]), let minor = UInt32(parts[1]), let patch = UInt32(parts[2])
    else { return nil }
    var version = Arca_Engine_V1_Version()
    version.major = major
    version.minor = minor
    version.patch = patch
    return version
}

/// The hex half of a digest, as the contract spells it: bare, lowercase, and
/// exactly 64 characters, with no "sha256:" prefix (engine.proto:179-185).
///
/// One predicate rather than one per direction. Both directions below decide
/// the same question, and two copies of it are two chances for the engine to
/// accept on the way in what it refuses on the way out.
///
/// `isASCII` first, and it is load-bearing rather than defensive: Swift's
/// `Character.isNumber` is true for every Unicode number, so without it a run
/// of 64 ARABIC-INDIC DIGIT THREEs (U+0663) passes a gate whose own
/// documentation and whose refusal message both say "hex". No store can hold
/// such a digest, so the only consequence was a `not_found` where an
/// `invalid_resource_identity` belonged -- but a predicate that admits what its
/// name forbids is one a later `Ack` could be built on, and it made two
/// shipped sentences say more than the code enforced.
private func isSHA256Hex(_ hex: String) -> Bool {
    hex.count == 64 && hex.allSatisfy { $0.isASCII && ($0.isNumber || ("a"..."f").contains($0)) }
}

/// Splits an exact digest reference into the two fields the contract carries.
///
/// A tag is not representable on the wire, so a reference that is not an exact
/// digest has nothing to map to and is refused.
public func imageDigest(fromReference reference: String) -> Arca_Engine_V1_ImageDigest? {
    guard let separator = reference.range(of: "@sha256:", options: .backwards) else { return nil }
    let repository = String(reference[reference.startIndex..<separator.lowerBound])
    let hex = String(reference[separator.upperBound...])
    guard !repository.isEmpty, isSHA256Hex(hex) else { return nil }
    var digest = Arca_Engine_V1_ImageDigest()
    digest.repository = repository
    digest.sha256Hex = hex
    return digest
}

/// A wire digest as the reference an operator would go looking for.
///
/// The exact inverse of `imageDigest(fromReference:)` above, and here rather
/// than spelt out at its call sites so the two cannot drift into disagreeing
/// about what the canonical form is. Used for the `resource` field of a
/// failure, which names "the resource the failure is about"
/// (engine.proto:66-67) -- and for a request that names content, the thing the
/// failure is about is the content, not the RPC.
///
/// Total, deliberately: this is what a refusal *echoes*, so it has to be able
/// to echo a request that is itself malformed. Validity is
/// `imageStoreDigest(_:)`'s question, one function down.
public func imageReference(forDigest digest: Arca_Engine_V1_ImageDigest) -> String {
    "\(digest.repository)@sha256:\(digest.sha256Hex)"
}

/// The image store's lookup key for a wire digest, or nil when the wire digest
/// is not one.
///
/// Refusing rather than passing a malformed digest through to a lookup that
/// would simply match nothing: the two answers are "you sent nonsense" and "the
/// engine does not hold that", and a consumer acts differently on each --
/// `not_found` is a final answer about content whose fix is to send the
/// content. `ImageDigest` is a message, so an *unset* one arrives here with
/// both fields empty and is refused by the same guard.
///
/// The `sha256:` prefix belongs to the store and not to the wire: the contract
/// carries bare hex "with no sha256: prefix" (engine.proto:182-183), while
/// Containerization records a descriptor digest prefixed. This is the one place
/// that conversion happens.
public func imageStoreDigest(_ digest: Arca_Engine_V1_ImageDigest) -> String? {
    guard !digest.repository.isEmpty, isSHA256Hex(digest.sha256Hex) else { return nil }
    return "sha256:\(digest.sha256Hex)"
}

/// The repository half of a stored image reference, split the way the consumer
/// splits its own.
///
/// The rule is Gas Can's, mirrored: `immutable_image_identity`
/// (crates/gascan-core/src/runtime.rs:704-715) drops anything from `@sha256:`
/// onward, then drops a tag -- the last `:` that comes after the last `/`, so
/// that the port in `registry.example:5000/repo` is not mistaken for one. The
/// two sides have to split identically, or the comparison they meet in is
/// decided by punctuation rather than by identity.
///
/// This is NOT the split `imageDigest(fromReference:)` performs one direction
/// up, which keeps a tag inside the repository it reports. That asymmetry is
/// real; it belongs to the Inspect path and is recorded rather than changed
/// here.
public func imageRepository(ofReference reference: String) -> String {
    let name = reference.range(of: "@sha256:", options: .backwards)
        .map { String(reference[reference.startIndex..<$0.lowerBound]) } ?? reference
    guard let tagSeparator = name.lastIndex(of: ":") else { return name }
    if let slash = name.lastIndex(of: "/"), tagSeparator < slash { return name }
    return String(name[name.startIndex..<tagSeparator])
}

/// Maps ContainerBridge's status string onto the contract's three states.
///
/// UNSPECIFIED for anything unrecognised rather than a guess: a paused or
/// restarting sandbox is neither running nor stopped, and reporting it as
/// either would have a reconciler act on a guess -- destroying live work if
/// the guess were wrong. UNSPECIFIED reaches the consumer as a hard
/// UnknownActualState error naming the state
/// (crates/gascan-arca/src/translate.rs:399-409), which is the correct
/// outcome here, not a defect to route around.
public func sandboxState(fromStatus status: String) -> Arca_Engine_V1_SandboxState {
    switch status {
    case "created": return .creating
    case "running": return .running
    case "exited", "dead": return .stopped
    default: return .unspecified
    }
}

/// A stored port binding the contract has no field to carry.
///
/// Carried out rather than swallowed because there is no third answer available:
/// `Sandbox.ports` is a plain `repeated PortMapping` (engine.proto:343) with no
/// way to say "there is a binding here I cannot name", and `InspectResponse`'s
/// three arms are sandbox, absent, and error (engine.proto:358-365). A sandbox
/// arm carrying a port list that silently omits or invents a binding is the one
/// outcome that cannot be detected downstream, so the refusal is the answer.
///
/// `reason` becomes the engine error's `message`: prose, never parsed
/// (EngineErrors.swift:32-35), naming the binding so an operator knows which
/// stored row to look at.
public struct UnrepresentablePortBinding: Error, Equatable {
    public let reason: String

    public init(reason: String) {
        self.reason = reason
    }
}

/// A port number the wire can carry, or nil.
///
/// The field is `uint32` (engine.proto:214-215) but a TCP port is 1...65535, so
/// three stored values have no representation: a negative, a number above
/// 65535, and 0. The first two would wrap or trap on a bare `UInt32(_:)`
/// conversion; 0 would convert cleanly and mean nothing -- the consumer reads it
/// back as `port 0 is not a mapping`
/// (crates/gascan-arca/src/translate.rs:370-375), blaming the engine's output
/// for a number the store never held as a port.
private func wirePort(_ value: Int) -> UInt32? {
    guard (1...65535).contains(value) else { return nil }
    return UInt32(value)
}

/// The binding as prose, for whichever refusal names it.
private func describe(_ binding: PortMapping) -> String {
    "\(binding.publicPort.map(String.init) ?? "<none>"):\(binding.privatePort)/\(binding.type)"
}

/// A sandbox's published ports, or the first binding that cannot be one.
///
/// The input is `ContainerManager.convertPortBindingsToMappings`' output, which
/// is the parse of the stored `hostConfig.portBindings`. The output is the
/// contract's `PortMapping`, and the two do not have the same shape: the stored
/// side carries an optional host port, a protocol, and a bind address
/// (`Types.swift:53-58`), and the wire side carries two numbers and nothing else
/// (engine.proto:211-217). Every field the wire side lacks is a case where the
/// only honest answers are "refuse" and "fabricate":
///
/// - **No host port.** An unset `publicPort` is a stored binding whose host side
///   is not recorded. `hostPort = 0` fabricates the very class of value this
///   mapping exists to stop, and dropping the entry asserts the sandbox
///   publishes nothing on that guest port -- which is what drift detection then
///   compares against.
/// - **A protocol that is not tcp.** The wire has no protocol field, so a udp
///   binding emitted here reads as a tcp publication that does not exist, and a
///   tcp and a udp binding on the same two numbers collapse into a duplicate the
///   consumer rejects outright (translate.rs:376-381).
/// - **A number that is not a port.** See `wirePort` above.
///
/// Sorted, because `repeated` is ordered on the wire and the input comes from
/// iterating a Dictionary (`ContainerManager.swift:959`), whose order is seeded
/// per process. Unsorted, two Inspects of one unchanged sandbox can disagree
/// about the order of its ports. Sorting reorders; it invents nothing.
public func sandboxPorts(
    fromBindings bindings: [PortMapping]
) -> Result<[Arca_Engine_V1_PortMapping], UnrepresentablePortBinding> {
    var ports: [Arca_Engine_V1_PortMapping] = []
    for binding in bindings {
        guard binding.type == "tcp" else {
            return .failure(UnrepresentablePortBinding(
                reason: "port binding \(describe(binding)) is not tcp, and the contract's "
                    + "PortMapping carries no protocol field to say otherwise"
            ))
        }
        guard let publicPort = binding.publicPort else {
            return .failure(UnrepresentablePortBinding(
                reason: "port binding \(describe(binding)) is stored with no host port, and "
                    + "the contract has no way to report a binding that has none"
            ))
        }
        guard let hostPort = wirePort(publicPort),
              let guestPort = wirePort(binding.privatePort)
        else {
            return .failure(UnrepresentablePortBinding(
                reason: "port binding \(describe(binding)) names a number that is not a port"
            ))
        }
        ports.append(Arca_Engine_V1_PortMapping.with {
            $0.hostPort = hostPort
            $0.guestPort = guestPort
        })
    }
    return .success(ports.sorted { ($0.guestPort, $0.hostPort) < ($1.guestPort, $1.hostPort) })
}

/// The container's resource name, as the contract requires it.
///
/// ContainerBridge reports Docker-style names with a leading slash
/// (Sources/ContainerBridge/ContainerManager.swift:725), but the consumer
/// compares a container resource's name against the bare sandbox id
/// (crates/gascan-core/src/runtime.rs:829-832). Reporting the slashed form
/// would make every owned container look unrelated to the sandbox that owns
/// it, and drift detection would silently see nothing.
///
/// Falls back to the id when there is no name to strip, because an empty
/// resource name fails the consumer's identity validation and would take the
/// whole ListResources call down with it.
public func containerResourceName(names: [String], id: String) -> String {
    guard let first = names.first else { return id }
    let stripped = first.hasPrefix("/") ? String(first.dropFirst()) : first
    return stripped.isEmpty ? id : stripped
}

/// One resource on the way out.
///
/// `owner` stays unset when the engine holds no labels for the resource, which
/// is how a consumer sees one it does not own (engine.proto:169-173).
public func resourceMessage(
    kind: Arca_Engine_V1_ResourceKind,
    name: String,
    labels: [String: String]
) -> Arca_Engine_V1_Resource {
    Arca_Engine_V1_Resource.with { resource in
        resource.identity = Arca_Engine_V1_ResourceIdentity.with {
            $0.kind = kind
            $0.name = name
        }
        if let owner = SandboxIdentity.owner(from: labels) {
            resource.owner = owner
        }
    }
}
