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
