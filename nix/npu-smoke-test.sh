#!/bin/sh
# npu-smoke-test: stage-1 RKNPU bring-up checks.
# Usage: npu-smoke-test [--self-test]
# Exit 0 iff all REQUIRED checks pass; informational checks warn only.
#
# Overridable inputs (defaults target the live system; the self-test and
# future operating points override them):
#   DT_ROOT          device-tree root (default /proc/device-tree)
#   SYS_CLASS_DRM    drm class dir (default /sys/class/drm)
#   DRI_DIR          DRI device dir (default /dev/dri)
#   IOMMU_GROUPS     iommu groups dir (default /sys/kernel/iommu_groups)
#   DEV_RKNPU        compat node path (default /dev/rknpu)
#   DMESG            log command (default dmesg)
#   EXPECTED_HZ      expected assigned-clock-rates (default 200000000)
#   REQUIRE_CHARDEV  1 requires a character device node, 0 accepts any
#                    existing file (self-test only; production stays 1)
set -u
fail=0
pass() { echo "ok: $1"; }
oops() { echo "FAIL: $1"; fail=1; }
note() { echo "note: $1"; }

: "${DT_ROOT:=/proc/device-tree}"
: "${SYS_CLASS_DRM:=/sys/class/drm}"
: "${DRI_DIR:=/dev/dri}"
: "${IOMMU_GROUPS:=/sys/kernel/iommu_groups}"
: "${DEV_RKNPU:=/dev/rknpu}"
: "${DMESG:=dmesg}"
: "${EXPECTED_HZ:=200000000}"
: "${REQUIRE_CHARDEV:=1}"

run_self_test() {
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  mkdir -p "$tmp/dt/rknpu@fdab0000" "$tmp/sys/class/drm/renderD129/device" \
    "$tmp/dri" "$tmp/ig" "$tmp/empty-dt" "$tmp/empty-sys" "$tmp/RKNPU"
  printf '\013\353\302\000' > "$tmp/dt/rknpu@fdab0000/assigned-clock-rates"
  ln -s "$tmp/RKNPU" "$tmp/sys/class/drm/renderD129/device/driver"
  : > "$tmp/dri/renderD129"
  printf 'rknpu: using non-iommu mode\n' > "$tmp/dmesg.txt"
  printf 'rknpu: using iommu mode\n' > "$tmp/dmesg-iommu.txt"
  base_env="DT_ROOT=$tmp/dt SYS_CLASS_DRM=$tmp/sys/class/drm DRI_DIR=$tmp/dri IOMMU_GROUPS=$tmp/ig DEV_RKNPU=$tmp/nope DMESG=cat"
  echo "-- self-test: healthy tree passes at 200 MHz"
  env $base_env DMESG="cat $tmp/dmesg.txt" REQUIRE_CHARDEV=0 "$0" | grep -q "ALL SMOKE CHECKS PASSED" || return 1
  env $base_env DMESG="cat $tmp/dmesg.txt" REQUIRE_CHARDEV=0 "$0" | grep -q "200 MHz" || return 1
  echo "-- self-test: 600 MHz DT rate fails against 200 MHz expectation"
  printf '\043\303\106\000' > "$tmp/dt/rknpu@fdab0000/assigned-clock-rates"
  if env $base_env DMESG="cat $tmp/dmesg.txt" REQUIRE_CHARDEV=0 "$0" | grep -q "ALL SMOKE CHECKS PASSED"; then
    return 1
  fi
  printf '\013\353\302\000' > "$tmp/dt/rknpu@fdab0000/assigned-clock-rates"
  echo "-- self-test: missing DT node fails as stale DTB"
  if env DT_ROOT="$tmp/empty-dt" DMESG="cat $tmp/dmesg.txt" "$0" 2>/dev/null | grep -q "ALL SMOKE CHECKS PASSED"; then
    return 1
  fi
  echo "-- self-test: iommu-mode dmesg fails"
  if env $base_env DMESG="cat $tmp/dmesg-iommu.txt" REQUIRE_CHARDEV=0 "$0" 2>/dev/null | grep -q "ALL SMOKE CHECKS PASSED"; then
    return 1
  fi
  echo "-- self-test: unbound render node fails"
  if env DT_ROOT="$tmp/dt" SYS_CLASS_DRM="$tmp/empty-sys" DRI_DIR="$tmp/dri" IOMMU_GROUPS="$tmp/ig" DEV_RKNPU="$tmp/nope" DMESG="cat $tmp/dmesg.txt" "$0" 2>/dev/null | grep -q "ALL SMOKE CHECKS PASSED"; then
    return 1
  fi
  echo "SMOKE SELF-TEST PASSED"
}

if [ "${1:-}" = "--self-test" ]; then
  run_self_test
  exit "$?"
fi

rknpu_node=""
for d in "$SYS_CLASS_DRM"/renderD*; do
  [ -e "$d/device/driver" ] || continue
  drv=$(basename "$(readlink "$d/device/driver")")
  if [ "$drv" = "RKNPU" ]; then rknpu_node="$DRI_DIR/$(basename "$d")"; fi
done
node_ok=0
if [ -n "$rknpu_node" ]; then
  if [ -c "$rknpu_node" ]; then
    node_ok=1
  elif [ "$REQUIRE_CHARDEV" = "0" ] && [ -e "$rknpu_node" ]; then
    node_ok=1
  fi
fi
if [ "$node_ok" = "1" ]; then
  pass "render node $rknpu_node (driver RKNPU)"
else
  oops "no usable render node bound to RKNPU (driver probed? device nodes ready?)"
fi

# Kbuild enables DRM_GEM, not DMA_HEAP. /dev/rknpu is only a misc
# device in DMA_HEAP builds, or a host-provided compatibility symlink.
if [ -e "$DEV_RKNPU" ]; then
  note "/dev/rknpu present (optional compatibility node)"
else
  note "/dev/rknpu absent (expected for DRM/GEM-only builds)"
fi

if $DMESG >/dev/null 2>&1; then
  if $DMESG | grep -qi "non-iommu mode"; then
    pass "driver reports non-iommu mode (expected: overlay has no iommus)"
  elif $DMESG | grep -qi "using iommu mode"; then
    oops "driver in iommu mode (overlay unexpectedly carries iommus)"
  else
    oops "no rknpu iommu-mode line in dmesg"
  fi
else
  note "dmesg unreadable (need root/adm); skipping log checks"
fi

grp=""
for g in "$IOMMU_GROUPS"/*/devices/*fdab0000*; do
  [ -e "$g" ] || continue
  grp=$(basename "$(dirname "$(dirname "$g")")")
done
if [ -z "$grp" ]; then
  pass "fdab0000.npu in no IOMMU group (non-iommu mode: expected)"
else
  note "fdab0000.npu in iommu group $grp (unexpected with this overlay; informational)"
fi

# Passive DT readback of the configured NPU rate. /proc/device-tree is the
# flattened blob in memory: no firmware MMIO, unlike clk_summary reads
# (see REVIEW.md: reading live PVTPLL rates can hit powered-off islands).
# A mismatch means the booted DTB is not the deployed overlay (stale
# generation, wrong board DTB) - fail loudly instead of testing blind.
rate_file=""
if [ -f "$DT_ROOT/rknpu@fdab0000/assigned-clock-rates" ]; then
  rate_file="$DT_ROOT/rknpu@fdab0000/assigned-clock-rates"
else
  cand=$(find "$DT_ROOT" -maxdepth 2 -name assigned-clock-rates -path '*rknpu@*' 2>/dev/null | head -1)
  if [ -n "$cand" ]; then rate_file="$cand"; fi
fi
if [ -z "$rate_file" ]; then
  oops "no rknpu node in live device tree (stale DTB? overlay not applied?)"
else
  rate_hz=$(od -An --endian=big -tu4 "$rate_file" | tr -d ' \n')
  case "$rate_hz" in
    ''|*[!0-9]*)
      oops "unreadable NPU rate in live device tree ($rate_file)"
      ;;
    *)
      rate_mhz=$((rate_hz / 1000000))
      if [ "$rate_hz" = "$EXPECTED_HZ" ]; then
        pass "live DT NPU rate ${rate_mhz} MHz ($rate_hz Hz, as configured)"
      else
        oops "live DT NPU rate ${rate_mhz} MHz ($rate_hz Hz), expected $EXPECTED_HZ Hz (wrong DTB/boot?)"
      fi
      ;;
  esac
fi

if [ "$fail" = "0" ]; then echo "ALL SMOKE CHECKS PASSED"; else echo "SMOKE CHECKS FAILED"; fi
exit $fail