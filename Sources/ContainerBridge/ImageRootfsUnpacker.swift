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

    /// Written once, because the reaper below finds orphans by matching it. Two spellings
    /// could drift apart, and the way they would fail is that the reaper silently stops
    /// finding anything -- the one failure mode a sweep has no way to report.
    private static let stagingPrefix = "rootfs.ext4.staging-"

    public init(cacheRoot: URL, capacityInBytes: UInt64, logger: Logger) {
        self.cacheRoot = cacheRoot
        self.capacityInBytes = capacityInBytes
        self.logger = logger
    }

    /// Where this image's composed rootfs lives on `platform`, whether or not it exists yet.
    ///
    /// **The platform is part of the key because the bytes are a function of it.**
    /// `image.digest` is the *index* descriptor's digest
    /// (`containerization/Sources/Containerization/Image/Image.swift:48`), and
    /// `manifest(for:)` selects a per-platform manifest out of that index (`:68-80`): a
    /// multi-platform image has ONE digest and a different layer set per platform. Keyed on
    /// the digest alone, an arm64 rootfs promoted into the slot would be returned for an
    /// amd64 request -- no unpack, no verification, no error, wrong filesystem. That cannot
    /// fire in a single build today, because `ContainerManager.detectSystemPlatform()` is a
    /// compile-time `#if arch(arm64)` switch and so a given cache root is only ever written
    /// by one platform; it becomes live the moment arca honours `--platform`, or a cache
    /// root is copied between machines.
    public func rootfsPath(forImageDigest digest: String, platform: ContainerizationOCI.Platform) -> URL {
        cacheRoot
            .appendingPathComponent(digest.replacingOccurrences(of: ":", with: "-"))
            .appendingPathComponent("\(platform.os)-\(platform.architecture)")
            .appendingPathComponent("rootfs.ext4")
    }

    /// Removes staging files left by a failure that never reached the `catch` below.
    ///
    /// Staging exists for the failure that runs no cleanup at all -- a crash, a `SIGKILL`, a
    /// power loss between the unpack and the `rename`. Those leave a fully sized
    /// (`capacityInBytes`, gigabytes in production) `rootfs.ext4.staging-<uuid>` in the
    /// image's directory. It poisons nothing, because only a promotion can create the slot,
    /// but the next call takes a fresh UUID, so the orphan is never reused and never removed
    /// and they accumulate one per crash, forever.
    ///
    /// **Call this once when the cache root is initialised, and deliberately NOT before each
    /// unpack.** Two concurrent calls for the same image stage to distinct UUID paths and
    /// both complete safely: each artefact is verified before it is promoted and `rename(2)`
    /// is atomic, so the loser's work is simply replaced. A sweep on the unpack path would
    /// delete a concurrent call's in-flight staging file out from under it and turn a race
    /// that is safe today into a corrupt one. Initialisation is the only point at which
    /// there is provably no in-flight work to destroy.
    public func reapOrphanedStagingFiles() throws {
        // Not an error: a cache root that has never been written holds no orphans. This is a
        // defined state of the cache, not a failure being swallowed -- every other error
        // below propagates.
        guard FileManager.default.fileExists(atPath: cacheRoot.path) else { return }

        // A recursive walk, deliberately NOT the two levels `rootfsPath` happens to build
        // today. A reaper that spelt out `<digest>/<platform>/` would still compile after any
        // change to the slot's shape, and the way it would fail is by silently finding
        // nothing -- which is indistinguishable from a cache with no orphans in it. Matching
        // on the name alone is also what keeps a promoted slot safe: `rootfs.ext4` does not
        // carry the `rootfs.ext4.staging-` prefix, and no directory does either.
        var walkFailure: Error?
        guard
            let walk = FileManager.default.enumerator(
                at: cacheRoot,
                includingPropertiesForKeys: nil,
                options: [],
                errorHandler: { _, error in
                    // Stop rather than skip. A sweep that walked past an unreadable
                    // directory would report success over a cache it had only partly seen.
                    walkFailure = error
                    return false
                }
            )
        else {
            throw ContainerizationError(
                .internalError,
                message: "could not enumerate the image rootfs cache at \(cacheRoot.path)"
            )
        }

        for case let entry as URL in walk
        where entry.lastPathComponent.hasPrefix(Self.stagingPrefix) {
            try FileManager.default.removeItem(at: entry)
            logger.info(
                "reaped an orphaned rootfs staging file",
                metadata: ["path": "\(entry.path)"]
            )
        }
        if let walkFailure { throw walkFailure }
    }

    /// The image's composed rootfs, unpacked if it is not already cached.
    public func rootfs(
        for image: Containerization.Image,
        platform: ContainerizationOCI.Platform
    ) async throws -> Containerization.Mount {
        let slot = rootfsPath(forImageDigest: image.digest, platform: platform)
        if FileManager.default.fileExists(atPath: slot.path) {
            logger.debug("image rootfs cache hit", metadata: ["path": "\(slot.path)"])
            return Self.blockMount(at: slot)
        }

        let directory = slot.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let staging = directory.appendingPathComponent("\(Self.stagingPrefix)\(UUID().uuidString)")

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
    /// `MemoryLayout<EXT4.SuperBlock>.size` bytes past the end**; a debug build traps.
    ///
    /// **The window is file lengths in (1024, 2048) exclusive, and nowhere else.** MEASURED
    /// on this Darwin host, `FileHandle.read(upToCount: 1024)` after
    /// `seek(toOffset: 1024)`:
    ///
    /// ```
    /// size=0    -> nil            size=1025 -> Data(count: 1)
    /// size=512  -> nil            size=1536 -> Data(count: 512)
    /// size=1024 -> nil            size=2047 -> Data(count: 1023)
    ///                             size=2048 -> Data(count: 1024)
    /// ```
    ///
    /// At or below the 1024-byte offset the read returns **nil**, which upstream's
    /// `guard let data = try? ... else { throw }` catches on its own -- so a truncated-to-zero
    /// artefact does NOT reach the load and cannot demonstrate this check. Only a length
    /// strictly between the offset and offset+superblock returns a short, non-nil `Data`
    /// that upstream hands straight to `loadLittleEndian`. That range is why
    /// `fixtureWhoseStagedFileIsTruncated` truncates to 1536 rather than to 0.
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
    /// **Do not delete this as dead code.** At the submodule pointer this was written
    /// against (`6304122`, before Task 12's bump) the fork's guard is still in the tree, at
    /// `containerization/Sources/ContainerizationEXT4/EXT4+VolumeLabel.swift:63`
    /// (`data.count == superBlockSize`), and *something* would refuse the truncated artefact
    /// even with this check gone. MEASURED: weakening the guard below to `size >= 0` makes
    /// the error `testAStagedFileWithNoReadableSuperblockIsNotPromoted` observes become
    /// `could not read 1024 bytes of superblock from ... at offset 1024` -- the fork guard,
    /// not this one.
    ///
    /// **What that test pins TODAY is which check reports, not whether the artefact is
    /// refused.** It asserts on this check's own message, so the weakening fails it; but the
    /// safety property underneath is still being provided by the fork guard, and no test at
    /// this pointer can show otherwise. The distinction matters because the fork guard goes
    /// out with the volume-label work, and then nothing is underneath.
    /// **Task 12: after the bump, weakening this check does not fail a test -- it TRAPS, and
    /// the trap IS the kill.** The fixture's 1536-byte artefact reaches upstream's nil-check
    /// as a 512-byte `Data`, the `guard let` succeeds, and `loadLittleEndian` -- which on a
    /// little-endian host is literally `self.load(as: T.self)`
    /// (`ContainerizationEXT4/UnsafeLittleEndianBytes.swift:54-57`) -- reads a 1024-byte
    /// struct out of it. MEASURED by simulating the post-bump reader exactly (seek to 1024
    /// in a 1536-byte file, `read(upToCount: 1024)`, `load(as:)` a 1024-byte struct):
    ///
    /// ```
    /// Swift/UnsafeRawBufferPointer.swift:1446: Fatal error: UnsafeRawBufferPointer.load out of bounds
    /// exit 133   (128 + 5, SIGTRAP)
    /// ```
    ///
    /// The process dies and takes the whole test bundle with it; no `catch` can see it and
    /// no `XCTAssert` reports it. **Do not read `Fatal error: … load out of bounds` plus
    /// SIGTRAP as an unrelated environment fault and call the mutation inconclusive** -- it
    /// is the mutation working. Restoring the check makes the trap go away, which is the
    /// confirmation.
    ///
    /// That is the *debug* outcome, and `swift test` builds debug. `_debugPrecondition` is
    /// `@inlinable` and so evaluated in the client's build configuration, so a **release**
    /// build of the same weakened code does not trap: it reads 1024 bytes out of a 512-byte
    /// buffer and returns whatever follows it in memory, silently.
    ///
    /// Post-bump this is therefore not defence-in-depth. Nothing else stands between a short
    /// staged artefact and that load: it is the only check left.
    /// **`capacityInBytes` is a FLOOR, and comparing against it is deliberate -- do not
    /// "fix" this into an exact-size comparison.** `EXT4.Formatter` treats its `minDiskSize`
    /// as usable capacity and writes more when the content or the journal needs it
    /// (`EXT4+Formatter.swift:697-702`), so the artefact's true final size is not knowable
    /// here; upstream's `unpack` does not report it, and obtaining it would mean an upstream
    /// API change inside a plan whose purpose is converging *toward* upstream.
    ///
    /// The threshold that actually matters for memory safety is **2048** -- a 1024-byte load
    /// at offset 1024 -- and `capacityInBytes` dominates it by seven orders of magnitude
    /// (Task 7 constructs with 32 GiB), so the memory-safety property is satisfied
    /// absolutely rather than marginally.
    ///
    /// **The gap this bound leaves is NOT covered by the reader below.** An earlier version
    /// of this comment claimed the `EXT4Reader` tree walk caught a file truncated between
    /// the floor and its true length. MEASURED against a promoted artefact from the test
    /// fixture -- `capacityInBytes` 2 MiB, real file 128 MiB, because the formatter pads out
    /// to one whole block group (`contentRequiredSize = blocksPerGroup * blockSize`,
    /// `EXT4+Formatter.swift:690-700`) -- `EXT4.EXT4Reader` ACCEPTED that artefact truncated
    /// to 2 MiB (1.5% of it), truncated to 50%, truncated 4 KiB short of full length, and
    /// with 1 MiB of zeros written over the metadata region at offsets 4096, 8192 and 32768.
    /// It refused only artefacts with no valid superblock magic: 2 MiB of zeros and 2 MiB of
    /// `0xAB` each gave `not a valid EXT4 superblock`.
    ///
    /// The honest division is therefore narrower than "short versus incomplete":
    ///
    /// - **size guard** -> an artefact below the floor;
    /// - **reader** -> a correctly sized artefact that is not an ext4 at all;
    /// - **neither** -> a correctly sized, truncated-but-still-parseable filesystem.
    ///
    /// Sparse metadata layout is why the third case escapes: a small image's inode table,
    /// bitmaps and group descriptors all land in the first few blocks, and the tail is
    /// padding the walk never visits.
    ///
    /// **That residue is acceptable, and here is the reason -- which is NOT that the case
    /// cannot arise before promotion.** It can: `EXT4Unpacker` closes the formatter in
    /// `defer { try? filesystem.close() }`, so a `close()` that fails part-way is swallowed
    /// and `unpack` returns normally, all of it before anything is promoted. What makes that
    /// safe is the ORDER `EXT4.Formatter.close()` writes in. The file is extended to its
    /// final size early (`EXT4+Formatter.swift:738-750`, `lseek` + one-byte write) and the
    /// superblock is written LAST, after the inode table, the bitmaps and the group
    /// descriptors (`:906-908`). So a partial close leaves a correctly sized file with no
    /// valid superblock -- which the reader refuses -- or a short file, which the size guard
    /// refuses. The two checks cover both realistic outcomes of the one failure mode that
    /// reaches this point.
    ///
    /// Beyond that, the slot is only ever created by a promotion, so a crash at any point
    /// during the unpack leaves the artefact at the staging path and never in the slot. For
    /// a correctly sized but internally truncated filesystem to occupy the slot it would
    /// have to be corrupted AFTER a successful promotion -- disk-level corruption, a
    /// different threat, and not one this type is positioned to detect.
    private static func verifyReadable(_ path: URL, expecting capacityInBytes: UInt64) throws {
        let size = try FileManager.default.attributesOfItem(atPath: path.path)[.size] as? UInt64
        guard let size, size >= capacityInBytes else {
            throw ContainerizationError(
                .internalError,
                message: "staged rootfs at \(path.path) is \(size.map { String($0) } ?? "unreadable") "
                    + "bytes, below the \(capacityInBytes)-byte floor it was formatted with "
                    + "(a minimum, not an expected size); refusing to promote it into the image cache"
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
