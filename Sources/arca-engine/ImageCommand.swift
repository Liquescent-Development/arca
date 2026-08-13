import ArcaEngine
import ArgumentParser
import Foundation

/// `arca-engine image ...`, the group that owns everything to do with the
/// engine's own image store.
///
/// It has a `run()` only to refuse. ArgumentParser's default for a bare group
/// is to print help and exit 0, so `arca-engine image && echo ok` printed `ok`
/// having loaded nothing -- the same "exits 0 having done nothing" shape Gas
/// Can's `build-arca-engine.sh` grew a listing guard for, after
/// `swift test --filter <no match>` passed a gate by running no tests.
/// `ValidationError` is the exit 64 ArgumentParser uses for a command line it
/// could not act on. What it prints beneath the message is the ROOT's custom
/// `usage:` -- both forms, then `See 'arca-engine --help'` -- and not this
/// group's own usage line. MEASURED against the built binary, and it matters to
/// whoever asserts on this output: the root's usage carries the literal
/// `arca-engine image load ...`, so a test reading stderr for `load` learns
/// nothing about the message above it.
struct ImageCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "image",
        abstract: "Manages the images in this engine's own store.",
        subcommands: [ImageLoadCommand.self]
    )

    func run() throws {
        // Read off the configuration rather than written out beside it, so an
        // action a later task adds cannot go missing from the message that
        // lists what this group can do. Held to by
        // ImageLoadTests.testTheRefusalNamesEveryActionTheGroupAdvertises,
        // which compares this list against the one `image --help` generates
        // from the same array -- a guard that can only bite once there are two
        // subcommands, which is Task 10.
        //
        // Spelt as an explicit closure and not `compactMap(\.configuration...)`:
        // the key-path form crashes swiftc 6.3.3 in SILGen, `signal 5` while
        // lowering this function, on the conversion of a key path rooted in an
        // existential metatype. MEASURED here; the closure compiles.
        let actions = Self.configuration.subcommands
            .compactMap { subcommand in subcommand.configuration.commandName }
            .joined(separator: ", ")
        throw ValidationError(
            "'arca-engine image' does nothing on its own; name an action: \(actions)"
        )
    }
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
