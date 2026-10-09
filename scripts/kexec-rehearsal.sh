#!/usr/bin/env bash
# Kexec rehearsal for headless bring-up.
#
# Boots a freshly built NixOS generation through kexec WITHOUT touching the
# bootloader. If the kexec'd kernel hangs, power-cycle the board: the boot
# loader still points at the known-good generation, so the box comes back.
# A hang here costs a power cycle, not a bricked boot chain.
#
# On the target host, from a healthy SSH session:
#
#   nixos-rebuild build --flake .#cm3588   # build only; never switch yet
#   ./kexec-rehearsal.sh --dry-run \
#     --kernel ./result/kernel --initrd ./result/initrd \
#     --dtb /path/to/board-applied.dtb
#   ./kexec-rehearsal.sh --confirm \
#     --kernel ./result/kernel --initrd ./result/initrd \
#     --dtb /path/to/board-applied.dtb
#
# After the exec step SSH drops; reconnect and validate. On a hang,
# power-cycle back to the untouched bootloader default.
#
# Finding the board DTB for --dtb:
#   nix build .#nixosConfigurations.cm3588.config.hardware.deviceTree.package
# then take the rockchip/<board>.dtb with the overlay applied.
#
# What this proves and what it does not: a clean kexec boot proves the
# kernel, initrd, DTB, module load and smoke tests in a warm state. It is
# NOT proof of cold-boot safety (warm kexec preserves firmware/power
# state). Promote to switch+reboot only after the kexec run is green.
set -euo pipefail

KERNEL=""
INITRD=""
DTB=""
APPEND=""
KEXEC_BIN=""
DRY_RUN=1
CONFIRM=0
SELF_TEST=0

usage() {
  echo "Usage: kexec-rehearsal.sh [--dry-run|--confirm|--self-test] --kernel K --initrd I --dtb D [--append CMDLINE] [--kexec-bin PATH]"
  echo "  Default mode is --dry-run (validate only, execute nothing)."
}

fail() { echo "FAIL: $1" >&2; exit 1; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --kernel) KERNEL="$2"; shift 2;;
    --initrd) INITRD="$2"; shift 2;;
    --dtb) DTB="$2"; shift 2;;
    --append) APPEND="$2"; shift 2;;
    --kexec-bin) KEXEC_BIN="$2"; shift 2;;
    --dry-run) DRY_RUN=1; CONFIRM=0; shift;;
    --confirm) DRY_RUN=0; CONFIRM=1; shift;;
    --self-test) SELF_TEST=1; shift;;
    -h|--help) usage; exit 0;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 1;;
  esac
done

check_file() {
  [ -n "$1" ] || fail "missing $2 path (see --help)"
  [ -f "$1" ] || fail "$2 not found: $1"
  [ -s "$1" ] || fail "$2 is empty: $1"
  [ -r "$1" ] || fail "$2 not readable: $1 (run as root or fix permissions)"
  echo "ok: $2 $1"
}

check_dtb_magic() {
  magic=$(head -c 4 "$1" | od -An -tx1 | tr -d ' \n')
  [ "$magic" = "d00dfeed" ] || fail "$1 is not a device tree blob (magic $magic)"
  echo "ok: DTB magic d00dfeed"
}

run_self_test() {
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  printf 'kernel-bytes' > "$tmp/kernel"
  printf 'initrd-bytes' > "$tmp/initrd"
  printf '\xd0\x0d\xfe\xedREST' > "$tmp/board.dtb"
  printf 'not-a-dtb' > "$tmp/bad.dtb"
  : > "$tmp/empty"
  echo "-- self-test: dry run on valid inputs prints the load command"
  "$0" --dry-run --kernel "$tmp/kernel" --initrd "$tmp/initrd" --dtb "$tmp/board.dtb" --append "console=test" | grep -q 'kexec -l' || fail "dry run did not print load command"
  echo "-- self-test: missing file rejected"
  if "$0" --dry-run --kernel "$tmp/nope" --initrd "$tmp/initrd" --dtb "$tmp/board.dtb" 2>/dev/null; then
    fail "missing kernel accepted"
  fi
  echo "-- self-test: bad DTB magic rejected"
  if "$0" --dry-run --kernel "$tmp/kernel" --initrd "$tmp/initrd" --dtb "$tmp/bad.dtb" 2>/dev/null; then
    fail "bad DTB accepted"
  fi
  echo "-- self-test: empty file rejected"
  if "$0" --dry-run --kernel "$tmp/empty" --initrd "$tmp/initrd" --dtb "$tmp/board.dtb" 2>/dev/null; then
    fail "empty kernel accepted"
  fi
  echo "-- self-test: unreadable file rejected with a clear message"
  if [ "$(id -u)" = "0" ]; then
    echo "note: running as root, readability check always passes; skipping"
  else
    chmod 000 "$tmp/kernel"
    "$0" --dry-run --kernel "$tmp/kernel" --initrd "$tmp/initrd" --dtb "$tmp/board.dtb" >"$tmp/sub.log" 2>&1 || true
    if grep -q "not readable" "$tmp/sub.log"; then
      echo "ok: unreadable kernel rejected"
    else
      echo "--- sub-run output was:"
      cat "$tmp/sub.log"
      fail "unreadable kernel accepted"
    fi
    chmod 644 "$tmp/kernel"
  fi
  echo "-- self-test: missing kexec binary rejected cleanly"
  if "$0" --confirm --kernel "$tmp/kernel" --initrd "$tmp/initrd" --dtb "$tmp/board.dtb" --append "console=test" --kexec-bin /nonexistent/kexec 2>/dev/null; then
    fail "missing kexec binary accepted"
  fi
  echo "KEXEC REHEARSAL SELF-TEST PASSED"
}

if [ "$SELF_TEST" -eq 1 ]; then
  run_self_test
  exit 0
fi

check_file "$KERNEL" kernel
check_file "$INITRD" initrd
check_file "$DTB" dtb
check_dtb_magic "$DTB"
if [ -z "$APPEND" ]; then
  APPEND=$(cat /proc/cmdline)
fi
echo "current booted system: $(readlink /run/booted-system 2>/dev/null || echo unknown)"
echo "this script never touches the bootloader (kexec only replaces the running kernel)"
echo "kexec -l --initrd=\"$INITRD\" --dtb=\"$DTB\" --append=\"$APPEND\" \"$KERNEL\""
if [ "$DRY_RUN" -eq 1 ]; then
  echo "dry run: load/exec NOT executed (pass --confirm to execute)"
  exit 0
fi
if [ -z "$KEXEC_BIN" ]; then
  KEXEC_BIN=$(command -v kexec) || KEXEC_BIN=""
fi
[ -n "$KEXEC_BIN" ] || fail "kexec not found (add pkgs.kexec-tools to systemPackages)"
[ -x "$KEXEC_BIN" ] || fail "kexec not executable: $KEXEC_BIN"
echo "ok: kexec $KEXEC_BIN"
echo "WARNING: executing kexec now; SSH will drop. Hang => power-cycle back to the bootloader default."
"$KEXEC_BIN" -l "--initrd=$INITRD" "--dtb=$DTB" "--append=$APPEND" "$KERNEL"
"$KEXEC_BIN" -e
