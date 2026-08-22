#if os(macOS)

import Foundation
import Logging
import Containerization
import ContainerizationEXT4
import ContainerizationError
import ContainerizationOCI
import SystemPackage

/// One composed ext4 rootfs per image, shared by every container built from it.
///
/// **The cache slot is created only by a promotion, and that is not a style choice.**
/// Upstream's `EXT4Unpacker` writes straight to the destination it is handed and closes
/// the formatter in `defer { try? filesystem.close() }`
/// (`containerization/Sources/Containerization/Image/Unpacker/EXT4Unpacker.swift:55`, `:85`).
/// A throw part-way through an unpack therefore leaves a valid, correctly sized, **empty**
/// filesystem at that destination. This type treats "a block is at the final path" as a
/// cache hit, so such a filesystem would be booted by every later container built from the
/// same image.
///
/// That is the defect `Documentation/EVIDENCE-layer-cache-poisoning.md` records at layer
/// granularity, fixed at `4134b54`. The fix lived in `OverlayFSUnpacker`, which the revert
/// to upstream's single composed rootfs deletes, so it is reimplemented here -- where the
/// cache path is now chosen -- rather than in the submodule, which this work is bringing
/// back toward upstream.
public struct ImageRootfsUnpacker: Sendable {
    private let cacheRoot: URL
    private let capacityInBytes: UInt64
    private let logger: Logger

    /// Test seam: called with the staging URL immediately before verification.
    internal var willPromote: (@Sendable (URL) throws -> Void)?

    public init(cacheRoot: URL, capacityInBytes: UInt64, logger: Logger) {
        self.cacheRoot = cacheRoot
        self.capacityInBytes = capacityInBytes
        self.logger = logger
    }

    /// Where this image's composed rootfs lives, whether or not it exists yet.
    public func rootfsPath(forImageDigest digest: String) -> URL {
        cacheRoot
            .appendingPathComponent(digest.replacingOccurrences(of: ":", with: "-"))
            .appendingPathComponent("rootfs.ext4")
    }

    /// The image's composed rootfs, unpacked if it is not already cached.
    public func rootfs(
        for image: Containerization.Image,
        platform: ContainerizationOCI.Platform
    ) async throws -> Containerization.Mount {
        let slot = rootfsPath(forImageDigest: image.digest)
        if FileManager.default.fileExists(atPath: slot.path) {
            logger.debug("image rootfs cache hit", metadata: ["path": "\(slot.path)"])
            return Self.blockMount(at: slot)
        }

        let directory = slot.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let staging = directory.appendingPathComponent("rootfs.ext4.staging-\(UUID().uuidString)")

        do {
            let unpacker = EXT4Unpacker(capacityInBytes: capacityInBytes)
            _ = try await unpacker.unpack(image, for: platform, at: staging, progress: nil)
            if let willPromote { try willPromote(staging) }
            try Self.verifyReadable(staging, expecting: capacityInBytes)
        } catch {
            // The staging file must not outlive the failure: a later run would otherwise
            // find scratch beside a slot that was never promoted.
            try? FileManager.default.removeItem(at: staging)
            throw error
        }

        try Self.promote(at: staging, to: slot)
        return Self.blockMount(at: slot)
    }

    /// Refuses an artefact whose superblock did not land.
    ///
    /// `EXT4Unpacker` swallows a failing `close()`, so `unpack` returning is not proof the
    /// filesystem is complete. Opening it is -- but only with the size check below.
    ///
    /// **The size check is required because the load is unbounded -- not because the magic
    /// number covers most cases.** Task 4 restored
    /// `ContainerizationEXT4/EXT4+Reader.swift` to upstream, which inlines the superblock
    /// read as `guard let data = try? self.handle.read(upToCount: superBlockSize) else`,
    /// checking only that the read did not throw. The fork's deleted
    /// `EXT4.SuperBlock.read` asserted `data.count == superBlockSize`; that guard arrived
    /// with the volume-label work and went out with it.
    ///
    /// On a short read, `EXT4+Reader.swift:59-61` reaches
    /// `data.withUnsafeBytes { $0.loadLittleEndian(as: EXT4.SuperBlock.self) }` on an
    /// undersized buffer. `UnsafeRawBufferPointer.load` bounds-checks with
    /// `_debugPrecondition`, which is `@inlinable` and so evaluated in the *client's*
    /// build configuration: **a release build compiles the check out and reads
    /// `MemoryLayout<EXT4.SuperBlock>.size` bytes past the end**; a debug build traps. A
    /// file shorter than the 1024-byte superblock offset yields a zero-count `Data` whose
    /// base address may be nil.
    ///
    /// The `s_magic` check at `:62` runs *after* that load, so it is no defence at all --
    /// the out-of-bounds read has already happened, whether or not the magic survived.
    /// Do not weaken the size assertion on the theory that magic narrows the window.
    ///
    /// Nor could re-adding the fork's guard have closed the class: `:123`, `:141`, `:156`
    /// and `:227` read group descriptors, inodes and data blocks with the same unchecked
    /// pattern, all of it upstream. Asserting the file's size at the caller, before the
    /// reader is constructed at all, is the right place for this.
    ///
    /// **Do not delete this as dead code on the evidence of a green suite.** At the
    /// submodule pointer this was written against (`6304122`, before Task 12's bump) the
    /// fork's guard is still in the tree, at
    /// `containerization/Sources/ContainerizationEXT4/EXT4+VolumeLabel.swift:63`
    /// (`data.count == superBlockSize`), and it is what refuses the truncated artefact
    /// today. MEASURED: weakening the guard below to `size >= 0` and running
    /// `swift test --filter ImageRootfsUnpackerTests` leaves all 5 tests passing, and the
    /// error `testAStagedFileWithNoReadableSuperblockIsNotPromoted` observes becomes
    /// `could not read 1024 bytes of superblock from ... at offset 1024` -- the fork guard,
    /// not this one. That guard goes out with the volume-label work, so no test in this
    /// suite can distinguish a live size check from a dead one until the pointer moves.
    private static func verifyReadable(_ path: URL, expecting capacityInBytes: UInt64) throws {
        let size = try FileManager.default.attributesOfItem(atPath: path.path)[.size] as? UInt64
        guard let size, size >= capacityInBytes else {
            throw ContainerizationError(
                .internalError,
                message: "staged rootfs at \(path.path) is \(size.map { String($0) } ?? "unreadable") "
                    + "bytes, short of the \(capacityInBytes) it was formatted for; refusing to "
                    + "promote it into the image cache"
            )
        }
        _ = try EXT4.EXT4Reader(blockDevice: FilePath(path.path))
    }

    /// `rename(2)` rather than `FileManager.moveItem`, and the difference is not stylistic:
    /// replacement is atomic, so no reader ever sees a half-built slot, and a concurrent
    /// winner's completed work is never clobbered mid-read. `staging` is a sibling of `path`
    /// because `rename` is only atomic within one filesystem.
    private static func promote(at staging: URL, to path: URL) throws {
        guard rename(staging.path, path.path) == 0 else {
            let code = errno
            try? FileManager.default.removeItem(at: staging)
            throw ContainerizationError(
                .internalError,
                message: "failed to promote the unpacked rootfs at \(staging.path) onto "
                    + "\(path.path): errno \(code)"
            )
        }
    }

    private static func blockMount(at path: URL) -> Containerization.Mount {
        .block(format: "ext4", source: path.path, destination: "/", options: [])
    }
}

#endif
