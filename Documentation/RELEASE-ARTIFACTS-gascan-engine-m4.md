# Release artefacts for `gascan-engine-m4`

Identity of the two binary assets published with the `gascan-engine-m4` tag.

The annotated tag `d143a6611fdb62e46b11f76cca2627a258f1b2eb` dereferences to
Arca commit `c545612b056e028d5885968a7b9f586d694f994c` — the commit that adds
this file — on branch `feat/milestone-4-engine`, with submodule
`containerization` at `63041224e82befc1e3a825253125feabbc323da7`. Gas Can's
`engine/arca-pin.json` records that same revision.

**The artefacts themselves were built from the tree at `4134b54549a5de89cfe2c4bf567df1b0c93d7ee3`**,
which is `c545612`'s grandparent; the two commits between them add this document
and the kernel recipe and change no engine code. An earlier version of this line
gave `4134b54` as the tag's commit, which is wrong twice over: the tag is not
there, and that tree has no `kernel/recipe/`, so a reader checking it out to
audit the corresponding-source offer would find none. **The copy inside the
`gascan-engine-m4` tag still carries the wrong SHA and cannot be corrected
without re-cutting the tag, which is not warranted** — the pin, the digests and
the published bytes are all correct.

Gas Can's `engine/arca-pin.json` records these digests and its fetch verifies
them, so this file states exactly which bytes were hashed. A directory is not a
hash; every digest below is over a single file.

Both assets were staged at `~/.arca/release/gascan-engine-m4/` on 2026-08-17.
That is the directory to upload from. They were built by the same two commands
`make build-assets` uses (`Makefile:235` and `Makefile:237`), run directly —
`make build-assets` was **not** invoked, because it depends on the `kernel` and
`vminit` targets and would have rebuilt the artefacts this release is about.

## `vmlinux-arm64.gz`

| | |
|---|---|
| bytes | 9,092,349 |
| sha256 | `8a30e10d9e40dcc44396049753a3a26be74cbc77a78afca819cf8f1c13f8597a` |

Built with `gzip -c ~/.arca/vmlinux > vmlinux-arm64.gz`.

`~/.arca/vmlinux` is a symlink to
`/Applications/Arca.app/Contents/Resources/vmlinux`, so this compresses the
kernel that is actually installed — and therefore the one every live test in
this milestone ran against, not a rebuild of it.

The digest above is over the gzip stream. The kernel inside it is:

| | |
|---|---|
| bytes | 28,248,576 |
| sha256 | `49e0f08165409769e5ae2abbe3414198c2907a15e7e20a5f3971aa7a0de33394` |

Verified by round trip: `gzip -dc vmlinux-arm64.gz | shasum -a 256` produces
`49e0f081…` and `gzip -dc vmlinux-arm64.gz | wc -c` produces 28248576.

This asset is byte-identical to the one built on 2025-12-01 — `assets/SHA256SUMS`
of that date carries the same `8a30e10d…`. The shipped kernel has not changed
since; nothing in Milestone 4 rebuilt it.

Provenance, licensing and the corresponding-source offer for this binary are in
`kernel/README.md`.

## `vminit-oci-arm64.tar.gz`

| | |
|---|---|
| bytes | 73,739,738 |
| sha256 | `51602e72883e49e4be1e27a690bf8c13b0a66cba381725cf8ea4888ec4e369be` |

Built with `cd ~/.arca && COPYFILE_DISABLE=1 tar czf …/vminit-oci-arm64.tar.gz vminit/`.

The archive holds one directory, `vminit/`, an OCI image layout of 5 files
totalling 187,005,035 bytes:

| path | bytes |
|---|---|
| `vminit/oci-layout` | 36 |
| `vminit/index.json` | 389 |
| `vminit/blobs/sha256/cf74cd41…` (manifest) | 478 |
| `vminit/blobs/sha256/f53ed295…` (config) | 228 |
| `vminit/blobs/sha256/ae7690c6…` (layer) | 187,003,904 |

Verified by round trip: extracting the archive to an empty directory and running
`diff -r ~/.arca/vminit <extracted>/vminit` reports no differences, and each blob
file's sha256 equals its own filename.

### The tarball's digest is not the image's identity

`tar czf` output is not reproducible: entry order, mtimes and the gzip header
vary between runs, so re-running the command above on this identical layout will
produce a different sha256. `51602e72…` identifies **this file**, the one staged
on 2026-08-17, and the upload must be that file rather than a fresh archive of
the same directory.

The identity that survives repackaging is the OCI manifest digest, which is
content-addressed and can be recomputed by anyone after extraction:

**`sha256:cf74cd41bd430d9d8935d36c1749d9c05f19a43842f4a4cff0d01de3832222c2`**, manifest size 478.

A consumer should check both: the tarball sha256 proves the download arrived
intact, and the manifest digest proves the image inside is the intended one
however it was packaged.

The current image is `cf74cd41…`, rebuilt after the Landing 1 fix wave. An
earlier vminit digest survives in git-ignored workspace scaffolding on the build
host and is superseded; it is deliberately not repeated here, so any vminit
digest found in this repository other than `cf74cd41…` is the wrong one.

## Summary for `arca-pin.json`

```
vmlinux-arm64.gz          9092349   sha256:8a30e10d9e40dcc44396049753a3a26be74cbc77a78afca819cf8f1c13f8597a
  └─ kernel (uncompressed) 28248576 sha256:49e0f08165409769e5ae2abbe3414198c2907a15e7e20a5f3971aa7a0de33394
vminit-oci-arm64.tar.gz   73739738  sha256:51602e72883e49e4be1e27a690bf8c13b0a66cba381725cf8ea4888ec4e369be
  └─ OCI manifest          478      sha256:cf74cd41bd430d9d8935d36c1749d9c05f19a43842f4a4cff0d01de3832222c2
```
