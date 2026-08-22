# Revert to Upstream's Single Composed Rootfs — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove arca's fork-local overlay-per-layer image handling so the engine attaches a constant number of block devices regardless of an image's layer count, letting Gas Can's 35-layer workspace image create and run.

**Architecture:** The host unpacks all image layers into one ext4 with upstream's `EXT4Unpacker`, cached per image digest and promoted into its cache slot only after the artefact is verified. That rootfs plus one per-container writable ext4 go to upstream's `create(_:image:rootfs:writableLayer:networking:configuration:)`, which builds the overlay in the guest. The guest's own overlay composition and the per-layer cache are deleted on both sides of the VM boundary.

**Tech Stack:** Swift 6 / SwiftPM, Apple Virtualization.framework, `apple/containerization` (forked as `Vas-Solutus/arca-containerization`), SQLite.swift, Rust (gascan consumer).

**Spec:** `Documentation/DESIGN-revert-to-upstream-rootfs.md` — read it before Task 1. This plan argues from it and does not repeat its evidence.

## Global Constraints

- **Do not raise the device ceiling** and **do not shrink the workspace image.** Either turns the suite green over a live product defect.
- **The submodule gains no new fork-local divergence.** Every fix in this plan that could live in `containerization/` lives in the parent instead.
- **Fail fast.** No fallback paths, no silenced errors, no `try?` on anything whose failure changes the result.
- **The ceiling is proven gone by the workspace image creating and running**, never by a unit test asserting a device count.
- **Never commit to `main`.** Every step below lands through a PR, merged with a merge commit and never squashed — the design cites SHAs.
- Repositories: submodule `containerization/` = `Vas-Solutus/arca-containerization`; parent = `Vas-Solutus/arca`; consumer = `gascan` at `/Users/kiener/code/gascan`.
- Baselines to beat, measured 2026-08-21: 1-layer alpine `2 passed (1 suite, 5.03s)`; 35-layer workspace `create failed ... no free indices are available for allocation`; unpack of 36 layers `duration_seconds=14.83`.
- **Never run `swift test --disable-swift-testing` in the submodule.** Measured 2026-08-21 in `containerization/`: it returns exit 0 and `Executed 0 tests, with 0 failures` — the suite is entirely swift-testing, so that flag proves compilation and nothing else. Plain `swift test` runs the real suite (608 tests in 84 suites as of `ecdcdd6`). Earlier drafts of this plan specified the flag at 13 sites; every "tests pass" it produced would have been green for the wrong reason. In the **parent** repo the flag does run XCTest — `EVIDENCE-layer-cache-poisoning.md` records 250 tests under it — but plain `swift test` is a superset there too, so use it in both.
- **On macOS, `swift build` compiles none of the guest.** Everything in `vminitd/Sources/VminitdCore/ArcaBoot.swift` and its callers sits inside `#if os(Linux)`. Guest changes are only compiled by `make vminitd`, which builds for `aarch64-swift-linux-musl`. A green `swift build` is not evidence about guest code.
- **Re-derive the per-file overlay/total counts; do not trust §4.1's table.** Those counts are keyword matches over changed lines, and a doc-comment block about overlay contributes lines that carry none of the keywords. Measured on `Kernel+Commandline.swift`: the table implies 6 overlay lines of 43, while the actual delta is 41+/3− and *all* of it is one `ARCA PATCH` block about `attachedOverlayLayers`. The table is a map of where to look, not a budget of what to change. Before restoring any file from `upstream/main`, read its full diff and decide hunk by hunk.

---

# PR 1 — submodule `arca-containerization`

Branch from the submodule's current HEAD `6304122`. Host and guest change together
here: a host-only change does not boot, and one PR is what makes landing it by
halves impossible.

Run after every task in this PR, from `containerization/`:

```bash
swift build 2>&1 | tail -20
swift test 2>&1 | tail -20
```

### Task 1: Remove the guest's overlay composition

**Files:**
- Modify: `vminitd/Sources/VminitdCore/ArcaBoot.swift`
- Modify: `vminitd/Sources/VminitdCore/AgentCommand.swift:129,174`
- Modify: `vminitd/Sources/VminitdCore/Server+GRPC.swift:659-670,672+`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `ArcaBoot.startServices(log:)` survives as the enum's only member. Nothing else in this repository may reference `ArcaBoot.mountScratch`, `ArcaBoot.prepareOverlayFS`, or `OverlayFSConfig`.

- [ ] **Step 1: Confirm the three call sites before editing**

```bash
cd containerization
rtk proxy grep -n "ArcaBoot\." vminitd/Sources/VminitdCore/AgentCommand.swift
```

Expected exactly three lines: `mountScratch` at `:129`, `startServices` at `:173`, `prepareOverlayFS` at `:174`.

- [ ] **Step 2: Delete the overlay half of `ArcaBoot.swift`**

Remove, and nothing else:
- the `OverlayFSConfig` actor and its doc comment (`:30-47`) — this is the guest-side actor, **not** the host-side `Containerization.OverlayFSConfig` struct that shares its name, as `:37-38` says;
- `static func mountScratch(log:)` (`:50-67`);
- `private static func labelledBlockDevices(log:)` (`:101` through its close);
- `static func prepareOverlayFS(log:attachedOverlayLayers:)` (`:167-312`).

Keep `enum ArcaBoot { ... }` with `startServices(log:)` (`:68-100`) inside it, and keep the file's imports and `#if`/`#endif`.

- [ ] **Step 3: Drop the two calls in `AgentCommand.swift`**

Delete line `:129` (`ArcaBoot.mountScratch(log: log)`) with the `// ARCA PATCH: scratch tmpfs for OverlayFS layer mount points. See ArcaBoot.` comment above it, and line `:174` (`await ArcaBoot.prepareOverlayFS(...)`). Keep `:173` (`ArcaBoot.startServices(log: log)`) and its comment.

Also delete the `attachedOverlayLayers` property and its doc comment at `:54` and every other reference to it in this file; Task 2 removes the kernel argument that supplies it.

- [ ] **Step 4: Drop both `ARCA PATCH` branches in `Server+GRPC.swift`**

Delete the branch at `:659-670` that returns early for `request.source.hasPrefix("/dev/vd")`, and the branch beginning `:672` that mounts the overlay at the rootfs path, through its `return .init()`. Both exist only because the guest composed the rootfs. Upstream's handler mounts what it is told to once the host supplies a single rootfs.

**Leave `:1922` alone** — that `ARCA PATCH` honours `ARCA_GROUP_ADD` and is unrelated.

- [ ] **Step 5: Verify nothing still references the removed symbols**

```bash
rtk proxy grep -rn "prepareOverlayFS\|mountScratch\|OverlayFSConfig\|attachedOverlayLayers" vminitd/Sources > /tmp/t1.txt 2>&1; cat /tmp/t1.txt
```

Expected: empty. (Read the file rather than trusting the terminal — the shell hook truncates.)

- [ ] **Step 6: Build**

Run: `swift build 2>&1 | tail -20`
Expected: the host still references `attachedOverlayLayers`, so this may fail only in `Sources/Containerization`. Guest targets must compile. Task 2 clears the rest.

- [ ] **Step 7: Commit**

```bash
git add vminitd/Sources/VminitdCore
git commit -m "revert: the guest no longer composes the rootfs from per-layer devices"
```

### Task 2: Remove the `attachedOverlayLayers` host/guest contract

**Files:**
- Modify: `Sources/Containerization/VMConfiguration.swift:91,100,108`
- Modify: `Sources/Containerization/LinuxContainer.swift:117,664`
- Modify: `Sources/Containerization/VZVirtualMachineInstance.swift:90,425-442`
- Modify: `Sources/Containerization/VZVirtualMachineManager.swift`
- Modify: `Sources/Containerization/CHVirtualMachineInstance.swift`
- Modify: `Sources/Containerization/CHVirtualMachineManager.swift:109`
- Modify: `Sources/Containerization/Kernel+Commandline.swift`
- Modify: `Tests/ContainerizationTests/KernelTests.swift`
- Delete: `Tests/ContainerizationTests/VZAttachedLayerReportTests.swift`

**Interfaces:**
- Consumes: Task 1's guarantee that no guest code reads the count.
- Produces: `Kernel.linuxCommandline(initialFilesystem:)` regains its upstream signature — one parameter, no `attachedOverlayLayers`. Task 3 relies on that signature.

- [ ] **Step 1: List every site**

```bash
rtk proxy grep -rn "attachedOverlayLayers" Sources Tests > /tmp/t2.txt 2>&1; cat /tmp/t2.txt
```

- [ ] **Step 2: Restore `Kernel+Commandline.swift` to upstream's signature**

The fork's version is `func linuxCommandline(initialFilesystem: Mount, attachedOverlayLayers: Int?) -> String` with an `if let attachedOverlayLayers { initArgs.append(ArcaLayerAttachment.initArgument(attached:)) }`. Restore upstream's:

```bash
git checkout upstream/main -- Sources/Containerization/Kernel+Commandline.swift
```

Then re-apply any hunk in that file whose `git diff upstream/main..HEAD` context is **not** about overlay. Check what you dropped:

```bash
rtk proxy git diff upstream/main..HEAD -- Sources/Containerization/Kernel+Commandline.swift > /tmp/kc.diff 2>&1
```

Read `/tmp/kc.diff` and re-apply the non-overlay hunks by hand. Do **not** assume there are none.

- [ ] **Step 3: Remove the property from the three config types**

Delete `public var attachedOverlayLayers: Int?` from `VMConfiguration.swift:91`, its initialiser parameter at `:100` and its assignment at `:108`; the same property from `LinuxContainer.Configuration` at `:117` and its use at `:664`; and from `VZVirtualMachineInstance.swift:90`. Delete the doc comment at `VZVirtualMachineInstance.swift:425-431` explaining why the field is read from `self`, and the argument at `:442`. Delete the one-line pass-throughs in `CHVirtualMachineManager.swift:109`, `VZVirtualMachineManager.swift`, and `CHVirtualMachineInstance.swift`.

- [ ] **Step 4: Delete the report test and prune the kernel test**

```bash
git rm Tests/ContainerizationTests/VZAttachedLayerReportTests.swift
```

In `Tests/ContainerizationTests/KernelTests.swift`, delete only the cases asserting the layer-count init argument. Keep every other case.

- [ ] **Step 5: Build and test**

Run: `swift build 2>&1 | tail -20`
Expected: fails only where `OverlayFSUnpacker`, `ArcaLayerAttachment` or `ArcaBlockDeviceRole` are still referenced — Task 3 deletes those.

- [ ] **Step 6: Commit**

```bash
git add -A Sources Tests
git commit -m "revert: the layer count is no longer part of the host/guest contract"
```

### Task 3: Delete the overlay unpacker and its types

**Files:**
- Delete: `Sources/Containerization/Image/Unpacker/OverlayFSUnpacker.swift`
- Delete: `Sources/Containerization/ArcaLayerAttachment.swift`
- Delete: `Sources/Containerization/ArcaBlockDeviceRole.swift`
- Delete: `Tests/ContainerizationTests/ArcaLayerAttachmentTests.swift`
- Modify: `Sources/Containerization/ContainerManager.swift`

**Interfaces:**
- Consumes: Task 2's restored `linuxCommandline` signature.
- Produces: `ContainerManager` exposes exactly upstream's three `create` overloads. Task 7 in PR 2 calls the `rootfs:writableLayer:` one at `:287`.

- [ ] **Step 1: Confirm `LayerUnpackFailure` survives the deletion**

`LayerUnpackFailure` is used by **both** unpackers. After `OverlayFSUnpacker` goes, `EXT4Unpacker` is its only consumer, and it must stay.

```bash
rtk proxy grep -rn "LayerUnpackFailure" Sources > /tmp/t3.txt 2>&1; cat /tmp/t3.txt
```

Expected: hits in `LayerUnpackFailure.swift`, `EXT4Unpacker.swift:92,149,152`, and `OverlayFSUnpacker.swift:381,382`. Only the last two disappear.

- [ ] **Step 2: Delete the four files**

```bash
git rm Sources/Containerization/Image/Unpacker/OverlayFSUnpacker.swift \
       Sources/Containerization/ArcaLayerAttachment.swift \
       Sources/Containerization/ArcaBlockDeviceRole.swift \
       Tests/ContainerizationTests/ArcaLayerAttachmentTests.swift
```

- [ ] **Step 3: Remove the fork's fourth `create` overload**

Upstream has three `create` overloads at `:201`, `:235` and `:287`. The fork added a fourth. Identify it and remove only it:

```bash
rtk proxy git diff upstream/main..HEAD -- Sources/Containerization/ContainerManager.swift > /tmp/cm.diff 2>&1
```

Read `/tmp/cm.diff`. Remove the added overload and any overlay-only helper it calls. Preserve every non-overlay hunk — the file has 53 changed lines against upstream of which only 14 are overlay.

- [ ] **Step 4: Build and test**

Run: `swift build 2>&1 | tail -20` then `swift test 2>&1 | tail -20`
Expected: both succeed. `Sources/Containerization` no longer mentions overlay.

- [ ] **Step 5: Verify**

```bash
rtk proxy grep -rni "overlayfsunpacker\|arcalayerattachment\|arcablockdevicerole" Sources vminitd/Sources Tests > /tmp/t3b.txt 2>&1; cat /tmp/t3b.txt
```

Expected: empty.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "revert: delete the per-layer unpacker and the block-device role types"
```

### Task 4: Delete the volume-label machinery

Volume labels exist only so a guest could classify block devices by role. With
Task 1 and Task 3 done, nothing reads them.

**Files:**
- Delete: `Sources/ContainerizationEXT4/EXT4+VolumeLabel.swift`
- Delete: `Sources/ContainerizationEXT4/EXT4+FilesystemEnumerator.swift`
- Modify: `Sources/ContainerizationEXT4/EXT4+Formatter.swift:71-72,86,113-117,970-971`
- Modify: `Sources/ContainerizationEXT4/EXT4.swift:330,353-355`

**Interfaces:**
- Consumes: Tasks 1 and 3.
- Produces: `EXT4.Formatter.init` regains upstream's signature with no `volumeLabel:` parameter. PR 2's Task 11 deletes the parent's only two callers.

- [ ] **Step 1: Prove both files are unreachable**

```bash
rtk proxy grep -rn "volumeLabel\|VolumeLabel\|FilesystemEnumerator" Sources vminitd/Sources Tests > /tmp/t4.txt 2>&1; cat /tmp/t4.txt
```

Expected: only self-references inside the two files being deleted, plus the `EXT4+Formatter.swift` and `EXT4.swift` sites this task edits. **If anything else appears, stop** — the design's claim that these are overlay-only was measured on 2026-08-21 and something has changed.

- [ ] **Step 2: Delete both files**

```bash
git rm Sources/ContainerizationEXT4/EXT4+VolumeLabel.swift \
       Sources/ContainerizationEXT4/EXT4+FilesystemEnumerator.swift
```

- [ ] **Step 3: Remove the `volumeLabel:` parameter from the formatter**

In `EXT4+Formatter.swift`, delete the `volumeLabel: String? = nil` parameter (`:86`), its doc lines (`:71-72`), the `if let volumeLabel { ... probe.setVolumeLabel(...) }` block (`:113-117`), the `self.volumeLabel` stored property, and the `if let volumeLabel = self.volumeLabel { try superblock.setVolumeLabel(...) }` in `close()` (`:970-971`).

In `EXT4.swift`, delete `case volumeLabelTooLong(_ label: String, _ bytes: Int)` (`:330`) and its `description` arm (`:353-355`).

- [ ] **Step 4: Build and test**

Run: `swift build 2>&1 | tail -20` then `swift test 2>&1 | tail -20`
Expected: both pass.

- [ ] **Step 5: Confirm the fork's kept improvements are still present**

These are **not** overlay support and must survive:

```bash
rtk proxy grep -c "rejectBlobUnmatchedByDeclaration" Sources/ContainerizationEXT4/Formatter+Unpack.swift
rtk proxy grep -c "LayerUnpackFailure" Sources/Containerization/Image/Unpacker/EXT4Unpacker.swift
```

Expected: non-zero for both.

- [ ] **Step 6: Commit and open the PR**

```bash
git add -A
git commit -m "revert: delete the ext4 volume-label machinery the role classifier needed"
git push -u origin <branch>
gh pr create --title "revert: overlay-per-layer image handling, both sides of the VM boundary"
```

---

# PR 2 — parent `arca`

Branch from `main`. Run after every task, from the repository root:

```bash
swift build 2>&1 | tail -20
swift test 2>&1 | tail -20
```

### Task 5: The per-image rootfs unpacker, with a slot that cannot be poisoned

This is the one piece of genuinely new code in the plan. Read the design's
"The cache slot must not be poisonable" section before starting.

**Files:**
- Create: `Sources/ContainerBridge/ImageRootfsUnpacker.swift`
- Create: `Tests/ArcaEngineTests/ImageRootfsUnpackerTests.swift`
- Modify: `Package.swift:87-95`

**Interfaces:**
- Consumes: PR 1's submodule, via the pointer Task 12 bumps. Until then this compiles against `6304122` and Task 12 re-verifies.
- Produces:
  - `ImageRootfsUnpacker.init(cacheRoot: URL, capacityInBytes: UInt64, logger: Logger)`
  - `func rootfsPath(forImageDigest digest: String) -> URL`
  - `func rootfs(for image: Containerization.Image, platform: ContainerizationOCI.Platform) async throws -> Mount`

  Task 7 calls `rootfs(for:platform:)` and nothing else.

- [ ] **Step 1: Add the explicit module dependency**

`ContainerBridge` reaches `ContainerizationOCI` today through an implicit transitive import. The new file needs `ContainerizationError` too; make both explicit rather than relying on that. In `Package.swift`, inside the `ContainerBridge` target's `dependencies` array (`:87-95`), add:

```swift
                .product(name: "ContainerizationError", package: "containerization"),
                .product(name: "ContainerizationOCI", package: "containerization"),
```

The tests use `@testable import ContainerBridge` to reach the `willPromote` seam, and
`ArcaEngineTests` currently reaches `ContainerBridge` only transitively through
`ArcaEngine` (`Package.swift:156`, `dependencies: ["ArcaEngine", "SandboxEngineProto"]`).
`@testable` needs it directly, so add it:

```swift
            dependencies: ["ArcaEngine", "SandboxEngineProto", "ContainerBridge"]
```

- [ ] **Step 2: Write the failing tests**

Create `Tests/ArcaEngineTests/ImageRootfsUnpackerTests.swift`. Three tests, one per mechanism, driven by the existing `OCILayoutFixture` — use `OCILayoutFixture.Layer.Blob.bytesThatAreNotTheDeclaredArchive` to make an unpack throw, the same fixture mode `LayerCacheRoleTests` used.

```swift
import Foundation
import XCTest
import Containerization
import ContainerizationEXT4
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
}
```

Write the four `Self.fixture*` helpers and `modificationDate(of:)` against the existing `OCILayoutFixture` in `Tests/ArcaEngineTests/OCILayoutFixture.swift`. For `fixtureWhoseStagedFileIsTruncated`, truncate the staged file to zero bytes between unpack and promotion by injecting a test seam — add an internal `willPromote: ((URL) throws -> Void)?` hook on `ImageRootfsUnpacker`, defaulting to `nil`, called with the staging URL immediately before verification.

- [ ] **Step 3: Run the tests and watch them fail**

Run: `swift test --filter ImageRootfsUnpackerTests 2>&1 | tail -20`
Expected: FAIL — `cannot find 'ImageRootfsUnpacker' in scope`.

- [ ] **Step 4: Write the implementation**

Create `Sources/ContainerBridge/ImageRootfsUnpacker.swift`:

```swift
#if os(macOS)

import Foundation
import Logging
import Containerization
import ContainerizationEXT4
import ContainerizationError
import ContainerizationOCI
import SystemPackage

/// One composed ext4 rootfs per image, shared by every container built from it.
///
/// **The cache slot is created only by a promotion, and that is not a style choice.**
/// Upstream's `EXT4Unpacker` writes straight to the destination it is handed and closes
/// the formatter in `defer { try? filesystem.close() }`
/// (`containerization/Sources/Containerization/Image/Unpacker/EXT4Unpacker.swift:55`, `:85`).
/// A throw part-way through an unpack therefore leaves a valid, correctly sized, **empty**
/// filesystem at that destination. This type treats "a block is at the final path" as a
/// cache hit, so such a filesystem would be booted by every later container built from the
/// same image.
///
/// That is the defect `Documentation/EVIDENCE-layer-cache-poisoning.md` records at layer
/// granularity, fixed at `4134b54`. The fix lived in `OverlayFSUnpacker`, which the revert
/// to upstream's single composed rootfs deletes, so it is reimplemented here — where the
/// cache path is now chosen — rather than in the submodule, which this work is bringing
/// back toward upstream.
public struct ImageRootfsUnpacker: Sendable {
    private let cacheRoot: URL
    private let capacityInBytes: UInt64
    private let logger: Logger

    /// Test seam: called with the staging URL immediately before verification.
    internal var willPromote: (@Sendable (URL) throws -> Void)?

    public init(cacheRoot: URL, capacityInBytes: UInt64, logger: Logger) {
        self.cacheRoot = cacheRoot
        self.capacityInBytes = capacityInBytes
        self.logger = logger
    }

    /// Where this image's composed rootfs lives, whether or not it exists yet.
    public func rootfsPath(forImageDigest digest: String) -> URL {
        cacheRoot
            .appendingPathComponent(digest.replacingOccurrences(of: ":", with: "-"))
            .appendingPathComponent("rootfs.ext4")
    }

    /// The image's composed rootfs, unpacked if it is not already cached.
    public func rootfs(
        for image: Containerization.Image,
        platform: ContainerizationOCI.Platform
    ) async throws -> Mount {
        let slot = rootfsPath(forImageDigest: image.digest)
        if FileManager.default.fileExists(atPath: slot.path) {
            logger.debug("image rootfs cache hit", metadata: ["path": "\(slot.path)"])
            return Self.blockMount(at: slot)
        }

        let directory = slot.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let staging = directory.appendingPathComponent("rootfs.ext4.staging-\(UUID().uuidString)")

        do {
            let unpacker = EXT4Unpacker(capacityInBytes: capacityInBytes)
            _ = try await unpacker.unpack(image, for: platform, at: staging, progress: nil)
            if let willPromote { try willPromote(staging) }
            try Self.verifyReadable(staging)
        } catch {
            // The staging file must not outlive the failure: a later run would otherwise
            // find scratch beside a slot that was never promoted.
            try? FileManager.default.removeItem(at: staging)
            throw error
        }

        try Self.promote(at: staging, to: slot)
        return Self.blockMount(at: slot)
    }

    /// Refuses an artefact whose superblock did not land.
    ///
    /// `EXT4Unpacker` swallows a failing `close()`, so `unpack` returning is not proof the
    /// filesystem is complete. Opening it is.
    private static func verifyReadable(_ path: URL) throws {
        _ = try EXT4.Reader(blockPath: FilePath(path.path))
    }

    /// `rename(2)` rather than `FileManager.moveItem`, and the difference is not stylistic:
    /// replacement is atomic, so no reader ever sees a half-built slot, and a concurrent
    /// winner's completed work is never clobbered mid-read. `staging` is a sibling of `path`
    /// because `rename` is only atomic within one filesystem.
    private static func promote(at staging: URL, to path: URL) throws {
        guard rename(staging.path, path.path) == 0 else {
            let code = errno
            try? FileManager.default.removeItem(at: staging)
            throw ContainerizationError(
                .internalError,
                message: "failed to promote the unpacked rootfs at \(staging.path) onto "
                    + "\(path.path): errno \(code)"
            )
        }
    }

    private static func blockMount(at path: URL) -> Mount {
        .block(format: "ext4", source: path.path, destination: "/", options: [])
    }
}

#endif
```

Check `EXT4.Reader`'s real initialiser label before running — if it is not `blockPath:`, use whatever `Tests/ArcaEngineTests/LayerCacheRoleTests.swift:958` used before deletion.

- [ ] **Step 5: Run the tests and watch them pass**

Run: `swift test --filter ImageRootfsUnpackerTests 2>&1 | tail -20`
Expected: 4 tests, 0 failures.

- [ ] **Step 6: Commit**

```bash
git add Package.swift Sources/ContainerBridge/ImageRootfsUnpacker.swift Tests/ArcaEngineTests/ImageRootfsUnpackerTests.swift
git commit -m "feat: one composed rootfs per image, promoted into its slot only when verified"
```

### Task 6: Mutation-test the three mechanisms

An untested invariant and no invariant are worth the same. This task produces
the evidence, and its output feeds Task 11's rewrite of
`EVIDENCE-layer-cache-poisoning.md`.

**Files:**
- Modify (temporarily, reverted at the end): `Sources/ContainerBridge/ImageRootfsUnpacker.swift`
- Create: `/tmp/mutation-matrix.md` — working notes for Task 11

**Interfaces:**
- Consumes: Task 5's three mechanisms and four tests.
- Produces: a mutation matrix with disjoint failing sets, and a `shasum` restoration check.

- [ ] **Step 1: Record the pre-mutation checksum**

```bash
shasum -a 256 Sources/ContainerBridge/ImageRootfsUnpacker.swift | tee /tmp/rootfs-unpacker.sha
```

- [ ] **Step 2: Mutation A — remove the promotion**

Change the unpack destination from `staging` to `slot` and delete the `try Self.promote(at:to:)` call. This is the pre-fix in-place shape.

Run: `swift test --filter ArcaEngineTests 2>&1 | tail -20`
Expected: `testARefusedUnpackLeavesNoCacheSlot` fails. Record the exact failing set and the run's totals.

**A mutation that fails on every path measures a broken build, not the mechanism.** If `promote` now throws on success paths too, the mutation is unclean — discard it, note that it happened, and construct a cleaner one.

- [ ] **Step 3: Restore and verify**

```bash
git checkout Sources/ContainerBridge/ImageRootfsUnpacker.swift
shasum -a 256 -c /tmp/rootfs-unpacker.sha
```
Expected: `OK`.

- [ ] **Step 4: Mutation B — remove the staging cleanup**

Delete `try? FileManager.default.removeItem(at: staging)` from the `catch`.

Run the same filter. Expected: `testARefusedUnpackLeavesNoScratchBesideTheSlot` fails and the other three pass. Restore and re-check the checksum.

- [ ] **Step 5: Mutation C — remove the verification**

Delete the `try Self.verifyReadable(staging)` call.

Run the same filter. Expected: `testAStagedFileWithNoReadableSuperblockIsNotPromoted` fails and the other three pass. Restore and re-check the checksum.

- [ ] **Step 6: Confirm the failing sets are disjoint**

Write `/tmp/mutation-matrix.md` with one row per mutation: the change, the failing set, and the run totals. The three failing sets must be pairwise disjoint. **If two mutations fail the same test, the mechanisms are not separately pinned** — add a test that distinguishes them and redo the matrix.

- [ ] **Step 7: Commit (tests only; the source is unchanged)**

```bash
git status --short
```
Expected: clean. Nothing to commit — this task produces evidence, not code.

### Task 7: Rewrite the create path onto upstream's API

**Files:**
- Modify: `Sources/ContainerBridge/ContainerManager.swift:80,212,220,305-309,1231-1353,1487-1495`

**Interfaces:**
- Consumes: `ImageRootfsUnpacker.rootfs(for:platform:)` from Task 5.
- Produces: `createNativeContainer` no longer references `OverlayFSConfig`, `OverlayFSMounter`, `OverlayFSUnpacker` or `attachedOverlayLayers`. Task 9 deletes those types.

- [ ] **Step 1: Replace the unpacker field**

At `:80`, replace `nonisolated public let layerCachePath: URL` with `nonisolated public let imageRootfsCachePath: URL`, and thread the rename through the initialiser at `:212` and `:220`. At `:83`, replace `private var overlayUnpacker: OverlayFSUnpacker?` with `private var rootfsUnpacker: ImageRootfsUnpacker?`. At `:305-309`, construct it:

```swift
        // One composed rootfs per image, shared by every container from it.
        rootfsUnpacker = ImageRootfsUnpacker(
            cacheRoot: imageRootfsCachePath,
            capacityInBytes: Self.imageRootfsCapacityInBytes,
            logger: logger
        )
```

Add near the type's other constants:

```swift
    /// Capacity of a composed image rootfs. Sparse, so this costs nothing until written;
    /// it only has to exceed the largest image's unpacked size. The approved workspace
    /// image is 2.9 GB compressed across 35 layers.
    private static let imageRootfsCapacityInBytes: UInt64 = 32 * 1024 * 1024 * 1024
```

- [ ] **Step 2: Replace `:1231-1353` wholesale**

Delete everything from `// Unpack image layers with OverlayFS (if not already provided)` through the `let managerCreateStart = Date()` line's preceding block, and replace with:

```swift
        // One composed rootfs for the image, and one writable layer for this container.
        // Upstream's LinuxContainer mounts the rootfs as the overlay's lower layer and the
        // writable mount as its upper, so the device count is the same for a 1-layer image
        // and a 35-layer one. That constancy is the whole point of this path: the engine
        // allocates block device tags from a 26-letter alphabet, and one device per layer
        // exhausted it at roughly 24 layers.
        guard let rootfsUnpacker else {
            throw ContainerManagerError.notInitialized
        }

        let unpackStart = Date()
        let rootfs = try await rootfsUnpacker.rootfs(for: config.image, platform: imagePlatform)
        logger.info("image rootfs ready", metadata: [
            "docker_id": "\(dockerID)",
            "source": "\(rootfs.source)",
            "duration_seconds": "\(String(format: "%.2f", Date().timeIntervalSince(unpackStart)))"
        ])

        // 64 GB thin-provisioned, matching what the OverlayFS writable layer used.
        let writablePath = containerPath.appendingPathComponent("writable.ext4")
        let writableLayer = try Self.writableLayer(at: writablePath, sizeInBytes: 64 * 1024 * 1024 * 1024)

        let managerCreateStart = Date()
        let container = try await manager.create(
            dockerID,
            image: config.image,
            rootfs: rootfs,
            writableLayer: writableLayer
        ) { @Sendable containerConfig in
```

Then add the helper beside the others:

```swift
    /// The container's writable upper layer. Created once; reused if the container is
    /// recreated from state, which is why an existing file is a hit and not an error.
    private static func writableLayer(at path: URL, sizeInBytes: UInt64) throws -> Mount {
        if !FileManager.default.fileExists(atPath: path.path) {
            let filesystem = try EXT4.Formatter(FilePath(path.path), minDiskSize: sizeInBytes)
            try filesystem.close()
        }
        return .block(format: "ext4", source: path.path, destination: "/", options: [])
    }
```

- [ ] **Step 3: Remove the overlay mount plumbing from the closure**

Delete `containerConfig.attachedOverlayLayers = attachedOverlayLayers` and, at `:1487-1495`, the `containerConfig.mounts.append(contentsOf: additionalMounts)` block with its log. The writable layer is now a `create` parameter, not a mount.

**Keep** the `if !config.mounts.isEmpty { containerConfig.mounts.append(contentsOf: config.mounts) }` that follows — those are the user's volume mounts.

- [ ] **Step 4: Build**

Run: `swift build 2>&1 | tail -20`
Expected: fails only on `config.overlayConfig`, which Task 8 removes.

- [ ] **Step 5: Commit**

```bash
git add Sources/ContainerBridge/ContainerManager.swift
git commit -m "feat: create from one composed rootfs and one writable layer"
```

### Task 8: Remove `CreateConfig.overlayConfig`

**Files:**
- Modify: `Sources/ContainerBridge/ContainerManager.swift:137,1954,2221,2355`

**Interfaces:**
- Consumes: Task 7.
- Produces: the create config type no longer carries an overlay field.

- [ ] **Step 1: Delete the field and its four call sites**

Remove `:137` (`let overlayConfig: Containerization.OverlayFSConfig?`) and the `overlayConfig:` arguments at `:1954`, `:2221` and `:2355`. The last carries `// TODO: Wire up from OverlayFSUnpacker (Phase 1)` — the TODO goes with it.

- [ ] **Step 2: Build and test**

Run: `swift build 2>&1 | tail -20` then `swift test 2>&1 | tail -20`
Expected: build passes. Tests fail only in the three overlay test files Task 11 deletes.

- [ ] **Step 3: Commit**

```bash
git add Sources/ContainerBridge/ContainerManager.swift
git commit -m "refactor: the create config no longer carries an overlay configuration"
```

### Task 9: Delete `Sources/ContainerBridge/OverlayFS/`

**Files:**
- Delete: `Sources/ContainerBridge/OverlayFS/` (1023 lines: `OverlayFSMounter.swift` 227, `OverlayFSClient.swift` 197, `OverlayFSUnpacker.swift` 74, `Generated/overlayfs.grpc.swift` 287, `Generated/overlayfs.pb.swift` 238)
- Modify: `Sources/ContainerBridge/grpc-swift-config.json` if it names the overlayfs proto
- Delete: the overlayfs `.proto` under `proto/`, if one exists

- [ ] **Step 1: Confirm nothing outside the directory still reaches in**

```bash
rtk proxy grep -rn "OverlayFSMounter\|OverlayFSClient\|OverlayFSUnpacker" Sources ArcaApp Tests > /tmp/t9.txt 2>&1; cat /tmp/t9.txt
```

Expected: only hits inside `Sources/ContainerBridge/OverlayFS/` and inside the three test files Task 11 deletes. `OverlayFSClient` had no external references at all when measured on 2026-08-21.

- [ ] **Step 2: Delete**

```bash
git rm -r Sources/ContainerBridge/OverlayFS
rtk proxy find proto -iname "*overlay*" > /tmp/t9b.txt 2>&1; cat /tmp/t9b.txt
```

Delete any proto that turns up, and remove its entry from `grpc-swift-config.json`.

- [ ] **Step 3: Build**

Run: `swift build 2>&1 | tail -20`
Expected: passes.

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "revert: delete the host-side OverlayFS mounter, client and generated protobuf"
```

### Task 10: Drop the layer cache and reclaim its disk

**Files:**
- Modify: `Sources/ContainerBridge/StateStore.swift:22,366,376-377,1423-1540`
- Modify: `Sources/ArcaEngine/EnginePaths.swift:49,90`
- Modify: `Sources/ArcaEngine/EngineManagers.swift:11,66`
- Modify: `Sources/ArcaDaemon/ArcaDaemon.swift:199`
- Create: `Tests/ArcaEngineTests/LayerCacheReclaimTests.swift`

**Interfaces:**
- Consumes: Task 9.
- Produces: `EnginePaths.imageRootfs` replaces `EnginePaths.layerCache`.

- [ ] **Step 1: Write the failing test for the reclaim**

The reclaim deletes a directory, so it must be scoped and must refuse a path that is not what it expects.

```swift
import Foundation
import XCTest
@testable import ArcaEngine

final class LayerCacheReclaimTests: XCTestCase {

    /// The orphaned per-layer cache is removed once, and only from inside the state root.
    func testReclaimRemovesTheLayersDirectoryUnderTheStateRoot() throws {
        let stateRoot = try Self.temporaryStateRoot()
        let layers = stateRoot.appendingPathComponent("layers")
        try FileManager.default.createDirectory(at: layers, withIntermediateDirectories: true)
        try Data().write(to: layers.appendingPathComponent("abc.ext4"))

        try LayerCacheReclaim.run(stateRoot: stateRoot)

        XCTAssertFalse(FileManager.default.fileExists(atPath: layers.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: stateRoot.path))
    }

    /// A `layers` path that is not a directory is a state root this code does not understand,
    /// and deleting anything under that assumption would be guessing.
    func testReclaimRefusesWhenLayersIsNotADirectory() throws {
        let stateRoot = try Self.temporaryStateRoot()
        let layers = stateRoot.appendingPathComponent("layers")
        try Data("not a directory".utf8).write(to: layers)

        XCTAssertThrowsError(try LayerCacheReclaim.run(stateRoot: stateRoot))
        XCTAssertTrue(FileManager.default.fileExists(atPath: layers.path))
    }

    /// Nothing to reclaim is success, not an error: this runs on every start.
    func testReclaimIsSilentWhenThereIsNothingToReclaim() throws {
        let stateRoot = try Self.temporaryStateRoot()
        XCTAssertNoThrow(try LayerCacheReclaim.run(stateRoot: stateRoot))
    }
}
```

Write `Self.temporaryStateRoot()` following the pattern in `Tests/ArcaEngineTests/TestSupport.swift`.

- [ ] **Step 2: Run and watch it fail**

Run: `swift test --filter LayerCacheReclaimTests 2>&1 | tail -20`
Expected: FAIL — `cannot find 'LayerCacheReclaim' in scope`.

- [ ] **Step 3: Implement the reclaim**

Create `Sources/ArcaEngine/LayerCacheReclaim.swift`:

```swift
import Foundation
import Logging

/// Removes the per-layer ext4 cache the single-composed-rootfs revert orphaned.
///
/// The files are a cache and regenerable by definition, and this is the only moment
/// anything will ever reclaim that disk — 213M on the development host when measured on
/// 2026-08-21. Scoped to `<state-root>/layers` and nowhere else, and it refuses rather
/// than guesses when that path is not a directory.
public enum LayerCacheReclaim {
    public static func run(stateRoot: URL, logger: Logger? = nil) throws {
        let layers = stateRoot.appendingPathComponent("layers")

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: layers.path, isDirectory: &isDirectory) else {
            return
        }
        guard isDirectory.boolValue else {
            throw ContainerizationError(
                .invalidState,
                message: "\(layers.path) exists and is not a directory; refusing to reclaim a "
                    + "state root this version does not understand"
            )
        }

        try FileManager.default.removeItem(at: layers)
        logger?.info("reclaimed the orphaned per-layer cache", metadata: ["path": "\(layers.path)"])
    }
}
```

`ContainerizationError(.invalidState, message:)` is the shape `ArcaEngine` already
throws — see `SandboxEngineService.swift:819`, `:1034` and `ExecSession.swift:314`.
Add `import ContainerizationError`; `ArcaEngine` already depends on it.

- [ ] **Step 4: Run and watch it pass**

Run: `swift test --filter LayerCacheReclaimTests 2>&1 | tail -20`
Expected: 3 tests, 0 failures.

- [ ] **Step 5: Call it once at start, and rename the path**

Call `LayerCacheReclaim.run(stateRoot:logger:)` where the engine opens its state root. In `EnginePaths.swift`, rename `layerCache` (`:49`) to `imageRootfs` and change `:90` from `stateRoot.appendingPathComponent("layers")` to `stateRoot.appendingPathComponent("image-rootfs")`. Update `EngineManagers.swift:66` and `ArcaDaemon.swift:199` to pass it as `imageRootfsCachePath:`. Fix the stale comment at `EngineManagers.swift:11`.

- [ ] **Step 6: Delete the `layer_cache` table and its API**

In `StateStore.swift`, delete the `layerCache` table (`:22`), its `create`/`createIndex` calls (`:366`, `:376-377`), the `layerDigest`/`layerRefCount` expressions, and every method at `:1423-1540`: `recordLayerCache`, `incrementLayerRefCount` (both the sync and `nonisolated` forms), `decrementLayerRefCount`, `loadLayerCache`, `loadAllCachedLayers`, `getUnreferencedLayers`, `deleteLayerCache`, `recordLayer`.

**Leave `volumeLabelsJSON` alone** (`:74`, `:307`, `:1185`, `:1220`) — those are Docker volume *labels* and share only a name.

- [ ] **Step 7: Build and test, then commit**

```bash
swift build 2>&1 | tail -20
swift test 2>&1 | tail -20
git add -A
git commit -m "revert: drop the per-layer cache table and reclaim its disk once"
```

### Task 11: Delete the overlay tests and correct the documentation

**Files:**
- Delete: `Tests/ArcaEngineTests/AttachedLayerCountTests.swift`, `Tests/ArcaEngineTests/LayerCacheRoleTests.swift`, `Tests/ArcaTests/OverlayFSTimingTests.swift`
- Modify: `Sources/ArcaEngine/SandboxEngineService.swift:594-608`
- Modify: `Documentation/EVIDENCE-layer-cache-poisoning.md`, `Documentation/ARCHITECTURE.md`, `Documentation/VMINIT_BUILD.md`

- [ ] **Step 1: Delete the three test files**

```bash
git rm Tests/ArcaEngineTests/AttachedLayerCountTests.swift \
       Tests/ArcaEngineTests/LayerCacheRoleTests.swift \
       Tests/ArcaTests/OverlayFSTimingTests.swift
```

`AttachedLayerCountTests` is the device-count assertion the design says must not stand in for the real experiment.

- [ ] **Step 2: Correct the `PrepareImage` comment**

`SandboxEngineService.swift:594-608` explains that `PrepareImage` cannot materialise a rootfs because the unpacker is per-container and upstream's per-image half is private. After this change that reason is false: `ImageRootfsUnpacker` is per-image and reachable. Rewrite the paragraph to say what is now true — that materialising is possible and is deliberately not done here — and delete the file:line citations that no longer resolve. **Do not leave it asserting the old reason.**

- [ ] **Step 3: Rewrite `EVIDENCE-layer-cache-poisoning.md`**

Update, do not supersede. The defect outlives the layer cache; only its home moves.

- Keep the defect and fix narrative.
- Change "the fix" section: the mechanism is now `ImageRootfsUnpacker`'s staging, verification and promotion, and there are **three** mechanisms rather than two.
- Replace the mutation matrix with Task 6's, from `/tmp/mutation-matrix.md`. Do not carry the old matrix forward as though it still ran.
- Replace the citation of `LayerCacheRoleTests.swift` with `ImageRootfsUnpackerTests.swift`.
- Record that upstream's `EXT4Unpacker` remains latently poisonable for other callers, and that this is a real upstream defect not fixed here.

- [ ] **Step 4: Update the other two tracked docs**

`ARCHITECTURE.md` has 4 overlay mentions and `VMINIT_BUILD.md` 1, measured 2026-08-21. Bring both in line with the single-composed-rootfs model. `ARCHITECTURE.md` is the one a reader is most likely to trust.

```bash
rtk proxy grep -in "overlay\|layer cache\|per-layer" Documentation/ARCHITECTURE.md Documentation/VMINIT_BUILD.md > /tmp/t11.txt 2>&1; cat /tmp/t11.txt
```

- [ ] **Step 5: Full suite, then commit**

```bash
swift test 2>&1 | tail -20
git add -A
git commit -m "docs: the poisoning fix moved, and three docs described an architecture that is gone"
```

### Task 12: Bump the submodule and verify the whole parent

- [ ] **Step 1: Point the submodule at PR 1's merged commit**

PR 1 must be merged first — a parent commit cannot reference an unmerged submodule commit.

```bash
cd containerization && git fetch origin && git checkout <merged-sha> && cd ..
git add containerization
```

- [ ] **Step 2: Clean build and full suite**

```bash
rm -rf .build
swift build 2>&1 | tail -20
swift test 2>&1 | tail -20
```
Expected: both pass with no overlay symbols anywhere.

- [ ] **Step 3: Prove the overlay surface is gone**

```bash
rtk proxy grep -rni "overlayfs\|attachedOverlayLayers\|ArcaBlockDeviceRole\|ArcaLayerAttachment" Sources ArcaApp Tests containerization/Sources containerization/vminitd/Sources > /tmp/t12.txt 2>&1; wc -l /tmp/t12.txt
```

Read `/tmp/t12.txt`. Expected: only `LinuxContainer`'s upstream `writableLayer` doc comments, which describe upstream's own overlayfs and are correct.

- [ ] **Step 4: Commit and open the PR**

```bash
git commit -m "build: point the submodule at the reverted containerization"
git push -u origin <branch>
gh pr create --title "revert: overlay-per-layer image handling, host side"
```

---

# Step 3 — the release

### Task 13: Build and publish vminit and the kernel

The guest changed, so gascan's e2e tier cannot see this work until a release exists:
that tier reads pin-verified artefacts installed by `gascan engine fetch` and does
**not** honour `GASCAN_ARCA_VMINIT_LAYOUT`.

- [ ] **Step 1: Iterate on the live tier first, before cutting anything**

The `gascan-arca` live tier does accept a locally-built vminit. Build it and run that tier before spending a release:

```bash
cd /Users/kiener/code/arca && ./scripts/build-vminit.sh release
```

```bash
cd /Users/kiener/code/gascan
GASCAN_ARCA_ENGINE_BIN=<engine> \
GASCAN_ARCA_KERNEL_PATH=<kernel> \
GASCAN_ARCA_VMINIT_LAYOUT=~/.arca/vminit \
  cargo test -p gascan-arca --test live -- --ignored 2>&1 | tail -20
```

Expected: passes. If it does not, the release is premature — fix and repeat.

- [ ] **Step 2: Cut the release**

Follow `Documentation/BUILDING_ASSETS.md` and `Documentation/VMINIT_BUILD.md`. Publish `vmlinux-arm64.gz` and `vminit-oci-arm64.tar.gz` under a new tag.

- [ ] **Step 3: Record the artefacts**

Create `Documentation/RELEASE-ARTIFACTS-<tag>.md` in the shape of the existing `RELEASE-ARTIFACTS-gascan-engine-m4.md`: asset names, byte counts, `sha256` of each asset, and the inner content digest. gascan's pin verifies these, so they must be exact.

```bash
shasum -a 256 vmlinux-arm64.gz vminit-oci-arm64.tar.gz
```

---

# PR 3 — `gascan`

### Task 14: Repin, and prove the ceiling is gone

**Files:**
- Modify: `/Users/kiener/code/gascan/engine/arca-pin.json`
- Modify: `/Users/kiener/code/gascan/docs/status/START-HERE.md`

- [ ] **Step 1: Repin**

Update `revision` to PR 2's merged parent SHA, and the `kernel` and `vminit` blocks — `asset`, `url`, `bytes`, `sha256`, and `content.bytes`/`content.sha256` — from Task 13's record. The schema is enforced by `engine/arca-pin-schema.jq`.

- [ ] **Step 2: Rebuild the engine from the pin**

```bash
cd /Users/kiener/code/gascan && ./scripts/build-arca-engine.sh 2>&1 | tail -20
```

Use its second output line as `GASCAN_ARCA_ENGINE_BIN` below. This is what makes the verification a statement about the pinned source rather than a local working tree.

- [ ] **Step 3: The baseline must stay green**

```bash
GASCAN_ARCA_ENGINE_BIN=<engine> GASCAN_ARCA_BASE_OCI_LAYOUT=/tmp/alpine-oci \
  cargo test -p gascan-e2e --test arca_engine -- --ignored 2>&1 | tail -20
```
Expected: `2 passed`. It measured `2 passed (1 suite, 5.03s)` on 2026-08-21.

- [ ] **Step 4: The experiment that found the defect**

```bash
GASCAN_ARCA_ENGINE_BIN=<engine> \
GASCAN_ARCA_BASE_OCI_LAYOUT=$PWD/.artifacts/e2e-image-probe/workspace-oci \
  cargo test -p gascan-e2e --test arca_engine -- --ignored 2>&1 | tail -40
```

Expected: `2 passed`. This command failed with `no free indices are available for allocation` on 2026-08-21.

If `.artifacts/e2e-image-probe/workspace-oci` is gone, recreate it — 35 layers, 2.9 GB, roughly 38 s:

```bash
skopeo copy --override-os linux --override-arch arm64 \
  docker://ghcr.io/liquescent-development/gascan/workspace@sha256:<digest> \
  oci:.artifacts/e2e-image-probe/workspace-oci:workspace
```

- [ ] **Step 5: Confirm the mechanism, not just the outcome**

The engine log previously printed `layer_devices_start=/dev/vdc layers=36 total_mounts=38 writable_device=/dev/vdb`. Capture the passing run's log and confirm the device count is now small and constant. Run step 4 against the 1-layer layout too and confirm **the same** device count for both.

- [ ] **Step 6: Measure what the design owes**

Time a create against a cold cache and a second against a warm one, and record both. The fork's per-layer unpack measured `duration_seconds=14.83` for 36 layers on 2026-08-21. The second create must be materially faster than the first, or the per-image cache is not being hit.

- [ ] **Step 7: Fix the ignore count in `START-HERE.md`**

It records arca as carrying 3 ignore attributes. It carries 2: `crates/gascan-e2e/tests/arca_engine.rs` has both and `arca_startup.rs` has none — its apparent match at `:10` is `` `#[ignore]`d `` inside a `//!` doc comment. Anchor the pattern in the doc:

```bash
rtk proxy grep -cE '^[[:space:]]*#\[ignore' crates/gascan-e2e/tests/arca_engine.rs crates/gascan-e2e/tests/arca_startup.rs
```

- [ ] **Step 8: Commit and open the PR**

```bash
git add engine/arca-pin.json docs/status/START-HERE.md
git commit -m "build: repin the engine onto the single composed rootfs"
git push -u origin <branch>
gh pr create --title "build: repin arca, and the 35-layer workspace image now creates"
```

Quote both runs from steps 3 and 4 verbatim in the PR body, and the two timings from step 6.

---

## What this plan does not do

- **It does not fix `PrepareImage`.** Task 11 only stops its comment asserting a reason that has become false. Making it materialise a rootfs is separate work with its own success criterion.
- **It does not close U5.** The harness provisions the image itself with `skopeo` and `arca-engine image load`; a shipped `.pkg` cannot. A green suite is evidence about the product on arca, not about U5.
- **It does not fix upstream's `EXT4Unpacker`.** Its deferred, error-swallowing `close()` stays latently poisonable for any other caller that caches on it. Task 11 records this.
