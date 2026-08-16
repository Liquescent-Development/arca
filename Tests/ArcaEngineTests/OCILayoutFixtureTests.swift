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
/// engine suite green and fails this file -- in ten consecutive runs, on both assertions each
/// time. Changing `pinnedPayload` fails the pin alone, with the sampling still green, which is
/// the case the sampling cannot see.
///
/// **It holds the property two ways, and the two fail for different reasons.** Sampling 32 writes
/// catches an order that VARIES between them; the pinned `index.json` digest catches an order
/// that is steady but is not the sorted one. Between them the only way past is for every sampled
/// write to emit exactly the sorted order -- which is not a miss, because in that process the
/// layout genuinely is the reproducible one this test names.
///
/// **The pin is here because the sampling alone rested on the least stable thing available.** How
/// the ordering behaves between writes is a property of the process, not of the system, and two
/// independent 500-write runs of the same mutation on the same machine disagree about it:
///
/// - one saw **13** distinct layouts, one of them **57%** of the time, with **199 of 499**
///   adjacent pairs equal -- a two-write guard would have missed it about two runs in five, and
///   was in fact observed passing inside `swift test --filter ArcaEngineTests` with the defect
///   present, then failing on the next run of the same file alone;
/// - the other saw **8**, in a strict period-8 rotation -- each about **12.5%**, with **0 of
///   499** adjacent pairs equal, where a two-write guard would have caught it every time.
///
/// Both are real. Neither is *the* distribution, because the key order comes from per-allocation
/// object identity inside the encoder and so depends on the process's allocation history. **No
/// miss probability is quoted here for that reason** -- a figure derived from either run would be
/// one process's heap behaviour dressed as a bound, and it is the number a later reader would
/// most likely reuse. The pin needs none: it does not depend on that behaviour at all.
///
/// `writes` is kept at 32, above both observed regimes, because the sampling still covers what
/// the pin cannot see -- an order that changes AFTER the write the pin reads. That is also the
/// residual: the sampling is 32 samples and a 33rd write is not among them.
final class OCILayoutFixtureTests: XCTestCase {
    /// Above both observed orderings, and cheap: 32 writes cost around 60ms.
    ///
    /// In the period-8 run every 32-sample window held all 8 orderings; in the 57%-dominant run
    /// separate executions failed at 5, 3 and 7 distinct layouts. See the type doc for why this
    /// is stated as "above both observations" rather than as a probability, and for what the
    /// pinned digest covers that no sample count can.
    private static let writes = 32

    /// The payloads the samples and the pin below are all taken over.
    private static let pinnedPayload = "one"
    private static let otherPayload = "two"

    /// What `write(at:reference:payload:)` puts in `index.json` for `pinnedPayload` under
    /// `reference`, as a SHA-256 of the file's bytes.
    ///
    /// **This is what makes the guard deterministic rather than sampled, and it is why the
    /// sample count stopped being the interesting question.** Sampling alone can only fail when
    /// two of the writes happen to differ, so its strength depends on how the encoder's ordering
    /// behaves in the running process -- which two 500-write runs on one machine measured
    /// differently. A fixed expectation does not depend on that at all: an emitted order that is
    /// not the sorted one fails here on the first sample, whatever the process is doing.
    ///
    /// The two are kept together because they fail for different reasons and neither subsumes
    /// the other. To get past both, the encoder would have to emit exactly the sorted order AND
    /// emit it for all `writes` samples.
    ///
    /// `index.json` rather than the config blob directly, because it covers it: the index names
    /// the manifest by digest, the manifest names the config and the layer by digest, and
    /// `writeBlob` derives every blob's filename from its own bytes. Anything that changes the
    /// config's bytes changes this value.
    ///
    /// **Deriving it, if it ever fails legitimately** -- a changed fixture structure, a changed
    /// payload, a submodule bump that alters how `ContainerizationOCI` encodes, or **a toolchain
    /// or libarchive change**, which is the likeliest of the four in practice and the one a
    /// reader hitting this after an Xcode upgrade needs to see named: these bytes come from
    /// Foundation's `JSONEncoder`, its `\/` escaping included. The failure message carries the
    /// value actually produced, and it is `shasum -a 256 index.json` of a layout written with
    /// these constants. Update it deliberately; do not relax the assertion.
    private static let pinnedIndexDigest =
        "3bf2571174665527b5c9107e798e3e0f7b9d84d82a64643bb628d7d4875a928a"

    /// Fixed, because it is an input to `pinnedIndexDigest` -- the reference is carried by the
    /// index as an annotation.
    private static let reference = "fixture-probe:latest"

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

    /// All three, because none of them subsumes another: a fixture emitting one constant layout
    /// passes the first, the nondeterministic fixture this replaced passed the second, and both
    /// of those are sampled properties that the third does not need.
    func testEveryLayoutFromOnePayloadIsIdenticalAndMatchesThePinnedDigest() throws {
        let sampled = try (0..<Self.writes).map {
            try layout(named: "same-\($0)", payload: Self.pinnedPayload)
        }
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
            sampled[0], try layout(named: "other", payload: Self.otherPayload),
            "a layout must still be a function OF the payload; without this a fixture that "
                + "ignored its payload entirely would satisfy the assertion above"
        )
        XCTAssertEqual(
            try indexDigest(ofLayoutNamed: "same-0"), Self.pinnedIndexDigest,
            """
            the layout is reproducible run to run but is no longer the one this test was pinned \
            to. Unlike the sampling above, this does not depend on how the encoder happens to \
            order keys in this process: it fails on the first sample. See `pinnedIndexDigest` \
            for how to re-derive it if the change was deliberate.
            """
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
            reference: Self.reference,
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

    /// The SHA-256 of one already-written layout's `index.json`, which is what `pinnedIndexDigest`
    /// holds. Read back off disk rather than recomputed, so the pin is over the bytes a loader
    /// would actually read.
    private func indexDigest(ofLayoutNamed name: String) throws -> String {
        let index = scratch.appendingPathComponent(name).appendingPathComponent("index.json")
        return SHA256.hash(data: try Data(contentsOf: index))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
