#!/usr/bin/env bash
# Apply the NixOS DT overlay to a pristine mainline DTB and assert the
# resulting tree: vendor node present, rocket cores off, IOMMUs on.
# Usage: check-dt-overlay.sh <linux-dir> <overlay-dts> [jobs]
set -euo pipefail
# Absolutize first: relative paths would break after the cd below
# (INC is computed from LINUX_DIR and consumed from inside it).
LINUX_DIR="$(cd "${1:?usage: check-dt-overlay.sh <linux-dir> <overlay-dts> [jobs]}" && pwd)"
OVERLAY_DTS="$(cd "$(dirname "${2:?usage: check-dt-overlay.sh <linux-dir> <overlay-dts> [jobs]}")" && pwd)/$(basename "${2}")"
JOBS="${3:-$(nproc)}"
DTC=$(command -v dtc)
FDTOVERLAY=$(command -v fdtoverlay)
FDTGET=$(command -v fdtget)
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
check() {
  got=$($FDTGET /tmp/board-applied.dtb "$1" "$2")
  if [ "$got" != "$3" ]; then
    echo "FAIL: $1 $2 mismatch (see values above)"
    exit 1
  fi
  echo "ok: $1 $2 = $got"
}
check /rknpu@fdab0000 status okay
check /rknpu@fdab0000 compatible rockchip,rk3588-rknpu
check /rknpu@fdab0000 assigned-clock-rates 600000000
# Non-IOMMU mode: the node must have NO iommus property and the
# merged mmu device must not exist (the mainline rockchip-iommu
# driver cannot drive the 4-window device - see REVIEW.md Finding 1b).
if $FDTGET /tmp/board-applied.dtb /rknpu@fdab0000 iommus >/dev/null 2>&1; then
  echo "FAIL: iommus present but non-iommu mode expected"
  exit 1
fi
echo "ok: /rknpu@fdab0000 has no iommus (non-iommu mode)"
if $FDTGET /tmp/board-applied.dtb /rknpu-mmu@fdab9000 status >/dev/null 2>&1; then
  echo "FAIL: merged rknpu-mmu node exists"
  exit 1
fi
echo "ok: no merged rknpu-mmu node"
check /npu@fdab0000 status disabled
check /npu@fdac0000 status disabled
check /npu@fdad0000 status disabled
check /iommu@fdab9000 status disabled
check /iommu@fdaca000 status disabled
check /iommu@fdada000 status disabled
echo "ALL DT CHECKS PASSED"
