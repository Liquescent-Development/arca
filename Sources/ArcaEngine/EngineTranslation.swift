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
