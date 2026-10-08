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
# exactly ONE iommu: the merged 4-window device. (A 3-phandle
# list would only program the last-xlate MMU - see REVIEW.md.)
iommus=$($FDTGET /tmp/board-applied.dtb /rknpu@fdab0000 iommus)
echo "iommus: $iommus"
[ "$(echo $iommus | wc -w)" = "1" ] || { echo "FAIL: want 1 iommu"; exit 1; }
check /rknpu-mmu@fdab9000 status okay
# compatible is a 2-string list; assert via decompile instead
$DTC -I dtb -O dts /tmp/board-applied.dtb 2>/dev/null | grep -A3 "rknpu-mmu@fdab9000 {" | grep -q "rockchip,rk3568-iommu" && echo "ok: mmu compatible has rk3568-iommu fallback"
check /npu@fdab0000 status disabled
check /npu@fdac0000 status disabled
check /npu@fdad0000 status disabled
check /iommu@fdab9000 status disabled
check /iommu@fdaca000 status disabled
check /iommu@fdada000 status disabled
echo "ALL DT CHECKS PASSED"
