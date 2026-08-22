import ContainerBridge
import Foundation
import Logging
import XCTest
@testable import ArcaEngine

/// The restore loop's crash-recovery write -- the milestone's whole thesis.
///
/// `ContainerManager.initialize()` ends in `loadPersistedState()`, which marks
/// every container the StateStore records as `running` exited with code 137 and
/// **writes that back** (`ContainerManager.swift:371-393`). That write is what
/// made `initialize()` unsafe against a state root shared with a live
/// ArcaDaemon, and giving the engine its own root is what made it safe.
///
/// A real start against a fresh root reports `Found persisted containers count=0`
/// and `restored=0`. That proves the loop RAN and says nothing about what it does
/// to a `running` row -- which is the only part anyone depends on. Nobody would
/// learn a mis-decode or a write against the wrong row until an engine restarted
/// holding live containers, the one moment the write matters.
///
/// `loadPersistedState()` is `package` precisely so this can be driven: it is
/// VM-free and needs no kernel, no vminit and no vmnet, unlike the
/// `initialize()` that normally calls it. That also makes it the only way the
/// loop executes at all while `arca-engine` is unsigned, since an unsigned
/// engine dies at `VmnetNetwork()` before ever reaching it.
final class CrashRecoveryTests: XCTestCase {
    private static let unbootedKernel = URL(fileURLWithPath: "/opt/arca/vmlinux")
    private let logger = Logger(label: "arca-engine-tests")

    /// Two containers, not one, and the survivor carries a distinctive exit
    /// code.
    ///
    /// With a single `running` container, "everything is now 137" and "the
    /// running one is now 137" are the same observation, and the first is a real
    /// failure mode: dropping the `status == "running"` guard rewrites every
    /// stopped container's exit code to 137, so `docker ps -a` would report a
    /// clean exit as a SIGKILL forever after. The second seed exits 42 and must
    /// still exit 42.
    ///
    /// Asserted in memory AND in the store. The in-memory half alone cannot
    /// distinguish a correct write from one aimed at the wrong row -- the loop
    /// builds `ContainerInfo` from its own local `actualExitCode`, so the map
    /// would read 137 even if `updateContainerStatus` had written to the other
    /// container. The store is read back through a SECOND `StateStore` over the
    /// same file, so what is asserted is what persisted, not what one connection
    /// remembers.
    ///
    /// MEASURED, both halves load-bearing (`swift test --filter ArcaEngineTests`):
    ///
    /// - with the `status == "running"` guard widened to `if true`, so every row
    ///   recovers: `Executed 63 tests, with 2 failures` -- the survivor's exit
    ///   code read 137 instead of 42, in memory and in the store.
    /// - with the `stateStore.updateContainerStatus` call deleted and the
    ///   in-memory recovery left intact: `Executed 63 tests, with 3 failures`,
    ///   and **every in-memory assertion above still passed**. Only the three
    ///   store assertions caught it. That is the whole reason this test reads the
    ///   database back.
    ///
    /// Restored: `Executed 63 tests, with 0 failures`.
    func testARunningContainerIsRecoveredAsExited137AndNoOtherRowIsTouched() async throws {
        let paths = Self.temporaryPaths()
        let seedStore = try StateStore(path: paths.stateDatabase.path, logger: logger)
        try await Self.seed(
            into: seedStore, id: Self.crashedID, name: "crashed-probe",
            status: "running", running: true, exitCode: 0, finishedAt: nil
        )
        try await Self.seed(
            into: seedStore, id: Self.stoppedID, name: "stopped-probe",
            status: "exited", running: false, exitCode: 42, finishedAt: Date()
        )

        let manager = Self.manager(paths: paths, stateStore: seedStore, logger: logger)
        try await manager.loadPersistedState()

        // In memory, through the public read the engine's Inspect will use.
        let crashedRead = try await manager.getContainer(id: Self.crashedID)
        let crashed = try XCTUnwrap(crashedRead)
        XCTAssertEqual(
            crashed.state.status, "exited",
            "a container the StateStore recorded as running died with the previous "
                + "engine process; the VM is gone and it must not read as running"
        )
        XCTAssertEqual(
            crashed.state.exitCode, 137,
            "crash recovery reports SIGKILL (128 + 9), which is what killed the VM"
        )

        let stoppedRead = try await manager.getContainer(id: Self.stoppedID)
        let stopped = try XCTUnwrap(stoppedRead)
        XCTAssertEqual(stopped.state.status, "exited")
        XCTAssertEqual(
            stopped.state.exitCode, 42,
            "a container that was already exited must keep the code it exited with; "
                + "rewriting every row to 137 would report every clean exit as a kill"
        )

        // In the store, through a second connection over the same database.
        let reread = try StateStore(path: paths.stateDatabase.path, logger: logger)
        let rows = try await Dictionary(
            uniqueKeysWithValues: reread.loadAllContainers().map { ($0.id, $0) }
        )

        let crashedRow = try XCTUnwrap(rows[Self.crashedID])
        XCTAssertEqual(
            crashedRow.status, "exited",
            "the recovery must be persisted, or the next start recovers it again"
        )
        XCTAssertEqual(crashedRow.exitCode, 137)
        XCTAssertNotNil(
            crashedRow.finishedAt,
            "a container recorded as exited with no finish time is a row Inspect "
                + "cannot answer about"
        )

        let stoppedRow = try XCTUnwrap(rows[Self.stoppedID])
        XCTAssertEqual(
            stoppedRow.exitCode, 42,
            "the write must land on the crashed container's row and no other; the "
                + "in-memory assertions above cannot see a write aimed at this one"
        )
        XCTAssertEqual(stoppedRow.status, "exited")
    }

    // MARK: - Fixtures

    /// Docker IDs are 64 characters, and `loadPersistedState()` derives the
    /// native ID from the first 32 -- two seeds sharing those 32 would overwrite
    /// each other in `reverseMapping` and one would vanish from every listing.
    private static let crashedID = String(repeating: "a", count: 64)
    private static let stoppedID = String(repeating: "b", count: 64)

    private static func temporaryPaths() -> EnginePaths {
        EnginePaths(
            stateRoot: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("arca-crash-recovery-\(UUID().uuidString)")
        )
    }

    private static func manager(
        paths: EnginePaths, stateStore: StateStore, logger: Logger
    ) -> ContainerManager {
        ContainerManager(
            imageManager: try! ImageManager(
                logger: logger, imageStorePath: paths.imageStoreRoot
            ),
            kernelPath: unbootedKernel.path,
            imageStoreRoot: paths.imageStoreRoot,
            imageRootfsCachePath: paths.imageRootfs,
            logRoot: paths.logsRoot,
            stateStore: stateStore,
            logger: logger
        )
    }

    private static func seed(
        into store: StateStore,
        id: String,
        name: String,
        status: String,
        running: Bool,
        exitCode: Int,
        finishedAt: Date?
    ) async throws {
        let encoder = JSONEncoder()
        try await store.saveContainer(
            id: id,
            name: name,
            image: "arca/probe:latest",
            imageID: "sha256:probe",
            createdAt: Date(),
            status: status,
            running: running,
            paused: false,
            restarting: false,
            pid: 0,
            exitCode: exitCode,
            startedAt: Date(),
            finishedAt: finishedAt,
            stoppedByUser: false,
            entrypoint: nil,
            configJSON: String(
                decoding: try encoder.encode(
                    ContainerConfiguration(image: "arca/probe:latest")
                ),
                as: UTF8.self
            ),
            hostConfigJSON: String(decoding: try encoder.encode(HostConfig()), as: UTF8.self)
        )
    }
}
