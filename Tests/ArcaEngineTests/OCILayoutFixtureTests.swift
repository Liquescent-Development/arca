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
/// enough.** A two-write version passed inside `swift test --filter ArcaEngineTests` with the
/// defect present and failed on the next run of the same file alone -- observed, not predicted.
///
/// **What the ordering does between writes is a property of the process, not of the system, and
/// two independent 500-write runs of the same mutation on the same machine disagree about it:**
///
/// - one saw **13** distinct layouts, one of them **57%** of the time, with **199 of 499**
///   adjacent pairs equal;
/// - the other saw **8**, in a strict period-8 rotation -- each about **12.5%**, with **0 of
///   499** adjacent pairs equal, where a two-write guard would have caught the defect every time.
///
/// Both are real. Neither is *the* distribution, because the key order comes from per-allocation
/// object identity inside the encoder and so depends on the process's allocation history. **No
/// miss probability is quoted here for that reason** -- a figure derived from either run would be
/// one process's heap behaviour dressed as a bound, and it is the number a later reader would
/// most likely reuse.
///
/// What survives both runs is the shape of the argument: there is no single-sample assertion that
/// avoids this, because the defect is the absence of a guarantee and any one layout is one sample
/// of it. Note that the same sentence still applies at 32 -- no sample count protects against a
/// process whose ordering happens to be constant throughout. `writes` is sized to sit comfortably
/// above both observed regimes rather than to bound a risk.
final class OCILayoutFixtureTests: XCTestCase {
    /// Comfortably above both observed orderings, and cheap: 32 writes cost around 60ms.
    ///
    /// In the period-8 run every 32-sample window held all 8 orderings; in the 57%-dominant run
    /// three separate executions failed at 5, 3 and 7 distinct layouts. See the type doc for why
    /// this is stated as "above both observations" rather than as a probability.
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
    /// Sorted into a string rather than returned as a `[String: String]` for a legible failure
    /// and a stable printed form -- **not** because a dictionary would have compared wrongly.
    /// `Dictionary` equality and hashing are order-independent, so `Set(sampled)` over
    /// dictionaries would have been correct; only its *iteration* and `description` order vary
    /// per instance, which would have made the failure message shuffle between runs while the
    /// comparison stayed sound.
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
