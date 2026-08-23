# Evidence: a refused unpack poisoned its own cache slot

The durable record for the measurements cited by
`Tests/ArcaEngineTests/ImageRootfsUnpackerTests.swift` and by the doc comments in
`Sources/ContainerBridge/ImageRootfsUnpacker.swift`. Both cite this file by name,
which is why `Documentation/.gitignore` carries a `!EVIDENCE-*.md` allowlist entry:
a committed test citing a file that is not in git leaves its evidence with no
durable home, which is how this record came to live in another repository's
ignored scaffolding in the first place.

**This document was updated, not superseded.** The defect it records did not go
away with the layer cache; only its home moved. It was found at *layer*
granularity, and the revert to upstream's single composed rootfs reproduces the
same hazard at *image* granularity, where it is worse: one poisoned `rootfs.ext4`
is reused by every later container built from that image, not just by the creates
that want one layer of it.

Found by the whole-landing review of milestone 4 Landing 1, after seven
task-scoped reviews had passed. Fixed at Arca `4134b54`, published in
`gascan-engine-m4` (`c545612b`).

## The defect

`EXT4.Formatter` writes the superblock **and the volume label** in `close()`
(`ContainerizationEXT4/EXT4+Formatter.swift:645`, `:970-972`). The formatter was
pointed at the final cache path and `close()` was deferred, so an unpack that
*threw* — which is exactly what a mistyped layer made it do — still left a valid,
correctly labelled, **empty** `layer.ext4` in the cache slot.

The next create's reuse predicate tests **the label alone**, so it hit.

An attached-layer count could not see it. The poisoned device is a real ext4,
carries `.overlayLayer`, is attached, *is* counted, and `ArcaLayerAttachment.resolve`
sees `attached == identified` and resolves `.complete`. **The first create failed
loudly; every create after it booted a container on a rootfs built from none of
that layer, with `Start` succeeding.**

## Failing-before evidence — HISTORICAL, and the command below no longer runs

The review's confidence came from reading. The tests were written and run against
**unfixed** code first.

Command, **as it was then**: `swift test --disable-swift-testing --filter LayerCacheRoleTests`,
at Arca `cc8068c` / submodule `fb2b2f28241e8c4a8d3257e97d4bf2acebb360d6`, source
otherwise unmodified.

Result: `Executed 14 tests, with 5 failures (0 unexpected)`.

```
LayerCacheRoleTests.swift:653: error: -[...testAnUnpackThatRefusesALayerLeavesNoCacheEntryForTheNextCreateToReuse] : XCTAssertFalse failed - the refused layer left a REUSABLE cache slot. It is a valid ext4 carrying .overlayLayer over none of the image, so the guest classifies it, the attached-layer count counts it, and the container boots on a rootfs missing that layer entirely.
LayerCacheRoleTests.swift:661: error: -[...testAnUnpackThatRefusesALayerLeavesNoCacheEntryForTheNextCreateToReuse] : XCTAssertFalse failed - a cache slot must not exist at all unless the unpack that would fill it succeeded: a slot whose existence is not conditional on success is one predicate change away from being reused again
LayerCacheRoleTests.swift:673: error: -[...testAnUnpackThatRefusesALayerLeavesNoCacheEntryForTheNextCreateToReuse] : XCTUnwrap failed: expected non-nil value of type "Error" - the retry SUCCEEDED over a layer the first attempt refused. The refusal was converted into a silent acceptance by the cache, which is the whole defect: it fails loudly once and then hands every later create an empty layer.
LayerCacheRoleTests.swift:738: error: -[...testARefusedLayerLeavesNoPartialSlotForItsSiblings] : XCTAssertFalse failed - the refused layer's own slot must not be reusable
LayerCacheRoleTests.swift:767: error: -[...testARefusedLayerLeavesNoPartialSlotForItsSiblings] : XCTAssertNotNil failed - the retry of a three-layer image SUCCEEDED over a layer the first attempt refused: two good layers and one empty one, labelled, counted, and resolved .complete. The container boots on a rootfs missing its top layer, and Start succeeds.
```

**The decisive lines are `:673` and `:767`: the RETRY SUCCEEDED**, in both the
one-layer and the three-layer shape. The defect was confirmed by measurement, not
by argument.

The tests were driven over a fixture mode
`OCILayoutFixture.Layer.Blob.bytesThatAreNotTheDeclaredArchive` — raw bytes written
under `MediaTypes.imageLayer`. The digest is still correct, so nothing upstream of
the unpack objects. That fixture mode survives; it is what
`ImageRootfsUnpackerTests.fixtureRefusingItsLayer` drives today.

### Do not run that command expecting it to check anything

`Tests/ArcaEngineTests/LayerCacheRoleTests.swift` was deleted at `2d1f8db`, along
with the host-side `Sources/ContainerBridge/OverlayFS/` directory whose types it
called. The filter therefore matches nothing, and `swift test` reports that as
success. MEASURED on 2026-08-22 against the tree of the commit that carries this
document:

```
$ swift test --disable-swift-testing --filter LayerCacheRoleTests
warning: No matching test cases were run
	 Executed 0 tests, with 0 failures (0 unexpected)
exit 0
```

Exit 0 over zero executed tests. The `warning:` line is the only thing that
distinguishes it from a pass, and it is one line in a build log.

**The live command is:**

```
swift test --disable-swift-testing --filter ImageRootfsUnpackerTests
```

MEASURED on 2026-08-22 at `f95850e`: exit 0,
`Executed 12 tests, with 0 failures (0 unexpected)`. **Check the count.** A green
run with a number that is not 12 means the filter, not the code, is what changed —
which is the whole point of the paragraph above.

## The fix, and where it lives now

The idea is the same. What changed is where it lives, and that it now takes
**three** mechanisms rather than two.

The original fix, at layer granularity, unpacked into a sibling staging path and
promoted onto `layer.ext4` with `rename(2)` only after `formatter.close()`
returned; `close()` was deliberately no longer deferred, because it was the commit
point. That code is `OverlayFSUnpacker.promoteStagedLayer` in the submodule, still
present at the pointer this repository carries
(`git show 6304122:Sources/Containerization/Image/Unpacker/OverlayFSUnpacker.swift`,
`promoteStagedLayer` at `:215`, staging at `:352`, promotion at `:377`, cleanup at
`:379`). The submodule revert deletes it, and this repository stops carrying it at
the pointer bump.

Staging was chosen over the smaller catch-and-discard because it closes the hole by
never creating the slot, which holds for a cancellation arriving mid-unpack as well
as for a refused layer. That reasoning is unchanged.

The fix is reimplemented in **`Sources/ContainerBridge/ImageRootfsUnpacker.swift`**,
in the parent repository, where the cache path is now chosen — so the submodule
gains no new fork-local divergence while this plan is converging it toward
upstream. The three mechanisms, by symbol:

1. **Promotion-on-success.** `rootfs(for:platform:)` unpacks into
   `rootfs.ext4.staging-<uuid>` beside the slot and calls `promote(at:to:)` only
   after the unpack returns without throwing. `promote` is `rename(2)` and not
   `FileManager.moveItem`: replacement is atomic, so no reader sees a half-built
   slot and a concurrent winner's completed work is never clobbered mid-read.
   Staging is a *sibling* of the slot because `rename` is only atomic within one
   filesystem.
2. **Staging-cleanup-on-failure.** The `catch` in `rootfs(for:platform:)` removes
   the staging file, so a later run finds no scratch beside a slot that was never
   promoted.
3. **Verification-before-promotion.** `verifyReadable(_:expecting:)` — this is the
   mechanism the layer version did not need.

**Why the third mechanism exists.** The original fix could un-defer `close()`
because it owned the formatter. `ImageRootfsUnpacker` does not: it calls upstream's
`EXT4Unpacker.unpack`, which owns the formatter and closes it in
`defer { try? filesystem.close() }`. A `close()` that fails is therefore swallowed,
`unpack` returns normally, and staging alone would promote an artefact whose
superblock never landed. So the staged file is checked before promotion — a size
floor, then opened with `EXT4.EXT4Reader` — and a failure removes the staging file
and throws. That is a positive check on the artefact rather than trust in the call
that produced it, and it is the reachable equivalent of making `close()` the commit
point without adding fork-local divergence to the submodule.

`verifyReadable`'s own doc comment carries the measurements behind the size floor,
including why it is a floor and not an exact size, and what the two halves of the
check do and do not cover. It is the authority on that; this document does not
restate it.

## Upstream's `EXT4Unpacker` is still poisonable, and that is not fixed here

At the pinned submodule pointer, both public `unpack` overloads write straight to
the destination path they are handed and close the formatter in
`defer { try? filesystem.close() }`
(`git show 6304122:Sources/Containerization/Image/Unpacker/EXT4Unpacker.swift`,
`:55` and `:85`). Nothing in that type stages, verifies or promotes.

So any caller that treats "a file is at the destination" as a cache hit reproduces
this defect. `ImageRootfsUnpacker` is safe because it never hands `EXT4Unpacker`
the slot — only the staging path — and decides for itself whether to promote. A
different caller gets no such protection.

This is a real upstream defect, and it is worth reporting upstream. It is
deliberately **not** fixed here: fixing it would mean a fork-local change to the
submodule inside a plan whose purpose is converging that submodule *toward*
upstream.

## Mutation matrix

**Do not read the layer-granularity matrix that this section used to hold as though
it still ran.** The tests it measured are deleted. What follows replaces it.

**Provenance, because a matrix without one is not evidence.** These rows were not
all taken at the same commit or against the same suite. The suite grew as the
review rounds added tests, so a row's failing set is a statement about the suite it
ran against:

| Measured at | Date | Suite size | Rows taken there |
|---|---|---|---|
| `7c2a40a` | 2026-08-21 | 5 tests | A, B, C, D, E, F |
| `69ad815` | 2026-08-21 | 7 tests | A–F re-run, plus H, I, J, K, L |
| `8ae55a9` | 2026-08-21 | 8 tests | all twelve; F changed from surviving to killed; **M survived** |
| `f1a7f28` | 2026-08-21 | 9 tests | C, F and M re-run after T9 was added to kill M |
| `63b30ce` | 2026-08-22 | **12 tests** | A, B, C, F, M — the five re-derived rows |

**Every SHA in that table is a commit the rows were MEASURED at. None of them is the
commit that carries this document**, which is necessarily a later one — a document
cannot name the commit that adds it. Why the rows nonetheless hold for that later
commit is argued below, from the diff, rather than assumed.

Every mutation, in every round, was applied to a restored copy of the source and
**rebuilt** — `--skip-build` was never used for a mutation — then reverted, with
`git status --porcelain` checked clean afterwards.

Mutations A–J were proposed by the implementer and independently reproduced by a
reviewer. **K, L and M were the reviewer's own**, not reproductions of anything,
and M is the one that mattered: it **survived** when first run, which is why T9
exists at all.

This table is the record. It is deliberately not a pointer at one, because the
review notes it was assembled from are not in any repository — which is the failure
the `!EVIDENCE-*.md` rule was written about.

### Re-derived at `63b30ce`, against all twelve tests

MEASURED on 2026-08-22 at `63b30ce`, against the twelve-test suite. Each mutation
was applied to a restored copy of `ImageRootfsUnpacker.swift`, **rebuilt** (never
`--skip-build`), and run with
`swift test --disable-swift-testing --filter ImageRootfsUnpackerTests`; the file was
then restored byte-identical (`shasum -a 256`
`f09722d0b4ec4baf38150ae1854d8501f23488095eb4d55ff27f54a9d585489a`, checked before
and after every mutation) and the restored suite re-run green.

**Why those rows still hold for later commits.** Every commit that has touched
`ImageRootfsUnpackerTests.swift` since `63b30ce` changed only doc comments in it —
zero non-comment lines, checked mechanically against the diff — and none touched
`ImageRootfsUnpacker.swift` at all. Failing sets are a function of the production
source and the test bodies, and neither moved. Mutation A was re-run at `f95850e` to
check that rather than assume it, and gave the same two failures in the same one
test. Anyone extending this document should do the same rather than extend the
argument.

Assertions are named by what they say rather than by line offset, because a line
offset in this plan has decayed twice inside a single round.

| Mut | Failing tests | Which assertions fired |
|---|---|---|
| **A** `let staging = slot` | **T5 only — T1 PASSES** | both of T5's: "the unpack wrote the cache slot directly" and "the cache slot existed before the promotion" |
| **B** drop the `catch` cleanup | T2 | T2's one: "a refused unpack left … in the image's cache directory" |
| **C** delete the `verifyReadable` call | **T3 and T9** | all four: each test's "was expected to be refused" and each test's "was promoted into the cache slot" |
| **F** `size >= capacityInBytes` → `size >= 0` | T3 | **only T3's error-identity assertion** ("the refusal must be `verifyReadable`'s size assertion and not some earlier error"). T3's slot assertion PASSES |
| **M** delete only the `EXT4Reader` line | T9 | both of T9's |

**A's result is the one to read twice.** Mechanism 1 is pinned by T5 and by nothing
else. `testARefusedUnpackLeavesNoCacheSlot` passes with the unpack writing straight
into the slot, because the error-path cleanup then deletes it and hides that it was
ever the destination. A maintainer who trims T5 as an incidental test reintroduces
upstream's write-straight-to-the-destination behaviour with nothing going red.

**F's result confirms the bound stated below**, at HEAD rather than by transcription:
the artefact is still refused with the size guard weakened — the failure message
carries the fork guard's own `could not read 1024 bytes of superblock … at offset
1024` — so what T3 pins today is which check reports, not whether the slot is
protected.

### Transcribed rows

The remaining seven rows — **D, E, H, I, J, K, L** — are transcribed from the rounds
above and were **not** re-derived at `63b30ce`. Their failing sets are statements
about the 5-, 7- and 8-test suites they ran against.

Test abbreviations, all in `Tests/ArcaEngineTests/ImageRootfsUnpackerTests.swift`:

| | Test |
|---|---|
| **T1** | `testARefusedUnpackLeavesNoCacheSlot` |
| **T2** | `testARefusedUnpackLeavesNoScratchBesideTheSlot` |
| **T3** | `testAStagedFileWithNoReadableSuperblockIsNotPromoted` |
| **T4** | `testASecondCallReusesThePromotedSlot` |
| **T5** | `testTheUnpackWritesASiblingOfTheSlotAndNeverTheSlotItself` |
| **T6** | `testAnotherPlatformDoesNotGetThisPlatformsRootfs` |
| **T7** | `testTheReaperRemovesAnOrphanedStagingFileAndSparesThePromotedSlot` |
| **T8** | `testAnUnreadableDirectoryMakesTheReaperThrowRatherThanReportSuccess` |
| **T9** | `testACorrectlySizedStagedFileThatIsNotAnExt4IsNotPromoted` |

**Three tests in the file appear in no row and have no T-number**, and no mutation
here says anything about them:
`testTheRootfsMountCarriesReadOnlyOnBothTheUnpackAndTheCacheHit`,
`testTheRootfsMountDeclaresExt4OnBothTheUnpackAndTheCacheHit` and
`testAnUnpackSparesAConcurrentCallsStagingFile`. They arrived with later tasks. Nine
of the twelve tests are covered by this matrix; the mount-flag pair and the
concurrent-staging test are not.

The letters run A–F and H–M; there is no G in this table. G was an earlier
platform-mismatch mutation over the test file, superseded by K, which asks the same
question by changing only the request.

| Mut | Change | Failing set |
|---|---|---|
| **A** | `let staging = slot` — upstream's write-straight-to-destination shape | {T5} |
| **B** | drop `try? removeItem(at: staging)` from the `catch` | {T2} |
| **C** | delete the whole `try Self.verifyReadable(…)` call | **{T3, T9}** |
| **D** | disable the cache-hit branch | {T4} |
| **E** | stage under `NSTemporaryDirectory()` instead of beside the slot | {T5} |
| **F** | `size >= capacityInBytes` → `size >= 0` | {T3}, identity assertion only — see below |
| **H** | drop the platform component from `rootfsPath` | {T6} |
| **I** | make `reapOrphanedStagingFiles` a no-op | {T7, T8} |
| **J** | widen the reaper's match to `hasPrefix("rootfs.ext4")` | {T7}, sparing assertion |
| **K** | request `linuxAmd` against the arm64 fixture | every test in the suite |
| **L** | `errorHandler` skips instead of stopping and rethrowing | {T8} |
| **M** | delete only `_ = try EXT4.EXT4Reader(blockDevice:)`, keeping the size guard | {T9} |

**All twelve kill** — M only after T9 was written for it, which is recorded above
rather than smoothed over.

**What the shape of the failing sets shows.** A, B and C/F/M land on the three
mechanisms and nothing else: mechanism 1 on T5, mechanism 2 on T2, mechanism 3 on T3
and T9. D, H and I/J/L pin the properties that surround them — that the cache is a
cache at all, that the key includes the platform, and that the orphan reaper removes
what it should and spares what it should.

C kills **two** because it deletes the feature that contains both halves of
mechanism 3. That is the correct signal for such a mutation; a mutation that removed
two behaviours and killed only one test would be the problem. F and M kill
**disjoint singletons** — T3 and T9 — so the two halves stay independently pinned
and neither stands in for the other. The same holds for the reaper: I kills both of
T7 and T8, while J and L kill one each.

### The bounds on two of these rows

**Read F narrowly.** At the pinned submodule pointer it pins *which check reports*,
not *whether the artefact is refused*. Confirmed at `63b30ce` in the table above and
not merely transcribed: under F only T3's error-identity assertion fails, and T3's
slot assertion — that the artefact was not promoted — still passes, because the
fork's own guard in
`containerization/Sources/ContainerizationEXT4/EXT4+VolumeLabel.swift:63`
(`data.count == superBlockSize`) refuses the truncated artefact underneath. That
guard goes out with the volume-label work at the pointer bump, and then nothing is
underneath — after which weakening the check does not fail an assertion at all, it
traps. `verifyReadable`'s doc comment carries that measurement, including the
`exit 133` and why a SIGTRAP there is the mutation working rather than an
environment fault.

**K's failing set was measured before T9 existed**, against the suite as it then
stood, so "every test in the suite" means every test of that run and not
necessarily of the twelve today. It is a fixture-integrity mutation rather than a
mechanism one — it makes the request stop matching the fixture — and a mutation
that breaks every test proves nothing about any single mechanism. It is recorded
because it was run, not as a result about the fix.

### Hygiene

`rm -rf .build` before the baseline. Every mutation was applied to a restored copy
of the source and **rebuilt** — `--skip-build` was never used for a mutation, so no
probe ran against a stale object — then the file was restored and
`git status --porcelain` checked clean. The submodule pointer was verified
unchanged at `6304122` before and after. One instrumented run, used to confirm that
T9's error-identity assertion is exercised rather than merely present, was reverted
from a byte-identical backup.

An early attempt at mutation A that changed only the formatter's path and left the
promote call in was **discarded as unclean**: `rename` of a nonexistent staging file
then threw on every success path, failing 9 tests across 6 cases. That measures a
broken build, not the mechanism. Recorded because it happened, not as a result.

## The residue this fix does not cover

`verifyReadable`'s two checks divide the space three ways, and the third way is a
gap the fix accepts rather than closes:

- **size guard** → an artefact below the floor;
- **`EXT4.EXT4Reader`** → a correctly sized artefact that is not an ext4 at all;
- **neither** → a correctly sized, truncated-but-still-parseable filesystem.

The reader was measured to ACCEPT the real promoted artefact truncated to 1.56% of
its length, and to accept it with a megabyte of zeros written over its metadata
region; it refuses only an artefact with no valid superblock magic. So the property
the reader pins is "not an ext4 at all", not "not incomplete".

That residue is acceptable for a reason that is **not** that the case cannot arise
before promotion — it can, because `EXT4Unpacker` swallows a failing `close()`.
What makes it safe is the order `EXT4.Formatter.close()` writes in: the file is
extended to its final size early and the superblock is written last, so a partial
close leaves either a correctly sized file with no valid superblock, which the
reader refuses, or a short file, which the size guard refuses. Beyond that, the slot
is only ever created by a promotion, so reaching the third case in the *slot* would
need corruption after a successful promotion — disk-level corruption, a different
threat, and not one this type is positioned to detect. The full argument, with its
citations into `EXT4+Formatter.swift`, is in `verifyReadable`'s doc comment.
