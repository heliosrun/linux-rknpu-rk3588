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
  if dmesg | grep -qi "non-iommu mode"; then
    pass "driver reports non-iommu mode (expected: overlay has no iommus)"
  elif dmesg | grep -qi "using iommu mode"; then
    oops "driver in iommu mode (overlay unexpectedly carries iommus)"
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
  pass "fdab0000.npu in no IOMMU group (non-iommu mode: expected)"
else
  note "fdab0000.npu in iommu group $grp (unexpected with this overlay; informational)"
fi

# clk_summary reads rates for all clocks, including SCMI PVTPLLs.
# Some firmware accesses powered-off islands on rate reads; do not
# perform that global hardware query in an otherwise passive smoke test.
note "clock readback skipped; DT bring-up checks require the 200 MHz GPLL rate"

if [ "$fail" = "0" ]; then echo "ALL SMOKE CHECKS PASSED"; else echo "SMOKE CHECKS FAILED"; fi
exit $fail
