import SandboxEngineProto

/// The decisions `Start`, `Stop` and `Remove` make before they touch anything,
/// held here for the reason `EngineCreate.swift` holds `Create`'s: they are pure
/// values, and the acts they gate are not reachable without a VM.
///
/// **These three are the first methods that WRITE.** Everything Landing 3 shipped
/// reads: a wrong answer from `Inspect` is a wrong report, and the consumer's own
/// checks stand behind it. A wrong answer here boots a VM, kills one, or deletes a
/// volume, and there is nothing behind it. So each of the gates below is written
/// as a refusal the engine makes for itself rather than a property it assumes of
/// the caller.

// MARK: - The resolver hazard, carried into every method that acts

/// Whether the engine may resolve a container by the name in this request.
///
/// `SandboxIdentity.refusalReason(forSandboxId:)` is the whole rule and this is
/// only the sentence that puts it in front of `Start`, `Stop` and `Remove` as
/// well as `Create`. It is stated here because the reason it exists changed when
/// these three landed.
///
/// `ContainerManager.resolveContainerID` (`:1999`) tries a hex prefix match
/// *before* the name lookup at `:2026`: any input of 4 or more characters that is
/// entirely hex is prefix-matched against Docker ids, and on more than one match
/// it returns `matches.sorted().first` with a warning and no error.
///
/// **What that costs is measured, not argued.** Two tests hold the two call
/// sites, and each is red when its own call to this function is deleted, run as
/// `swift test --filter ArcaEngineTests`:
///
/// - deleted from `SandboxEngineService.lifecycleAck`, the only failure is
///   `LifecycleTests.testStopRefusesAHexSandboxIdItWouldOtherwiseHaveAckedForAnUnrelatedContainer`
///   -- the engine resolves `beef` to a container named `unrelated-container`
///   and answers `Ack` for having stopped a sandbox it never touched.
/// - deleted from `removableKind` below, the only failure is
///   `LifecycleTests.testARemoveNamingAHexPrefixRefusesAndDeletesNothing`, which
///   finds that same container **deleted**.
///
/// A Gas Can sandbox id always contains a hyphen
/// (`crates/gascan-core/src/sandbox.rs`), so a well-behaved consumer cannot send
/// such a name. That is exactly why the engine enforces it rather than assuming
/// it: nothing on this side of the socket makes it true, and the property decides
/// which container gets destroyed.
///
/// Volume and network names do not go through it -- `VolumeManager.volumes` and
/// `NetworkManager.networkNames` are exact-key dictionary lookups
/// (`VolumeManager.swift:297-303`, `NetworkManager.swift:696-702`) -- so this gate
/// is applied to container names only, and applying it wider would refuse volume
/// names the consumer is entitled to use.
func containerNameRefusal(_ name: String) -> Arca_Engine_V1_EngineError? {
    guard let reason = SandboxIdentity.refusalReason(forSandboxId: name) else { return nil }
    return engineError(.invalidResourceIdentity, resource: name, message: reason)
}

// MARK: - Start and Stop

/// Why this engine will not run a lifecycle verb against the container it holds
/// under this name, or nil when it will.
///
/// `storedLabels` is nil when the engine holds no container under the name.
///
/// **Absent is `not_found` and unlabelled is `foreign_resource_refused`, and the
/// two are not the same answer.** `not_found` is a final answer about a sandbox
/// that is not there, which a reconciler responds to by creating it.
/// `foreign_resource_refused` says something else is there under that name, which
/// a reconciler must not respond to by creating a second one.
///
/// The unlabelled refusal is `Inspect`'s, one step harder. Task 7 refuses to
/// *assert* that an unlabelled container is the sandbox that was asked for
/// (`SandboxEngineService.sandboxResponse`); these methods would *boot* or *kill*
/// it. Container names are a flat namespace this engine does not own, so a
/// sandbox id can resolve to something the consumer never created, and starting
/// it is a VM the consumer did not ask for running work it cannot see.
///
/// There is deliberately **no label comparison** here, unlike `Remove`'s.
/// `StartRequest` and `StopRequest` carry a `sandbox_id` and nothing else
/// (engine.proto:367-375) -- there are no caller labels on the wire to compare
/// against, so an engine that decided a labelled container was or was not the
/// caller's would be inventing the caller's identity. `Remove` compares because
/// `RemoveRequest.owner` exists (`:383`). The asymmetry is the contract's.
///
/// **`containerNameRefusal` is deliberately NOT repeated here**, and the reason
/// is a measured one. It ran in both this function and `lifecycleAck`, one
/// belt-and-braces call apart, and the duplicate made the gate unfalsifiable:
/// deleting the call in `lifecycleAck` -- the one that decides whether the
/// resolver sees the name at all -- left `swift test --filter ArcaEngineTests`
/// reporting `Executed 147 tests, with 0 failures`, because this copy caught it.
/// A gate that two places enforce is a gate no test measures. It belongs in
/// `lifecycleAck`, before the read, because a name this engine refuses to act
/// under is one it should not resolve either.
func lifecycleRefusal(
    verb: String,
    sandboxId: String,
    storedLabels: [String: String]?
) -> Arca_Engine_V1_EngineError? {
    guard let labels = storedLabels else {
        return engineError(
            .notFound,
            resource: sandboxId,
            message: "this engine holds no container named \(sandboxId) to \(verb)"
        )
    }
    guard SandboxIdentity.owner(from: labels) != nil else {
        return engineError(
            .foreignResourceRefused,
            resource: sandboxId,
            message: "container \(sandboxId) carries no gascan owner labels, so this engine "
                + "cannot assert it is the sandbox that was asked for and will not \(verb) it"
        )
    }
    return nil
}

// MARK: - Remove

/// The three kinds `Remove` can delete, with `UNSPECIFIED` and any future value
/// already excluded.
///
/// A parsed kind rather than a switch on the wire enum at each step, so that
/// "this engine cannot delete that" is decided exactly once and no later switch
/// needs an unreachable arm to satisfy exhaustiveness -- an arm no test could
/// ever cover and which would quietly become reachable if the contract grew a
/// fourth kind.
enum RemovableKind {
    case container
    case volume
    case network

    /// The word an operator reading a refusal needs.
    var noun: String {
        switch self {
        case .container: return "container"
        case .volume: return "volume"
        case .network: return "network"
        }
    }

    /// The order `Remove` deletes in: containers, then volumes, then networks.
    ///
    /// **This is a dependency order and it is load-bearing, not tidiness.**
    /// `VolumeManager.deleteVolume` refuses a volume any container still mounts
    /// (`VolumeManager.swift:317-327`, `VolumeError.inUse`), and the
    /// `volume_mounts` rows that make it "in use" are cleared by CASCADE when the
    /// container row is deleted (`ContainerManager.swift:3173`). So a `Remove`
    /// that deleted volumes first would fail on every sandbox that has one --
    /// which is every sandbox Gas Can creates.
    ///
    /// MEASURED with the sort in `remove(request:)` deleted, so the request's own
    /// order stands: `swift test --filter ArcaEngineTests`, the only failure is
    /// `LifecycleTests.testRemoveDeletesAContainerTheVolumeItMountsAndItsNetworkInOneCall`,
    /// which gets `invalid_state` naming the volume where it expected `Ack`.
    ///
    /// It is the reverse of `Create`'s volumes -> network -> container, which is
    /// the same dependency read the other way, and it is the order the sibling
    /// backend already uses (`crates/gascan-apple/src/backend.rs:487-491`) and the
    /// one the consumer's own fake runtime sorts into
    /// (`crates/gascan-core/src/fake_runtime.rs:935-940`). Three implementations
    /// of one contract agreeing is worth more than any of them arguing.
    var removalRank: Int {
        switch self {
        case .container: return 0
        case .volume: return 1
        case .network: return 2
        }
    }
}

/// The kind this identity names, or the refusal that says why the engine will
/// not act on it.
///
/// `RESOURCE_KIND_UNSPECIFIED` is an unset field, which arrives as a request to
/// delete "a resource" with no statement of which kind -- and the three kinds
/// live in three separate namespaces, so guessing would pick a namespace. An
/// empty name is refused for the same reason `containerResourceName` falls back
/// to an id: a resource with no name is not one this engine can find.
func removableKind(
    _ identity: Arca_Engine_V1_ResourceIdentity
) -> Result<RemovableKind, Arca_Engine_V1_EngineError> {
    let kind: RemovableKind
    switch identity.kind {
    case .container: kind = .container
    case .volume: kind = .volume
    case .network: kind = .network
    case .unspecified, .UNRECOGNIZED:
        return .failure(engineError(
            .invalidResourceIdentity,
            resource: identity.name,
            message: "a remove names each resource's kind, and this one names "
                + "\(identity.kind) -- container, volume and network are three separate "
                + "namespaces and this engine will not guess which one to delete from"
        ))
    }
    guard !identity.name.isEmpty else {
        return .failure(engineError(
            .invalidResourceIdentity,
            resource: "",
            message: "a \(kind.noun) in this remove carries no name"
        ))
    }
    if kind == .container, let refusal = containerNameRefusal(identity.name) { return .failure(refusal) }
    return .success(kind)
}

/// Why this engine will not delete the resource it holds under this identity, or
/// nil when it will.
///
/// `storedLabels` is nil when the engine holds no such resource.
///
/// **This is `Inspect`'s posture, not `ListResources`'.** `ListResources` reports
/// an unlabelled resource with `owner` unset, because a consumer's leak detection
/// depends on seeing it (engine.proto:389-391). That is a report. This is an
/// authorisation, and the two answer different questions -- reporting a resource
/// the consumer does not own is how it finds a leak; deleting one is how it
/// causes an incident.
///
/// The three refusals are the three the consumer's own reference implementation
/// raises, in the same order (`crates/gascan-core/src/fake_runtime.rs:916-934`):
/// absent is `not_found`, unlabelled is `foreign_resource_refused`, and labels
/// that differ from the caller's are `ownership_mismatch`.
///
/// **The comparison is on both labels and it is exact.** A resource carrying
/// `managed_by=gascan` under a different `sandbox_id` is another sandbox's, and
/// deleting it is precisely what `engine.proto:381-383` says this field exists to
/// stop: "so one consumer cannot be induced to delete another's resource".
/// Comparing only `sandbox_id` would let a different tool's resource through on a
/// colliding id, and comparing only `managed_by` would let every gascan sandbox
/// delete every other one.
///
/// This is not the engine interpreting labels, which `engine.proto:143-148`
/// forbids. It is not deciding whether a labelled resource is the caller's on the
/// caller's behalf -- the caller has *said* whose it is, in `RemoveRequest.owner`,
/// and this refuses to act when the store disagrees with what the caller said.
func removalRefusal(
    kind: RemovableKind,
    name: String,
    storedLabels: [String: String]?,
    owner: Arca_Engine_V1_OwnerLabels
) -> Arca_Engine_V1_EngineError? {
    guard let labels = storedLabels else {
        return engineError(
            .notFound,
            resource: name,
            message: "this engine holds no \(kind.noun) named \(name)"
        )
    }
    guard let stored = SandboxIdentity.owner(from: labels) else {
        return engineError(
            .foreignResourceRefused,
            resource: name,
            message: "\(kind.noun) \(name) carries no gascan owner labels, so this engine "
                + "cannot establish it is the caller's and will not delete it"
        )
    }
    guard stored == owner else {
        return engineError(
            .ownershipMismatch,
            resource: name,
            message: "\(kind.noun) \(name) is labelled managed_by '\(stored.managedBy)' "
                + "sandbox_id '\(stored.sandboxID)', and this remove is made under "
                + "managed_by '\(owner.managedBy)' sandbox_id '\(owner.sandboxID)'"
        )
    }
    return nil
}
