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

MEASURED on 2026-08-22 against the tree of the commit that carries this document
(parent `1916f00`): exit 0,
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
it still ran.** The tests it measured are deleted. What follows is the matrix for
`ImageRootfsUnpacker`: twelve mutations, at per-assertion granularity, accumulated
over four review rounds. Every row was measured against a separately rebuilt
binary, and an independent reviewer reproduced the implementer's failing sets
rather than accepting them.

This table is the record. It is deliberately not a pointer at one, because the
review notes it was assembled from are not in any repository — which is the failure
the `!EVIDENCE-*.md` rule was written about.

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

**All twelve kill.** Each row was measured; none is inferred from another. M and
T9 arrived together and in that order: M survived the suite as it stood before T9
existed, and T9 was written to kill it.

**What the shape of the failing sets shows.** A, B and C/F/M land on the three
mechanisms above and nothing else: mechanism 1 on T5, mechanism 2 on T2, mechanism
3 on T3 and T9. D, H and I/J/L pin the properties that surround them — that the
cache is a cache at all, that the key includes the platform, and that the orphan
reaper removes what it should and spares what it should.

C kills **two** because it deletes the feature that contains both halves of
mechanism 3. That is the correct signal for such a mutation; a mutation that
removed two behaviours and killed only one test would be the problem. F and M kill
**disjoint singletons** — T3 and T9 — so the two halves stay independently pinned
and neither stands in for the other. The same holds for the reaper: I kills both of
T7 and T8, while J and L kill one each.

### The bounds on two of these rows

**Read F narrowly.** At the pinned submodule pointer it pins *which check reports*,
not *whether the artefact is refused*. Measured at the per-assertion level, only
T3's error-identity assertion fails under F; T3's slot assertion still passes,
because the fork's own guard in
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
