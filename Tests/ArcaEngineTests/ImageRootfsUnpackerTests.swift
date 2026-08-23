import Foundation
import Logging
import XCTest
import Containerization
import ContainerizationEXT4
import ContainerizationOCI
@testable import ArcaEngine
@testable import ContainerBridge

/// The per-image cache slot is created only by a promotion.
///
/// **Which test pins which mechanism, MEASURED. Do not infer it from the order of the
/// tests or from the `Mechanism N` label on any one of them.** Each mutation below was
/// applied to this commit's source, rebuilt, and run against all twelve tests here:
///
/// - **Mechanism 1, promotion-on-success --
///   `testTheUnpackWritesASiblingOfTheSlotAndNeverTheSlotItself` ALONE.** `let staging =
///   slot` fails that test twice and nothing else; `testARefusedUnpackLeavesNoCacheSlot`
///   PASSES, because the error-path cleanup then deletes the slot and hides that it was
///   ever the destination. **That test is not a surrounding property and must not be
///   trimmed as one.** It is the only thing standing between this type and upstream's
///   write-straight-to-the-destination behaviour, which is the defect this whole design
///   exists to prevent.
/// - **Mechanism 2, staging-cleanup-on-failure --
///   `testARefusedUnpackLeavesNoScratchBesideTheSlot`.** Dropping the `catch`'s
///   `removeItem` fails that test and nothing else.
/// - **Mechanism 3, verification-before-promotion -- two halves, one test each.** Deleting
///   the whole `verifyReadable` call fails BOTH
///   `testAStagedFileWithNoReadableSuperblockIsNotPromoted` and
///   `testACorrectlySizedStagedFileThatIsNotAnExt4IsNotPromoted`. Weakening only the size
///   guard fails the first; deleting only the `EXT4Reader` line fails the second. The
///   halves are independently pinned.
///
/// The remaining tests pin properties around those three: the cache hit, the platform
/// component of the key, the mount's type and flags, and how staging files are reaped and
/// spared.
///
/// `EVIDENCE-layer-cache-poisoning.md` records the layer-granularity version of this defect
/// -- an unpack that threw left a valid, correctly labelled, EMPTY ext4 in the slot and the
/// next create reused it -- and carries the full mutation matrix, with the test-name
/// mapping it uses, what was measured where, and the bounds on two of its rows.
final class ImageRootfsUnpackerTests: XCTestCase {

    /// The refusal path's observable outcome: a refused unpack leaves no slot for the next
    /// create to hit.
    ///
    /// **This does NOT pin mechanism 1 on its own, MEASURED**: it passes with the unpack
    /// writing straight to the slot, because the error-path cleanup then deletes it.
    /// `testTheUnpackWritesASiblingOfTheSlotAndNeverTheSlotItself` is what pins that.
    func testARefusedUnpackLeavesNoCacheSlot() async throws {
        let (unpacker, image, cacheRoot) = try await Self.fixtureRefusingItsLayer()
        let slot = unpacker.rootfsPath(forImageDigest: image.digest, platform: Self.platform)

        do {
            _ = try await unpacker.rootfs(for: image, platform: Self.platform)
            XCTFail("the unpack was expected to refuse the layer")
        } catch {
            Self.assertIsTheLayerRefusal(error)
        }

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: slot.path),
            "a refused unpack created the cache slot at \(slot.path); the next create would reuse it"
        )
        _ = cacheRoot
    }

    /// Mechanism 2: the staging file does not survive the failure.
    func testARefusedUnpackLeavesNoScratchBesideTheSlot() async throws {
        let (unpacker, image, cacheRoot) = try await Self.fixtureRefusingItsLayer()
        let slot = unpacker.rootfsPath(forImageDigest: image.digest, platform: Self.platform)

        do {
            _ = try await unpacker.rootfs(for: image, platform: Self.platform)
            XCTFail("the unpack was expected to refuse the layer")
        } catch {
            Self.assertIsTheLayerRefusal(error)
        }

        let residue = (try? FileManager.default.contentsOfDirectory(
            atPath: slot.deletingLastPathComponent().path)) ?? []
        XCTAssertEqual(
            residue, [],
            "a refused unpack left \(residue) in the image's cache directory"
        )
        _ = cacheRoot
    }

    /// Mechanism 3: an artefact whose superblock never landed is not promoted.
    ///
    /// Upstream's `EXT4Unpacker` closes the formatter in `defer { try? filesystem.close() }`,
    /// so a close that fails is swallowed and `unpack` returns normally. Staging alone
    /// would promote that. Verification before promotion is what refuses it.
    func testAStagedFileWithNoReadableSuperblockIsNotPromoted() async throws {
        let (unpacker, image, cacheRoot) = try await Self.fixtureWhoseStagedFileIsTruncated()
        let slot = unpacker.rootfsPath(forImageDigest: image.digest, platform: Self.platform)

        do {
            _ = try await unpacker.rootfs(for: image, platform: Self.platform)
            XCTFail("an unreadable staged filesystem was expected to be refused")
        } catch {
            XCTAssertTrue(
                "\(error)".contains("below the \(Self.capacityInBytes)-byte floor"),
                "the refusal must be `verifyReadable`'s size assertion and not some earlier "
                    + "error, or this test is not about verification-before-promotion at "
                    + "all. Got: \(error)"
            )
        }

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: slot.path),
            "an artefact with no readable superblock was promoted into the cache slot"
        )
        _ = cacheRoot
    }

    /// Mechanism 3, second half: a correctly sized artefact that is not an ext4 at all is
    /// not promoted.
    ///
    /// **This is what the `EXT4.EXT4Reader` line in `verifyReadable` actually buys, and
    /// nothing else here pinned it.** MEASURED: deleting that line while leaving the size
    /// guard intact left all eight other tests passing, because the only fixture that
    /// reached `verifyReadable` in a bad state was truncated to 1536 bytes -- far below the
    /// floor -- so the size guard always fired first and the reader was never the check that
    /// refused.
    ///
    /// It pins the reader for what it does rather than for what an earlier version of
    /// `verifyReadable`'s doc comment claimed it did. MEASURED against the real promoted
    /// artefact, `EXT4.EXT4Reader` ACCEPTS that filesystem truncated to 1.56% of its length
    /// and accepts it with a megabyte of zeros over its metadata region; it refuses an
    /// artefact with no valid superblock magic. So the property is "not an ext4 at all", not
    /// "incomplete".
    func testACorrectlySizedStagedFileThatIsNotAnExt4IsNotPromoted() async throws {
        let (unpacker, image, _) = try await Self.fixtureWhoseStagedFileIsNotAnExt4()
        let slot = unpacker.rootfsPath(forImageDigest: image.digest, platform: Self.platform)

        do {
            _ = try await unpacker.rootfs(for: image, platform: Self.platform)
            XCTFail("a staged file that is not an ext4 was expected to be refused")
        } catch {
            XCTAssertTrue(
                "\(error)".contains("not a valid EXT4 superblock"),
                "the refusal must come from the READER, not from the size guard -- the "
                    + "artefact is exactly the floor size, so a size-guard failure here "
                    + "would mean this test is not about the reader at all. Got: \(error)"
            )
        }

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: slot.path),
            "an artefact that is not an ext4 filesystem was promoted into the cache slot"
        )
    }

    /// A second call for the same image reuses the slot instead of unpacking again.
    func testASecondCallReusesThePromotedSlot() async throws {
        let (unpacker, image, _) = try await Self.fixtureThatUnpacksCleanly()

        let first = try await unpacker.rootfs(for: image, platform: Self.platform)
        let firstModified = try Self.modificationDate(of: first.mount)

        let second = try await unpacker.rootfs(for: image, platform: Self.platform)
        let secondModified = try Self.modificationDate(of: second.mount)

        XCTAssertEqual(first.mount.source, second.mount.source)
        XCTAssertEqual(
            firstModified, secondModified,
            "the second call rewrote the rootfs; the per-image cache is not being hit"
        )

        // `origin` is what the create path logs to tell a cold unpack from a hit, and the
        // mtime check above is exactly the state that distinction is reporting on. Pinned
        // here rather than in a test of its own so the two cannot disagree: an `origin`
        // that said `cache-hit` for a call that rewrote the file would be worse than none.
        XCTAssertEqual(first.origin, .unpacked, "the first call composed the rootfs")
        XCTAssertEqual(second.origin, .cacheHit, "the second call answered from the slot")
    }

    /// The mount this type hands out carries `"ro"`, on BOTH the fresh-unpack and the
    /// cache-hit path.
    ///
    /// **READ THIS BEFORE CONCLUDING THE SHARED SLOT IS PROTECTED FROM THE HOST. IT IS
    /// NOT.** An earlier version of this test asserted the flag made the attachment
    /// read-only. It does not. `LinuxContainer.create()` strips it before the VZ mount
    /// array is built -- VERIFIED against the pinned object,
    /// `git show a5803b6:Sources/Containerization/LinuxContainer.swift`. In
    /// `LinuxContainer.create()`: `var modifiedRootfs = self.rootfs` /
    /// `modifiedRootfs.options.removeAll(where: { $0 == "ro" })`, and the `containerMounts`
    /// array built from it goes into `mountsByID`, which is the only thing
    /// `VZVirtualMachineInstance.Configuration.mountAttachments(allocator:)` turns into a
    /// storage device. So the
    /// `VZDiskImageStorageDeviceAttachment(readOnly: mount.readonly)` in
    /// `VZDiskImageStorageDeviceAttachment.mountToVZAttachment(mount:options:)`
    /// always gets `false` for the rootfs. Upstream does this on purpose -- see the comment
    /// directly above `modifiedRootfs`: `EROFS` writing `/etc/hosts`. **The host-side hole
    /// is open and this test does not close it.**
    ///
    /// **What it does pin.** `LinuxContainer.generateRuntimeSpec()` reads the UNSTRIPPED
    /// `self.rootfs` for `spec.root?.readonly = … && self.writableLayer == nil`, so on
    /// upstream's no-overlay path (the `else` branch of `LinuxContainer.mountRootfs(...)`,
    /// "No writable layer. Mount rootfs directly.") this option is what makes the OCI
    /// runtime remount the guest root read-only. That is a real effect on a real supported
    /// path, it is free, and it is upstream's own stated preference -- so the flag stays
    /// and this test keeps it from being dropped as decoration.
    ///
    /// Both calls are asserted because the two paths build the mount through the same
    /// helper today and need not tomorrow.
    ///
    /// WHAT THIS DOES NOT PROVE: anything about a running guest. Nothing in this target
    /// starts a VM. That is Task 13/14's 35-layer create-and-run.
    func testTheRootfsMountCarriesReadOnlyOnBothTheUnpackAndTheCacheHit() async throws {
        let (unpacker, image, _) = try await Self.fixtureThatUnpacksCleanly()

        let fresh = try await unpacker.rootfs(for: image, platform: Self.platform)
        XCTAssertTrue(
            fresh.mount.options.contains("ro"),
            "the freshly promoted rootfs mount dropped \"ro\", so a writableLayer == nil "
                + "caller would no longer get spec.root.readonly; got \(fresh.mount.options)"
        )

        let hit = try await unpacker.rootfs(for: image, platform: Self.platform)
        XCTAssertTrue(
            hit.mount.options.contains("ro"),
            "the cache-hit rootfs mount dropped \"ro\", and the hit is the common case; "
                + "got \(hit.mount.options)"
        )
    }

    /// The rootfs mount declares `ext4`, on both paths.
    ///
    /// **`isBlock` cannot see this and neither can any other assertion in this file.**
    /// `Mount.block(format:source:destination:options:)` stores its `format` argument AS
    /// `type`, while `Mount.isBlock` tests `runtimeOptions` and is true for a
    /// block device of any format. Nothing else here reads `type`, so before this test
    /// `blockMount`'s `"ext4"` could become `"ext3"` in silence.
    ///
    /// It is the half of the mount that reaches the guest intact. Upstream overwrites
    /// `destination` before handing the mount to the agent -- in
    /// `LinuxContainer.mountRootfs(...)`, `lowerMount.destination = lowerPath` and
    /// `upperMount.destination = upperMountPath` -- and never touches `type`, so `type` is
    /// what the guest tries to mount
    /// the device as. A wrong string there fails the mount inside the VM, which is the
    /// slowest place in this system to find a one-character defect.
    ///
    /// The artefact really is an ext4: `verifyReadable` constructs an `EXT4.EXT4Reader`
    /// over it before promotion, so this is pinning the mount's agreement with the bytes
    /// rather than an unbacked string.
    func testTheRootfsMountDeclaresExt4OnBothTheUnpackAndTheCacheHit() async throws {
        let (unpacker, image, _) = try await Self.fixtureThatUnpacksCleanly()

        let fresh = try await unpacker.rootfs(for: image, platform: Self.platform)
        XCTAssertEqual(
            fresh.mount.type, "ext4",
            "the freshly promoted rootfs mount must declare ext4; the guest mounts the "
                + "device as whatever this says"
        )
        XCTAssertTrue(fresh.mount.isBlock, "the rootfs must be a virtio block device")

        let hit = try await unpacker.rootfs(for: image, platform: Self.platform)
        XCTAssertEqual(
            hit.mount.type, "ext4",
            "the cache-hit rootfs mount must declare ext4, and the hit is the common case"
        )
        XCTAssertTrue(hit.mount.isBlock)
    }

    /// Mechanism 1, isolated: the unpack's destination is a sibling of the slot, never the
    /// slot itself.
    ///
    /// **The three tests above cannot see this, MEASURED.** Mutating
    /// `let staging = directory.appendingPathComponent("rootfs.ext4.staging-...")` to
    /// `let staging = slot` -- which is upstream's write-straight-to-the-destination
    /// behaviour -- leaves all four of them passing, because the error-path cleanup then
    /// deletes the slot and hides that it was ever the destination. Only with the cleanup
    /// ALSO removed do three of them fail. Staging and cleanup are separate mechanisms and
    /// one was standing in for the other.
    ///
    /// What staging buys over cleanup is the failure that never reaches the `catch`: a
    /// crash, a `SIGKILL`, a power loss. Those cannot be produced in-process, so the
    /// reading here is the invariant that makes them safe rather than the events
    /// themselves -- at the moment the artefact is complete and not yet promoted, the slot
    /// does not exist and the bytes are somewhere else.
    func testTheUnpackWritesASiblingOfTheSlotAndNeverTheSlotItself() async throws {
        var (unpacker, image, _) = try await Self.fixtureThatUnpacksCleanly()
        let slot = unpacker.rootfsPath(forImageDigest: image.digest, platform: Self.platform)

        let observation = PromotionObservation()
        unpacker.willPromote = { staging in
            observation.record(
                staging: staging,
                slotExists: FileManager.default.fileExists(atPath: slot.path)
            )
        }

        _ = try await unpacker.rootfs(for: image, platform: Self.platform)

        let staging = try XCTUnwrap(
            observation.staging, "the unpack must reach the promotion seam at all"
        )
        XCTAssertNotEqual(
            staging, slot,
            "the unpack wrote the cache slot directly; a crash mid-unpack would leave a "
                + "valid empty filesystem there for every later create to boot"
        )
        XCTAssertEqual(
            staging.deletingLastPathComponent(), slot.deletingLastPathComponent(),
            "the staging path must be a SIBLING of the slot: rename(2) is atomic only "
                + "within one filesystem, and a staging path elsewhere silently gives that up"
        )
        XCTAssertEqual(
            observation.slotExistedAtPromotion, false,
            "the cache slot existed before the promotion, so something other than a "
                + "verified promotion can create it"
        )
    }

    /// The slot is keyed by platform as well as digest, so one platform's rootfs is never
    /// handed to another.
    ///
    /// `image.digest` is the INDEX descriptor's digest and `manifest(for:)` picks a
    /// per-platform manifest out of that index, so a multi-platform image has one digest and
    /// a different layer set per platform. Keyed on the digest alone, the second call here
    /// would take the cache-hit branch and return the arm64 rootfs for an amd64 request --
    /// no unpack, no verification, no error.
    ///
    /// `testASecondCallReusesThePromotedSlot` passes either way, so nothing else in this
    /// suite can see it. It cannot fire in a single build today, because
    /// `ContainerManager.detectSystemPlatform()` is a compile-time `#if arch(arm64)` switch;
    /// it becomes live if arca honours `--platform` or a cache root moves between machines.
    func testAnotherPlatformDoesNotGetThisPlatformsRootfs() async throws {
        let (unpacker, image, _) = try await Self.fixtureThatUnpacksCleanly()
        let slot = unpacker.rootfsPath(forImageDigest: image.digest, platform: Self.platform)
        let otherSlot = unpacker.rootfsPath(
            forImageDigest: image.digest, platform: Self.otherPlatform
        )

        XCTAssertNotEqual(
            slot, otherSlot,
            "two platforms share one cache slot, so whichever unpacks first decides what "
                + "every later platform boots"
        )

        let promoted = try await unpacker.rootfs(for: image, platform: Self.platform)
        XCTAssertEqual(promoted.mount.source, slot.path)

        // The fixture image carries an arm64 manifest and nothing else, so the amd64
        // request has nothing to unpack and must SAY so rather than quietly answering out
        // of the slot beside it.
        do {
            let wrong = try await unpacker.rootfs(for: image, platform: Self.otherPlatform)
            XCTFail(
                "an amd64 request was answered with \(wrong.mount.source); the fixture image is "
                    + "arm64-only, so this can only have come from the arm64 slot"
            )
        } catch {
            // expected: no amd64 manifest in the index
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: otherSlot.path))
    }

    /// The staging file left by the failure staging exists to protect against is reaped.
    ///
    /// The `catch` cleanup handles an in-process throw, which
    /// `testARefusedUnpackLeavesNoScratchBesideTheSlot` pins. It cannot handle the case
    /// `testTheUnpackWritesASiblingOfTheSlotAndNeverTheSlotItself` names as staging's whole
    /// reason for existing -- a crash, a `SIGKILL`, a power loss -- which runs no cleanup at
    /// all and leaves a fully sized rootfs behind under a UUID no later call will ever
    /// choose again.
    ///
    /// The second assertion is not decoration: a reaper that took the whole directory, or
    /// matched on `rootfs.ext4` as a prefix, would satisfy the first one while destroying
    /// every cached image on the machine.
    func testTheReaperRemovesAnOrphanedStagingFileAndSparesThePromotedSlot() async throws {
        let (unpacker, image, _) = try await Self.fixtureThatUnpacksCleanly()
        let slot = unpacker.rootfsPath(forImageDigest: image.digest, platform: Self.platform)
        let directory = slot.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // Exactly what a SIGKILL between the unpack and the rename leaves behind.
        let orphan = directory.appendingPathComponent("rootfs.ext4.staging-\(UUID().uuidString)")
        XCTAssertTrue(
            FileManager.default.createFile(
                atPath: orphan.path, contents: Data(repeating: 0, count: 4096)
            ),
            "the fixture must actually create the orphan it is about to assert on"
        )

        _ = try await unpacker.rootfs(for: image, platform: Self.platform)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: slot.path),
            "the unpack must have promoted a slot for the sparing assertion to mean anything"
        )

        try unpacker.reapOrphanedStagingFiles()

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: orphan.path),
            "a staging file orphaned by a crash survived the reaper; each one is a full "
                + "rootfs and they accumulate one per crash"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: slot.path),
            "the reaper deleted the promoted rootfs, not just the orphan beside it"
        )
    }

    /// An unpack leaves a concurrent call's in-flight staging file alone.
    ///
    /// **This is the corruption half of the sweep's contract, and it is the half a
    /// source-text guard was carrying until this commit.** The reaper must run exactly once,
    /// when the cache root is opened, and never on the unpack path. Two concurrent unpacks
    /// stage to distinct UUID paths and both finish safely -- each artefact is verified before
    /// promotion and `rename(2)` is atomic, so the loser's work is simply replaced. Sweep
    /// before each unpack instead and the second call deletes the first's in-flight file out
    /// from under it, turning a race that is safe today into a corrupt one.
    ///
    /// The staging file created here is what a *concurrent* call would have on disk mid-flight.
    /// It is indistinguishable on disk from the orphan in the test above; that is exactly why
    /// the sweep cannot be moved onto this path, and why the two tests assert opposite fates
    /// for the same kind of file.
    ///
    /// The slot assertion is not decoration: without it, an unpack that failed before it
    /// touched anything would satisfy the survival assertion having never run the path.
    func testAnUnpackSparesAConcurrentCallsStagingFile() async throws {
        let (unpacker, image, _) = try await Self.fixtureThatUnpacksCleanly()
        let slot = unpacker.rootfsPath(forImageDigest: image.digest, platform: Self.platform)
        let directory = slot.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let inFlight = directory.appendingPathComponent("rootfs.ext4.staging-\(UUID().uuidString)")
        XCTAssertTrue(
            FileManager.default.createFile(
                atPath: inFlight.path, contents: Data(repeating: 0, count: 4096)
            ),
            "the fixture must actually create the staging file it is about to assert on"
        )

        _ = try await unpacker.rootfs(for: image, platform: Self.platform)

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: slot.path),
            "the unpack must have promoted a slot, or it never ran the path under test"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: inFlight.path),
            "the unpack path swept the cache root and destroyed a staging file it did not "
                + "own; run concurrently that is another call's in-flight rootfs being "
                + "deleted mid-write, which is corruption rather than accumulation"
        )
    }

    /// An unreadable directory stops the sweep loudly rather than being walked past.
    ///
    /// **MEASURED that nothing else pins this**: reducing the enumerator's `errorHandler` to
    /// `{ _, _ in true }` -- skip the entry, record nothing, return normally -- survives
    /// every other test in this file. A sweep that walks past what it cannot read reports
    /// success over a cache it has only partly seen, and the orphans it missed are
    /// indistinguishable from a cache that had none.
    ///
    /// `chmod 000` on a directory inside the cache root is the cheapest real instance: the
    /// enumerator cannot descend and hands the error to the handler.
    func testAnUnreadableDirectoryMakesTheReaperThrowRatherThanReportSuccess() async throws {
        try XCTSkipIf(
            geteuid() == 0,
            "root ignores the mode bits, so `chmod 000` cannot make the enumerator fail"
        )

        let (unpacker, image, cacheRoot) = try await Self.fixtureThatUnpacksCleanly()
        _ = try await unpacker.rootfs(for: image, platform: Self.platform)

        let unreadable = cacheRoot.appendingPathComponent("unreadable-image")
        try FileManager.default.createDirectory(at: unreadable, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000], ofItemAtPath: unreadable.path
        )
        // Restored so the suite's own tearDown can still delete the scratch tree.
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: unreadable.path
            )
        }

        do {
            try unpacker.reapOrphanedStagingFiles()
            XCTFail(
                "the reaper reported success over a cache root it could not fully read; "
                    + "an orphan it never saw is indistinguishable from no orphan at all"
            )
        } catch {
            // expected
        }
    }

    /// That the error came from the unpack REFUSING the layer, and not from never having
    /// reached the unpack.
    ///
    /// **Without this, T1, T2 and T3 assert only that *something* threw**, and a `do/catch`
    /// plus `XCTAssertFalse(fileExists)` is satisfied just as well by an error raised before
    /// `EXT4.Formatter` is ever constructed -- at which point no slot could exist whatever
    /// the promotion rule did. MEASURED (mutation K, requesting `linuxAmd` against this
    /// arm64 fixture): all three passed on `unsupported: "platform linux/amd64"`, having
    /// never run the mechanism they exist to pin.
    ///
    /// **Both halves are checked, and each rules out a different way of passing wrongly.**
    /// The wrapper proves the failure happened *inside* the per-layer unpack loop, so the
    /// formatter existed and the staging file was already on disk; the cause proves it is
    /// Task 6's archive refusal rather than some other mid-unpack failure. Either one alone
    /// leaves the other unconstrained -- the wrapper alone admits any mid-unpack error, and
    /// the cause alone admits the archive refusal raised from somewhere that never built a
    /// slot.
    private static func assertIsTheLayerRefusal(
        _ error: Error, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertTrue(
            "\(error)".contains("could not be unpacked into"),
            "the failure must be the per-layer refusal raised INSIDE the unpack -- an error "
                + "from before the formatter exists leaves no slot for reasons that have "
                + "nothing to do with the mechanism under test. Got: \(error)",
            file: file, line: line
        )
        XCTAssertTrue(
            "\(error)".contains("is not a paxRestricted archive with filter none"),
            "the refusal must be the archive refusal the fixture provokes and not some "
                + "other mid-unpack failure. Got: \(error)",
            file: file, line: line
        )
    }

    // MARK: - Fixtures

    /// What the `willPromote` seam saw. A `@Sendable` closure cannot write to a local, and
    /// the seam runs on whichever executor the unpack left off on while the assertions read
    /// it afterwards, so the two sides are separated by a lock rather than by hope.
    private final class PromotionObservation: @unchecked Sendable {
        private let lock = NSLock()
        private var _staging: URL?
        private var _slotExistedAtPromotion: Bool?

        func record(staging: URL, slotExists: Bool) {
            lock.lock()
            defer { lock.unlock() }
            _staging = staging
            _slotExistedAtPromotion = slotExists
        }

        var staging: URL? {
            lock.lock()
            defer { lock.unlock() }
            return _staging
        }

        var slotExistedAtPromotion: Bool? {
            lock.lock()
            defer { lock.unlock() }
            return _slotExistedAtPromotion
        }
    }

    /// The platform every test here requests, and deliberately NOT `Platform.current`.
    ///
    /// `OCILayoutFixture` writes `architecture: "arm64", os: "linux"` with no variant --
    /// the `ContainerizationOCI.Image(architecture:os:)` literal in
    /// `OCILayoutFixture.write(at:reference:layers:)`. `Platform.current` reads `uname` and hardcodes
    /// `os: "linux"` (`ContainerizationOCI/Platform.swift:38-48`), so on this arm64 host it
    /// supplies `variant: "v8"` and matches the fixture only through the `arm64`+`nil`
    /// versus `arm64`+`"v8"` special case in `Platform.==` (`:252-266`) -- the suite's
    /// correctness resting on a compatibility shim two modules away.
    ///
    /// **The reason to change it is not the shim, it is that the wrong host goes silently
    /// GREEN.** MEASURED, substituting what `Platform.current` returns on an x86_64 host
    /// (`Platform(arch: "amd64", os: "linux", variant: nil)`, since
    /// `normalizeArch("x86_64") -> ("amd64", nil)`): only
    /// `testASecondCallReusesThePromotedSlot` and
    /// `testTheUnpackWritesASiblingOfTheSlotAndNeverTheSlotItself` fail. The three tests
    /// carrying the ENTIRE anti-poisoning guarantee PASS -- vacuously.
    /// `image.manifest(for:)` throws `unsupported platform linux/amd64` before
    /// `EXT4.Formatter` is ever constructed, and `prepareUnpackPath` creates nothing, so the
    /// `catch` is entered, no slot exists, and `XCTAssertFalse(fileExists)` is satisfied
    /// without the mechanism under test ever running. Two reds beside three false greens is
    /// the worst shape available: the red reads as "a platform problem" and the reader
    /// concludes the other three were unaffected.
    ///
    /// Naming the same platform the fixture writes removes both the shim dependence and the
    /// vacuity. The convention came from `LayerCacheRoleTests`, which named the platform
    /// explicitly at each of its fixtures; that file was deleted in `2d1f8db`, so the reasoning
    /// is written out here rather than cited to it. It is not unique to this suite:
    /// `CreatePathSeamTests.testOpeningTheCacheSweepsOrphansSparesSlotsAndIsRootedWhereItSwept`
    /// names the same platform against its own hand-built `linux-arm64` path.
    private static let platform = SystemPlatform.linuxArm.ociPlatform()

    /// A platform the fixture image does NOT carry, for the cache-key test below.
    private static let otherPlatform = SystemPlatform.linuxAmd.ociPlatform()

    /// Small enough that four unpacks are cheap, and the value `verifyReadable` is handed:
    /// the size assertion is `>= capacityInBytes`, so the number the unpacker is
    /// CONSTRUCTED with is the number the check is made against, and a test that passed a
    /// different one would be checking a threshold production never uses.
    private static let capacityInBytes: UInt64 = 2 * 1024 * 1024

    /// One directory per process, removed whole in `tearDown`.
    ///
    /// The fixtures are `static` because the tests reach them as `Self.fixture*`, and a
    /// `static` member has no `self` to hang its scratch off -- so the root is `static` too
    /// and the cleanup is the `class` `tearDown` override rather than the instance one, which
    /// is the whole reason this is not a per-instance property. A per-fixture subdirectory
    /// under one root keeps two fixtures in the same test from sharing an image store, which
    /// would make the second load see the first's image.
    private static let scratchRoot = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("arca-image-rootfs-unpacker-tests-\(UUID().uuidString)")

    override class func tearDown() {
        try? FileManager.default.removeItem(at: scratchRoot)
        super.tearDown()
    }

    /// An image whose single layer is not the archive its media type declares, so the
    /// unpack throws part-way through -- after `EXT4.Formatter` has already created the
    /// destination. That is the state the promotion rule exists for.
    private static func fixtureRefusingItsLayer() async throws
        -> (ImageRootfsUnpacker, Containerization.Image, URL)
    {
        try await fixture(
            reference: "refused-layer-probe:latest",
            layers: [
                OCILayoutFixture.Layer(
                    path: "payload",
                    content: "these bytes are not a tar",
                    blob: .bytesThatAreNotTheDeclaredArchive
                )
            ]
        )
    }

    /// An image that unpacks, wired so the staged file is emptied between the unpack and
    /// the verification.
    ///
    /// This stands in for the case `EXT4Unpacker` cannot report: it closes the formatter in
    /// `defer { try? filesystem.close() }`, so a `close()` that fails to write the
    /// superblock is swallowed and `unpack` returns normally over a file that is not a
    /// filesystem. Truncating at the seam produces that artefact without needing a
    /// formatter that can be made to fail on demand.
    ///
    /// **1536 bytes, and the number is the whole point of the fixture.** Zero is the one
    /// length that EVERY guard in the chain catches, so it cannot distinguish them. MEASURED
    /// on this Darwin host, `FileHandle.read(upToCount: 1024)` after `seek(toOffset: 1024)`
    /// returns `nil` for sizes 0, 512 and 1024, and `Data(count: 512)` for 1536. Upstream's
    /// reader is `guard let data = try? handle.read(upToCount: superBlockSize) else { throw }`
    /// -- a NIL check, not a length check -- so a zero-byte artefact is refused by upstream
    /// itself and `verifyReadable`'s size assertion could be deleted without any test
    /// noticing, before Task 12's bump and equally after it.
    ///
    /// At 1536 the read succeeds SHORT. Before Task 12's bump the fork's
    /// `data.count == superBlockSize` guard in `EXT4.SuperBlock.read(from:at:)`
    /// (`git show 6304122:Sources/ContainerizationEXT4/EXT4+VolumeLabel.swift`, line 63)
    /// refused it, so nothing went red. Task 12 removed that guard with the volume-label
    /// work -- `EXT4+VolumeLabel.swift` does not exist at `a5803b6` -- so upstream now hands
    /// the 512-byte `Data` to `loadLittleEndian` for a
    /// 1024-byte struct, and the size check is the only thing left between the caller and an
    /// out-of-bounds load. Only at this length does the check become falsifiable.
    private static func fixtureWhoseStagedFileIsTruncated() async throws
        -> (ImageRootfsUnpacker, Containerization.Image, URL)
    {
        var (unpacker, image, cacheRoot) = try await fixtureThatUnpacksCleanly()
        unpacker.willPromote = { staging in
            let handle = try FileHandle(forWritingTo: staging)
            try handle.truncate(atOffset: 1536)
            try handle.close()
        }
        return (unpacker, image, cacheRoot)
    }

    /// An image that unpacks, wired so the staged file is replaced with exactly
    /// `capacityInBytes` bytes of zeros before verification.
    ///
    /// **The size is the point: it is exactly the floor, so the size guard passes and the
    /// reader is the only check left.** That is the half of `verifyReadable` the truncating
    /// fixture above can never reach, since 1536 bytes fails the size guard first.
    /// MEASURED standalone: `EXT4.EXT4Reader` on 2 MiB of zeros, and on 2 MiB of `0xAB`,
    /// both give `not a valid EXT4 superblock`.
    private static func fixtureWhoseStagedFileIsNotAnExt4() async throws
        -> (ImageRootfsUnpacker, Containerization.Image, URL)
    {
        var (unpacker, image, cacheRoot) = try await fixtureThatUnpacksCleanly()
        unpacker.willPromote = { staging in
            let handle = try FileHandle(forWritingTo: staging)
            try handle.truncate(atOffset: 0)
            try handle.write(contentsOf: Data(repeating: 0, count: Int(capacityInBytes)))
            try handle.close()
        }
        return (unpacker, image, cacheRoot)
    }

    /// An image whose single layer is a real tar, so the unpack succeeds and the slot is
    /// promoted.
    private static func fixtureThatUnpacksCleanly() async throws
        -> (ImageRootfsUnpacker, Containerization.Image, URL)
    {
        try await fixture(
            reference: "clean-unpack-probe:latest",
            layers: [
                OCILayoutFixture.Layer(path: "payload", content: "the layer this test unpacks")
            ]
        )
    }

    /// A real `Image`, loaded from a real OCI layout through the engine's own store, and an
    /// unpacker over an empty cache root.
    ///
    /// The load is `ImageManager.loadFromOCILayout`, the same call `arca-engine image load`
    /// reaches, so the digest the cache slot is keyed by is Containerization's own and not
    /// one this test invented -- which is the whole thing `rootfsPath(forImageDigest:)`
    /// is a function of.
    private static func fixture(
        reference: String, layers: [OCILayoutFixture.Layer]
    ) async throws -> (ImageRootfsUnpacker, Containerization.Image, URL) {
        let scratch = scratchRoot.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)

        let layout = try OCILayoutFixture.write(
            at: scratch.appendingPathComponent("layout"),
            reference: reference,
            layers: layers
        )
        let logger = Logger(label: "image-rootfs-unpacker-tests")
        let manager = try EngineManagers.makeImageManager(
            paths: EnginePaths(stateRoot: scratch.appendingPathComponent("state")),
            logger: logger
        )
        let loaded = try await manager.loadFromOCILayout(directory: layout)
        let image = try XCTUnwrap(
            loaded.first, "the layout must load exactly the image the unpack is driven over"
        )

        let cacheRoot = scratch.appendingPathComponent("rootfs")
        let unpacker = ImageRootfsUnpacker(
            cacheRoot: cacheRoot,
            capacityInBytes: capacityInBytes,
            logger: logger
        )
        return (unpacker, image, cacheRoot)
    }

    /// When the file behind a returned mount was last written.
    ///
    /// Read through the mount's own `source` rather than through `rootfsPath` again: a
    /// promotion that returned a mount pointing somewhere other than the slot it filled
    /// would satisfy a check made against the path the test computed for itself.
    private static func modificationDate(of mount: Containerization.Mount) throws -> Date {
        try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: mount.source)[.modificationDate] as? Date,
            "the returned mount must name a file that exists: \(mount.source)"
        )
    }
}
