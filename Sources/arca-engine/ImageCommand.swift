import ArcaEngine
import ArgumentParser
import Foundation

/// `arca-engine image ...`, the group that owns everything to do with the
/// engine's own image store.
///
/// A group with no `run()` of its own: ArgumentParser prints its help when it
/// is invoked bare, which is what should happen to `arca-engine image`.
struct ImageCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "image",
        abstract: "Manages the images in this engine's own store.",
        subcommands: [ImageLoadCommand.self]
    )
}

/// `arca-engine image load --state-root <dir> --oci-layout <dir>`.
///
/// This subcommand loads and exits. It binds no socket, starts no VM and calls
/// no manager's `initialize()`, so it runs anywhere -- including CI, where
/// there is no vmnet entitlement.
///
/// Deliberately NOT a merge with `--vminit-layout`, which the served engine
/// takes at startup: vminit is an input the engine must have before it can
/// construct a manager, and a workspace image is content a consumer pushes
/// afterwards. Merging them would put an ordering step into installation.
///
/// A shell over `loadWorkspaceImages`, which lives in the `ArcaEngine` library,
/// and holds no logic of its own beyond parsing and printing: a test target
/// cannot import an executable, so anything decided here would be undecidable
/// by any test. The rule is the same one `EnginePaths` and `EngineManagers`
/// were moved for.
struct ImageLoadCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "load",
        abstract: "Loads an OCI image layout into this engine's own image store."
    )

    /// The engine's own state root, which is what decides the store the images
    /// land in. Undefaulted, exactly as on the served engine: a default is how
    /// a process silently ends up writing into another product's state, and the
    /// store this must never write into is Apple's shared one.
    @Option(name: .customLong("state-root"), help: "Directory holding engine state.")
    var stateRoot: String

    @Option(name: .customLong("oci-layout"), help: "Directory holding the OCI image layout to load.")
    var ociLayout: String

    @Option(name: .customLong("log-level"), help: "trace, debug, info, notice, warning, error.")
    var logLevel: String = "info"

    func run() async throws {
        let report = try await loadWorkspaceImages(
            fromOCILayout: URL(fileURLWithPath: ociLayout),
            stateRoot: URL(fileURLWithPath: stateRoot),
            logger: engineLogger(logLevel: logLevel)
        )

        // On stdout, and naming the store that was actually written to. A load
        // that reported only "ok" would be indistinguishable from a load that
        // wrote nothing, and one that reported no path would be
        // indistinguishable from a load into Apple's shared store -- the exact
        // outcome this engine's private state root exists to prevent.
        print("loaded \(report.references.count) image(s) into \(report.storeRoot.path)")
        for reference in report.references {
            print(reference)
        }
    }
}
