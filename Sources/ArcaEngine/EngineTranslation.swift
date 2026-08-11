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

/// Splits an exact digest reference into the two fields the contract carries.
///
/// A tag is not representable on the wire, so a reference that is not an exact
/// digest has nothing to map to and is refused. The hex is bare and lowercase,
/// exactly 64 characters, with no "sha256:" prefix (engine.proto:179-185).
public func imageDigest(fromReference reference: String) -> Arca_Engine_V1_ImageDigest? {
    guard let separator = reference.range(of: "@sha256:", options: .backwards) else { return nil }
    let repository = String(reference[reference.startIndex..<separator.lowerBound])
    let hex = String(reference[separator.upperBound...])
    guard !repository.isEmpty, hex.count == 64,
          hex.allSatisfy({ $0.isNumber || ("a"..."f").contains($0) })
    else { return nil }
    var digest = Arca_Engine_V1_ImageDigest()
    digest.repository = repository
    digest.sha256Hex = hex
    return digest
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
