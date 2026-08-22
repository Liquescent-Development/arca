import ContainerBridge
import Foundation
import Logging
import SQLite
import XCTest

/// The other half of what the single-composed-rootfs revert orphaned: the `layer_cache` table
/// that indexed the per-layer ext4 files `LayerCacheReclaim` deletes.
///
/// Asserted against `sqlite_master` on a second connection rather than through `StateStore`'s
/// own API, because the API being gone is precisely what is under test -- there is no
/// `loadLayerCache` left to ask.
final class StateStoreLayerCacheDropTests: XCTestCase {

    /// One directory per process, removed whole in `tearDown`.
    private static let scratchRoot = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("arca-layer-cache-drop-tests-\(UUID().uuidString)")

    override class func tearDown() {
        try? FileManager.default.removeItem(at: scratchRoot)
        super.tearDown()
    }

    private static func temporaryDatabasePath(_ name: String = #function) throws -> String {
        let directory = scratchRoot.appendingPathComponent("\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("state.db").path
    }

    private static func tableExists(_ table: String, in path: String) throws -> Bool {
        let db = try Connection(path)
        let count = try db.scalar(
            "SELECT count(*) FROM sqlite_master WHERE type = 'table' AND name = ?", table
        ) as? Int64
        return (count ?? 0) > 0
    }

    /// Writes a database in the shape the fork left behind: schema v2, with a populated
    /// `layer_cache`. Stopping at the two tables the migration path reads keeps this fixture
    /// from becoming a second copy of `createSchemaV1Synchronously` that can drift from it --
    /// at v2 the only step `StateStore.init` still has to take is the v3 drop.
    private static func writeAForkEraDatabase(at path: String, digest: String) throws {
        let db = try Connection(path)
        try db.run("CREATE TABLE schema_version (version INTEGER PRIMARY KEY, applied_at TEXT)")
        try db.run("INSERT INTO schema_version (version, applied_at) VALUES (1, '')")
        try db.run("INSERT INTO schema_version (version, applied_at) VALUES (2, '')")
        try db.run(
            """
            CREATE TABLE layer_cache (
                digest TEXT PRIMARY KEY, path TEXT, size INTEGER,
                created_at TEXT, last_used TEXT, ref_count INTEGER
            )
            """
        )
        try db.run(
            "INSERT INTO layer_cache VALUES (?, ?, ?, ?, ?, ?)",
            digest, "/tmp/layers/\(digest)/layer.ext4", Int64(1024), "", "", Int64(1)
        )
    }

    /// A database the fork already wrote keeps its rows until something drops them, and after
    /// the revert nothing will ever read them again.
    func testOpeningAForkEraDatabaseDropsTheLayerCacheTable() throws {
        let path = try Self.temporaryDatabasePath()
        try Self.writeAForkEraDatabase(at: path, digest: "sha256:abc")
        XCTAssertTrue(try Self.tableExists("layer_cache", in: path))

        _ = try StateStore(path: path, logger: Logger(label: "layer-cache-drop-tests"))

        XCTAssertFalse(try Self.tableExists("layer_cache", in: path))
    }

    /// The drop is a migration, so it must survive being asked twice: every later start reads
    /// schema v3 and has nothing to do.
    func testTheDropSurvivesASecondOpen() throws {
        let path = try Self.temporaryDatabasePath()
        try Self.writeAForkEraDatabase(at: path, digest: "sha256:def")

        _ = try StateStore(path: path, logger: Logger(label: "layer-cache-drop-tests"))
        XCTAssertNoThrow(
            try StateStore(path: path, logger: Logger(label: "layer-cache-drop-tests"))
        )
        XCTAssertFalse(try Self.tableExists("layer_cache", in: path))
    }

    /// A database created after the revert never grows the table in the first place.
    func testAFreshDatabaseHasNoLayerCacheTable() throws {
        let path = try Self.temporaryDatabasePath()

        _ = try StateStore(path: path, logger: Logger(label: "layer-cache-drop-tests"))

        XCTAssertFalse(try Self.tableExists("layer_cache", in: path))
        // A positive control on the assertion itself: `tableExists` reports the tables this
        // schema does still create, so `false` above is an absent table rather than a query
        // that never matches anything.
        XCTAssertTrue(try Self.tableExists("containers", in: path))
        XCTAssertTrue(try Self.tableExists("volumes", in: path))
    }
}
