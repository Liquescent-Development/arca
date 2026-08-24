import Containerization
import ContainerizationOCI
import Foundation
import Logging
import XCTest
@testable import ContainerBridge

/// Two seams on the create path that the rest of the suite cannot see.
///
/// **Both tests below run the code they are about. Neither reads a source file.** That is
/// worth stating because until this commit the first one did read source text and count a
/// string, and it was defeated five times in a row: by a comment naming the symbol, by a
/// comment naming it with its receiver, by `//` inside a string literal eating the line after
/// it, by a string literal supplying the token, and by string interpolation smuggling quotes
/// past a tokenizer. Each repair closed one spelling and left the class open, and the fifth
/// left a sibling guard weaker than it had been before. The instrument was the defect:
/// approximating a compiler well enough to say "this is code" is not something a test should
/// be doing.
///
/// What made a text guard look necessary was a design problem in the production code, not a
/// missing test technique. `ContainerManager.initialize()` builds a `Kernel` and a
/// `Containerization.VmnetNetwork`, so it needs a kernel image and a VM that this target does
/// not have -- and preparing the image rootfs cache was welded to it, out of reach for that
/// reason alone. `ContainerManager.openImageRootfsCache(at:capacityInBytes:logger:)` is that
/// preparation on its own, so the first test simply calls it.
///
/// `ContainerManager.writableLayer(at:sizeInBytes:)` is `internal` and was always callable
/// directly, and the mutation the second test has to catch lives inside the function. What it
/// does NOT prove is that `createNativeContainer` calls it -- nothing in this repository can
/// prove that, and Gas Can's live `Create` test is the instrument that can.
final class CreatePathSeamTests: XCTestCase {

    // MARK: - Opening the image rootfs cache

    /// Opening the cache sweeps the orphans a crash left, spares promoted slots, and hands
    /// back an unpacker rooted where it swept.
    ///
    /// **Why this is the claim and not "the reaper is called from initialize()".** Nothing
    /// else assigns `ContainerManager.rootfsUnpacker`, and `createNativeContainer` reads it
    /// through a `guard let` that throws `.notInitialized`, so an `initialize()` that stopped
    /// calling this seam could not create a container at all. That half needs no test; it is
    /// enforced by the optional. What is not enforced anywhere else is what the seam *does*,
    /// which is this test.
    ///
    /// **The three assertions guard three different mistakes.**
    ///
    /// - **The orphan must go.** A staging file is what a failure that runs no cleanup leaves
    ///   behind -- a crash, a `SIGKILL`, a power loss between the unpack and the `rename`.
    ///   Each is a fully sized rootfs, gigabytes in production, under a UUID no later call
    ///   will choose again, so they accumulate one per crash forever. Drop the sweep from the
    ///   seam and this assertion is the only thing that notices.
    /// - **The promoted slot must survive.** A sweep that took the whole directory, or that
    ///   matched `rootfs.ext4` as a prefix, would satisfy the first assertion while deleting
    ///   every cached image on the machine.
    /// - **The returned unpacker must be rooted at the cache root that was swept.** A seam
    ///   that swept one root and returned an unpacker over another would pass the first two
    ///   and leave every real unpack writing somewhere nothing ever sweeps.
    ///
    /// The opposite mistake -- sweeping *before each unpack*, which would delete a concurrent
    /// call's in-flight staging file and turn a safe race into a corrupt one -- cannot be seen
    /// from here, because it is a property of the unpack path rather than of this seam. It is
    /// pinned by `ImageRootfsUnpackerTests`.`testAnUnpackSparesAConcurrentCallsStagingFile`.
    func testOpeningTheCacheSweepsOrphansSparesSlotsAndIsRootedWhereItSwept() throws {
        let cacheRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("arca-cache-seam-\(UUID().uuidString)")
        let imageDirectory = cacheRoot
            .appendingPathComponent("sha256-cafebabe")
            .appendingPathComponent("linux-arm64")
        try FileManager.default.createDirectory(
            at: imageDirectory, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: cacheRoot) }

        // Exactly what a SIGKILL between the unpack and the rename leaves behind, beside
        // exactly what a completed unpack leaves behind.
        let orphan = imageDirectory
            .appendingPathComponent("rootfs.ext4.staging-\(UUID().uuidString)")
        let promoted = imageDirectory.appendingPathComponent("rootfs.ext4")
        for file in [orphan, promoted] {
            XCTAssertTrue(
                FileManager.default.createFile(
                    atPath: file.path, contents: Data(repeating: 0, count: 4096)
                ),
                "the fixture must create the file it is about to assert on: \(file.path)"
            )
        }

        let unpacker = try ContainerManager.openImageRootfsCache(
            at: cacheRoot,
            capacityInBytes: 4096,
            logger: Logger(label: "arca-engine-tests")
        )

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: orphan.path),
            "opening the cache left a staging file orphaned by a crash in place; each one is "
                + "a full rootfs and they accumulate one per crash, forever"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: promoted.path),
            "opening the cache deleted a promoted rootfs, not just the orphan beside it"
        )
        XCTAssertEqual(
            unpacker.rootfsPath(
                forImageDigest: "sha256:cafebabe",
                platform: SystemPlatform.linuxArm.ociPlatform()
            ),
            promoted,
            "the unpacker handed back must be rooted at the cache root that was swept, or "
                + "every real unpack writes somewhere nothing ever sweeps"
        )
    }

    // MARK: - The writable upper layer

    /// The container's writable layer is created once, reused after, and mounted writable.
    ///
    /// **`options` must be empty, and the rootfs beside it is now handled the opposite way.**
    /// `LinuxContainer.create()` inserts the writable layer verbatim
    /// (`containerMounts.insert(writableLayer, at: 1)`), so `Mount.readonly` reaches the
    /// `VZDiskImageStorageDeviceAttachment(readOnly:)` built by
    /// `VZDiskImageStorageDeviceAttachment.mountToVZAttachment(mount:options:)` here, and a
    /// `"ro"` on this mount attaches the overlay's upper layer read-only.
    ///
    /// The rootfs is ASSERTED `"ro"` on this path, not stripped: because a writable layer is
    /// supplied, `create()` keeps the shared per-image slot read-only so more than one guest
    /// can attach it. At `a5803b6` it stripped unconditionally, and this comment said so.
    ///
    /// **MEASURED that nothing else catches it:** with the helper's options changed from
    /// `[]` to `["ro"]` and a clean `.build`, `swift test --filter ArcaEngineTests` reported
    /// `Executed 260 tests, with 0 failures`.
    ///
    /// `created` is asserted in both directions because the create path branches on it to
    /// decide whether to log, and because "an existing file is a hit, not an error" is the
    /// behaviour that lets a container be recreated from persisted state.
    ///
    /// The size is 2 MiB rather than the production 64 GB: `EXT4.Formatter` treats it as a
    /// floor and the file is sparse either way, and nothing here depends on the capacity.
    ///
    /// WHAT THIS DOES NOT PROVE: that `createNativeContainer` calls this at all. It guards
    /// on `nativeManager`, which only `initialize()` sets, so the call site is unreachable
    /// from this target.
    func testTheWritableLayerIsCreatedOnceAndMountedWritable() throws {
        let path = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("arca-writable-layer-\(UUID().uuidString)")
            .appendingPathComponent("writable.ext4")
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }

        let first = try ContainerManager.writableLayer(at: path, sizeInBytes: 2 * 1024 * 1024)

        XCTAssertTrue(first.created, "the first call must have formatted the filesystem")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: path.path),
            "the writable layer must exist at the path the mount names, got nothing at "
                + path.path
        )
        XCTAssertEqual(first.mount.source, path.path)
        XCTAssertTrue(first.mount.isBlock, "the writable layer must be a block device")
        // `type` and not just `isBlock`: `Mount.block(format:source:destination:options:)`
        // stores `format` AS `type`, while `Mount.isBlock` reads `runtimeOptions` and is
        // true for any format at all -- so `isBlock` alone cannot see "ext4" become
        // "ext3". The format is also the half that survives into the guest: upstream
        // overwrites `destination` before mounting (`upperMount.destination =
        // upperMountPath` in `LinuxContainer.mountRootfs(...)`) and
        // leaves `type` alone, so it is what the guest actually tries to mount as.
        XCTAssertEqual(
            first.mount.type, "ext4",
            "the writable layer must be formatted and declared ext4 -- EXT4.Formatter wrote "
                + "it, and this string is what the guest mounts it as"
        )
        XCTAssertTrue(
            first.mount.options.isEmpty,
            "the writable layer must attach writable -- it is the overlay's upper layer and "
                + "the guest writes to it. \"ro\" here reaches the VZ attachment verbatim, "
                + "unlike the rootfs, which create() asserts \"ro\" on so the shared slot "
                + "stays shareable. Got \(first.mount.options)"
        )

        let second = try ContainerManager.writableLayer(at: path, sizeInBytes: 2 * 1024 * 1024)
        XCTAssertFalse(
            second.created,
            "an existing writable layer is a hit and not an error: recreating a container "
                + "from persisted state must not reformat the filesystem it was using"
        )
        XCTAssertTrue(second.mount.options.isEmpty)
    }
}
