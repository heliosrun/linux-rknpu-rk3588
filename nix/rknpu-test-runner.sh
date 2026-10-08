#!/bin/sh
# rknpu-test: NPU bring-up gate. No arguments.
# Runs fp16 matmul at the validated shapes on each core separately and
# on all cores. The probe exits 0 even on mismatch, so grepping for
# the OK marker is the verdict. RKNPU_CORE_MASK pins per-core runs.
set -u
BIN="@BINDIR@/matmul_fp16_rocket"
fail=0
run_one() {
  desc="$1"; mask="$2"; shift 2
  if [ "$mask" = all ]; then
    out=$(timeout 120 "$BIN" "$@" 2>&1)
  else
    out=$(timeout 120 env RKNPU_CORE_MASK="$mask" "$BIN" "$@" 2>&1)
  fi
  if printf '%s\n' "$out" | grep -q '^OK:'; then
    echo "PASS: $desc"
  else
    echo "FAIL: $desc"
    printf '%s\n' "$out" | tail -5
    fail=1
  fi
}
for core in 1 2 4; do
  run_one "tiny/core$core" "$core" 4 32 16
done
run_one "tiny/all" all 4 32 16
for core in 1 2 4; do
  run_one "large/core$core" "$core" 64 256 256
done
run_one "large/all" all 64 256 256
if [ "$fail" = 0 ]; then echo "ALL RKNPU TESTS PASSED"; fi
exit $fail
