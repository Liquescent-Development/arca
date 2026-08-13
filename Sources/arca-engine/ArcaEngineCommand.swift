import ArcaEngine
import ArgumentParser
import ContainerBridge
import Foundation
import Logging
import NIOCore
import NIOPosix

@main
struct ArcaEngineCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "arca-engine",
        abstract: "Serves the arca.engine.v1 sandbox-engine contract over a Unix socket."
    )

    @Option(name: .customLong("socket-path"), help: "Path of the Unix socket to serve on.")
    var socketPath: String

    @Option(name: .customLong("state-root"), help: "Directory holding engine state.")
    var stateRoot: String

    // Read-only inputs, separate from --state-root and from each other. None of
    // the three is defaulted and none falls back to ~/.arca: a default is how a
    // process silently ends up pointed at another product's state.
    @Option(name: .customLong("kernel-path"), help: "Path of the Linux kernel image to boot sandboxes with.")
    var kernelPath: String

    @Option(name: .customLong("vminit-layout"), help: "Directory holding the arca-vminit OCI layout.")
    var vminitLayout: String

    @Option(name: .customLong("log-level"), help: "trace, debug, info, notice, warning, error.")
    var logLevel: String = "info"

    func run() async throws {
        var logger = Logger(label: "arca-engine")
        logger.logLevel = Logger.Level(rawValue: logLevel) ?? .info

        // First, and before anything is created or constructed: a bad input
        // must cost a clear error naming which option and which path, not a
        // half-initialised engine that answers unsupported_capability for
        // everything that matters. This runs ahead of the socket directory too,
        // so a refusal leaves nothing behind on disk.
        let inputs = EngineInputs(
            stateRoot: URL(fileURLWithPath: stateRoot),
            kernelPath: URL(fileURLWithPath: kernelPath),
            vminitLayout: URL(fileURLWithPath: vminitLayout)
        )
        try validateEngineInputs(inputs)

        // The socket's mode is set to 0600 immediately after bind (EngineServer),
        // but bind returns an already-listening server, so there is a brief
        // window before that lands. The containing directory is the real
        // control for that window: nothing other than its owner can reach the
        // path to connect if the directory itself is 0700.
        try createSocketParentDirectory(for: socketPath)

        // Every path below comes from this one derivation, which the tests call
        // too. Spelling the components out here a second time is what let the
        // suite stay green while the engine's real image-store root changed:
        // TestSupport held a hand-copy of these lines, so the tests exercised a
        // replica of the wiring rather than the wiring. See EnginePaths.
        // The kernel is not among them: it is a read-only input the engine is
        // handed, not state the engine owns.
        let paths = EnginePaths(stateRoot: inputs.stateRoot)

        // Every manager below is rooted in the state root this engine owns, and
        // that ownership is the design: a state root shared with a live
        // ArcaDaemon is the hazard EngineInputs records, and an image store
        // shared with it is the one EnginePaths records. Nothing here is
        // derived a second way.
        //
        // initialize() is still not called on any manager. It needs a live
        // Containerization.VmnetNetwork alongside the kernel and the vminit
        // image (ContainerBridge/ContainerManager.swift:246-278), and until it
        // is called, Inspect and ListResources answer unsupported_capability --
        // see the notes on each in SandboxEngineService. The managers are
        // constructed and handed to the service regardless: the dependency edge
        // they create is a property gascan's release gate measures.
        let stateStore = try StateStore(
            path: paths.stateDatabase.path,
            logger: logger
        )
        let imageManager = try ImageManager(
            logger: logger,
            imageStorePath: paths.imageStoreRoot
        )

        // Before any manager that resolves an init image. This is the second of
        // initialize()'s three preconditions, and the engine now satisfies it
        // itself rather than inheriting an image ArcaDaemon happened to load
        // into the shared store.
        _ = try await loadVminit(
            from: inputs.vminitLayout,
            into: imageManager,
            stateRoot: inputs.stateRoot,
            logger: logger
        )

        let containerManager = ContainerManager(
            imageManager: imageManager,
            kernelPath: inputs.kernelPath.path,
            imageStoreRoot: paths.imageStoreRoot,
            layerCachePath: paths.layerCache,
            stateStore: stateStore,
            logger: logger
        )
        let config = ArcaConfig(
            kernelPath: inputs.kernelPath.path,
            socketPath: paths.socket.path,
            logLevel: logLevel
        )

        let service = SandboxEngineService(
            containerManager: containerManager,
            volumeManager: VolumeManager(
                volumesBasePath: paths.volumesRoot.path,
                stateStore: stateStore,
                logger: logger
            ),
            networkManager: NetworkManager(
                config: config,
                stateStore: stateStore,
                containerManager: containerManager,
                logger: logger
            ),
            imageManager: imageManager,
            execManager: ExecManager(containerManager: containerManager, logger: logger),
            logger: logger
        )

        let group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
        try await serve(service: service, group: group, logger: logger)
        try await group.shutdownGracefully()
        logger.info("engine stopped", metadata: ["socket": "\(socketPath)"])
    }

    /// Runs the engine until it closes, and holds every object that references
    /// an event loop.
    ///
    /// **This is a separate function so that those objects are released before
    /// `run()` shuts the group down. Inlining it reintroduces a crash.**
    /// MEASURED: with the server still live at group-shutdown time, the process
    /// printed `ERROR: Cannot schedule tasks on an EventLoop that has already
    /// shut down` on every run, and under `SWIFTNIO_STRICT=1` the same runs
    /// died with `SelectableEventLoop.swift:483: Fatal error` and exit 133 --
    /// NIO's own note says the error becomes a forced crash in a future
    /// version. It was not a race: a run that slept 1.5s after the group
    /// shutdown logged, survived the sleep, and then crashed on the way out of
    /// `run()`, which is where the server was being deallocated. Scoping it
    /// here so it is released first gives exit 0 with no diagnostic, verified
    /// under `SWIFTNIO_STRICT=1`.
    ///
    /// The order matters and the alternatives do not help: awaiting the
    /// teardown inside a `Task.detached`, dropping the redundant close, and
    /// swapping the async `shutdownGracefully()` for a blocking
    /// `syncShutdownGracefully()` on a Dispatch thread were each measured and
    /// each still crashed.
    private func serve(
        service: SandboxEngineService,
        group: MultiThreadedEventLoopGroup,
        logger: Logger
    ) async throws {
        let engine = try await EngineServer.start(
            socketPath: socketPath,
            service: service,
            group: group
        )
        logger.info("engine listening", metadata: ["socket": "\(socketPath)"])

        // Held for the whole run: a DispatchSourceSignal stops delivering the
        // moment it is deallocated, so a source that is not kept alive is a
        // handler that silently never fires. Cancelling them here also drops
        // the last references these closures hold to the engine.
        let signals = Self.installShutdownHandler(logger: logger, for: engine)
        defer { signals.forEach { $0.cancel() } }

        try await engine.onClose.get()
        try await engine.shutDown()
    }

    /// Turns SIGTERM and SIGINT into a graceful close, and a repeat of either
    /// into an immediate one.
    ///
    /// Without this the process had no shutdown path at all: nothing closed the
    /// server, nothing shut the event-loop group down, and nothing unlinked the
    /// socket, so the only way it ended was by being killed -- which runs no
    /// cleanup and leaves behind exactly the ambiguous socket file that
    /// `EngineServer.start` then has to reason about.
    ///
    /// Each signal is set to `SIG_IGN` first. A `DispatchSourceSignal` observes
    /// delivery, it does not replace the disposition, so leaving the default in
    /// place would terminate the process before the handler ever ran.
    ///
    /// The escalation matters because a graceful shutdown waits for in-flight
    /// RPCs, and a client holding a stream open can hold the engine open with
    /// it. Without a second signal that forces the issue, "handles SIGTERM"
    /// would be true and "can be stopped" would not.
    private static func installShutdownHandler(
        logger: Logger,
        for engine: EngineServer
    ) -> [DispatchSourceSignal] {
        // One serial queue shared by both sources, so the two handlers can
        // never run concurrently and `asked` needs no lock of its own.
        let queue = DispatchQueue(label: "arca-engine.shutdown")
        let asked = ShutdownRequests()
        return [SIGTERM, SIGINT].map { number in
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: queue)
            source.setEventHandler {
                if asked.recordAndReportFirst() {
                    logger.info("shutting down gracefully", metadata: ["signal": "\(number)"])
                    engine.server.initiateGracefulShutdown(promise: nil)
                } else {
                    logger.notice("closing immediately", metadata: ["signal": "\(number)"])
                    engine.server.close(promise: nil)
                }
            }
            source.resume()
            return source
        }
    }

    /// Creates the socket's parent directory mode 0700 if it does not already
    /// exist. Existing directories are left with whatever mode they already
    /// have -- this only strengthens a fresh directory, it does not tighten
    /// one the caller chose to leave looser.
    private func createSocketParentDirectory(for socketPath: String) throws {
        let parent = URL(fileURLWithPath: socketPath).deletingLastPathComponent()
        guard !FileManager.default.fileExists(atPath: parent.path) else { return }
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
        )
    }
}

/// Counts shutdown signals.
///
/// `@unchecked Sendable` because every access happens on the one serial queue
/// `installShutdownHandler` gives both of its signal sources; it carries no
/// synchronisation of its own and must not be used anywhere else.
private final class ShutdownRequests: @unchecked Sendable {
    private var seen = 0

    /// Records a request and answers whether it was the first.
    func recordAndReportFirst() -> Bool {
        seen += 1
        return seen == 1
    }
}
