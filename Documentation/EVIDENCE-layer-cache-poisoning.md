# Evidence: a refused layer poisoned its own cache slot

The durable record for the measurements cited by
`Tests/ArcaEngineTests/LayerCacheRoleTests.swift`. Those tests are committed and
their docstrings previously pointed at a working file in another repository's
git-ignored scaffolding, which meant the evidence for this landing's most
important fix had no home in any shipped repository. This file is that home.

Found by the whole-landing review of milestone 4 Landing 1, after seven
task-scoped reviews had passed. Fixed at Arca `4134b54`, published in
`gascan-engine-m4` (`c545612b`).

## The defect

`EXT4.Formatter` writes the superblock **and the volume label** in `close()`
(`ContainerizationEXT4/EXT4+Formatter.swift:645`, `:970-972`). The formatter was
pointed at the final cache path and `close()` was deferred, so an unpack that
*threw* — which is exactly what Task 6 made a mistyped layer do — still left a
valid, correctly labelled, **empty** `layer.ext4` in the cache slot.

The next create's reuse predicate tests **the label alone**, so it hit.

Task 7's attached-layer count could not see it. The poisoned device is a real
ext4, carries `.overlayLayer`, is attached, *is* counted, and
`ArcaLayerAttachment.resolve` sees `attached == identified` and resolves
`.complete`. **The first create failed loudly; every create after it booted a
container on a rootfs built from none of that layer, with `Start` succeeding.**

## Failing-before evidence

The review's confidence came from reading. The tests were written and run
against **unfixed** code first.

Command: `swift test --disable-swift-testing --filter LayerCacheRoleTests`, at
Arca `cc8068c` / submodule `fb2b2f28241e8c4a8d3257e97d4bf2acebb360d6`, source
otherwise unmodified.

Result: `Executed 14 tests, with 5 failures (0 unexpected)`.

```
LayerCacheRoleTests.swift:653: error: -[...testAnUnpackThatRefusesALayerLeavesNoCacheEntryForTheNextCreateToReuse] : XCTAssertFalse failed - the refused layer left a REUSABLE cache slot. It is a valid ext4 carrying .overlayLayer over none of the image, so the guest classifies it, Task 7's count counts it, and the container boots on a rootfs missing that layer entirely.
LayerCacheRoleTests.swift:661: error: -[...testAnUnpackThatRefusesALayerLeavesNoCacheEntryForTheNextCreateToReuse] : XCTAssertFalse failed - a cache slot must not exist at all unless the unpack that would fill it succeeded: a slot whose existence is not conditional on success is one predicate change away from being reused again
LayerCacheRoleTests.swift:673: error: -[...testAnUnpackThatRefusesALayerLeavesNoCacheEntryForTheNextCreateToReuse] : XCTUnwrap failed: expected non-nil value of type "Error" - the retry SUCCEEDED over a layer the first attempt refused. The refusal was converted into a silent acceptance by the cache, which is the whole defect: it fails loudly once and then hands every later create an empty layer.
LayerCacheRoleTests.swift:738: error: -[...testARefusedLayerLeavesNoPartialSlotForItsSiblings] : XCTAssertFalse failed - the refused layer's own slot must not be reusable
LayerCacheRoleTests.swift:767: error: -[...testARefusedLayerLeavesNoPartialSlotForItsSiblings] : XCTAssertNotNil failed - the retry of a three-layer image SUCCEEDED over a layer the first attempt refused: two good layers and one empty one, labelled, counted, and resolved .complete by Task 7's guard. The container boots on a rootfs missing its top layer, and Start succeeds.
```

**The decisive lines are `:673` and `:767`: the RETRY SUCCEEDED**, in both the
one-layer and the three-layer shape. The defect was confirmed by measurement,
not by argument.

The tests are driven over a fixture mode
`OCILayoutFixture.Layer.Blob.bytesThatAreNotTheDeclaredArchive` — raw bytes
written under `MediaTypes.imageLayer`. The digest is still correct, so nothing
upstream of the unpack objects.

## The fix

Unpack into a sibling staging path and promote onto `layer.ext4` with
`rename(2)` only after `formatter.close()` returns. `close()` is deliberately no
longer deferred, because it is the commit point.

Chosen over the smaller catch-and-discard: staging closes the hole by never
creating the slot, which holds for a cancellation arriving mid-`unpackEntries`
as well as for Task 6's refusal.

## Mutation matrix

Full-suite runs, `swift test --disable-swift-testing --filter ArcaEngineTests`,
250 tests each.

| Mutation | Change | Failing set | Result |
| --- | --- | --- | --- |
| **A — the promotion** | formatter created at `layerPath` instead of `staging`, and `try Self.promoteStagedLayer(...)` removed (the pre-fix in-place shape; cleanup and the M5 wrap left intact) | `testAnUnpackThatRefusesALayerLeavesNoCacheEntryForTheNextCreateToReuse`, `testARefusedLayerLeavesNoPartialSlotForItsSiblings` | `250 tests, with 5 failures (0 unexpected)` — 2 tests |
| **B — the staging cleanup** | `try? FileManager.default.removeItem(at: staging)` removed from the failure path | `testARefusedUnpackLeavesNoScratchBesideTheCacheSlot` | `250 tests, with 1 failure (0 unexpected)` — 1 test |

**Disjoint**: `{test 1, test 2}` ∩ `{test 3}` = ∅. The fix has two separate
mechanisms — the slot's existence being conditional on success, and the staging
file not surviving the failure — and each has a test the other's mutation does
not touch.

Mutation B's output:

```
LayerCacheRoleTests.swift:842: error: -[...testARefusedUnpackLeavesNoScratchBesideTheCacheSlot] : XCTAssertEqual failed: ("["layer.ext4.staging-774D4308-9D0B-4809-A81E-CCDA317CC32E"]") is not equal to ("[]") - a refused unpack left [...] in the layer's cache directory.
```

A first attempt at mutation A — changing only the formatter's path and leaving
the promote call in — was **discarded as unclean**: `rename` of a nonexistent
staging file then threw on every success path, failing 9 tests across 6 cases.
That measures a broken build, not the mechanism. Recorded because it happened,
not as a result.

## What one assertion does NOT catch

In `testARefusedLayerLeavesNoPartialSlotForItsSiblings`, the assertion that a
sibling which finished before the cancellation arrived has a legitimately
complete entry **passes pre-fix as well**: with the fixture's one-entry layers
the siblings almost always finish. It pins the invariant; it is not what catches
the defect. What catches the defect pre-fix is that test's assertions 1 and 3,
`:738` and `:767` above.

## Restoration checks

`shasum -a 256` of
`Sources/Containerization/Image/Unpacker/OverlayFSUnpacker.swift`:

- fixed source, before any mutation: `1559e9c18a91482232d0a86068c1f73bbed64c59445b2f35d2d7c6eb78a51e84`
- after restoring from mutation A: identical
- after restoring from mutation B: identical

`git status --porcelain` in both repositories after each restore showed only the
intended modified files.
