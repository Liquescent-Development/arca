import Foundation
import Logging
import Containerization
import ContainerizationExtras
import ContainerizationOCI
import ContainerizationOS

/// The two things `ExecManager` needs from a `ContainerManager`, and nothing
/// else: the state of a container it is about to exec into, and the native
/// container it execs through.
///
/// It exists because **no VM-free path can produce a container in state
/// `running`**, and `createExec` admits nothing else.
///
/// The reachable part is stated first, because an earlier revision of this
/// comment got it wrong and would have sent readers to the wrong place.
/// `getContainerState` reads the in-memory `containers` map
/// (`ContainerManager.swift:3680-3685`), and that map *is* populated without a
/// VM: `package func loadPersistedState()` (`ContainerManager.swift:340`)
/// restores it from the StateStore, is `package` precisely so tests can drive it
/// -- its own comment at `ContainerManager.swift:319-327` says so -- and six
/// suites in `ArcaEngineTests` already drive it.
///
/// What that restore cannot produce is a *running* container. It rewrites a
/// stored `running` to `exited` with code 137 as crash recovery
/// (`ContainerManager.swift:395-401`), on the reasoning that a daemon restoring
/// state is one whose VMs are already gone. So `createExec`'s
/// `guard containerState == "running"` below can never pass in a unit test.
///
/// MEASURED against the concrete `ContainerManager` with no stub anywhere,
/// seeding one row through `StateStore.saveContainer`, calling
/// `loadPersistedState()`, then `createExec`, once per stored status:
///
///     seeded=running -> getContainerState=exited  | createExec THREW: Container is not running
///     seeded=created -> getContainerState=created | createExec THREW: Container is not running
///     seeded=exited  -> getContainerState=exited  | createExec THREW: Container is not running
///     seeded=paused  -> getContainerState=paused  | createExec THREW: Container is not running
///
/// `getContainerState` answers truthfully in every case and `createExec` refuses
/// in every case. Without this seam every guard in `signalExec` below is
/// therefore unreachable without a VM, and an unreachable guard is one nothing
/// stops from being deleted.
///
/// The cost of the seam is that wiring `ExecManager` to the wrong source stopped
/// being a compile error. That is paid for by
/// `EngineManagerWiringTests.testTheExecManagerSeesTheEngineSOwnContainers`,
/// which asserts the production wiring. It is not optional: without it, an
/// engine whose every `exec` fails `No such container` against a container it is
/// holding passes the release gate.
///
/// `package` rather than `public`, and named for what it supplies rather than
/// for the type that supplies it, matching `NetworkAttachmentSource`
/// (`NetworkManager.swift:46-49`).
package protocol ExecContainerSource: Sendable {
    func getContainerState(id: String) async -> String?
    func getNativeContainer(id: String) async -> LinuxContainer?
}

extension ContainerManager: ExecContainerSource {}

/// Everything an exec session drives, and nothing else: creating an instance,
/// running it, acting on the process behind it, and the two questions the
/// session asks about its state.
///
/// **It exists for `ExecContainerSource`'s reason, one level up.** That seam
/// made `ExecManager`'s own guards reachable without a VM. It cannot make
/// `SandboxEngineService.runSession` reachable, because everything that session
/// has to get right on teardown happens after `startExec` has a `LinuxProcess`,
/// and a `LinuxProcess` comes from `LinuxContainer.exec` (`:310` below).
/// `LinuxContainer` is `final` and vends processes only out of its `started`
/// state (both `exec(_:configuration:)` overloads open with
/// `state.startedState("exec")` and record the process into that state's
/// `vendedProcesses`), which is reached by booting a virtual
/// machine. So against the concrete actor, `execInfo.process` is nil in every
/// VM-free test that can ever be written, `startExec` returns as soon as it
/// finds no native container, and the one situation the teardown exists for --
/// a guest that does not answer -- cannot be staged at all.
///
/// That is not an abstract gap. The session's teardown shipped three defects
/// that no test in this repository could see, each of them an `Exec` RPC that
/// never returns, and each needing an exec manager that can be told to hang.
/// `ExecTeardownTests` is what the seam bought; every measurement recorded there
/// reverts one defect and fails exactly the one test written for it.
///
/// **The two reads are narrower than `getExecInfo` deliberately.** An `ExecInfo`
/// carries a `LinuxProcess?`, so a protocol vending one could only be
/// implemented by something holding a real guest process -- the very thing no
/// test has. The session asks an exec's state two questions, and those two are
/// what this vends.
///
/// `package` rather than `public`, named for what it supplies rather than for
/// the type that supplies it, following `ExecContainerSource` above.
package protocol ExecInstanceSource: Sendable {
    func createExec(
        containerID: String,
        cmd: [String],
        env: [String]?,
        workingDir: String?,
        user: String?,
        tty: Bool,
        attachStdin: Bool,
        attachStdout: Bool,
        attachStderr: Bool
    ) async throws -> String

    func startExec(
        execID: String,
        detach: Bool,
        tty: Bool?,
        stdin: ReaderStream?,
        stdout: Writer?,
        stderr: Writer?
    ) async throws

    func resizeExec(execID: String, height: Int?, width: Int?) async throws
    func signalExec(execID: String, signal: Int32) async throws
    func deleteExec(execID: String) async throws

    /// Whether `startExec` has recorded this exec's guest process yet.
    func execProcessStarted(execID: String) async -> Bool

    /// The exit code `startExec` recorded, or nil if it recorded none.
    func execExitCode(execID: String) async -> Int?
}

extension ExecManager: ExecInstanceSource {}

/// Manages exec instances for running containers
public actor ExecManager {
    private let containerManager: any ExecContainerSource
    private let logger: Logger

    /// Information about an exec instance
    public struct ExecInfo: Sendable {
        public let id: String
        public let containerID: String
        public let config: ExecConfig
        public var process: LinuxProcess?
        public var running: Bool
        public var exitCode: Int?
        public var pid: Int32?
        public let createdAt: Date
        public var startedAt: Date?
        public var finishedAt: Date?

        public struct ExecConfig: Sendable {
            public let cmd: [String]
            public let env: [String]
            public let workingDir: String
            public let user: String?
            public let tty: Bool
            public let attachStdin: Bool
            public let attachStdout: Bool
            public let attachStderr: Bool
        }
    }

    /// Tracked exec instances by exec ID
    private var execInstances: [String: ExecInfo] = [:]

    /// `package` rather than `public` because `ExecContainerSource` is, and
    /// because every caller -- `ArcaDaemon.swift:209`, `EngineManagers.swift:86`
    /// -- is in this package. There is deliberately only this one initializer:
    /// a second one taking the concrete `ContainerManager` would be a way to
    /// build an `ExecManager` that the tests below cannot build.
    package init(containerManager: any ExecContainerSource, logger: Logger) {
        self.containerManager = containerManager
        self.logger = logger
    }

    /// Create a new exec instance
    public func createExec(
        containerID: String,
        cmd: [String],
        env: [String]?,
        workingDir: String?,
        user: String?,
        tty: Bool,
        attachStdin: Bool,
        attachStdout: Bool,
        attachStderr: Bool
    ) async throws -> String {
        logger.info("Creating exec instance", metadata: [
            "container_id": "\(containerID)",
            "cmd": "\(cmd)",
            "tty": "\(tty)"
        ])

        // Validate command
        guard !cmd.isEmpty else {
            throw ExecManagerError.invalidCommand("Command cannot be empty")
        }

        // Check container exists and is running
        guard let containerState = await containerManager.getContainerState(id: containerID) else {
            throw ExecManagerError.containerNotFound(containerID)
        }

        guard containerState == "running" else {
            throw ExecManagerError.containerNotRunning(containerID)
        }

        // Generate exec ID
        let execID = generateExecID()

        // Store exec instance info
        let execConfig = ExecInfo.ExecConfig(
            cmd: cmd,
            env: env ?? [],
            workingDir: workingDir ?? "/",
            user: user,
            tty: tty,
            attachStdin: attachStdin,
            attachStdout: attachStdout,
            attachStderr: attachStderr
        )

        let execInfo = ExecInfo(
            id: execID,
            containerID: containerID,
            config: execConfig,
            process: nil,
            running: false,
            exitCode: nil,
            pid: nil,
            createdAt: Date(),
            startedAt: nil,
            finishedAt: nil
        )

        execInstances[execID] = execInfo

        logger.info("Exec instance created", metadata: [
            "exec_id": "\(execID)",
            "container_id": "\(containerID)"
        ])

        return execID
    }

    /// Start an exec instance
    public func startExec(
        execID: String,
        detach: Bool,
        tty: Bool?,
        stdin: ReaderStream? = nil,
        stdout: Writer? = nil,
        stderr: Writer? = nil
    ) async throws {
        logger.info("Starting exec instance", metadata: [
            "exec_id": "\(execID)",
            "detach": "\(detach)"
        ])

        guard var execInfo = execInstances[execID] else {
            throw ExecManagerError.execNotFound(execID)
        }

        guard !execInfo.running else {
            throw ExecManagerError.execAlreadyRunning(execID)
        }

        // Get the container's native instance
        guard let nativeContainer = await containerManager.getNativeContainer(id: execInfo.containerID) else {
            throw ExecManagerError.containerNotFound(execInfo.containerID)
        }

        // Create process configuration
        var processConfig = LinuxProcessConfiguration()
        processConfig.arguments = execInfo.config.cmd

        // Only override environment if user specified any, otherwise keep defaults (including PATH)
        if !execInfo.config.env.isEmpty {
            processConfig.environmentVariables = execInfo.config.env
        }

        processConfig.workingDirectory = execInfo.config.workingDir
        processConfig.terminal = tty ?? execInfo.config.tty

        // Set up I/O streams based on attach configuration
        // For attached exec, we must provide writers/readers even if caller didn't specify
        // For detached exec, we shouldn't set them
        if !detach {
            // Set stdin if provided and attachStdin is true
            if let stdin = stdin, execInfo.config.attachStdin {
                processConfig.stdin = stdin
            }

            if let stdout = stdout {
                processConfig.stdout = stdout
            } else if execInfo.config.attachStdout {
                // Attached but no writer provided - this shouldn't happen in practice
                // but we need to handle it to avoid crashes
                logger.warning("Attached exec without stdout writer", metadata: ["exec_id": "\(execID)"])
            }

            // Only set stderr when NOT using a terminal (TTY merges stderr into stdout)
            if let stderr = stderr, !processConfig.terminal {
                processConfig.stderr = stderr
            } else if execInfo.config.attachStderr && !processConfig.terminal {
                // Attached but no writer provided
                logger.warning("Attached exec without stderr writer", metadata: ["exec_id": "\(execID)"])
            }
        }

        // Parse user if provided
        if let userStr = execInfo.config.user {
            processConfig.user = parseUser(userStr)
        }

        // Create LinuxProcess
        let process = try await nativeContainer.exec(execID, configuration: processConfig)

        // Start the process
        try await process.start()

        // Update exec info
        execInfo.process = process
        execInfo.running = true
        execInfo.pid = process.pid
        execInfo.startedAt = Date()
        execInstances[execID] = execInfo

        logger.info("Exec instance started", metadata: [
            "exec_id": "\(execID)",
            "pid": "\(process.pid)"
        ])

        // If not detached, wait for process to complete
        if !detach {
            let exitStatus = try await process.wait()

            // Close output streams to signal completion
            // This finishes the AsyncStream continuations
            // Works for both RawWriter (TTY mode) and StreamingWriter (non-TTY mode)
            if let writer = stdout {
                do {
                    try writer.close()
                } catch {
                    logger.warning("Failed to close stdout writer", metadata: [
                        "exec_id": "\(execID)",
                        "error": "\(error)"
                    ])
                }
            }

            if let writer = stderr {
                do {
                    try writer.close()
                } catch {
                    logger.warning("Failed to close stderr writer", metadata: [
                        "exec_id": "\(execID)",
                        "error": "\(error)"
                    ])
                }
            }

            // Update exec info with exit status
            execInfo.running = false
            execInfo.exitCode = Int(exitStatus.exitCode)
            execInfo.finishedAt = Date()
            execInstances[execID] = execInfo

            // Clean up process
            try await process.delete()

            logger.info("Exec instance completed", metadata: [
                "exec_id": "\(execID)",
                "exit_code": "\(exitStatus.exitCode)"
            ])
        }
    }

    /// Get exec instance info
    public func getExecInfo(execID: String) -> ExecInfo? {
        return execInstances[execID]
    }

    /// Whether `startExec` has reached `:316` for this exec and recorded its
    /// process.
    ///
    /// The one fact `signalExec`'s and `resizeExec`'s start-window guards turn
    /// on, answered on its own so that a caller waiting for the window to close
    /// does not have to hold an `ExecInfo` -- and so that
    /// `ExecInstanceSource` can vend it without vending a `LinuxProcess`.
    /// **Never reset:** nothing clears `process` once set, so a false here means
    /// the process has not started, never that it has finished.
    public func execProcessStarted(execID: String) -> Bool {
        execInstances[execID]?.process != nil
    }

    /// The exit code `startExec` recorded at `:358`, or nil for an exec that has
    /// not got that far.
    public func execExitCode(execID: String) -> Int? {
        execInstances[execID]?.exitCode
    }

    /// Resize the TTY for an exec instance
    public func resizeExec(execID: String, height: Int?, width: Int?) async throws {
        guard let execInfo = execInstances[execID] else {
            throw ExecManagerError.execNotFound(execID)
        }

        guard execInfo.config.tty else {
            // Not an error - just silently ignore resize for non-TTY exec
            logger.debug("Ignoring resize for non-TTY exec", metadata: ["exec_id": "\(execID)"])
            return
        }

        // Race condition: Docker client may send resize before process is fully started
        // This is normal behavior - silently ignore if process not ready yet
        guard let process = execInfo.process else {
            logger.debug("Ignoring resize - exec process not started yet", metadata: ["exec_id": "\(execID)"])
            return
        }

        let h = UInt16(height ?? 24)
        let w = UInt16(width ?? 80)

        logger.debug("Resizing exec TTY", metadata: [
            "exec_id": "\(execID)",
            "height": "\(h)",
            "width": "\(w)"
        ])

        let size = Terminal.Size(width: w, height: h)
        try await process.resize(to: size)
    }

    /// Forward a signal to an exec instance's process.
    ///
    /// `signal` is the raw number, not a `Containerization.Signal`, and that is
    /// the point. `Signal.init(rawValue:)` is not failable
    /// (`Signal.swift:31-33`) and `Signal` is `ExpressibleByIntegerLiteral`, so a
    /// `Signal` parameter would carry no validation whatsoever while looking as
    /// though it did -- the caller would reach the same unchecked number through
    /// a type that reads as checked. The wire agrees: `ExecClientFrame`'s signal
    /// arm is `int32 signal = 4` (`proto/arca/engine/v1/engine.proto:437`). So
    /// the number arrives raw and is validated here, once.
    ///
    /// Validation is Containerization's own `Signal.init(_:from:)`
    /// (`Signal.swift:36-50`), reached by handing it the number as a string:
    /// that initializer's numeric branch rejects anything absent from
    /// `Signal.linux`, which is the right map because `LinuxProcess.kill` sends
    /// to a Linux guest. It admits 1...31 and 34...64 and throws
    /// `SignalError.invalidSignal` for everything else -- including 0, which is
    /// an existence probe rather than a signal to forward. That error is left to
    /// propagate rather than rewrapped: the fact already has a name in this
    /// repository and a second one for it would be a second vocabulary.
    ///
    /// **Unlike `resizeExec` above, a process that has not started is an error
    /// here, not a silent return.** That difference is deliberate and it is the
    /// reason this method exists in this shape. A window size that arrives
    /// before the process does is genuinely unimportant, so `resizeExec` drops
    /// it. A signal is not: dropping one while telling the caller nothing is the
    /// same defect as an engine that publishes no ports and reports success. The
    /// caller is told.
    ///
    /// The signal check precedes the process check so that a bad signal number
    /// is reported as a bad signal number even for an exec that never started,
    /// which is also what makes that validation reachable from a test.
    ///
    /// That a signal actually arrives at a guest process is **not** verified by
    /// anything here; that needs a live VM and belongs to the live tier. Be
    /// precise about what the VM-free tests do buy, because it is less than it
    /// looks: **they pin the guards, not the send.** MEASURED, with
    /// `try await process.kill(resolved)` below replaced by `_ = process`:
    /// `swift test --filter ExecSignalTests` -> `Executed 4 tests, with 0
    /// failures`. Every test stops at the `execNotStarted` guard, so none of them
    /// reaches the line that does the work.
    ///
    /// **Consequence for whoever writes the live tier: it must assert an
    /// observable effect on the guest process -- an exit status, a handler
    /// running, a wait that returns -- and not merely that `signalExec` returned
    /// without throwing.** A live test asserting only "no error" leaves the
    /// deleted-`kill` mutation above green at every tier, and the `signals`
    /// capability flag would then be raised over a signal path that sends
    /// nothing.
    public func signalExec(execID: String, signal: Int32) async throws {
        guard let execInfo = execInstances[execID] else {
            throw ExecManagerError.execNotFound(execID)
        }

        let resolved = try Signal(String(signal))

        guard let process = execInfo.process else {
            throw ExecManagerError.execNotStarted(execID)
        }

        logger.info("Signalling exec instance", metadata: [
            "exec_id": "\(execID)",
            "signal": "\(resolved.rawValue)"
        ])

        try await process.kill(resolved)
    }

    /// Delete an exec instance
    public func deleteExec(execID: String) async throws {
        logger.info("Deleting exec instance", metadata: ["exec_id": "\(execID)"])

        guard let execInfo = execInstances[execID] else {
            throw ExecManagerError.execNotFound(execID)
        }

        // If process exists and is running, clean it up
        if let process = execInfo.process {
            do {
                try await process.delete()
            } catch {
                logger.warning("Failed to delete process", metadata: [
                    "exec_id": "\(execID)",
                    "error": "\(error)"
                ])
            }
        }

        execInstances.removeValue(forKey: execID)

        logger.info("Exec instance deleted", metadata: ["exec_id": "\(execID)"])
    }

    // MARK: - Helper Methods

    /// Generate a unique exec ID (similar to container ID format)
    private func generateExecID() -> String {
        // Docker exec IDs are 64-character hex strings
        let uuid = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        return uuid.lowercased() + uuid.lowercased()
    }

    /// Parse user string into User struct
    /// Format: "username" or "uid" or "username:group" or "uid:gid"
    private func parseUser(_ userStr: String) -> ContainerizationOCI.User {
        // Handle empty user string
        guard !userStr.isEmpty else {
            return ContainerizationOCI.User()
        }

        let parts = userStr.split(separator: ":", maxSplits: 1)

        // Handle case where split resulted in empty array
        guard !parts.isEmpty else {
            return ContainerizationOCI.User()
        }

        var user = ContainerizationOCI.User()

        // Parse UID or username
        if let uid = UInt32(parts[0]) {
            user.uid = uid
        } else {
            user.username = String(parts[0])
        }

        // Parse GID if provided (groupname not supported by OCI spec)
        if parts.count > 1 {
            if let gid = UInt32(parts[1]) {
                user.gid = gid
            }
            // Note: groupname is not supported in ContainerizationOCI.User
            // Only numeric GID is supported
        }

        return user
    }
}

// MARK: - Error Types

public enum ExecManagerError: Error, CustomStringConvertible {
    case execNotFound(String)
    case execAlreadyRunning(String)
    /// The exec instance exists but `startExec` has not run, so it has no
    /// process to act on. Distinct from `containerNotRunning`, which is about the
    /// container: the container here may be running perfectly well.
    case execNotStarted(String)
    case containerNotFound(String)
    case containerNotRunning(String)
    case invalidCommand(String)
    case startFailed(String)

    public var description: String {
        switch self {
        case .execNotFound(let id):
            return "No such exec instance: \(id)"
        case .execAlreadyRunning(let id):
            return "Exec instance already running: \(id)"
        case .execNotStarted(let id):
            return "Exec instance has not been started: \(id)"
        case .containerNotFound(let id):
            return "No such container: \(id)"
        case .containerNotRunning(let id):
            return "Container is not running: \(id)"
        case .invalidCommand(let msg):
            return "Invalid command: \(msg)"
        case .startFailed(let msg):
            return "Failed to start exec: \(msg)"
        }
    }
}
