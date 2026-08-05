#!/bin/bash
# Build custom vminit:latest OCI image with Arca extensions
#
# This script builds a custom vminit image based on Apple's vminitd with
# Arca-specific networking extensions:
# - arca-wireguard-service: WireGuard network service for bridge networks (Phase 3)
# - arca-embedded-dns: DNS resolver for container name resolution (Phase 3.1)
#
# Usage: build-vminit.sh [debug|release]
#   debug   - Build with DEBUG flag enabled (better logging, runs vminitd as subprocess of pid1)
#   release - Build optimized release binary (default)

set -e

# Parse build configuration (default: release)
BUILD_CONFIG="${1:-release}"

if [ "$BUILD_CONFIG" != "debug" ] && [ "$BUILD_CONFIG" != "release" ]; then
    echo "ERROR: Invalid build configuration: $BUILD_CONFIG"
    echo "Usage: $0 [debug|release]"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
VMINITD_DIR="$PROJECT_ROOT/containerization"

echo "========================================"
echo "Building custom vminit:latest ($BUILD_CONFIG)"
echo "========================================"

# Check if vminitd submodule is initialized
if [ ! -f "$VMINITD_DIR/Package.swift" ]; then
    echo "ERROR: vminitd submodule not initialized"
    echo "Run: git submodule update --init --recursive"
    exit 1
fi

# Ensure Swift Static Linux SDK is installed (required for cross-compilation)
echo ""
echo "→ Checking for Swift Static Linux SDK..."
if ! swift sdk list 2>/dev/null | grep -q "static-linux"; then
    echo "ERROR: Swift Static Linux SDK not installed"
    echo ""
    echo "Install it with:"
    echo "  cd $VMINITD_DIR/vminitd"
    echo "  make cross-prep"
    echo ""
    echo "This is a one-time setup that takes ~5 minutes."
    exit 1
fi
echo "  ✓ Swift Static Linux SDK found"

# Build unified arca-services (Go binary cross-compiled to Linux)
# This single binary contains all container extension services:
# - WireGuard network service (vsock:51820) with integrated DNS
# - Filesystem operations service (vsock:51821)
# - Process control service (vsock:51822)
# - Ready signal coordination (vsock:51819)
echo ""
echo "→ Building unified arca-services (Go → Linux ARM64)..."
cd "$VMINITD_DIR/vminitd/extensions/arca-services"

if [ ! -f build.sh ]; then
    echo "ERROR: arca-services/build.sh not found"
    exit 1
fi

# Run go mod tidy to ensure dependencies are resolved
echo "  Resolving Go dependencies..."
go mod tidy

./build.sh

if [ ! -f arca-services ]; then
    echo "ERROR: arca-services binary not built"
    exit 1
fi

echo "  ✓ Unified services built: arca-services"

# WireGuard tools (wg command) no longer needed - using netlink API
# Build vminitd (Swift cross-compiled to Linux)
echo ""
echo "→ Building vminitd (Swift → Linux ARM64, $BUILD_CONFIG)..."
cd "$VMINITD_DIR"

# Build using parent Makefile's init target which handles the nested package properly
BUILD_CONFIGURATION="$BUILD_CONFIG" make init

# The binaries are placed in vminitd/bin/ by the parent Makefile
VMINITD_BINARY="$VMINITD_DIR/vminitd/bin/vminitd"
VMEXEC_BINARY="$VMINITD_DIR/vminitd/bin/vmexec"

if [ ! -f "$VMINITD_BINARY" ]; then
    echo "ERROR: vminitd binary not built at $VMINITD_BINARY"
    exit 1
fi

if [ ! -f "$VMEXEC_BINARY" ]; then
    echo "ERROR: vmexec binary not built at $VMEXEC_BINARY"
    exit 1
fi

echo "  ✓ vminitd built: $VMINITD_BINARY"
echo "  ✓ vmexec built: $VMEXEC_BINARY"

# Create vminit rootfs using cctl (includes Swift runtime and all dependencies)
echo ""
echo "→ Creating vminit rootfs with cctl..."

# Path to cctl binary
CCTL_BINARY="$VMINITD_DIR/bin/cctl"

if [ ! -f "$CCTL_BINARY" ]; then
    echo "ERROR: cctl binary not found at $CCTL_BINARY"
    echo "Please build containerization first: cd containerization && make"
    exit 1
fi

# Output directory
VMINIT_DIR="$HOME/.arca/vminit"
rm -rf "$VMINIT_DIR"
mkdir -p "$VMINIT_DIR"

# Create the OCI image from the rootfs tar produced by `make init`.
#
# The 2026-08 upstream merge changed this flow. `cctl rootfs create` no longer assembles a
# rootfs from --vminitd/--vmexec/--add-file; it now consumes a prebuilt gzip tar, which
# containerization/scripts/build-initfs.sh writes to bin/init.rootfs.tar.gz along with the
# ext4 initfs. arca-services is staged into both by the --add-file flag that the fork adds
# to that script, wired in via the Makefile's INITFS_BUILD_CMD.
OCI_DIR="$VMINIT_DIR/oci"
ROOTFS_TAR="$VMINITD_DIR/bin/init.rootfs.tar.gz"

if [ ! -f "$ROOTFS_TAR" ]; then
    echo "ERROR: rootfs tar not found at $ROOTFS_TAR"
    echo "Expected 'make init' to have produced it."
    exit 1
fi

# Confirm arca-services actually made it into the rootfs, rather than trusting the flag.
if ! tar -tzf "$ROOTFS_TAR" | grep -q '^\./sbin/arca-services$'; then
    echo "ERROR: arca-services missing from $ROOTFS_TAR"
    echo "Check the --add-file wiring in containerization/Makefile (INITFS_BUILD_CMD)."
    exit 1
fi
echo "  ✓ arca-services present in rootfs tar"

echo "  Creating arca-vminit:latest image from rootfs tar..."
"$CCTL_BINARY" rootfs create \
    --image arca-vminit:latest \
    --label org.opencontainers.image.source=https://github.com/Vas-Solutus/arca \
    "$ROOTFS_TAR"

echo "  ✓ Rootfs tarball created: $(du -h "$ROOTFS_TAR" | awk '{print $1}')"

# Convert tarball to OCI image layout for loading into ImageStore
echo "  Converting rootfs to OCI image layout..."

# Extract tarball to temp directory
TEMP_ROOTFS="$VMINIT_DIR/temp_rootfs"
mkdir -p "$TEMP_ROOTFS"
tar -xf "$ROOTFS_TAR" -C "$TEMP_ROOTFS"

# Create OCI layout structure
mkdir -p "$OCI_DIR/blobs/sha256"

cat > "$OCI_DIR/oci-layout" <<EOF
{
  "imageLayoutVersion": "1.0.0"
}
EOF

# Create layer from extracted rootfs
LAYER_TAR="$VMINIT_DIR/layer.tar"
tar -C "$TEMP_ROOTFS" -cf "$LAYER_TAR" .
LAYER_DIGEST=$(shasum -a 256 "$LAYER_TAR" | awk '{print $1}')
LAYER_SIZE=$(stat -f%z "$LAYER_TAR")
mv "$LAYER_TAR" "$OCI_DIR/blobs/sha256/$LAYER_DIGEST"

# Create config
CONFIG_JSON=$(cat <<EOF
{
  "architecture": "arm64",
  "os": "linux",
  "rootfs": {
    "type": "layers",
    "diff_ids": ["sha256:$LAYER_DIGEST"]
  },
  "config": {
    "Cmd": ["/sbin/vminitd"]
  }
}
EOF
)

CONFIG_FILE="$VMINIT_DIR/config.json"
echo "$CONFIG_JSON" > "$CONFIG_FILE"
CONFIG_DIGEST=$(shasum -a 256 "$CONFIG_FILE" | awk '{print $1}')
CONFIG_SIZE=$(stat -f%z "$CONFIG_FILE")
mv "$CONFIG_FILE" "$OCI_DIR/blobs/sha256/$CONFIG_DIGEST"

# Create manifest
MANIFEST_JSON=$(cat <<EOF
{
  "schemaVersion": 2,
  "mediaType": "application/vnd.oci.image.manifest.v1+json",
  "config": {
    "mediaType": "application/vnd.oci.image.config.v1+json",
    "digest": "sha256:$CONFIG_DIGEST",
    "size": $CONFIG_SIZE
  },
  "layers": [
    {
      "mediaType": "application/vnd.oci.image.layer.v1.tar",
      "digest": "sha256:$LAYER_DIGEST",
      "size": $LAYER_SIZE
    }
  ]
}
EOF
)

MANIFEST_FILE="$VMINIT_DIR/manifest.json"
echo "$MANIFEST_JSON" > "$MANIFEST_FILE"
MANIFEST_DIGEST=$(shasum -a 256 "$MANIFEST_FILE" | awk '{print $1}')
mv "$MANIFEST_FILE" "$OCI_DIR/blobs/sha256/$MANIFEST_DIGEST"

# Create index with "arca-vminit:latest" tag
INDEX_JSON=$(cat <<EOF
{
  "schemaVersion": 2,
  "mediaType": "application/vnd.oci.image.index.v1+json",
  "manifests": [
    {
      "mediaType": "application/vnd.oci.image.manifest.v1+json",
      "digest": "sha256:$MANIFEST_DIGEST",
      "size": $(stat -f%z "$OCI_DIR/blobs/sha256/$MANIFEST_DIGEST"),
      "annotations": {
        "org.opencontainers.image.ref.name": "arca-vminit:latest"
      }
    }
  ]
}
EOF
)

echo "$INDEX_JSON" > "$OCI_DIR/index.json"

# Clean up temp files
rm -rf "$TEMP_ROOTFS" "$ROOTFS_TAR"

# Move OCI layout contents to vminit directory root
# OCI layout is currently at $VMINIT_DIR/oci/, we want it at $VMINIT_DIR/
mv "$OCI_DIR"/* "$VMINIT_DIR/"
rmdir "$OCI_DIR"

echo ""
echo "========================================"
echo "✓ arca-vminit:latest built successfully"
echo "========================================"
echo ""
echo "OCI image location: $VMINIT_DIR"
echo ""
echo "Contents:"
echo "  /sbin/vminitd      - Init system (PID 1)"
echo "  /sbin/vmexec       - Exec helper"
echo "  /sbin/arca-services - Unified container services (single binary):"
echo "                        - vsock:51819 - Ready signal (opens when all services ready)"
echo "                        - vsock:51820 - WireGuard network API with integrated DNS"
echo "                        - vsock:51821 - Filesystem operations API"
echo "                        - vsock:51822 - Process control API"
echo "  + Swift runtime and system libraries (via cctl)"
echo ""
echo "This image will be loaded as 'arca-vminit:latest' and used by all containers."
echo "Restart Arca daemon to pick up the new vminit image."
