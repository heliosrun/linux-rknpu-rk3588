#!/usr/bin/env bash
# Build a pristine kernel (vmlinux + modules) for out-of-tree use.
# Usage: build-kernel.sh <linux-dir> [jobs]
#
# Pure out-of-tree flow: no patching. "all" builds vmlinux and modules
# in one correctly ordered pass; the modules pass needs vmlinux.symvers
# (built-in symbol exports) for its modpost, and produces
# Module.symvers for external module links.
set -euo pipefail
LINUX_DIR="${1:?usage: build-kernel.sh <linux-dir> [jobs]}"
JOBS="${2:-$(nproc)}"
if command -v ccache >/dev/null 2>&1; then CC="ccache gcc"; else CC="cc"; fi
cd "$LINUX_DIR"
make ARCH=arm64 O=build defconfig
make ARCH=arm64 O=build CC="$CC" -j"$JOBS" all
test -f build/Module.symvers
test -f build/vmlinux
