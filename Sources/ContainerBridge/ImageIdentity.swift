// `range(of:options:)` below is Foundation's, not the standard library's. This
// file compiled without the import -- the symbol was reachable through another
// module in this target -- which is an accident of what its neighbours import
// and not something to rely on.
import Foundation

/// How an image reference is split into the identity of the content it names.
///
/// **Not `ImageReference` in `ImageTypes.swift:241`, and the difference is the
/// reason this exists rather than reusing it.** That type's `repository` is the
/// bare last path component -- `ImageReference.parse("docker.io/library/alpine")`
/// reports registry `docker.io`, namespace `library`, repository `alpine`
/// (`:289-313`). The rule below keeps the whole name: `docker.io/library/alpine`.
/// Both are defensible readings of the word "repository" and this codebase now
/// contains both; what it must not do is use one where the other is meant.
///
/// The rule here is Gas Can's, mirrored, because it is the rule the comparison
/// has to survive: `immutable_image_identity`
/// (`crates/gascan-core/src/runtime.rs:704-715`) drops anything from `@sha256:`
/// onward, then drops a tag -- the last `:` that comes after the last `/`, so
/// that the port in `registry.example:5000/repo` is not mistaken for one. The
/// two sides of the wire have to split identically, or the comparison they meet
/// in is decided by punctuation rather than by identity.
///
/// **One copy, because two components compare the results and a divergence
/// between them is undetectable.** `ArcaEngine` splits a stored reference to
/// decide whether it holds requested content (`PrepareImage`), and
/// `ImageManager.resolveImage` splits the same kind of string to decide which
/// stored image an exact digest reference names. Those answers must agree: an
/// `Ack` from `PrepareImage` is a promise that the resolver will find the
/// content, and `Create` collects on that promise. Two copies of a splitting
/// rule agree only until one of them is edited.
///
/// It lives in `ContainerBridge` because the resolver is here and cannot import
/// upward. `EngineTranslation.imageRepository(ofReference:)` forwards to
/// `repository(of:)` and keeps its own name, which is what its call sites
/// already say.
public enum ImageIdentity {
    /// The repository half of an image reference, tag and digest removed.
    public static func repository(of reference: String) -> String {
        let name = reference.range(of: "@sha256:", options: .backwards)
            .map { String(reference[reference.startIndex..<$0.lowerBound]) } ?? reference
        guard let tagSeparator = name.lastIndex(of: ":") else { return name }
        if let slash = name.lastIndex(of: "/"), tagSeparator < slash { return name }
        return String(name[name.startIndex..<tagSeparator])
    }

    /// A reference that names content exactly, split into the repository it
    /// claims and the digest the store records it under -- or nil when the
    /// reference is not one.
    ///
    /// This is the form Gas Can sends for every create
    /// (`immutable_image_reference`, `crates/gascan-core/src/runtime.rs:677-686`)
    /// and the form Docker itself accepts for `run`, `rmi` and `inspect`.
    ///
    /// **Lowercase hex, exactly 64 characters, and nothing else counts.** The
    /// store records digests lowercase, so accepting an uppercase spelling would
    /// produce a reference that parses and then matches nothing -- a "no such
    /// image" for content the store holds. `ArcaEngine`'s `imageStoreDigest(_:)`
    /// applies the same rule to the wire form, which is what lets the two meet.
    ///
    /// The repository half goes through `repository(of:)` rather than being
    /// taken as the raw prefix, so that `workspace:latest@sha256:<hex>` and
    /// `workspace@sha256:<hex>` name the same repository -- which they do.
    public static func exactDigest(of reference: String) -> (repository: String, digest: String)? {
        guard let separator = reference.range(of: "@sha256:", options: .backwards) else {
            return nil
        }
        let hex = String(reference[separator.upperBound...])
        guard hex.count == 64,
              hex.allSatisfy({ $0.isASCII && ($0.isNumber || ("a"..."f").contains($0)) })
        else { return nil }
        let name = repository(of: reference)
        guard !name.isEmpty else { return nil }
        return (repository: name, digest: "sha256:\(hex)")
    }
}
