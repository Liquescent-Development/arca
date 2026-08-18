# The Linux kernel Arca distributes

Arca ships a Linux kernel binary. Linux is licensed under the GNU General Public
License, version 2, so distributing that binary carries an obligation to offer
the corresponding source. This directory is how Arca discharges it.

The obligation is narrow. It attaches to the kernel binary and to nothing else
Arca distributes: Arca's own code is not a derivative of the kernel, and the
build recipe below is Apple's, under Apache-2.0.

## What is distributed

Release asset `vmlinux-arm64.gz` — a gzip of a single file, the arm64 kernel
image. Uncompressed it is:

| | |
|---|---|
| bytes | 28,248,576 |
| sha256 | `49e0f08165409769e5ae2abbe3414198c2907a15e7e20a5f3971aa7a0de33394` |

The file is named `vmlinux` by history, but it is `arch/arm64/boot/Image` from
the kernel build tree — `recipe/build.sh:26` is where the name changes. It is a
kernel image, not the ELF `vmlinux`.

## The corresponding source

Linux **6.14.9**, unmodified upstream, exactly as published by kernel.org:

| | |
|---|---|
| url | https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.14.9.tar.xz |
| bytes | 149,501,424 |
| sha256 | `390cdde032719925a08427270197ef55db4e90c09d454e9c3554157292c9f361` |

That sha256 is kernel.org's own published sum for the file. It is the
`linux-6.14.9.tar.xz` line of
<https://cdn.kernel.org/pub/linux/kernel/v6.x/sha256sums.asc>, and it matches the
tarball this project built from.

Arca applies no patches to the kernel source. The version is confirmed from the
tarball itself and not only from the URL: `linux-6.14.9/Makefile` in it declares
`VERSION = 6`, `PATCHLEVEL = 14`, `SUBLEVEL = 9`, with `EXTRAVERSION` empty.

## The configuration

`recipe/config-arm64`, sha256
`0b05408d7d5f5d5e941d89767780dc87a2e90e2f8ef20ec6f8cf11a3037f9f36`. It is
copied to `.config` and run through `make olddefconfig` by `recipe/build.sh:20`.

Arca requires two options beyond a stock container kernel, and both are already
set in that config:

- `CONFIG_WIREGUARD=y` — `recipe/config-arm64:1916`
- `CONFIG_TUN=y` — `recipe/config-arm64:1932`

Arca does not edit the config to obtain them. `scripts/build-kernel.sh` asserts
they are present and fails the build if they are not.

## The scripts used to control compilation

GPLv2 §3 counts "the scripts used to control compilation and installation of the
executable" as part of the corresponding source. Those are, in this repository:

- `scripts/build-kernel.sh` — Arca's driver: verifies the recipe and the source
  against their pinned digests, stages the recipe, runs the build, installs.
- `recipe/Makefile` — builds the build container and runs the build in it.
- `recipe/build.sh` — unpacks the source, applies the config, runs `make`.
- `recipe/image/Dockerfile`, `recipe/image/sources.list` — the toolchain image.

## Where the recipe came from

`recipe/` is a verbatim copy of the `kernel/` directory of
[apple/containerization](https://github.com/apple/containerization) at tag
**0.20.1**, commit `452f354bac52ecbfe4a40b729880435a070c5a29`.

Before this was vendored, `scripts/build-kernel.sh` obtained the recipe with
`git clone --depth 1` of `main` and no pinned commit, so which recipe — and
therefore which kernel version — a build used depended on the day it ran.

The commit above is not a guess about what that clone got. The build tree that
produced the shipped kernel survives at `~/.arca/kernel-build/kernel/`, and all
six upstream files in it are byte-identical to that tag:

```
$ cd containerization
$ for f in Makefile build.sh config-arm64 README.md image/Dockerfile image/sources.list; do
    git rev-parse "452f354bac52ecbfe4a40b729880435a070c5a29:kernel/$f"
    git hash-object ~/.arca/kernel-build/kernel/$f
  done
```

all six pairs agree. Which commit the shallow clone actually fetched is not
recorded anywhere and cannot be recovered, but it does not need to be: the recipe
sat unchanged upstream for a long stretch. 121 commits reachable from
`apple/containerization` `main` carry it verbatim, the oldest `995a2313`
(2025-10-03) and the newest `452f354b` (2026-01-05), so whichever of them the
clone landed on, the bytes were these. `452f354b` is the newest and is tagged,
which is why it is the name used here; tags `0.20.0` and `0.20.1` both point at
it.

One file in `recipe/` is not upstream: `recipe/image/.dockerignore`, an empty
file that `container build` requires. The previous script created it at build
time; it is now vendored so the recipe is complete.

`recipe/` is Apple's work under the Apache License 2.0, whose headers are intact
in each file. Vendoring it does not change its licence.

## Rebuilding

```bash
./scripts/build-kernel.sh
```

It needs Apple's `container` tool
(<https://github.com/apple/container/releases>). It verifies `recipe/` against
`recipe.sha256`, downloads the pinned Linux source to `~/.arca/kernel-build/kernel/`
and refuses to build unless its sha256 matches, then builds.

## What rebuilding does and does not give you

Rebuilding gives you a kernel from identical source, identical config and
identical scripts. It does **not** give you a byte-identical copy of the binary
Arca ships. This build is not bit-reproducible — kernel builds embed build IDs
and timestamps.

That is measured, not assumed. The shipped kernel and the kernel left in the
build tree by the build that produced it are the same size and different bytes:

| file | bytes | sha256 |
|---|---|---|
| `/Applications/Arca.app/Contents/Resources/vmlinux` (shipped) | 28,248,576 | `49e0f08165409769e5ae2abbe3414198c2907a15e7e20a5f3971aa7a0de33394` |
| `~/.arca/kernel-build/kernel/vmlinux` (build tree) | 28,248,576 | `9678e68702169b30b3e7326a16c2b3edbcb883c9ce4ef5ad638cb46363e77934` |

So do not treat a digest mismatch after a rebuild as evidence of tampering. What
corresponds is the source, the config and the scripts. Bit-identity does not.

## Written offer

The complete corresponding source for the kernel binary Arca distributes is the
tarball named above, at the URL named above, together with the configuration and
the scripts in this repository. It is available to any third party for the
lifetime of the release that contains the binary. If that URL ever stops
resolving, open an issue on the Arca repository and a copy will be provided on a
physical medium or by download, for no more than the cost of distribution.
