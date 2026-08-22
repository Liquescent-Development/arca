import Containerization
import Foundation
import XCTest
@testable import ContainerBridge

/// Two seams on the create path that the rest of the suite cannot see.
///
/// READ THIS BEFORE TRUSTING THE FIRST TEST BELOW. It reads
/// `Sources/ContainerBridge/ContainerManager.swift` as text. It executes none of it and
/// proves nothing about runtime. It is text because the runtime is out of reach:
/// `ContainerManager.initialize()` builds a `Kernel` and a `Containerization.VmnetNetwork`,
/// so it needs a kernel image and a VM and this target has neither. That is the same reason
/// `ContainerBridgePathsTests` gives for its own two source-text guards, and this file uses
/// the same reader.
///
/// The second test is not a text guard. `ContainerManager.writableLayer(at:sizeInBytes:)` is
/// `internal`, so it can be called directly, and the mutation it has to catch lives inside
/// the function. What it does NOT prove is that `createNativeContainer` calls it -- nothing
/// in this repository can prove that, and Gas Can's live `Create` test is the instrument
/// that can.
final class CreatePathSeamTests: XCTestCase {

    // MARK: - The staging reaper's only production caller

    /// `initialize()` sweeps orphaned staging files exactly once, and nothing else does.
    ///
    /// **MEASURED that nothing else catches this:** with
    /// `try unpacker.reapOrphanedStagingFiles()` deleted from `initialize()` and a clean
    /// `.build`, `swift test --filter ArcaEngineTests` reported `Executed 260 tests, with 0
    /// failures`. `ImageRootfsUnpackerTests` drives the reaper directly, so the reaper is
    /// tested; its only caller was not, and deleting the call was silent.
    ///
    /// **Both halves of the assertion are load-bearing, and they guard opposite mistakes.**
    /// A staging file is left behind by the failure that runs no cleanup at all -- a crash,
    /// a `SIGKILL`, a power loss between the unpack and the `rename`. Each is a fully sized
    /// rootfs, gigabytes in production, under a UUID no later call will choose again.
    ///
    /// - **Not fewer.** Drop the call and they accumulate one per crash, forever.
    /// - **Not more.** Sweeping before each unpack would delete a concurrent call's
    ///   in-flight staging file out from under it, turning a race that is safe today --
    ///   distinct UUID paths, verify, atomic `rename(2)` -- into a corrupt one. That is why
    ///   the whole-file count is asserted and not just the presence inside `initialize()`.
    ///
    /// **Both assertions scan `SwiftSource.codeOnly`, and neither is sound over raw text.**
    /// Two different things can supply this token without a call existing. The call-site
    /// comment at `ContainerManager.swift:327` names the symbol and sits *inside* the
    /// `initialize()` window the second assertion scans, so an edit that deleted the call and
    /// rewrote that comment to name what it had removed would leave both assertions green. So
    /// would replacing the call with `logger.info("reapOrphanedStagingFiles() moved")` -- a
    /// string literal, measured green at `0e9dad1`. No choice of searched-for spelling fixes
    /// either, because any spelling a call can have, a comment or a literal can have too.
    /// Counting only code closes the class rather than one shape of it.
    ///
    /// **A comment-only strip is not enough, and the reason is the count.** Stripping is a
    /// shrinking transform, so for the *presence* check its failure direction is a false RED.
    /// For an equality-to-one it is not: over-stripping carries a failing 2 down to a passing
    /// 1. Measured at `0e9dad1` with a comment-only stripper, a real second sweep written
    /// `if config.image.reference.hasPrefix("oci://") { try rootfsUnpacker.reapOrphanedStagingFiles() }`
    /// passed, because the `//` inside `"oci://"` ate the rest of the line and took the second
    /// call with it. `codeOnly` is literal-aware, so that `//` is text inside a literal and
    /// nothing is eaten.
    ///
    /// The sibling guard `ContainerBridgePathsTests`.`testTheContainersDirectoryIsDerivedInExactlyOnePlace`
    /// counts a token in this same file and had the same two holes; it uses
    /// `SwiftSource.codeWithFlattenedLiterals` because its token is a literal. Change one of
    /// these two and look at the other.
    func testTheStagingReaperIsCalledExactlyOnceAndFromInitialize() throws {
        let source = try BridgeSources.containerManager()
        let call = "reapOrphanedStagingFiles()"

        XCTAssertEqual(
            SwiftSource.codeOnly(source).components(separatedBy: call).count - 1, 1,
            "exactly one occurrence of the staging reaper must survive in the code of this "
                + "file, comments and string-literal text excluded: zero means orphaned "
                + "staging files accumulate one full rootfs per crash forever, and more than "
                + "once means something sweeps outside initialize(), which would delete a "
                + "concurrent unpack's in-flight staging file. This counts code text and not "
                + "execution -- an occurrence in unreachable code would still count"
        )

        XCTAssertTrue(
            try SwiftSource.codeOnly(String(Self.initializeBody(of: source))).contains(call),
            "the one surviving occurrence of the staging reaper must be inside initialize(), "
                + "the only point in a process with no in-flight unpack to destroy"
        )
    }

    /// The text of `initialize()`, bounded by its own signature and the next member's doc
    /// comment.
    ///
    /// Bounded rather than "appears somewhere after the signature": `createNativeContainer`
    /// is also after it, and moving the sweep onto the unpack path is precisely the mistake
    /// the second assertion above exists to catch. A brace-counting parse would be more
    /// exact and more to go wrong; if either marker stops matching this throws, and the test
    /// goes red rather than quietly checking the whole file.
    ///
    /// **Takes raw source, and must.** Its closing marker is a `///` doc comment, so the
    /// window has to be cut before comments are stripped, not after. The caller passes the
    /// window this returns through `SwiftSource.codeOnly`.
    private static func initializeBody(of source: String) throws -> Substring {
        let opening = "    public func initialize() async throws {"
        let next = "    /// Load persisted containers from StateStore and reconcile"

        let start = try XCTUnwrap(
            source.range(of: opening), "initialize()'s signature is no longer spelt \(opening)"
        )
        let end = try XCTUnwrap(
            source.range(of: next, range: start.upperBound..<source.endIndex),
            "the member after initialize() is no longer the one this guard bounds against"
        )
        return source[start.upperBound..<end.lowerBound]
    }

    // MARK: - The writable upper layer

    /// The container's writable layer is created once, reused after, and mounted writable.
    ///
    /// **`options` must be empty, and unlike the rootfs this mount is not stripped.**
    /// `LinuxContainer.create()` removes `"ro"` from the rootfs before the VZ mount array is
    /// built (`LinuxContainer.swift:639-640`) but inserts the writable layer verbatim
    /// (`:654`), so `Mount.readonly` (`Mount.swift:441`) does reach
    /// `VZDiskImageStorageDeviceAttachment(readOnly:)` (`Mount.swift:372`) here. A `"ro"`
    /// on this mount attaches the overlay's upper layer read-only.
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
        // `type` and not just `isBlock`: `Mount.block(format:)` stores `format` AS `type`
        // (`Mount.swift:82`), while `isBlock` reads `runtimeOptions` (`:446-451`) and is
        // true for any format at all -- so `isBlock` alone cannot see "ext4" become
        // "ext3". The format is also the half that survives into the guest: upstream
        // overwrites `destination` before mounting (`LinuxContainer.swift:597-599`) and
        // leaves `type` alone, so it is what the guest actually tries to mount as.
        XCTAssertEqual(
            first.mount.type, "ext4",
            "the writable layer must be formatted and declared ext4 -- EXT4.Formatter wrote "
                + "it, and this string is what the guest mounts it as"
        )
        XCTAssertTrue(
            first.mount.options.isEmpty,
            "the writable layer must attach writable -- it is the overlay's upper layer and "
                + "the guest writes to it. Unlike the rootfs, \"ro\" here is NOT stripped by "
                + "LinuxContainer.create() and does reach the VZ attachment. Got "
                + "\(first.mount.options)"
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
