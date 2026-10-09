#!/usr/bin/env bash
# Apply the NixOS DT overlay to a pristine mainline DTB and assert the
# resulting tree: powered OPP operation and one four-bank IOMMU.
# Usage: check-dt-overlay.sh <linux-dir> <overlay-dts> [jobs]
set -euo pipefail
# Absolutize first: relative paths would break after the cd below
# (INC is computed from LINUX_DIR and consumed from inside it).
LINUX_DIR="$(cd "${1:?usage: check-dt-overlay.sh <linux-dir> <overlay-dts> [jobs]}" && pwd)"
OVERLAY_DTS="$(cd "$(dirname "${2:?usage: check-dt-overlay.sh <linux-dir> <overlay-dts> [jobs]}")" && pwd)/$(basename "${2}")"
JOBS="${3:-$(nproc)}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DTC=$(command -v dtc)
FDTOVERLAY=$(command -v fdtoverlay)
INC="$LINUX_DIR/scripts/dtc/include-prefixes"
cd "$LINUX_DIR"
gcc -E -nostdinc -I"$INC" -undef -D__DTS__ -x assembler-with-cpp \
  "$OVERLAY_DTS" -o /tmp/overlay-pp.dts
$DTC -@ -I dts -O dtb -o /tmp/rknpu.dtbo /tmp/overlay-pp.dts
BASE=build/arch/arm64/boot/dts/rockchip/rk3588-friendlyelec-cm3588-nas.dtb
# -@ so the DTB carries __symbols__: our label-based overlay
# (same file the NixOS deviceTree machinery applies) needs it.
# Full dtbs tree: single-file targets are not addressable (kbuild
# prepends the dts dir and doubles the path) and directory targets
# are no-ops. Do not "optimize".
make ARCH=arm64 O=build DTC_FLAGS="-@" -j"$JOBS" dtbs
$FDTOVERLAY -i "$BASE" -o /tmp/board-applied.dtb /tmp/rknpu.dtbo
python3 "$SCRIPT_DIR/check-applied-dt.py" /tmp/board-applied.dtb "$BASE"
python3 "$SCRIPT_DIR/test-dt-check.py" /tmp/board-applied.dtb "$BASE"
