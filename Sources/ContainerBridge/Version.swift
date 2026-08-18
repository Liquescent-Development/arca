import Foundation

/// Centralized version configuration for Arca
/// Update version here for releases - all version strings are derived from this
public struct ArcaVersion {
    /// Arca version number (e.g., "0.2.4-alpha")
    public static let version = "0.2.4-alpha"

    /// Docker Engine API version we implement
    public static let apiVersion = "1.51"

    /// Minimum API version we support
    public static let minAPIVersion = "1.24"

    /// Git commit hash - injected by Makefile, see BuildInfo.generated.swift
    public static var gitCommit: String {
        ArcaBuildInfo.gitCommit
    }

    /// The full 40-character revision, for the capability gate. Distinct from
    /// `gitCommit`, which is a 7-character display value Docker's `/version`
    /// returns as `GitCommit` -- once for the engine component and once at the
    /// top level (`Sources/DockerAPI/Handlers/SystemHandlers.swift:35`, `:54`,
    /// both inside `handleVersion()`): a prefix is not an identity and must
    /// not be used as one, and widening `gitCommit` in place would change what
    /// those two payloads report.
    public static var buildRevision: String {
        ArcaBuildInfo.buildRevision
    }

    /// Build time - injected by Makefile, see BuildInfo.generated.swift
    public static var buildTime: String {
        ArcaBuildInfo.buildTime
    }

    /// Swift version used to build
    public static let swiftVersion = "6.2"

    /// Full version string with API version (for CLI display)
    public static var fullVersion: String {
        "\(version) (API v\(apiVersion))"
    }

    /// Server header value
    public static var serverHeader: String {
        "Arca/\(version)"
    }

    /// Whether experimental features are enabled
    public static let experimental = false
}
