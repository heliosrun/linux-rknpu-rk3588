#!/usr/bin/env bash
# Build the IOMMU-patched kernel (vmlinux + modules) for out-of-tree use.
# Usage: build-kernel.sh <linux-dir> [jobs]
#
# The companion patch gives the four-bank IOMMU its own clock/PM dependencies.
set -euo pipefail
LINUX_DIR="${1:?usage: build-kernel.sh <linux-dir> [jobs]}"
JOBS="${2:-$(nproc)}"
if command -v ccache >/dev/null 2>&1; then CC="ccache ${CROSS_COMPILE:-}gcc"; else CC="${CROSS_COMPILE:-}gcc"; fi
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
"$SCRIPT_DIR/apply-kernel-patches.sh" "$LINUX_DIR"
cd "$LINUX_DIR"
make ARCH=arm64 O=build defconfig
./scripts/config --file build/.config -e PM_DEVFREQ -e DEVFREQ_GOV_PERFORMANCE -e DEVFREQ_THERMAL
make ARCH=arm64 O=build olddefconfig
make ARCH=arm64 O=build CC="$CC" DTC_FLAGS="-@" -j"$JOBS" all
test -f build/Module.symvers
test -f build/vmlinux
