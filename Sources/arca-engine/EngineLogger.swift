import Logging

/// The logger every `arca-engine` command builds, from the `--log-level` it was
/// given.
///
/// One function rather than the same two lines in each command's `run()`: the
/// label is what a consumer greps its logs by, and two spellings of it is a
/// consumer that finds half its logs.
func engineLogger(logLevel: String) -> Logger {
    var logger = Logger(label: "arca-engine")
    logger.logLevel = Logger.Level(rawValue: logLevel) ?? .info
    return logger
}
