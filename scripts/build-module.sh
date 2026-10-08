#!/usr/bin/env bash
# Build the rknpu module out-of-tree and verify the artifact.
# Usage: build-module.sh <linux-dir> <driver-dir> [jobs]
set -euo pipefail
LINUX_DIR="${1:?usage: build-module.sh <linux-dir> <driver-dir> [jobs]}"
DRIVER_DIR="${2:?usage: build-module.sh <linux-dir> <driver-dir> [jobs]}"
JOBS="${3:-$(nproc)}"
if command -v ccache >/dev/null 2>&1; then CC="ccache gcc"; else CC="cc"; fi
cd "$LINUX_DIR"
make ARCH=arm64 O=build CC="$CC" -j"$JOBS" M="$DRIVER_DIR" modules
test -f "$DRIVER_DIR/rknpu.ko"
cd "$DRIVER_DIR"
echo "=== modinfo ==="
modinfo rknpu.ko | head -30
echo "=== vermagic ==="
modinfo -F vermagic rknpu.ko
echo "=== undefined symbols: $(nm rknpu.ko | grep -c " U ") ==="
