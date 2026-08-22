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
/// These three tests pin three separate mechanisms. `EVIDENCE-layer-cache-poisoning.md`
/// records the layer-granularity version of this defect: an unpack that threw left a
/// valid, correctly labelled, EMPTY ext4 in the slot and the next create reused it.
final class ImageRootfsUnpackerTests: XCTestCase {

    /// Mechanism 1: a refused unpack leaves no slot for the next create to hit.
    func testARefusedUnpackLeavesNoCacheSlot() async throws {
        let (unpacker, image, cacheRoot) = try await Self.fixtureRefusingItsLayer()
        let slot = unpacker.rootfsPath(forImageDigest: image.digest)

        do {
            _ = try await unpacker.rootfs(for: image, platform: .current)
            XCTFail("the unpack was expected to refuse the layer")
        } catch {
            // expected
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
        let slot = unpacker.rootfsPath(forImageDigest: image.digest)

        _ = try? await unpacker.rootfs(for: image, platform: .current)

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
        let slot = unpacker.rootfsPath(forImageDigest: image.digest)

        do {
            _ = try await unpacker.rootfs(for: image, platform: .current)
            XCTFail("an unreadable staged filesystem was expected to be refused")
        } catch {
            // expected
        }

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: slot.path),
            "an artefact with no readable superblock was promoted into the cache slot"
        )
        _ = cacheRoot
    }

    /// A second call for the same image reuses the slot instead of unpacking again.
    func testASecondCallReusesThePromotedSlot() async throws {
        let (unpacker, image, _) = try await Self.fixtureThatUnpacksCleanly()

        let first = try await unpacker.rootfs(for: image, platform: .current)
        let firstModified = try Self.modificationDate(of: first)

        let second = try await unpacker.rootfs(for: image, platform: .current)
        let secondModified = try Self.modificationDate(of: second)

        XCTAssertEqual(first.source, second.source)
        XCTAssertEqual(
            firstModified, secondModified,
            "the second call rewrote the rootfs; the per-image cache is not being hit"
        )
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
        let slot = unpacker.rootfsPath(forImageDigest: image.digest)

        let observation = PromotionObservation()
        unpacker.willPromote = { staging in
            observation.record(
                staging: staging,
                slotExists: FileManager.default.fileExists(atPath: slot.path)
            )
        }

        _ = try await unpacker.rootfs(for: image, platform: .current)

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

    /// Small enough that four unpacks are cheap, and the value `verifyReadable` is handed:
    /// the size assertion is `>= capacityInBytes`, so the number the unpacker is
    /// CONSTRUCTED with is the number the check is made against, and a test that passed a
    /// different one would be checking a threshold production never uses.
    private static let capacityInBytes: UInt64 = 2 * 1024 * 1024

    /// One directory per process, removed whole in `tearDown`.
    ///
    /// The fixtures are `static` because the tests reach them as `Self.fixture*`, so they
    /// cannot hang their scratch off an instance property the way `LayerCacheRoleTests`
    /// does. A per-fixture subdirectory under one root keeps two fixtures in the same test
    /// from sharing an image store, which would make the second load see the first's image.
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
    private static func fixtureWhoseStagedFileIsTruncated() async throws
        -> (ImageRootfsUnpacker, Containerization.Image, URL)
    {
        var (unpacker, image, cacheRoot) = try await fixtureThatUnpacksCleanly()
        unpacker.willPromote = { staging in
            let handle = try FileHandle(forWritingTo: staging)
            try handle.truncate(atOffset: 0)
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
