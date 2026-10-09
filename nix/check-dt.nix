{
  lib,
  stdenv,
  kernel,
  dtc,
  python3,
}:

stdenv.mkDerivation {
  pname = "rknpu-dt-check";
  version = "0.9.8";

  # No unpack: the overlay is referenced straight from the flake source.
  dontUnpack = true;

  nativeBuildInputs = [ dtc python3 ];

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
    python3 ${../scripts/check-applied-dt.py} "$OUT" "$DTBS/$BOARD"
    python3 ${../scripts/test-dt-check.py} "$OUT" "$DTBS/$BOARD" ${../scripts/check-applied-dt.py}

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
