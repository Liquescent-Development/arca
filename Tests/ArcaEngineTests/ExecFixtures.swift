import ContainerBridge
import Foundation
import Logging
import SandboxEngineProto

@testable import ArcaEngine

/// The engine, the container and the opening frame that every `Exec` suite needs
/// in front of it, in one place.
///
/// `ExecTests` drives the refusals and `ExecTeardownTests` drives the session,
/// and both need the same setup: the engine's own managers over a throwaway
/// state root, holding one labelled container under the sandbox's name. Spelt
/// out twice, the two suites could come to be testing two different engines --
/// and the second one to drift is the one whose failure nobody would read as a
/// drift.
enum ExecFixtures {
    static let logger = Logger(label: "arca-engine-exec-tests")

    /// 64 characters, because `loadPersistedState()` keys `reverseMapping` on
    /// the first 32 and `listContainers` drops any container missing from it.
    static let dockerID = String(repeating: "a", count: 64)
    static let sandboxID = "exec-a1b2c3d4e5f6"
    static let image = "ghcr.io/liquescent-development/gascan/workspace@sha256:"
        + String(repeating: "1", count: 64)

    static let ownerLabels = Arca_Engine_V1_OwnerLabels.with {
        $0.managedBy = "gascan"
        $0.sandboxID = sandboxID
    }

    static func start(sandboxID: String) -> Arca_Engine_V1_ExecClientFrame {
        Arca_Engine_V1_ExecClientFrame.with { frame in
            frame.start = Arca_Engine_V1_ExecStart.with { start in
                start.sandboxID = sandboxID
                start.argv = [Data("/bin/sh".utf8)]
            }
        }
    }

    /// The engine's own managers over a throwaway state root, as `LogsTests` and
    /// `InspectTests` build them and for their reason: this is the factory
    /// `arca-engine` calls, so what these tests drive is what it serves.
    static func managers() throws -> EngineManagers {
        try EngineManagers(
            stateRoot: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("arca-exec-tests-\(UUID().uuidString)"),
            kernelPath: URL(fileURLWithPath: "/opt/arca/vmlinux"),
            logLevel: "info",
            logger: logger
        )
    }

    /// One container row through `StateStore` and then `loadPersistedState()`,
    /// which is the restore path the engine itself runs.
    static func seed(_ managers: EngineManagers, labels: [String: String]) async throws {
        try await managers.stateStore.saveContainer(
            id: dockerID,
            name: sandboxID,
            image: image,
            imageID: "sha256:probe",
            createdAt: Date(),
            status: "created",
            running: false,
            paused: false,
            restarting: false,
            pid: 0,
            exitCode: 0,
            startedAt: nil,
            finishedAt: Date(),
            stoppedByUser: false,
            entrypoint: nil,
            configJSON: String(
                decoding: try JSONEncoder().encode(
                    ContainerConfiguration(image: image, labels: labels)
                ),
                as: UTF8.self
            ),
            hostConfigJSON: String(
                decoding: try JSONEncoder().encode(HostConfig(portBindings: [:])),
                as: UTF8.self
            )
        )
        try await managers.containerManager.loadPersistedState()
    }
}
