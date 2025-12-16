import Foundation
import NIOHTTP1
import DockerAPI

/// Utility for validating HTTP query parameters
/// Returns descriptive error messages for invalid parameters
public struct QueryParameterValidator {

    /// Validate and parse a positive integer parameter
    /// Returns nil if parameter is missing or empty, or throws ValidationError if invalid
    public static func parsePositiveInt(_ value: String?, paramName: String) throws -> Int? {
        guard let value = value, !value.isEmpty else {
            return nil
        }

        guard let intValue = Int(value) else {
            throw ValidationError.invalidParameter(
                paramName: paramName,
                value: value,
                reason: "must be a valid integer"
            )
        }

        guard intValue > 0 else {
            throw ValidationError.invalidParameter(
                paramName: paramName,
                value: value,
                reason: "must be a positive integer"
            )
        }

        return intValue
    }

    /// Validate and parse a non-negative integer parameter
    /// Returns nil if parameter is missing or empty, or throws ValidationError if invalid
    public static func parseNonNegativeInt(_ value: String?, paramName: String) throws -> Int? {
        guard let value = value, !value.isEmpty else {
            return nil
        }

        guard let intValue = Int(value) else {
            throw ValidationError.invalidParameter(
                paramName: paramName,
                value: value,
                reason: "must be a valid integer"
            )
        }

        guard intValue >= 0 else {
            throw ValidationError.invalidParameter(
                paramName: paramName,
                value: value,
                reason: "must be a non-negative integer"
            )
        }

        return intValue
    }

    /// Validate and parse a UNIX timestamp parameter
    /// Returns nil if parameter is missing or empty, or throws ValidationError if invalid
    /// Accepts both integer and decimal timestamps (e.g., "1764801953" or "1764801953.000000000")
    public static func parseUnixTimestamp(_ value: String?, paramName: String) throws -> Int? {
        guard let value = value, !value.isEmpty else {
            return nil
        }

        // Try parsing as Double first to handle decimal timestamps like "1764801953.000000000"
        // Then convert to Int (truncating the decimal portion)
        let timestamp: Int
        if let intValue = Int(value) {
            timestamp = intValue
        } else if let doubleValue = Double(value) {
            timestamp = Int(doubleValue)
        } else {
            throw ValidationError.invalidParameter(
                paramName: paramName,
                value: value,
                reason: "must be a valid UNIX timestamp"
            )
        }

        guard timestamp >= 0 else {
            throw ValidationError.invalidParameter(
                paramName: paramName,
                value: value,
                reason: "must be a non-negative UNIX timestamp"
            )
        }

        return timestamp
    }

    /// Validate and parse tail parameter (positive integer or "all")
    /// Returns nil if parameter is missing or empty, or throws ValidationError if invalid
    public static func parseTail(_ value: String?, paramName: String = "tail") throws -> String? {
        guard let value = value, !value.isEmpty else {
            return nil
        }

        // "all" is valid
        if value.lowercased() == "all" {
            return value
        }

        // Otherwise must be a positive integer
        guard let intValue = Int(value) else {
            throw ValidationError.invalidParameter(
                paramName: paramName,
                value: value,
                reason: "must be a positive integer or 'all'"
            )
        }

        guard intValue > 0 else {
            throw ValidationError.invalidParameter(
                paramName: paramName,
                value: value,
                reason: "must be a positive integer or 'all'"
            )
        }

        return value
    }

    /// Validate and parse JSON filters parameter
    /// Returns empty dictionary if parameter is missing, or throws ValidationError if invalid JSON
    public static func parseFilters<T: Decodable>(_ value: String?, paramName: String = "filters") throws -> T? {
        guard let value = value, !value.isEmpty else {
            return nil
        }

        guard let data = value.data(using: .utf8) else {
            throw ValidationError.invalidParameter(
                paramName: paramName,
                value: value,
                reason: "contains invalid UTF-8 characters"
            )
        }

        do {
            let decoded = try JSONDecoder().decode(T.self, from: data)
            return decoded
        } catch {
            throw ValidationError.invalidParameter(
                paramName: paramName,
                value: value,
                reason: "must be valid JSON: \(error.localizedDescription)"
            )
        }
    }

    /// Parse Docker-format filters and convert to array format
    /// Docker sends filters in two formats:
    ///   Old format: {"filterName": {"value1": true, "value2": false}}
    ///   New format: {"filterName": ["value1", "value2"]}
    /// Converts both to: {"filterName": ["value1", "value2"]}
    public static func parseDockerFiltersToArray(_ value: String?, paramName: String = "filters") throws -> [String: [String]] {
        guard let value = value, !value.isEmpty else {
            return [:]
        }

        guard let data = value.data(using: .utf8) else {
            throw ValidationError.invalidParameter(
                paramName: paramName,
                value: value,
                reason: "contains invalid UTF-8 characters"
            )
        }

        // Try new format first: {"name": ["value1", "value2"]}
        if let arrayFilters = try? JSONDecoder().decode([String: [String]].self, from: data) {
            return arrayFilters
        }

        // Fall back to old format: {"name": {"value1": true, "value2": false}}
        if let boolFilters = try? JSONDecoder().decode([String: [String: Bool]].self, from: data) {
            return boolFilters.mapValues { valueMap in
                valueMap.compactMap { key, include in include ? key : nil }
            }
        }

        throw ValidationError.invalidParameter(
            paramName: paramName,
            value: value,
            reason: "must be valid JSON filters in Docker format"
        )
    }

    /// Parse Docker-format filters and convert to single-value format
    /// Docker sends filters as: {"filterName": {"value": true}}
    /// Converts to: {"filterName": "value"} (taking first true value)
    public static func parseDockerFiltersToSingle(_ value: String?, paramName: String = "filters") throws -> [String: String] {
        let dockerFilters: [String: [String: Bool]]? = try parseFilters(value, paramName: paramName)

        return dockerFilters?.compactMapValues { valueMap in
            valueMap.first { $0.value }?.key
        } ?? [:]
    }

    /// Validate a boolean parameter
    /// Returns false if parameter is missing (default behavior)
    public static func parseBoolean(_ value: String?) -> Bool {
        guard let value = value else {
            return false
        }
        return value == "true" || value == "1"
    }

    /// Validate a boolean parameter with default true
    /// Used for parameters like stdout/stderr that default to true
    public static func parseBooleanDefaultTrue(_ value: String?) -> Bool {
        guard let value = value else {
            return true
        }
        return value != "false" && value != "0"
    }
}

// MARK: - Validation Error

/// Error type for query parameter validation failures
public enum ValidationError: Error, CustomStringConvertible {
    case invalidParameter(paramName: String, value: String, reason: String)
    case missingRequiredParameter(paramName: String)

    public var description: String {
        switch self {
        case .invalidParameter(let paramName, let value, let reason):
            return "Invalid query parameter '\(paramName)=\(value)': \(reason)"
        case .missingRequiredParameter(let paramName):
            return "Missing required query parameter: \(paramName)"
        }
    }

    /// Convert validation error to HTTP response
    public func toHTTPResponse() -> HTTPResponse {
        return HTTPResponse.error(self.description, status: .badRequest)
    }
}
