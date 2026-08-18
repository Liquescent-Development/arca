#!/bin/bash
# Build the Linux kernel Arca runs its VMs on.
#
# The recipe is NOT fetched from the network. It is vendored at kernel/recipe/,
# copied verbatim from apple/containerization at the tag recorded in
# kernel/recipe.env, and every byte of it is pinned in kernel/recipe.sha256.
# The Linux source tarball is pinned to kernel.org's own published sha256.
#
# So "which source produced this kernel" is answerable from a clean checkout,
# offline, by reading kernel/recipe.env and kernel/recipe.sha256.
#
# This build is NOT bit-reproducible -- see kernel/README.md. Rebuilding gives a
# kernel from identical source and config, not an identical binary.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RECIPE_DIR="$PROJECT_ROOT/kernel/recipe"
LOCK_FILE="$PROJECT_ROOT/kernel/recipe.sha256"
WORK_DIR="$HOME/.arca/kernel-build"
INSTALL_PATH="$HOME/.arca/vmlinux"

# shellcheck source=../kernel/recipe.env
source "$PROJECT_ROOT/kernel/recipe.env"

echo "=== Building Linux $KERNEL_VERSION for Arca ==="
echo "    recipe: apple/containerization $UPSTREAM_TAG ($UPSTREAM_COMMIT)"
echo

if ! command -v container &> /dev/null; then
    echo "ERROR: 'container' tool not found"
    echo "Download from: https://github.com/apple/container/releases"
    exit 1
fi

# 1. The vendored recipe must be exactly what recipe.sha256 says it is.
echo "→ Verifying vendored recipe against kernel/recipe.sha256..."
grep -E '^[0-9a-f]{64}  recipe/' "$LOCK_FILE" \
    | (cd "$PROJECT_ROOT/kernel" && shasum -a 256 -c -)
echo

# 2. The options Arca needs must already be set. Arca does not patch the config:
#    a config that does not carry them is not a config we know how to build.
echo "→ Asserting required kernel options..."
for opt in $REQUIRED_CONFIGS; do
    if ! grep -qx -- "$opt" "$RECIPE_DIR/config-arm64"; then
        echo "ERROR: $opt is not set in kernel/recipe/config-arm64"
        echo "       Set it in the vendored config and refresh kernel/recipe.sha256."
        exit 1
    fi
    echo "  ✓ $opt"
done
echo

# 3. Lay the recipe into the work dir. Refreshed every run so a stale or edited
#    work tree can never silently decide what gets built.
echo "→ Staging recipe into $WORK_DIR/kernel..."
mkdir -p "$WORK_DIR/kernel"
rsync -a --delete --exclude 'source.tar.xz' --exclude 'vmlinux' \
    "$RECIPE_DIR/" "$WORK_DIR/kernel/"
echo

# 4. Fetch the pinned Linux source, and refuse anything that is not it. The
#    recipe's own Makefile would fetch it silently; doing it here means the
#    digest is checked before a compiler ever sees the bytes.
cd "$WORK_DIR/kernel"
if [ ! -f source.tar.xz ]; then
    echo "→ Downloading Linux $KERNEL_VERSION source..."
    curl -SsL --fail -o source.tar.xz "$KERNEL_SOURCE_URL"
fi
echo "→ Verifying Linux source against kernel.org's published sha256..."
actual="$(shasum -a 256 source.tar.xz | cut -d' ' -f1)"
if [ "$actual" != "$KERNEL_SOURCE_SHA256" ]; then
    echo "ERROR: source.tar.xz does not match the pinned digest."
    echo "  expected: $KERNEL_SOURCE_SHA256"
    echo "  actual:   $actual"
    echo "  file:     $WORK_DIR/kernel/source.tar.xz"
    exit 1
fi
echo "  ✓ $actual"
echo

# 5. Build, using the recipe's own Makefile and build.sh unchanged.
echo "→ Building kernel (this takes 10-15 minutes)..."
make

if [ ! -f vmlinux ]; then
    echo "ERROR: Build completed but vmlinux not found"
    exit 1
fi

echo
echo "→ Built: $WORK_DIR/kernel/vmlinux"
echo "  sha256: $(shasum -a 256 vmlinux | cut -d' ' -f1)"
echo "  bytes:  $(wc -c < vmlinux | tr -d ' ')"
echo

# 6. Install. $INSTALL_PATH is a symlink into the installed Arca.app on machines
#    that took a release build, and writing through it would overwrite the
#    shipped, tested kernel in place. Refuse rather than guess.
if [ -L "$INSTALL_PATH" ]; then
    echo "ERROR: $INSTALL_PATH is a symlink to $(readlink "$INSTALL_PATH")"
    echo "       Installing would overwrite that file through the link."
    echo "       Remove the symlink first if you intend to replace the kernel."
    exit 1
fi

if [ -f "$INSTALL_PATH" ]; then
    BACKUP="$INSTALL_PATH.backup-$(date +%Y%m%d-%H%M%S)"
    mv "$INSTALL_PATH" "$BACKUP"
    echo "  ✓ Backed up existing kernel to: $BACKUP"
fi

cp vmlinux "$INSTALL_PATH"
echo "  ✓ Installed to: $INSTALL_PATH"
echo
echo "=== Build complete ==="
