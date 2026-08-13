import ContainerBridge
import Foundation
import Logging

/// What an `image load` put where.
///
/// `storeRoot` is read back from the `ImageManager` that performed the load,
/// not re-derived from the state root beside it. The whole milestone rests on
/// the engine's image store being its own -- ArcaDaemon shares Apple's and
/// deletes `initfs.ext4` out of it on every start -- so a load that quietly
/// wrote into the shared store would undo it silently, and a report that
/// restated the expected path could not tell anyone that it had. The value here
/// is the one the store actually used.
///
/// `references` is what distinguishes loading something from loading nothing.
/// A load that reports only success is the shape this project has been bitten
/// by repeatedly.
package struct ImageLoadReport: Sendable, Equatable {
    package let storeRoot: URL
    package let references: [String]

    package init(storeRoot: URL, references: [String]) {
        self.storeRoot = storeRoot
        self.references = references
    }
}

/// The option `loadWorkspaceImages` refuses on behalf of, so a refusal names
/// the thing the user would change.
///
/// Deliberately not `--vminit-layout`. That one is a *startup input* the engine
/// must hold before it can construct a manager at all; this one is *content a
/// consumer pushes* afterwards. Two concerns, two options, and keeping them
/// apart is what avoids an install-time ordering step between them.
private let ociLayoutOption = "--oci-layout"

/// Loads an OCI image layout into the engine's OWN image store, and reports
/// which references landed and where.
///
/// Lives in `ArcaEngine` and not in the `arca-engine` executable for the reason
/// `EnginePaths` and `EngineManagers` do: a test target cannot import an
/// executable, so a load only the executable can reach is a load no test can
/// assert on. `ImageLoadTests` drives this function directly, and the
/// subcommand over it by spawning the binary.
///
/// Nothing here calls `initialize()` on anything, and nothing here needs to.
/// `ImageManager` opens its `ImageStore` in `init` and its own `initialize()`
/// only logs (`ContainerBridge/ImageManager.swift:40-48`), while the
/// `initialize()` that matters -- `ContainerManager`'s -- constructs a live
/// `Containerization.VmnetNetwork` and needs an entitlement. An image load that
/// demanded a VM and an entitlement is an image load that could not run in CI,
/// so this deliberately touches neither, binds no socket, and serves nothing.
///
/// The load is wrapped rather than left to throw raw. `ImageStore.load` refuses
/// a layout it can import nothing from -- it throws `failed to import image`
/// when the imported set is empty
/// (containerization/Sources/Containerization/Image/ImageStore/ImageStore+OCILayout.swift:101-103)
/// -- and it refuses a truncated blob too, but neither message names an option
/// or a path, which is the failure `validateOCILayoutDirectory`'s
/// existence-only marker check leaves behind. Wrapping keeps the cause verbatim
/// and adds the two things a user needs to act: which option, and which path.
package func loadWorkspaceImages(
    fromOCILayout layout: URL,
    stateRoot: URL,
    logger: Logger
) async throws -> ImageLoadReport {
    // Before the store is opened, so a bad layout leaves no state root behind:
    // the same posture, and the same ordering, that `validateEngineInputs`
    // holds ahead of `createSocketParentDirectory` at startup.
    try validateOCILayoutDirectory(layout, option: ociLayoutOption)

    let imageManager = try EngineManagers.makeImageManager(
        paths: EnginePaths(stateRoot: stateRoot), logger: logger
    )

    // `[Containerization.Image]` is never named here, only mapped over, which is
    // what keeps `ArcaEngine`'s declared dependencies as they are: `loadVminit`
    // reads the same return value the same way, and neither needs the module
    // imported to do it.
    let references: [String]
    do {
        references = try await imageManager.loadFromOCILayout(directory: layout)
            .map(\.reference)
    } catch {
        throw EngineStartupError.unreadableInput(
            name: ociLayoutOption, path: layout.path, cause: "\(error)"
        )
    }

    let report = ImageLoadReport(storeRoot: imageManager.storeRoot, references: references)
    logger.info("loaded images into the engine's own store", metadata: [
        "store": "\(report.storeRoot.path)",
        "count": "\(report.references.count)",
        "images": "\(report.references.joined(separator: ", "))",
    ])
    return report
}
