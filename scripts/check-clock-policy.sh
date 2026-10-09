#!/usr/bin/env bash
# Enforce the NPU clock policy: the whole tree must agree on the fixed
# 200 MHz GPLL bring-up rate. Raising the rate requires completing the
# REVIEW.md higher-frequency validation checklist with hardware evidence,
# then updating EXPECTED_HZ here together with that evidence.
# Usage: scripts/check-clock-policy.sh (no dependencies beyond grep)
set -euo pipefail
EXPECTED_HZ=200000000
# Rates with history on this project: a 600M DT default hung the board;
# 900M/1G have no validated rail here.
UNSAFE_HZ="600000000 900000000 1000000000"
fail=0
cd "$(dirname "$0")/.."
check_contains() {
  if grep -q "$2" "$1"; then
    echo "ok: $1 contains $3"
  else
    echo "FAIL: $1 lacks $3"
    fail=1
  fi
}
check_absent() {
  if grep -q "$2" "$1"; then
    echo "FAIL: $1 contains forbidden $3"
    fail=1
  else
    echo "ok: $1 has no $3"
  fi
}
for f in nix/overlay.dts linux-integration/rk3588-vendor-nodes.dtsi nix/check-dt.nix scripts/check-dt-overlay.sh; do
  check_contains "$f" "$EXPECTED_HZ" "rate $EXPECTED_HZ"
  for hz in $UNSAFE_HZ; do
    check_absent "$f" "$hz" "rate $hz"
  done
done
check_contains driver/Kbuild 'rknpu_devfreq_stub\.o' "devfreq stub object"
check_absent driver/Kbuild '^rknpu-y += rknpu_devfreq\.o$' "real devfreq object"
check_contains nix/default.nix 'npuClockHz == 200000000' "200 MHz assertion"
if [ "$fail" -ne 0 ]; then
  echo "CLOCK POLICY CHECKS FAILED"
  exit 1
fi
echo "ALL CLOCK POLICY CHECKS PASSED"
