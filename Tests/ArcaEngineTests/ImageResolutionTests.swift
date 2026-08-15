import ContainerBridge
import Foundation
import Logging
import XCTest
@testable import ArcaEngine

/// The store resolves the reference `Create` hands it.
///
/// **This is Problem 1, and it is the one part of `Create` that a VM cannot
/// stand in for.** `ContainerManager.createContainer` uses a single string for
/// two jobs -- it resolves the image with it (`ContainerManager.swift:1698`) and
/// records it as `ContainerInfo.image` (`:1901`) -- and `startContainer`
/// resolves that recorded string again when it rebuilds a container after a
/// restart (`:2218`). Meanwhile `Inspect` requires the recorded string to be an
/// exact digest reference, or it answers `invalid_output`
/// (`SandboxEngineService.swift:196`, `imageDigest(fromReference:)`).
///
/// So one string must satisfy three constraints, and the only form that can is
/// `repository@sha256:<hex>` -- which is exactly the form gascan sends
/// (`immutable_image_reference`, `crates/gascan-core/src/runtime.rs:677-686`)
/// and exactly the form the resolver did not accept.
///
/// These tests drive `ImageManager` directly rather than through `Create`,
/// because `createContainer`'s uninitialised-manager guard (`:1659`) throws
/// before the resolution ever happens: a test that went through `Create` could
/// not tell a resolver that works from one that is never reached.
final class ImageResolutionTests: XCTestCase {
    private let logger = Logger(label: "image-resolution-tests")

    /// The immutable reference resolves, and the tag it is stored under still
    /// resolves too.
    ///
    /// The store holds one row, referenced `workspace:latest` -- a tag. Nothing
    /// in it is spelt `workspace@sha256:...`, so this cannot pass by an exact
    /// string match against a stored reference; the digest arm has to actually
    /// compare the digest.
    ///
    /// The tag half is not decoration. It is the whole Docker surface of this
    /// codebase in one assertion: `docker run nginx:alpine` resolves through
    /// this same function, and a digest arm written so that it swallowed every
    /// input would take the tag path away without anything else noticing.
    func testTheImmutableReferenceGasCanSendsResolvesAndSoDoesTheStoredTag() async throws {
        let store = try await preparedStore()

        let byDigest = try await store.manager.getImage(
            nameOrId: "workspace@sha256:\(store.hex)"
        )
        XCTAssertEqual(
            byDigest.reference, "workspace:latest",
            "the immutable reference must resolve to the row the store really holds"
        )

        let byTag = try await store.manager.getImage(nameOrId: "workspace:latest")
        XCTAssertEqual(byTag.reference, "workspace:latest")
    }

    /// The repository half is compared, not ignored.
    ///
    /// A digest arm that resolved on the digest alone would return this store's
    /// only image for `anything-at-all@sha256:<hex>`, which is a create running
    /// content under a name the caller did not ask for. The comparison is exact
    /// and normalizes no registry, the same direction `PrepareImage` chose: a
    /// false "not found" is visible and recoverable, a false match is neither.
    func testADigestHeldUnderAnotherRepositoryDoesNotResolve() async throws {
        let store = try await preparedStore()

        do {
            let wrong = try await store.manager.getImage(
                nameOrId: "not-the-workspace@sha256:\(store.hex)"
            )
            XCTFail("a foreign repository must not resolve, got \(wrong.reference)")
        } catch {
            // `imageNotFound` is what the resolver throws when nothing matches;
            // any other error would mean the lookup broke rather than declined.
            XCTAssertTrue(
                "\(error)".contains("not-the-workspace"),
                "the refusal must name what was asked for, got \(error)"
            )
        }
    }

    /// And a digest the store does not hold does not resolve under a repository
    /// it does.
    ///
    /// The pair to the test above, on the other axis: together they say the arm
    /// requires both halves to match rather than either one.
    func testAnAbsentDigestDoesNotResolveUnderAHeldRepository() async throws {
        let store = try await preparedStore()
        let flipped = store.hex.first == "0"
            ? "1" + store.hex.dropFirst()
            : "0" + store.hex.dropFirst()

        do {
            let wrong = try await store.manager.getImage(
                nameOrId: "workspace@sha256:\(flipped)"
            )
            XCTFail("an absent digest must not resolve, got \(wrong.reference)")
        } catch {
            XCTAssertTrue(
                "\(error)".contains(String(flipped)),
                "the refusal must name what was asked for, got \(error)"
            )
        }
    }

    // MARK: - The additive claim, proved rather than asserted

    /// Every form that resolved before the exact-digest arm existed still
    /// resolves, and to the same image.
    ///
    /// **This is the whole safety argument for touching a resolver shared with
    /// Arca's Docker surface, so it is a test and not a sentence in a comment.**
    /// The three arms that were already here -- short ID, long ID and the
    /// reference matcher -- are each driven against the one row this store holds,
    /// and each must come back with it.
    ///
    /// The short ID is twelve characters because that is the width `resolveImage`
    /// documents and `^[a-f0-9]{12,64}$` enforces; the long ID carries the
    /// `sha256:` prefix that is what distinguishes it from the short one.
    func testEveryFormThatResolvedBeforeStillResolvesToTheSameImage() async throws {
        let store = try await preparedStore()

        let byTag = try await store.manager.getImage(nameOrId: "workspace:latest")
        XCTAssertEqual(byTag.reference, "workspace:latest", "the tag arm")

        let byShortID = try await store.manager.getImage(nameOrId: String(store.hex.prefix(12)))
        XCTAssertEqual(byShortID.reference, "workspace:latest", "the short-ID arm")

        let byLongID = try await store.manager.getImage(nameOrId: "sha256:\(store.hex)")
        XCTAssertEqual(byLongID.reference, "workspace:latest", "the long-ID arm")
    }

    /// A store row whose reference literally *is* `repo@sha256:<hex>` still
    /// resolves by exact string match, through `matchesReference`.
    ///
    /// **This is the arm the new one could most easily have taken away**, and the
    /// fixture is built so that only `matchesReference` can satisfy it: the tag's
    /// digest half is sixty-four `b`s, which is *not* the digest this store
    /// records for the image, so the exact-digest arm can match neither half of
    /// it. Had the new arm been written by making the reference arm unreachable
    /// for digest-shaped input -- the obvious way to write it -- this fails.
    ///
    /// The second half is the pair that makes the first mean something: the same
    /// row's real digest, under its real repository, resolves through the *new*
    /// arm. One store answers both ways, so the two arms are shown to coexist
    /// rather than one having replaced the other.
    func testAStoredReferenceThatIsItselfADigestReferenceStillResolvesByName() async throws {
        let store = try await preparedStore()
        let notTheDigest = String(repeating: "b", count: 64)

        try await store.manager.tagImage(
            source: "workspace:latest", target: "legacy@sha256:\(notTheDigest)"
        )

        let byStoredName = try await store.manager.getImage(
            nameOrId: "legacy@sha256:\(notTheDigest)"
        )
        // Asserted on the REFERENCE, not the digest. Both rows carry the same
        // content and therefore the same digest -- `tagImage` adds a name to
        // bytes that are already there -- so a digest assertion here would pass
        // whichever row came back and could not tell which arm answered.
        XCTAssertEqual(
            byStoredName.reference, "legacy@sha256:\(notTheDigest)",
            "a row stored under a digest-shaped reference must still resolve by exact name, "
                + "through matchesReference, even though that name names a digest the store "
                + "does not hold"
        )

        let byRealDigest = try await store.manager.getImage(
            nameOrId: "workspace@sha256:\(store.hex)"
        )
        XCTAssertEqual(
            byRealDigest.digest, "sha256:\(store.hex)",
            "and the same store must still answer the new arm"
        )
    }

    // MARK: - The other callers the widened resolver reaches

    /// `inspectImage` must accept the digest form too, and this pins why the arm
    /// cannot be scoped to `getImage` alone.
    ///
    /// **`createContainer` calls both with the SAME string**, one line apart:
    /// `getImage(nameOrId: image)` at `ContainerManager.swift:1698` and
    /// `inspectImage(nameOrId: image)` at `:1701`. `inspectImage` swallows a
    /// resolution failure with `try?` and returns nil, and the call site takes
    /// `imageDetails?.id ?? "sha256:" + String(repeating: "0", count: 64)`
    /// (`:1702`). So narrowing the arm to `getImage` would raise no error -- it
    /// would silently record an all-zero image ID on every sandbox this engine
    /// creates.
    ///
    /// Task 11's review preferred narrowing, precisely so the Docker-surface
    /// change would disappear, and asked for this to be traced rather than
    /// guessed. This test is the trace, and it fails if the arm is narrowed.
    func testInspectImageResolvesTheDigestFormBecauseTheCreatePathAsksItTo() async throws {
        let store = try await preparedStore()

        let details = try await store.manager.inspectImage(
            nameOrId: "workspace@sha256:\(store.hex)"
        )
        let found = try XCTUnwrap(
            details,
            "inspectImage must resolve the digest form: createContainer passes it the same "
                + "string it passes getImage, and swallows a nil into an all-zero image ID"
        )
        XCTAssertEqual(found.repoTags, ["workspace:latest"])
        XCTAssertNotEqual(
            found.id, "sha256:" + String(repeating: "0", count: 64),
            "the all-zero fallback is what a narrowed arm would record instead"
        )
    }

    /// `rmi` by digest reference does not delete a row it did not name.
    ///
    /// **This is the destructive consequence the widening introduced**, found by
    /// Task 11's review and measured there: over a store whose only row was
    /// `alpha:latest`, `deleteImage("alpha@sha256:<digest>")` untagged
    /// `alpha:latest` and cleaned up the content behind it. Before the resolver
    /// arm the same call threw `No such image`, so the widening turned an error
    /// into an unforced destructive success on the Docker socket.
    ///
    /// `deleteImage` deletes by the RESOLVED row's reference
    /// (`ImageManager.swift:441`), not by the string it was given, which is why
    /// resolving more inputs makes it delete more things.
    ///
    /// The second half is the pair that keeps the refusal honest: a digest
    /// reference that names an actual stored row still deletes exactly that row,
    /// and only that row. A guard that refused every digest form would pass the
    /// first half on its own.
    func testDeletingByDigestRefusesToRemoveARowItDidNotName() async throws {
        let store = try await preparedStore()

        do {
            let removed = try await store.manager.deleteImage(
                nameOrId: "workspace@sha256:\(store.hex)"
            )
            XCTFail("must refuse to untag workspace:latest, removed \(removed)")
        } catch {
            XCTAssertTrue(
                "\(error)".contains("which is a different reference"),
                "the refusal must say the resolved row was not the one named, got \(error)"
            )
        }

        let survived = try await store.manager.inspectImage(nameOrId: "workspace:latest")
        XCTAssertNotNil(
            survived, "the tag the caller never typed must still be there after the refusal"
        )

        // A row that really is named by the digest form deletes normally.
        let notTheDigest = String(repeating: "c", count: 64)
        try await store.manager.tagImage(
            source: "workspace:latest", target: "legacy@sha256:\(notTheDigest)"
        )
        _ = try await store.manager.deleteImage(nameOrId: "legacy@sha256:\(notTheDigest)")
        let deleted = try await store.manager.inspectImage(
            nameOrId: "legacy@sha256:\(notTheDigest)"
        )
        XCTAssertNil(deleted, "a digest reference naming a real row must still delete that row")
        let untouched = try await store.manager.inspectImage(nameOrId: "workspace:latest")
        XCTAssertNotNil(untouched, "and must not take the other reference with it")
    }

    /// A legitimate `rmi` by digest reference succeeds every time, not most
    /// times.
    ///
    /// **This pins a nondeterminism the round-2 fix introduced and the re-review
    /// caught.** With both a tag row and a row literally named
    /// `repository@sha256:<hex>` in the store, two arms can answer one input: the
    /// name arm matches the literal row, the digest arm matches the content. The
    /// arms used to be interleaved inside one loop over `imageStore.list()`,
    /// whose order is the store's own, so whichever ROW came first decided which
    /// ARM answered -- and `deleteImage`'s guard, which compares the resolved
    /// row's reference against the input, then refused a legitimate delete
    /// whenever the tag row happened to come first. MEASURED by the re-review
    /// over five runs: two threw, three succeeded, and in one run `getImage` and
    /// `deleteImage` resolved the same string to different rows inside one
    /// process.
    ///
    /// The loop is now one pass per arm rather than one pass per row, so a name
    /// match always beats a content match and the answer is a function of what
    /// the store holds rather than of how it enumerates.
    ///
    /// **Twenty stores, and they are independent only because `preparedStore()`
    /// gives each one its own content.** A fresh store is not by itself a fresh
    /// enumeration order -- see that fixture's comment. MEASURED against the
    /// interleaved resolver this test exists to catch (`de8c880`'s
    /// `ImageManager.swift`, restored whole), 20 runs each: with every store
    /// holding identical content this test caught it **5 times in 20**; with the
    /// content varied per store, **19 times in 20**. The re-review's "39 of 40"
    /// for that mutation was the whole suite going RED, which it did on the
    /// strength of the three other tests here, not this one.
    func testDeletingALiterallyNamedDigestRowSucceedsOnEveryRun() async throws {
        for iteration in 1...20 {
            let store = try await preparedStore()
            let named = "workspace@sha256:\(store.hex)"
            // The store now holds `workspace:latest` AND a row literally named
            // by the digest reference. Both can answer; only one is right.
            try await store.manager.tagImage(source: "workspace:latest", target: named)

            let resolved = try await store.manager.getImage(nameOrId: named)
            XCTAssertEqual(
                resolved.reference, named,
                "run \(iteration): the row the caller named must win over the row that "
                    + "merely holds the same content"
            )

            _ = try await store.manager.deleteImage(nameOrId: named)

            // Asserted on the store's ROWS, not on whether the reference still
            // resolves. It still does, and correctly: the surviving
            // `workspace:latest` holds the same content under the same
            // repository, so `workspace@sha256:<hex>` remains a true statement
            // about what the store has. The question this test asks is which row
            // was removed.
            let rows = try await store.manager.listImages()
                .flatMap(\.repoTags).sorted()
            XCTAssertEqual(
                rows, ["workspace:latest"],
                "run \(iteration): the named row must be the one deleted, and the tag must "
                    + "survive its sibling's deletion"
            )
        }
    }

    /// A row the caller named beats a row that merely holds the content, on
    /// every read.
    ///
    /// **This tests arm PRECEDENCE and -- corrected -- it does not test the
    /// tie-break.** Its first version claimed a third row "gives a tie-break
    /// something to trip on"; the re-review showed the tie-break never runs
    /// here, because the store holds a row named exactly what is being asked
    /// for, so the name arm answers and the digest pass is never reached. The
    /// tie-break has its own test below. This one goes RED under the interleaved
    /// mutation, which is what it is for.
    func testANamedRowBeatsAContentMatchOnEveryRead() async throws {
        let store = try await preparedStore()
        let named = "workspace@sha256:\(store.hex)"
        try await store.manager.tagImage(source: "workspace:latest", target: named)

        var answers: Set<String> = []
        for _ in 1...25 {
            answers.insert(try await store.manager.getImage(nameOrId: named).reference)
        }
        XCTAssertEqual(
            answers, [named],
            "twenty-five reads of one unchanged store must give exactly one answer, and it "
                + "must be the row the caller named"
        )
    }

    /// The digest pass's tie-break is fixed, not incidental.
    ///
    /// **The store is built so the digest pass is the only arm that can
    /// answer**: no row is named `workspace@sha256:<hex>`, and two rows hold that
    /// content under the same repository. Both are equally valid answers, so
    /// something must choose -- and if that something is `imageStore.list()`'s
    /// order, the resolver is nondeterministic again.
    ///
    /// Pinned to the `alpha` row, the lexicographically smaller reference. The
    /// direction is arbitrary; that it is *fixed* is not. Both mutations the
    /// re-review ran against the first version of this fix -- reversing the
    /// tie-break and deleting it -- survived all 131 tests, which is what a
    /// tie-break with no test looks like. This is **Minor 6** from round 1,
    /// finally pinned.
    ///
    /// Twenty stores, with the tag names salted per iteration for the reason
    /// `testTheShortAndLongIdArmsAlsoAnswerTheSameWayEveryTime` records: twenty
    /// stores holding the same names enumerate alike inside one process, so
    /// without the salt the loop is worth far fewer than twenty samples.
    /// MEASURED on the tree this ships as, three mutations, each applied to a
    /// clean tree:
    ///
    /// - this arm reverted to `images.first(where:)`: RED **15 of 15**, 6 to 14
    ///   of the twenty iterations failing per run.
    /// - the tie-break deleted (`candidates.first`): RED **10 of 10**.
    /// - the tie-break reversed: RED **5 of 5**, and it cannot depend on
    ///   enumeration at all -- it answers the `zulu` row from any order.
    func testTheDigestPassPicksTheSameCandidateEveryTime() async throws {
        for iteration in 1...20 {
            let store = try await preparedStore()
            let salt = String(format: "%02d", iteration)
            try await store.manager.tagImage(
                source: "workspace:latest", target: "workspace:alpha\(salt)"
            )
            try await store.manager.tagImage(
                source: "workspace:latest", target: "workspace:zulu\(salt)"
            )
            // Leaves exactly two rows, both holding this content under
            // `workspace`, and neither named by the digest reference below.
            _ = try await store.manager.deleteImage(nameOrId: "workspace:latest")

            let resolved = try await store.manager.getImage(
                nameOrId: "workspace@sha256:\(store.hex)"
            )
            XCTAssertEqual(
                resolved.reference, "workspace:alpha\(salt)",
                "run \(iteration): with two equally-valid candidates the digest pass must "
                    + "choose by a fixed rule, not by the store's enumeration order"
            )
        }
    }

    /// The ID arms are order-independent too.
    ///
    /// **The re-review measured these still unstable after the first ordering
    /// fix**: five reads of one unchanged store, inside one process, gave two
    /// different answers for a short ID and for a long ID. Both arms can match
    /// more than one row -- two references to one content share a digest -- and
    /// both were still returning whichever row the loop reached first.
    ///
    /// So "resolution is a function of what the store holds, not how it
    /// enumerates" was false for half the arms while being written in three
    /// places. Every arm now collects and takes the minimum, and this says so
    /// rather than the comment saying it.
    ///
    /// **Twenty stores, and the tag names are salted per iteration, because the
    /// salt is what makes the twenty samples independent.** The first version of
    /// this test read one store 25 times, and the re-review measured it catching
    /// a revert of the short-ID arm in 10 runs of 15. Twenty *unsalted* stores
    /// did not help -- MEASURED at 9 of 15, and every one of those runs failed
    /// either all 100 assertions or none of them, so twenty stores carrying the
    /// same three names are one sample and not twenty. Salting the names
    /// resamples the store's enumeration per iteration, and on the tree this
    /// ships as:
    ///
    /// - short-ID arm reverted to `images.first(where:)`: RED **15 of 15**,
    ///   failing 40 to 100 of the 100 short-ID assertions per run.
    /// - long-ID arm reverted the same way: RED **15 of 15**, 30 to 96 per run.
    ///
    /// Not proven deterministic, and this comment will not say it is. What is
    /// measured is 30 of 30 runs RED off a per-iteration miss rate near half,
    /// which is the difference between one chance to catch a later edit and
    /// twenty.
    func testTheShortAndLongIdArmsAlsoAnswerTheSameWayEveryTime() async throws {
        for iteration in 1...20 {
            let store = try await preparedStore()
            let salt = String(format: "%02d", iteration)
            try await store.manager.tagImage(
                source: "workspace:latest", target: "workspace:alpha\(salt)"
            )
            try await store.manager.tagImage(
                source: "workspace:latest", target: "workspace:zulu\(salt)"
            )
            // `alpha…` sorts before `latest`, which sorts before `zulu…`, so the
            // rule's answer is known without recomputing the rule.
            let expected = "workspace:alpha\(salt)"

            for read in 1...5 {
                let shortId = try await store.manager
                    .getImage(nameOrId: String(store.hex.prefix(12))).reference
                XCTAssertEqual(
                    shortId, expected,
                    "store \(iteration), read \(read): a short ID matching three rows must "
                        + "resolve to one of them by a fixed rule"
                )
                let longId = try await store.manager
                    .getImage(nameOrId: "sha256:\(store.hex)").reference
                XCTAssertEqual(
                    longId, expected,
                    "store \(iteration), read \(read): and so must a long ID"
                )
            }
        }
    }

    // MARK: - The parser the arm is built on

    /// `ImageIdentity.exactDigest` recognises the form and nothing near it.
    ///
    /// Tested directly, because these refusals are invisible through
    /// `getImage`: a malformed digest that the parser wrongly accepted would
    /// engage the exact-digest arm, match no stored digest, and throw "No such
    /// image" -- which is what a *correctly* refused one does too. The two paths
    /// are indistinguishable from outside, so the only place the guard can be
    /// held is here. A mutation that dropped the length check survived the whole
    /// suite until this existed.
    ///
    /// The uppercase row is the one that would bite in practice: the store
    /// records digests lowercase, so accepting `SHA256` hex would parse a
    /// reference that then matches nothing, reporting content absent that the
    /// engine holds.
    func testTheExactDigestParserRecognisesTheFormAndNothingNearIt() {
        let hex = String(repeating: "a", count: 64)

        let parsed = ImageIdentity.exactDigest(of: "workspace@sha256:\(hex)")
        XCTAssertEqual(parsed?.repository, "workspace")
        XCTAssertEqual(parsed?.digest, "sha256:\(hex)")

        // A tag before the digest names the same repository.
        XCTAssertEqual(
            ImageIdentity.exactDigest(of: "workspace:latest@sha256:\(hex)")?.repository,
            "workspace"
        )
        // And a registry port is not a tag.
        XCTAssertEqual(
            ImageIdentity.exactDigest(of: "registry.example:5000/repo@sha256:\(hex)")?.repository,
            "registry.example:5000/repo"
        )

        XCTAssertNil(ImageIdentity.exactDigest(of: "workspace:latest"), "no digest at all")
        XCTAssertNil(ImageIdentity.exactDigest(of: "sha256:\(hex)"), "a bare long ID is not one")
        XCTAssertNil(
            ImageIdentity.exactDigest(of: "workspace@sha256:\(hex.dropLast())"), "63 characters"
        )
        XCTAssertNil(
            ImageIdentity.exactDigest(of: "workspace@sha256:\(hex)a"), "65 characters"
        )
        XCTAssertNil(
            ImageIdentity.exactDigest(of: "workspace@sha256:\(hex.uppercased())"), "uppercase hex"
        )
        XCTAssertNil(
            ImageIdentity.exactDigest(of: "workspace@sha256:\(String(repeating: "g", count: 64))"),
            "64 characters that are not hex"
        )
        XCTAssertNil(ImageIdentity.exactDigest(of: "@sha256:\(hex)"), "no repository")
    }

    // MARK: - Fixtures

    private struct PreparedStore {
        let manager: ImageManager
        /// Read back from the store: Containerization synthesizes an index for a
        /// single-manifest layout during import, so the digest the store records
        /// is not one this test could state in advance.
        let hex: String
    }

    /// Every store gets its own content, and that is load-bearing for the loop
    /// tests above.
    ///
    /// A store's enumeration order is fixed for the life of a *process* given a
    /// fixed set of references: MEASURED, by reverting the short-ID arm to
    /// `images.first(where:)` against twenty stores that all carried the same
    /// three names -- every run failed either all 100 assertions or none of
    /// them, and the revert still escaped 6 runs in 15. Twenty such stores are
    /// one sample and not twenty.
    ///
    /// A unique payload gives a unique digest, and so a unique spelling for
    /// every reference that carries one. That is what makes
    /// `testDeletingALiterallyNamedDigestRowSucceedsOnEveryRun`'s twenty stores
    /// twenty samples -- its rows are named `workspace@sha256:<hex>` -- and it
    /// took that test from 5 catches in 20 to 19 in 20. The two loop tests whose
    /// rows are plain tags salt the tag names themselves, for the same reason.
    private func preparedStore() async throws -> PreparedStore {
        let identity = UUID().uuidString
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("arca-image-resolution-tests-\(identity)")
        let stateRoot = root.appendingPathComponent("state")
        _ = try await loadWorkspaceImages(
            fromOCILayout: try OCILayoutFixture.write(
                at: root.appendingPathComponent("workspace"),
                reference: "workspace:latest",
                payload: "pushed by the consumer, not by startup, \(identity)"
            ),
            stateRoot: stateRoot,
            logger: logger
        )
        let manager = try EngineManagers.makeImageManager(
            paths: EnginePaths(stateRoot: stateRoot), logger: logger
        )
        let details = try await manager.inspectImage(nameOrId: "workspace:latest")
        let digest = try XCTUnwrap(
            details?.repoDigests.first, "the store must report a digest for the image it loaded"
        )
        return PreparedStore(
            manager: manager, hex: digest.replacingOccurrences(of: "sha256:", with: "")
        )
    }
}
