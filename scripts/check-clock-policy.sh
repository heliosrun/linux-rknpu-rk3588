#!/usr/bin/env bash
# Enforce the NPU clock policy: the whole tree must agree on the fixed
# 200 MHz GPLL bring-up rate. Raising the rate requires completing the
# REVIEW.md higher-frequency validation checklist with hardware evidence,
# then updating EXPECTED_HZ here together with that evidence.
# Usage: scripts/check-clock-policy.sh [--self-test]
# (no dependencies beyond grep/sed/cp/mktemp)
set -euo pipefail
EXPECTED_HZ=200000000
# Rates with history on this project: a 600M DT default hung the board;
# 900M/1G have no validated rail here.
UNSAFE_HZ="600000000 900000000 1000000000"
fail=0
: "${ROOT:=$(dirname "$0")/..}"
# Absolutize the script path before cd: recursive self-test calls use a
# relative $0, which would break once we leave the caller's directory.
SCRIPT="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
cd "$ROOT"

run_self_test() {
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  # Mirror every dir the policy reads, so fixtures can never rot behind
  # the check list: every checked file is present by construction.
  # (Plain cp -r: no tar dependency, works on minimal PATHs.)
  cp -r nix linux-integration scripts driver "$tmp/"
  cp flake.nix "$tmp/"
  echo "-- self-test: pristine fixtures pass"
  if ROOT="$tmp" "$SCRIPT" | grep -q "ALL CLOCK POLICY CHECKS PASSED"; then
    echo "ok: fixtures pass"
  else
    echo "FAIL: fixtures should pass"
    return 1
  fi
  echo "-- self-test: tampered rate fails"
  sed -i 's/200000000/600000000/g' "$tmp/scripts/check-dt-overlay.sh"
  if ROOT="$tmp" "$SCRIPT" >/dev/null 2>&1; then
    echo "FAIL: tampered rate accepted"
    return 1
  else
    echo "ok: tampered rate rejected"
  fi
  echo "-- self-test: missing devfreq stub fails"
  cp scripts/check-dt-overlay.sh "$tmp/scripts/"
  sed -i '/rknpu_devfreq_stub/d' "$tmp/driver/Kbuild"
  if ROOT="$tmp" "$SCRIPT" >/dev/null 2>&1; then
    echo "FAIL: missing stub accepted"
    return 1
  else
    echo "ok: missing stub rejected"
  fi
  echo "CLOCK POLICY SELF-TEST PASSED"
}

if [ "${1:-}" = "--self-test" ]; then
  run_self_test
  exit "$?"
fi
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
for f in linux-integration/rk3588-vendor-nodes.dtsi nix/check-dt.nix scripts/check-dt-overlay.sh; do
  check_contains "$f" "$EXPECTED_HZ" "rate $EXPECTED_HZ"
  for hz in $UNSAFE_HZ; do
    check_absent "$f" "$hz" "rate $hz"
  done
done
# The NixOS overlay is a template: the rate comes from the gated
# hardware.rknpu.npuClockHz option. The placeholder must survive, and no
# unsafe literal rate may be baked in.
check_contains nix/overlay.dts.in '@NPU_CLOCK_HZ@' "rate placeholder"
check_contains nix/overlay.dts.in "$EXPECTED_HZ" "documented default rate"
for hz in $UNSAFE_HZ; do
  check_absent nix/overlay.dts.in "$hz" "rate $hz"
done
check_contains driver/Kbuild 'rknpu_devfreq_stub\.o' "devfreq stub object"
check_absent driver/Kbuild '^rknpu-y += rknpu_devfreq\.o$' "real devfreq object"
check_contains nix/default.nix 'npuClockHz == 200000000' "200 MHz assertion"
check_contains nix/npu-smoke-test.sh 'EXPECTED_HZ:=200000000' "smoke-test expected-rate default"
check_contains nix/test.nix 'expectedHz ? 200000000' "test-package rate default"
check_contains nix/default.nix 'expectedHz = cfg.npuClockHz' "test follows gated option"
# The negative gate itself must survive: without it, a silently removed
# rejection check would leave every other gate green and useless.
check_contains flake.nix 'rate-gate-negative' "negative gate check"
check_contains flake.nix 'mkSys 600000000' "negative test vector"
if [ "$fail" -ne 0 ]; then
  echo "CLOCK POLICY CHECKS FAILED"
  exit 1
fi
echo "ALL CLOCK POLICY CHECKS PASSED"
