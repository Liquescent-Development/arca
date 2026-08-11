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

    @Option(name: .customLong("log-level"), help: "trace, debug, info, notice, warning, error.")
    var logLevel: String = "info"

    func run() async throws {
        var logger = Logger(label: "arca-engine")
        logger.logLevel = Logger.Level(rawValue: logLevel) ?? .info

        // The socket's mode is set to 0600 immediately after bind (EngineServer),
        // but bind returns an already-listening server, so there is a brief
        // window before that lands. The containing directory is the real
        // control for that window: nothing other than its owner can reach the
        // path to connect if the directory itself is 0700.
        try createSocketParentDirectory(for: socketPath)

        let root = URL(fileURLWithPath: stateRoot)

        // This milestone implements only Capabilities, Inspect, and
        // ListResources -- none of which starts a VM -- so ContainerManager's
        // initialize() is deliberately never called here. initialize()
        // requires the kernel file to exist on disk, an "arca-vminit:latest"
        // image already loaded by ArcaDaemon, and a live
        // Containerization.VmnetNetwork (Sources/ContainerBridge/
        // ContainerManager.swift:213-258); requiring all three would make this
        // engine refuse to start anywhere a kernel or vminit image is absent,
        // which defeats the point of this milestone -- a Rust client dialling
        // a real, running engine. A later milestone that implements
        // VM-starting RPCs will call initialize() here, gated by a
        // --kernel-path option.
        //
        // Consequence: without initialize(), the engine reports only its
        // in-memory view. It does not load or reconcile containers persisted
        // by a previous run, so a restarted engine reports zero containers
        // even if StateStore's database still has rows for them.
        let stateStore = try StateStore(
            path: root.appendingPathComponent("state.db").path,
            logger: logger
        )
        let imageManager = try ImageManager(
            logger: logger,
            imageStorePath: root.appendingPathComponent("images")
        )
        let containerManager = ContainerManager(
            imageManager: imageManager,
            kernelPath: root.appendingPathComponent("vmlinux").path,
            stateStore: stateStore,
            logger: logger
        )
        let config = ArcaConfig(
            kernelPath: root.appendingPathComponent("vmlinux").path,
            socketPath: root.appendingPathComponent("arca.sock").path,
            logLevel: logLevel
        )

        let service = SandboxEngineService(
            containerManager: containerManager,
            volumeManager: VolumeManager(
                volumesBasePath: root.appendingPathComponent("volumes").path,
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
        let server = try await EngineServer.start(
            socketPath: socketPath,
            service: service,
            group: group
        )
        logger.info("engine listening", metadata: ["socket": "\(socketPath)"])
        try await server.onClose.get()
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
