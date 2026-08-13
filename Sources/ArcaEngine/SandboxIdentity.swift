import SandboxEngineProto

/// The naming and labelling rules, in one place because Gas Can validates them
/// exactly and a divergence fails every create rather than degrading.
public enum SandboxIdentity {
    public static let managedByLabelKey = "dev.gascan.managed-by"
    public static let sandboxIdLabelKey = "dev.gascan.sandbox-id"

    /// The container's name is the sandbox id, unchanged.
    ///
    /// gascan's validator builds the expected container identity as the
    /// request's id (crates/gascan-core/src/runtime.rs:829-832). A prefix, a
    /// suffix, or a normalisation makes every create fail client-side.
    ///
    /// Safe because ContainerBridge applies no container-name grammar
    /// validation, and because a sandbox id always contains a hyphen -- which
    /// keeps resolveContainerID from reading it as a hex short ID
    /// (Sources/ContainerBridge/ContainerManager.swift:2005-2023).
    public static func containerName(forSandboxId id: String) -> String { id }

    /// Why this engine will not act under this sandbox id, or nil when it will.
    ///
    /// **This exists because `Create` acts on what `resolveContainerID` matches,
    /// and that matcher is a prefix search.** `request.sandboxID` reaches it
    /// unvalidated: `ContainerManager.swift:2005-2023` treats any pure-hex
    /// string of 4 or more characters as a Docker short id, prefix-matches it
    /// against every container the engine holds, and on more than one match
    /// returns `matches.sorted().first` -- an arbitrary container chosen by
    /// string order. `:2001` matches a full 64-character id outright.
    ///
    /// While every implemented method was read-only this was harmless: the worst
    /// outcome was an `Inspect` reporting the wrong container, which the
    /// consumer's own ownership check catches. `Create` is the first method that
    /// *acts* on the match -- `createContainer`'s name-conflict check
    /// (`:1650-1656`) runs through the same resolver, so a hex sandbox id can
    /// collide with an unrelated container and be refused as a name conflict, or
    /// worse, be created and then be what a later `Stop` or `Remove` resolves
    /// to.
    ///
    /// Gas Can cannot send such an id -- a sandbox id always carries a hyphen
    /// (`crates/gascan-core/src/sandbox.rs:168-198`) -- and that is exactly why
    /// this is enforced here rather than assumed: nothing on this side of the
    /// socket made it true, and the engine must not depend on a well-behaved
    /// consumer for a property that decides which container it writes to.
    ///
    /// The hex test mirrors `resolveContainerID`'s own character set, including
    /// its uppercase, rather than reasoning about which forms are reachable. The
    /// length test is `>= 4` with no upper bound, which is deliberately wider
    /// than the `< 64` of the prefix arm, because the 64-character case is
    /// caught by the direct-lookup arm one line above it.
    public static func refusalReason(forSandboxId id: String) -> String? {
        if id.isEmpty {
            return "a sandbox id is required and this request carries none"
        }
        let hex = "0123456789abcdefABCDEF"
        if id.count >= 4 && id.allSatisfy({ hex.contains($0) }) {
            return "sandbox id \(id) is pure hexadecimal, which this engine's container "
                + "resolver reads as a Docker id prefix and would match against an unrelated "
                + "container; a gascan sandbox id always contains a hyphen"
        }
        return nil
    }

    /// Stored verbatim, echoed back, never interpreted. Deciding whether a
    /// labelled resource is yours is the consumer's judgment
    /// (engine.proto:144-148).
    public static func labels(from owner: Arca_Engine_V1_OwnerLabels) -> [String: String] {
        [managedByLabelKey: owner.managedBy, sandboxIdLabelKey: owner.sandboxID]
    }

    /// nil when the engine holds no labels for a resource, which is how a
    /// consumer sees one it does not own. Both keys are required: a half
    /// labelled resource would otherwise be reported claiming an empty
    /// managed_by, which gascan's classifier would have to interpret.
    public static func owner(from labels: [String: String]) -> Arca_Engine_V1_OwnerLabels? {
        guard let managedBy = labels[managedByLabelKey],
              let sandboxId = labels[sandboxIdLabelKey]
        else { return nil }
        var owner = Arca_Engine_V1_OwnerLabels()
        owner.managedBy = managedBy
        owner.sandboxID = sandboxId
        return owner
    }
}
