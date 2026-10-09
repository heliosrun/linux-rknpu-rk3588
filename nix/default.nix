{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.hardware.rknpu;
in
{
  options.hardware.rknpu = {
    enable = lib.mkEnableOption ''
      the Rockchip RKNPU NPU driver: an out-of-tree kernel module
      (vendor v0.9.8 ported to mainline) plus a device tree overlay
      enabling the vendor rknpu@fdab0000 node at 200 MHz. Mutually
      exclusive with the mainline rocket (accel) driver: the overlay also disables
      the rknn_core_* nodes.
    '';

    autoload = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Load rknpu during boot. Disable for initial headless bring-up
        to boot the overlay first and load the module manually after
        establishing remote access. This does not override module
        loading requested elsewhere in the host configuration.
      '';
    };

    npuClockHz = lib.mkOption {
      type = lib.types.ints.positive;
      default = 200000000;
      description = ''
        Target NPU compute-clock rate in Hz. Currently locked to
        200 MHz (the vendor POWER_DOWN_FREQ / safe GPLL bring-up
        rate): any other value is rejected by the assertion below until
        the REVIEW.md higher-frequency validation checklist is complete
        with hardware evidence (board-validated rail voltage, in-driver
        raise sequencing, park-to-200 on power-down).
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.npuClockHz == 200000000;
        message = ''
          hardware.rknpu.npuClockHz above 200 MHz is rejected: higher NPU
          rates require completing the REVIEW.md higher-frequency
          validation checklist with hardware evidence.
        '';
      }
    ];

    boot.extraModulePackages = [
      (config.boot.kernelPackages.callPackage ./package.nix { })
    ];

    boot.kernelModules = lib.optionals cfg.autoload [ "rknpu" ];

    # Bring-up test tools: npu-smoke-test (stage-1 checks), rknpu-test
    # (per-core fp16 matmul sweep), matmul_fp16_rocket (raw probe).
    environment.systemPackages = [
      (pkgs.callPackage ./test.nix { })
    ];

    hardware.deviceTree.overlays = [
      {
        name = "rknpu";
        # NOTE: filter is a plain SUBSTRING match in
        # apply_overlays.py, not a glob.
        filter = "rk3588";
        dtsFile = ./overlay.dts;
      }
    ];
  };
}
