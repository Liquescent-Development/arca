# Design: revert overlay-per-layer image handling to upstream's single composed rootfs

Date: 2026-08-21
Repositories: `arca` (this one), `Vas-Solutus/arca-containerization` (the
`containerization/` submodule), and `gascan` (the consumer that pins this engine).

Status: design. Nothing is implemented.

---

## 1. The defect

The engine attaches **one block device per OCI layer**. Block device tags are
allocated from a 26-letter alphabet — `Array("abcdefghijklmnopqrstuvwxyz")` at
`containerization/Sources/ContainerizationExtras/NetworkAddress+Allocator.swift:96`
— and exhausting it throws `AllocatorError.allocatorFull`, whose text is
`no free indices are available for allocation`
(`containerization/Sources/ContainerizationExtras/AddressAllocator.swift:49-50`).
`vda` is the initfs and `vdb` the writable overlay, leaving **24** tags for layers.

Any image with more than roughly 24 layers therefore cannot be created. This is a
product defect that reaches any user with a normal-sized image, not a defect in
any test fixture.

### Reproduced on 2026-08-21

Host `newcombe`. Engine binary
`.artifacts/arca-engine/arca/.build/arm64-apple-macosx/release/arca-engine`, built
2026-08-17 22:31 from arca `c545612` with submodule `6304122`. One variable changed
between the two runs, `GASCAN_ARCA_BASE_OCI_LAYOUT`; the command in both was
`cargo test -p gascan-e2e --test arca_engine -- --ignored`, run from the `gascan`
working copy at `af3358a`:

| Base layout | Result |
|---|---|
| `/tmp/alpine-oci`, 1 layer | `cargo test: 2 passed (1 suite, 5.03s)` |
| `.artifacts/e2e-image-probe/workspace-oci`, 35 layers | `create failed with exit code None: no free indices are available for allocation` |

The failing run's engine log carries the mechanism directly:

```
layer_devices_start=/dev/vdc layers=36 total_mounts=38 writable_device=/dev/vdb
```

36 is the image's 35 layers plus one the fixture adds. The same run logged
`duration_seconds=14.83 layers=36`, so every layer unpacked successfully and the
failure is at **attachment**, not at unpack.

### This is fork-local design, not a regression

`OverlayFSUnpacker`, `ArcaLayerAttachment` and `ArcaBlockDeviceRole` are all absent
from `upstream/main` in the submodule and present at fork HEAD `6304122`; each was
checked with `git cat-file -e upstream/main:<path>`, which fails for all three.
The 26-letter allocator is upstream's own. Upstream stays under it because
`LinuxContainer` takes a single `rootfs: Mount` plus an optional `writableLayer:
Mount?` (`containerization/Sources/Containerization/LinuxContainer.swift:40-47`
and `:304-315`), so its device count never scales with layer count.

The submodule is **70 commits ahead of `upstream/main` and 0 behind**
(`git rev-list --count upstream/main..HEAD` and the reverse). There is no upstream
backlog to reconcile first.

---

## 2. The decision, and what it rules out

The maintainer decided on 2026-08-21 to revert to upstream's model rather than
raise the ceiling or shrink the image, reasoning that reimplementing what upstream
does means fighting it indefinitely instead of receiving its improvements by merge.

Two things are therefore explicitly **not** in scope, and a change that did either
would be wrong even though it would turn the suite green:

- **Do not raise the device ceiling.** A larger alphabet moves the wall; it does
  not remove it, and it keeps the fork's divergence.
- **Do not shrink the workspace image.** That turns the suite green over a live
  product defect.

---

## 3. Target state

Upstream's model, adopted unchanged:

- The host unpacks **all image layers into one ext4** with upstream's
  `EXT4Unpacker`. That unpacker caches per *image*: it resolves a block path and
  refuses when one already exists
  (`containerization/Sources/Containerization/Image/Unpacker/EXT4Unpacker.swift:151-153`
  at `upstream/main`).
- The host attaches that rootfs plus one writable ext4, and hands both to
  `LinuxContainer(rootfs:writableLayer:)`.
- The **guest composes the overlay**, upstream's way: rootfs as the lower layer,
  the writable mount as the upper.

The device count becomes **constant and independent of layer count** — the initfs,
the rootfs, and the writable layer. A 35-layer image attaches the same number as a
1-layer image. The ceiling is removed rather than raised.

### Why the fork's optimisation does not pay here

The fork caches one ext4 per *layer*, which wins when many derived images share
base layers — a registry workload. Gas Can has one pinned workspace image, so
cross-image layer sharing is worth nothing, while upstream's per-image cache
delivers the same repeat-create benefit attaching a constant number of devices.

---

## 4. Scope, measured

All counts below were taken on 2026-08-21 against arca `6460a21` with submodule
`6304122`. Note that arca `6460a21` is 3 commits ahead of the `c545612` that built
the tested binary, and `git diff --stat c545612..HEAD -- Sources/ containerization`
is empty — so the source read here is the source that ran.

### 4.1 Submodule `arca-containerization`

**The overlay design is not confined to three files.** The fork is 61 files and
13,770 insertions ahead of `upstream/main`, most of it the unrelated `arca-services`
Go tree. Within it, overlay code touches **21 files**, and in fourteen of them it is
interleaved with fork changes that must survive. The table below is the triage that
scopes this work. `OVL` counts changed lines matching
`overlay|volumeLabel|lowerLayers|upperDir|workDir|layerCache|attachedOverlay|ArcaBlockDevice|ArcaLayerAttachment`;
`TOTAL` counts all changed lines. Both were produced on 2026-08-21 from
`git diff upstream/main..HEAD -- <file>` counting `^[+-][^+-]`.

**Delete outright** — every one of these is overlay-only:

| Path | OVL / TOTAL | Note |
|---|---|---|
| `Sources/Containerization/Image/Unpacker/OverlayFSUnpacker.swift` | 45 / 401 | |
| `Sources/Containerization/ArcaLayerAttachment.swift` | 8 / 87 | |
| `Sources/Containerization/ArcaBlockDeviceRole.swift` | 15 / 65 | |
| `Sources/ContainerizationEXT4/EXT4+VolumeLabel.swift` | 9 / 85 | see below |
| `Sources/ContainerizationEXT4/EXT4+FilesystemEnumerator.swift` | 0 / 83 | see below |
| `Tests/ContainerizationTests/ArcaLayerAttachmentTests.swift` | 12 / 77 | |
| `Tests/ContainerizationTests/VZAttachedLayerReportTests.swift` | 11 / 75 | |

Two of those are reached only through code this change removes, so they are dead on
arrival rather than deleted on judgement:

- `EXT4+VolumeLabel.swift` exists so that a block device can be classified by its
  ext4 volume label. Its only consumers are `ArcaBlockDeviceRole.swift:67`,
  `OverlayFSUnpacker.swift:283` and `:357` in this repository, and
  `OverlayFSMounter.swift:204` and `LayerCacheRoleTests.swift` in the parent — all
  deleted here. Note the name collision: `StateStore.swift`'s `volumeLabelsJSON`
  (`:74`, `:307`, `:1185`, `:1220`) is Docker volume *labels* and is unrelated.
- `EXT4+FilesystemEnumerator.swift` has **no consumer at all** in this repository,
  and its only consumer in the parent is `LayerCacheRoleTests.swift:957-959`, which
  §4.3 deletes.

**Edit per hunk** — overlay is threaded through changes that must stay, so these
cannot be reverted wholesale to `upstream/main`:

| Path | OVL / TOTAL | What the overlay part is |
|---|---|---|
| `vminitd/Sources/VminitdCore/ArcaBoot.swift` | 39 / 287 | see below |
| `vminitd/Sources/VminitdCore/AgentCommand.swift` | 16 / 38 | the boot calls |
| `Sources/Containerization/ContainerManager.swift` | 14 / 53 | a 4th `create` overload upstream does not have |
| `vminitd/Sources/VminitdCore/Server+GRPC.swift` | 11 / 92 | two mount-handler branches |
| `Sources/ContainerizationEXT4/EXT4+Formatter.swift` | 10 / 28 | the `volumeLabel:` parameter |
| `Tests/ContainerizationTests/KernelTests.swift` | 9 / 50 | the layer-count kernel argument |
| `Sources/Containerization/LinuxContainer.swift` | 8 / 84 | `attachedOverlayLayers` at `:117`, `:664` |
| `Sources/Containerization/VZVirtualMachineInstance.swift` | 7 / 37 | `attachedOverlayLayers` at `:90`, `:425-442` |
| `Sources/Containerization/Kernel+Commandline.swift` | 6 / 43 | `linuxCommandline(initialFilesystem:attachedOverlayLayers:)` |
| `Sources/Containerization/VMConfiguration.swift` | 6 / 9 | `attachedOverlayLayers` at `:91`, `:100`, `:108` |
| `Sources/ContainerizationEXT4/EXT4.swift` | 4 / 5 | `volumeLabelTooLong` |
| `Sources/Containerization/CHVirtualMachineInstance.swift` | 4 / 8 | |
| `Sources/Containerization/CHVirtualMachineManager.swift` | 1 / 3 | `:109` |
| `Sources/Containerization/VZVirtualMachineManager.swift` | 1 / 3 | |

**Leave alone.** These carry fork changes with no overlay content, and the three
with an `OVL` of 1 match only a comment that mentions the overlay unpacker in
passing: `ArchiveReader.swift` (0/91), `EXT4+Reader.swift` (0/16),
`Formatter+Unpack.swift` (0/25), `ImageConfig.swift` (0/19), `Mount.swift` (0/33),
`User.swift` (0/12), `ManagedProcess.swift` (0/107), `RuncProcess.swift` (0/2),
all four `vmexec/` files, `ArchiveReaderTests.swift` (0/200),
`EXT4Unpacker.swift` (1/31), `LayerUnpackFailure.swift` (1/42),
`TestFormatterUnpack.swift` (1/201), and the entire `vminitd/extensions/arca-services`
Go tree.

Edit, guest side:

- `vminitd/Sources/VminitdCore/ArcaBoot.swift` — remove `labelledBlockDevices`
  (from `:101`) and `prepareOverlayFS` (`:167`) through the end of the enum at
  `:312`; remove `mountScratch` (`:50`), whose own comment says the tmpfs it
  mounts is what the OverlayFS layer mount points live under; and remove the
  `OverlayFSConfig` actor (`:39-47`), which exists only to carry the composed
  mount options from boot to the gRPC handler.
- `vminitd/Sources/VminitdCore/AgentCommand.swift` — drop the `mountScratch` call
  at `:129` and the `prepareOverlayFS` call at `:174`.
- `vminitd/Sources/VminitdCore/Server+GRPC.swift` — drop **two** `ARCA PATCH`
  branches in the mount handler: `:659-670`, which skips `/dev/vd*` mounts on the
  grounds that boot already mounted them, and `:672` onward, which mounts the
  overlay at the container rootfs path instead of bind mounting. Both exist only
  because the guest composed the rootfs; upstream's handler does the right thing
  once the host supplies a single rootfs.

Two name collisions to avoid tripping over here. The `ARCA PATCH` at
`Server+GRPC.swift:1922` is unrelated — it honours `ARCA_GROUP_ADD` — and stays.
And the `OverlayFSConfig` actor being deleted from `ArcaBoot.swift` is a different
type from the host-side `OverlayFSConfig` struct in the `Containerization` module
that happens to share its name; `ArcaBoot.swift:37-38` says so explicitly.

**`ArcaBoot.swift` is not a whole-file deletion.** It holds three responsibilities,
all called from `AgentCommand.run()`. The third, `startServices` (`:68`, called at
`AgentCommand.swift:173`), launches `/sbin/arca-services` — arca's networking
extension. It must survive. Deleting the file wholesale would remove arca's
networking along with the overlay code.

### 4.2 What must be kept, though it sits among the deletions

Three fork-local changes live in the same directories and are **not** overlay
support. They are improvements to the single-composed-rootfs path this design
restores, and reverting them would be a regression:

- `Sources/Containerization/Image/Unpacker/LayerUnpackFailure.swift` (44 lines).
  Referenced by **both** unpackers; after `OverlayFSUnpacker` is deleted,
  `EXT4Unpacker` is its sole consumer (`EXT4Unpacker.swift:92`, `:149`, `:152`).
- The `EXT4Unpacker` patch, 31 changed lines against `upstream/main`. It carries
  each layer's digest and media type through so that a layer the unpacker refuses
  can be named. Its own comment states the reason: this unpacker stacks every
  layer into one filesystem, so the destination path alone cannot say which layer
  refused.
- The `Formatter+Unpack` patch, 26 added lines against `upstream/main`. It rejects
  a blob that is not the archive it was declared to be, which would otherwise
  build an empty filesystem and label it valid.

An earlier scope estimate counted these ~101 lines among the revert targets. They
are the opposite: they are the restored path's fail-fast and diagnostics.

### 4.3 Parent repository `arca`

Delete `Sources/ContainerBridge/OverlayFS/` in full — 1023 lines:

| Path | Lines |
|---|---|
| `OverlayFSMounter.swift` | 227 |
| `OverlayFSClient.swift` | 197 |
| `OverlayFSUnpacker.swift` | 74 |
| `Generated/overlayfs.grpc.swift` | 287 |
| `Generated/overlayfs.pb.swift` | 238 |

`OverlayFSClient` and its generated protobuf — 722 of those lines — are already
dead. All 14 references to `OverlayFSClient` across `Sources/`, `ArcaApp/` and
`Tests/` are inside `OverlayFSClient.swift` itself.

`OverlayFSUnpacker.swift` here is a distinct type from the submodule's: a thin
wrapper that delegates to `Containerization.OverlayFSUnpacker`, constructed at
`ContainerManager.swift:305`. It is live, and it goes with the rest.

Edit:

- `Sources/ContainerBridge/ContainerManager.swift` — 52 overlay references, of
  which **34 sit in the create path at `1231-1353`**. This is the substantive
  rewrite: build one rootfs and one writable mount, hand them to
  `LinuxContainer(rootfs:writableLayer:)`.
- `Sources/ContainerBridge/StateStore.swift` — drop the `layer_cache` table
  (declared `:22`, created `:366`) and the refcount and GC code that reads it,
  roughly 13 sites.
- `Sources/ArcaEngine/SandboxEngineService.swift:594-608` — this comment explains
  that `PrepareImage` cannot materialise a rootfs because the unpacker is
  per-container and upstream's per-image half is private. After the revert that
  reason is no longer true, and the comment must be corrected rather than left
  asserting something false.

Delete `Tests/ArcaEngineTests/AttachedLayerCountTests.swift`,
`Tests/ArcaEngineTests/LayerCacheRoleTests.swift` and
`Tests/ArcaTests/OverlayFSTimingTests.swift`.

Bump the `containerization` submodule pointer to the merged commit from §4.1.

### 4.4 Orphaned state

The revert leaves two things behind that nothing will read again: the `layer_cache`
table, and the per-layer ext4 files under the layer cache path — `~/.arca/layers`
under `ArcaDaemon` and `<state-root>/layers` under `arca-engine`. That directory
measured 213M on the development host on 2026-08-21 (`du -sh ~/.arca/layers`).

The decision is to drop the table and reclaim the files, once, on first start after
the revert. The files are a cache and are regenerable by definition, and this is
the only moment anything will ever reclaim that disk. The reclaim must be scoped
strictly to the engine's own layers path and must fail fast if that path is not
what it expects, rather than recursing anywhere broader.

### 4.5 Documentation superseded

`Documentation/.gitignore` ignores `*.md` by default and allowlists the
public-facing documents by name or prefix, so most of what sits in that directory
on any given machine is untracked local planning. Six files there describe the
design being removed, and **only one of them is in the repository**:

- Tracked, and must be updated by the same change that removes the code:
  `EVIDENCE-layer-cache-poisoning.md` (3 matches), `ARCHITECTURE.md` (4) and
  `VMINIT_BUILD.md` (1). `ARCHITECTURE.md` is the one a reader is most likely to
  trust, so it is the one that most matters.
- Untracked local files, and therefore not this change's business:
  `OVERLAYFS_CLEANUP_PLAN.md`, `OVERLAYFS_DEFINITIVE_PLAN.md`,
  `OVERLAYFS_IMPLEMENTATION_GUIDE.md`, `OVERLAYFS_SIMPLIFIED_APPROACH.md` and
  `OVERLAYFS_IMPLEMENTATION_VIOLATIONS.md`.

`EVIDENCE-layer-cache-poisoning.md` needs care rather than deletion. The
`!EVIDENCE-*.md` rule exists because committed test docstrings cite these files,
and the gitignore's own comment records what happens otherwise: evidence with no
durable home. Removing the layer cache does not make the poisoning that was
observed untrue, so mark the document superseded and say what replaced the
mechanism — and check for test docstrings citing it before touching it.

This design document is tracked under a new `!DESIGN-*.md` allowlist entry, for
the same reason: `gascan`'s documentation will cite it, and a citation pointing
into another repository's ignored files is the failure that rule was written
about.

---

## 5. Sequencing

The submodule and the parent are separate repositories, and a parent commit cannot
point at an unmerged submodule commit, so the order is forced:

1. **Submodule PR** — §4.1. Host and guest change together here. A host-only change
   does not boot, and keeping both sides in one PR is what makes that impossible to
   land by halves.
2. **Parent `arca` PR** — §4.3, including the submodule pointer bump.
3. **Release** — build vminit and the kernel, publish under a new tag. See
   `Documentation/RELEASE-ARTIFACTS-gascan-engine-m4.md` for what the current tag
   published, and `Documentation/VMINIT_BUILD.md` for the build.
4. **`gascan` PR** — repin `engine/arca-pin.json`: revision, and the vminit and
   kernel asset bytes, sha256 and inner content digests.

### Why a release is required rather than a local override

`gascan`'s e2e tier reads the artifacts that `gascan engine fetch` installed into
`~/Library/Application Support/dev.gascan/engine/`, verified against
`engine/arca-pin.json`. It does **not** honour `GASCAN_ARCA_VMINIT_LAYOUT` or
`GASCAN_ARCA_KERNEL_PATH`; only the `gascan-arca` live tier does, through
`EngineInputs::from_environment`. Because the guest side changes here, the
definitive verification cannot run against a locally-built vminit without changing
what the harness trusts. Cutting the release means the verifying run exercises the
same path a user gets.

Iteration before that point belongs on the `gascan-arca` live tier, which does
accept a locally-built vminit through those two variables.

---

## 6. Verification

**The ceiling is proven gone by the experiment that found it — the workspace image
creating and running — and not by a unit test asserting a device count.** The test
that asserts an attached-layer count is itself deleted by this change (§4.3).

Definitive, run from the `gascan` working copy after step 4:

```
GASCAN_ARCA_BASE_OCI_LAYOUT=<workspace layout> \
  cargo test -p gascan-e2e --test arca_engine -- --ignored
```

This command fails today with the allocator error in §1. It must reach `2 passed`.
The layout is 35 layers and 2.9 GB; if `.artifacts/e2e-image-probe/workspace-oci`
is absent, recreate it with `skopeo copy --override-os linux --override-arch arm64`
from the approved workspace image, which took 38 s when it was last measured on
2026-08-21.

Guards that must hold alongside it:

- **The 1-layer alpine baseline stays green.** It measured `2 passed (1 suite,
  5.03s)` on 2026-08-21 and must not regress.
- **The engine log shows a constant device count.** Where it now prints
  `layers=36 total_mounts=38`, it must print a small fixed number. This is
  evidence about the mechanism, not a substitute for the run above.
- **Networking still starts.** The e2e tier constructs its environment as
  `ArcaE2e::new("arca-e2e", "networked")`, so a `startServices` broken by the
  `ArcaBoot.swift` edit surfaces there.
- **Both repositories build and their test suites pass**, submodule and parent.

### A measurement this design owes

Upstream stacks every layer into one filesystem, where the fork unpacked layers in
parallel. The fork's unpack of 36 layers measured `duration_seconds=14.83` on
2026-08-21. Upstream's first create for the same image may be slower, and is then
cached per image. This has not been measured. Measure it and record the number
rather than assuming the trade is free; the maintainer accepted the trade in
principle, but no one has yet put a figure on it.

---

## 7. What this design does not claim

- **It does not fix `PrepareImage`.** The revert makes upstream's public per-image
  `unpack` reachable, which is what `PrepareImage` would need to keep the promise
  its contract states. Doing so is separate work with its own success criterion —
  that `Ack` means `Create` will find the content without reaching a registry —
  and its own tests. This change only stops `SandboxEngineService.swift:594-608`
  from asserting a reason that has become false.
- **It does not close U5.** How image digests reach a user's engine without
  registry access is unresolved. The `gascan` harness sidesteps it legitimately by
  running `skopeo` and `arca-engine image load` on its own machine; a shipped
  `.pkg` cannot. A green arca suite is evidence about the product on arca and is
  not evidence about U5.
- **It does not change Apple's `container` backend**, which is out of scope here
  and slated for removal in the consumer's own roadmap.
