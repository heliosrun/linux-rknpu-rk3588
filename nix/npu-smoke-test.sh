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
  if [ "$drv" = "RKNPU" ]; then rknpu_node="/dev/$(basename "$d")"; fi
done
if [ -n "$rknpu_node" ]; then
  pass "render node $rknpu_node (driver RKNPU)"
else
  oops "no render node bound to RKNPU (driver probed?)"
fi

if [ -e /dev/rknpu ]; then
  pass "/dev/rknpu present"
else
  oops "/dev/rknpu missing"
fi

if dmesg >/dev/null 2>&1; then
  if dmesg | grep -qi "using iommu mode"; then
    pass "driver reports iommu mode"
  elif dmesg | grep -qi "non-iommu mode"; then
    oops "driver in non-iommu mode (DT overlay not applied?)"
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
  oops "fdab0000.npu in no IOMMU group (no IOMMU bound?)"
else
  ndev=$(ls /sys/kernel/iommu_groups/$grp/devices | wc -l | tr -d " ")
  if [ "$ndev" = "1" ]; then
    pass "iommu group $grp holds exactly the rknpu device"
  else
    oops "iommu group $grp holds $ndev devices (want 1)"
  fi
fi

if [ -r /sys/kernel/debug/clk/clk_summary ]; then
  note "npu clock lines:"
  grep -i "npu" /sys/kernel/debug/clk/clk_summary | head -5 | sed "s/^/  /"
else
  note "debugfs clk_summary unavailable; skipping clock check"
fi

if [ "$fail" = "0" ]; then echo "ALL SMOKE CHECKS PASSED"; else echo "SMOKE CHECKS FAILED"; fi
exit $fail
