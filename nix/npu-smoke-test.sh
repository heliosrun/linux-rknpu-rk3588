#!/bin/sh
# npu-smoke-test: stage-1 RKNPU bring-up checks. No arguments.
# Exit 0 iff all REQUIRED checks pass; informational checks warn only.
set -u
fail=0
pass() { echo "ok: $1"; }
oops() { echo "FAIL: $1"; fail=1; }
note() { echo "note: $1"; }

rknpu_node=""
for d in /sys/class/drm/renderD*; do
  [ -e "$d/device/driver" ] || continue
  drv=$(basename "$(readlink "$d/device/driver")")
  if [ "$drv" = "RKNPU" ]; then rknpu_node="/dev/dri/$(basename "$d")"; fi
done
if [ -n "$rknpu_node" ] && [ -c "$rknpu_node" ]; then
  pass "render node $rknpu_node (driver RKNPU)"
else
  oops "no usable render node bound to RKNPU (driver probed? device nodes ready?)"
fi

# Kbuild enables DRM_GEM, not DMA_HEAP. /dev/rknpu is only a misc
# device in DMA_HEAP builds, or a host-provided compatibility symlink.
if [ -e /dev/rknpu ]; then
  note "/dev/rknpu present (optional compatibility node)"
else
  note "/dev/rknpu absent (expected for DRM/GEM-only builds)"
fi

if dmesg >/dev/null 2>&1; then
  if dmesg | grep -qi "using iommu mode"; then
    pass "driver reports IOMMU mode"
  elif dmesg | grep -qi "non-iommu mode"; then
    oops "driver reports non-IOMMU mode; check the kernel patch and overlay"
  else
    oops "no rknpu iommu-mode line in dmesg"
  fi
else
  note "dmesg unreadable (need root/adm); skipping log checks"
fi

grp=""
for g in /sys/kernel/iommu_groups/*/devices/*fdab0000*; do
  [ -e "$g" ] || continue
  grp=$(echo "$g" | cut -d/ -f5)
done
if [ -z "$grp" ]; then
  oops "fdab0000.npu has no IOMMU group"
else
  pass "fdab0000.npu in iommu group $grp"
fi

# clk_summary reads rates for all clocks, including SCMI PVTPLLs.
# Some firmware accesses powered-off islands on rate reads; do not
# perform that global hardware query in an otherwise passive smoke test.
# This driver's frequency reader resumes the full clock/domain bulk first.
# Never substitute a global clk_summary read for this powered query.
if [ -r /sys/kernel/debug/rknpu/freq ]; then
  freq=$(cat /sys/kernel/debug/rknpu/freq)
  case "$freq" in
    200000000|300000000|400000000|500000000|600000000|700000000|800000000|900000000|1000000000)
      pass "powered NPU rate $freq Hz (may be thermally capped)" ;;
    *) oops "unexpected NPU rate $freq" ;;
  esac
else
  note "powered frequency read unavailable; mount debugfs as root to inspect it"
fi

if [ "$fail" = "0" ]; then echo "ALL SMOKE CHECKS PASSED"; else echo "SMOKE CHECKS FAILED"; fi
exit $fail
