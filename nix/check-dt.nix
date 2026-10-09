{
  lib,
  stdenv,
  kernel,
  dtc,
}:

stdenv.mkDerivation {
  pname = "rknpu-dt-check";
  version = "0.9.8";

  # No unpack: the overlay is referenced straight from the flake source.
  dontUnpack = true;

  nativeBuildInputs = [ dtc ];

  buildCommand = ''
    set -euo pipefail
    INC=${kernel.dev}/lib/modules/${kernel.modDirVersion}/source/scripts/dtc/include-prefixes
    DTBS=${kernel}/dtbs/rockchip
    OVERLAY=${./overlay.dts}
    FILTER=rk3588
    BOARD=rk3588-friendlyelec-cm3588-nas.dtb

    ls "$DTBS"/rk3588*.dtb > /dev/null

    # Same preprocessing + flags as NixOS compileDTS.
    $CC -E -nostdinc -I"$INC" -undef -D__DTS__ -x assembler-with-cpp \
      "$OVERLAY" -o overlay-pp.dts
    dtc -@ -I dts -O dtb -o rknpu.dtbo overlay-pp.dts

    OVERLAY_COMPAT=$(fdtget rknpu.dtbo / compatible)
    echo "overlay root compatible: $OVERLAY_COMPAT"
    [ -n "$OVERLAY_COMPAT" ] || { echo "FAIL: overlay has no root compatible"; exit 1; }

    applied=0
    for dtb in "$DTBS"/rk3588*.dtb; do
      base=$(basename "$dtb")
      # Gate 1 replicates apply_overlays.py: substring filter.
      case "$base" in
        *"$FILTER"*) ;;
        *) echo "skip $base: filter"; continue ;;
      esac
      # Gate 2 replicates apply_overlays.py: root compatible intersection.
      base_compats=$(fdtget "$dtb" / compatible)
      case " $base_compats " in
        *" $OVERLAY_COMPAT "*) ;;
        *) echo "skip $base: incompatible ($base_compats)"; continue ;;
      esac
      fdtoverlay -i "$dtb" -o "applied-$base" rknpu.dtbo
      echo "applied to $base"
      applied=$((applied + 1))
    done
    [ "$applied" -gt 0 ] || { echo "FAIL: overlay applied to zero DTBs"; exit 1; }

    # Full node-state assertions on the production board DTB.
    OUT=applied-$BOARD
    check() {
      got=$(fdtget "$OUT" "$1" "$2")
      if [ "$got" != "$3" ]; then
        echo "FAIL: check failed"
        exit 1
      fi
      echo "ok: $1 $2 = $got"
    }
    check /rknpu@fdab0000 status okay
    check /rknpu@fdab0000 compatible rockchip,rk3588-rknpu
    # Clock defaults are applied with the NPU domains still off.
    check /rknpu@fdab0000 assigned-clock-rates 200000000
    # Non-IOMMU mode: the node must have NO iommus property and the
    # merged mmu device must not exist (the mainline rockchip-iommu
    # driver cannot drive the 4-window device - see overlay.dts).
    if fdtget "$OUT" /rknpu@fdab0000 iommus >/dev/null 2>&1; then
      echo "FAIL: iommus present but non-iommu mode expected"; exit 1
    fi
    echo "ok: /rknpu@fdab0000 has no iommus (non-iommu mode)"
    if fdtget "$OUT" /rknpu-mmu@fdab9000 status >/dev/null 2>&1; then
      echo "FAIL: merged rknpu-mmu node exists"; exit 1
    fi
    echo "ok: no merged rknpu-mmu node"
    check /npu@fdab0000 status disabled
    check /npu@fdac0000 status disabled
    check /npu@fdad0000 status disabled
    check /iommu@fdab9000 status disabled
    check /iommu@fdaca000 status disabled
    check /iommu@fdada000 status disabled
    echo "ALL DT CHECKS PASSED"

    mkdir -p $out
    cp "$OUT" $out/board-applied.dtb
    cp rknpu.dtbo $out/
  '';

  meta = {
    description = "Validate the RKNPU device tree overlay against nixpkgs kernel DTBs";
    license = lib.licenses.gpl2Only;
    platforms = [ "aarch64-linux" ];
  };
}
