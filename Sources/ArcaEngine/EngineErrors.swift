import SandboxEngineProto

/// The generated message type is plain data with no `Error` conformance;
/// this lets it stand as the failure side of a `Result` without hand-editing
/// generated code.
extension Arca_Engine_V1_EngineError: Swift.Error {}

/// The engine's entire error vocabulary.
///
/// NOT open to extension. Gas Can maps these with a table rather than a
/// judgment, "so a new engine failure mode cannot quietly become an existing
/// one" (proto/arca/engine/v1/engine.proto:62-65), and its table
/// (crates/gascan-arca/src/error.rs:20-55) accepts exactly these twelve --
/// anything else arrives as invalid_output naming the offender. Two further
/// codes are not an engine's to raise: injected_failure belongs to Gas Can's
/// fake runtime, and unsupported_version is the consumer's own refusal.
public enum EngineErrorCode: String, CaseIterable, Sendable {
    case commandIo = "command_io"
    case commandFailed = "command_failed"
    case invalidOutput = "invalid_output"
    case helperError = "helper_error"
    case unsupportedCapability = "unsupported_capability"
    case ownershipMismatch = "ownership_mismatch"
    case foreignResourceRefused = "foreign_resource_refused"
    case invalidResourceIdentity = "invalid_resource_identity"
    case resourceConflict = "resource_conflict"
    case notFound = "not_found"
    case invalidState = "invalid_state"
    case unknownActualState = "unknown_actual_state"
}

/// `resource` names the thing the failure is about and is empty when it is not
/// about one; `message` is prose and is never parsed. They are not
/// interchangeable: two codes carry both fields, so a transposition survives
/// every assertion weaker than an exact string comparison.
public func engineError(
    _ code: EngineErrorCode,
    resource: String = "",
    message: String
) -> Arca_Engine_V1_EngineError {
    var error = Arca_Engine_V1_EngineError()
    error.code = code.rawValue
    error.resource = resource
    error.message = message
    return error
}

/// Runs `body`, converting any thrown error into an `EngineError`.
///
/// This exists because an uncaught throw in a grpc-swift provider method becomes
/// a gRPC status, and status codes are reserved for transport faults and carry
/// no engine semantics (engine.proto:52-58). A status where an outcome belongs
/// is a contract violation, not an error path.
public func engineErrorCatching<T>(
    _ code: EngineErrorCode,
    resource: String = "",
    _ body: () async throws -> T
) async -> Result<T, Arca_Engine_V1_EngineError> {
    do {
        return .success(try await body())
    } catch {
        return .failure(engineError(code, resource: resource, message: "\(error)"))
    }
}
