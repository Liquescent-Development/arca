import CryptoKit
import Foundation
import XCTest

/// That `OCILayoutFixture` writes a layout which is a function of its payload and nothing else.
///
/// **This exists because the property is stated, load-bearing, and was silently false.** The
/// fixture's own doc calls it that -- "two written from the same `payload` are byte-identical …
/// the second is what makes the first mean anything" -- and until `9780291` `JSONEncoder` emitted
/// the config's keys in a different order on every encode, so two layouts holding an IDENTICAL
/// payload carried different image digests.
///
/// What that costs is not a failing test, which is why nothing caught it. It costs
/// `EngineStartupTests.testAnUnchangedVminitKeepsTheInitfsAndAChangedOneDeletesIt` its meaning:
/// its `XCTAssertNotEqual(second, first, "a different vminit must load to a different digest")`
/// passes for two layouts written from the same payload, so it cannot tell "the vminit changed"
/// from "the fixture was written twice". A regression whose only symptom is another test quietly
/// ceasing to assert anything is exactly what needs a guard rather than a measurement.
///
/// MEASURED both ways: deleting `encoder.outputFormatting = [.sortedKeys]` leaves the rest of the
/// engine suite green and fails this file.
///
/// **The repetition count is the load-bearing part of this test, and two writes were not
/// enough.** `JSONEncoder` without `.sortedKeys` does not emit a uniformly random order: MEASURED
/// over 500 writes of one payload with the line deleted, the layout took only **13** distinct
/// forms, one of them **57%** of the time, and **199 of 499 adjacent pairs were equal**. A
/// two-write version of this test therefore passed roughly two runs in five with the defect
/// present -- observed, not predicted: it passed inside `swift test --filter ArcaEngineTests` and
/// failed on the next run of the same file alone.
///
/// There is no single-sample assertion that avoids this, because the defect is the absence of a
/// guarantee and any one layout is one sample of it. So the guard is sized instead: at the
/// measured 57% dominant order, `writes` = 32 leaves a miss probability of 0.57^31, about 1 in
/// 10^8, while costing a few tens of milliseconds.
final class OCILayoutFixtureTests: XCTestCase {
    /// Enough samples that the measured 57% dominant ordering cannot carry all of them. See the
    /// type doc: at two writes this guard missed the regression about 40% of the time.
    private static let writes = 32

    private var scratch: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("arca-oci-layout-fixture-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
        try super.tearDownWithError()
    }

    /// Both halves, because either alone is satisfied by something useless: a fixture that
    /// emitted one constant layout would pass the first, and the nondeterministic fixture this
    /// replaced passed the second.
    func testEveryLayoutFromOnePayloadIsIdenticalAndADifferentPayloadIsNot() throws {
        let sampled = try (0..<Self.writes).map { try layout(named: "same-\($0)", payload: "one") }
        let distinct = Set(sampled)

        XCTAssertEqual(
            distinct.count, 1,
            """
            \(distinct.count) distinct layouts from \(Self.writes) writes of one payload. That \
            makes EngineStartupTests.swift:288 -- "a different vminit must load to a different \
            digest" -- vacuous: it cannot tell a changed vminit from a re-written fixture.
            """
        )
        XCTAssertNotEqual(
            sampled[0], try layout(named: "other", payload: "two"),
            "a layout must still be a function OF the payload; without this a fixture that "
                + "ignored its payload entirely would satisfy the assertion above"
        )
    }

    /// Every file in the layout as one canonical string: `<relative path>=<content digest>` per
    /// line, sorted.
    ///
    /// The whole tree rather than `index.json` alone: the index names the manifest by digest and
    /// the manifest names the config and the layer the same way, so a difference anywhere below
    /// reaches the index -- but reading only the index would leave a reader guessing whether that
    /// is by construction or by luck, and the blob filenames ARE their digests.
    ///
    /// Sorted into a string rather than returned as a `[String: String]` because this test
    /// compares readings for equality, and `Dictionary`'s own iteration and `description` order
    /// is per-instance -- a comparison built on it would have carried the exact defect it exists
    /// to catch.
    private func layout(named name: String, payload: String) throws -> String {
        let directory = try OCILayoutFixture.write(
            at: scratch.appendingPathComponent(name),
            reference: "fixture-probe:latest",
            payload: payload
        )
        let walker = try XCTUnwrap(
            FileManager.default.enumerator(atPath: directory.path),
            "the fixture must write a directory that can be walked"
        )

        var lines: [String] = []
        for case let entry as String in walker {
            let file = directory.appendingPathComponent(entry)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue
            else { continue }
            let digest = SHA256.hash(data: try Data(contentsOf: file))
                .map { String(format: "%02x", $0) }
                .joined()
            lines.append("\(entry)=\(digest)")
        }
        XCTAssertFalse(lines.isEmpty, "the fixture must write files, or this compares nothing")
        return lines.sorted().joined(separator: "\n")
    }
}
