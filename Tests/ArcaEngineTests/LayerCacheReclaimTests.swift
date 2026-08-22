import ContainerBridge
import Foundation
import Logging
import XCTest

@testable import ArcaEngine

/// The one-time reclaim of the per-layer ext4 cache the single-composed-rootfs revert
/// orphaned.
///
/// These tests are about **scoping**, not about deletion. `removeItem` works; what has to be
/// pinned is that the reclaim deletes the one directory it was written for and refuses
/// anything it does not recognise, because it is the only recursive delete the revert adds.
final class LayerCacheReclaimTests: XCTestCase {

    /// One directory per process, removed whole in `tearDown`.
    private static let scratchRoot = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("arca-layer-cache-reclaim-tests-\(UUID().uuidString)")

    override class func tearDown() {
        try? FileManager.default.removeItem(at: scratchRoot)
        super.tearDown()
    }

    /// A fresh root, created on disk. Named per test rather than shared, so one test's
    /// deletion can never be another's missing fixture.
    private static func temporaryRoot(_ name: String = #function) throws -> URL {
        let root = scratchRoot.appendingPathComponent("\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// A populated `layers` directory under `root`, as the fork left it.
    @discardableResult
    private static func plantLayers(under root: URL) throws -> URL {
        let layers = root.appendingPathComponent("layers")
        try FileManager.default.createDirectory(at: layers, withIntermediateDirectories: true)
        try Data("ext4".utf8).write(to: layers.appendingPathComponent("abc.ext4"))
        return layers
    }

    // MARK: - The engine's orphan, under its state root

    /// The orphaned per-layer cache is removed, and the state root that held it is not.
    func testReclaimRemovesTheLayersDirectoryUnderTheStateRoot() throws {
        let stateRoot = try Self.temporaryRoot()
        let layers = try Self.plantLayers(under: stateRoot)

        try LayerCacheReclaim.run(stateRoot: stateRoot)

        XCTAssertFalse(FileManager.default.fileExists(atPath: layers.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: stateRoot.path))
    }

    /// A `layers` path that is not a directory is a state root this code does not understand,
    /// and deleting anything under that assumption would be guessing.
    func testReclaimRefusesWhenLayersIsNotADirectory() throws {
        let stateRoot = try Self.temporaryRoot()
        let layers = stateRoot.appendingPathComponent("layers")
        try Data("not a directory".utf8).write(to: layers)

        XCTAssertThrowsError(try LayerCacheReclaim.run(stateRoot: stateRoot))
        XCTAssertTrue(FileManager.default.fileExists(atPath: layers.path))
    }

    /// Nothing to reclaim is success, not an error: this runs on every start, and every start
    /// after the first has nothing left to do.
    func testReclaimIsSilentWhenThereIsNothingToReclaim() throws {
        let stateRoot = try Self.temporaryRoot()

        XCTAssertNoThrow(try LayerCacheReclaim.run(stateRoot: stateRoot))
        XCTAssertNoThrow(try LayerCacheReclaim.run(stateRoot: stateRoot))
    }

    // MARK: - ArcaDaemon's orphan, under `~/.arca`

    /// ArcaDaemon wrote its own copy of the per-layer cache, and the rename of the live cache
    /// to `image-rootfs` is what put this directory out of every other code path's reach. It
    /// is reclaimed under the same rule as the engine's.
    func testReclaimRemovesTheLayersDirectoryUnderTheArcaRoot() throws {
        let arcaRoot = try Self.temporaryRoot()
        let layers = try Self.plantLayers(under: arcaRoot)

        try LayerCacheReclaim.run(arcaRoot: arcaRoot)

        XCTAssertFalse(FileManager.default.fileExists(atPath: layers.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: arcaRoot.path))
    }

    /// The refusal is a property of the reclaim, not of the engine's entry point, so it holds
    /// on ArcaDaemon's tree too.
    func testReclaimRefusesWhenTheArcaRootsLayersIsNotADirectory() throws {
        let arcaRoot = try Self.temporaryRoot()
        let layers = arcaRoot.appendingPathComponent("layers")
        try Data("not a directory".utf8).write(to: layers)

        XCTAssertThrowsError(try LayerCacheReclaim.run(arcaRoot: arcaRoot))
        XCTAssertTrue(FileManager.default.fileExists(atPath: layers.path))
    }

    /// ArcaDaemon's start has nothing to do on the second run either.
    func testReclaimIsSilentWhenTheArcaRootHasNothingToReclaim() throws {
        let arcaRoot = try Self.temporaryRoot()

        XCTAssertNoThrow(try LayerCacheReclaim.run(arcaRoot: arcaRoot))
    }

    // MARK: - Scoping

    /// A symbolic link at `layers` is the case a `fileExists(atPath:isDirectory:)` check gets
    /// wrong: it follows the link and reports a directory. The reclaim refuses instead, and
    /// the tree the link pointed at keeps its contents.
    func testReclaimRefusesASymbolicLinkAtTheLayersPath() throws {
        let root = try Self.temporaryRoot()
        let elsewhere = root.appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let hostage = elsewhere.appendingPathComponent("keep-me")
        try Data("keep me".utf8).write(to: hostage)

        let layers = root.appendingPathComponent("layers")
        try FileManager.default.createSymbolicLink(at: layers, withDestinationURL: elsewhere)

        XCTAssertThrowsError(try LayerCacheReclaim.run(stateRoot: root))
        XCTAssertTrue(FileManager.default.fileExists(atPath: hostage.path))
    }

    /// Everything beside `layers` survives -- in particular `image-rootfs`, the live cache the
    /// revert renames into the same parent. A reclaim that recursed one level broader would
    /// delete the engine's working image store.
    func testReclaimLeavesEverySiblingOfTheLayersDirectory() throws {
        let stateRoot = try Self.temporaryRoot()
        try Self.plantLayers(under: stateRoot)

        let imageRootfs = stateRoot.appendingPathComponent("image-rootfs")
        try FileManager.default.createDirectory(
            at: imageRootfs, withIntermediateDirectories: true
        )
        let composed = imageRootfs.appendingPathComponent("sha256-abc.ext4")
        try Data("composed rootfs".utf8).write(to: composed)
        let database = stateRoot.appendingPathComponent("state.db")
        try Data("sqlite".utf8).write(to: database)

        try LayerCacheReclaim.run(stateRoot: stateRoot)

        XCTAssertTrue(FileManager.default.fileExists(atPath: composed.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: database.path))
    }

    // MARK: - The engine's call site

    /// The engine reclaims on start, through the one factory `arca-engine` itself calls.
    ///
    /// Pinning `EngineManagers` rather than `ServeCommand.run()` for the reason `EngineManagers`
    /// exists at all: a test target cannot import an executable, so a wiring only the
    /// executable can reach is a wiring no test can assert on.
    func testBuildingTheEngineManagersReclaimsTheLayersDirectory() throws {
        let stateRoot = try Self.temporaryRoot()
        let layers = try Self.plantLayers(under: stateRoot)

        _ = try EngineManagers(
            stateRoot: stateRoot,
            kernelPath: URL(fileURLWithPath: "/opt/arca/vmlinux"),
            logLevel: "info",
            logger: Logger(label: "layer-cache-reclaim-tests")
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: layers.path))
    }
}
