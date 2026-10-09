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
        Device-tree default NPU compute-clock rate in Hz, applied cold
        at bind time by of_clk_set_defaults. It must therefore stay at
        a cold-safe value, currently locked to 200 MHz (the vendor
        POWER_DOWN_FREQ / safe GPLL bring-up rate). A higher
        *operating* rate belongs to a future driver-managed raise path
        (raise only while powered, park-to-200 on power-down), never to
        this option: programming an unsafe rate here would reintroduce
        cold programming of the NPU-local PVTPLL. See REVIEW.md.
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
      # The installed smoke test's expected rate follows the gated
      # option, so a future unlocked rate flows through automatically.
      (pkgs.callPackage ./test.nix { expectedHz = cfg.npuClockHz; })
    ];

    hardware.deviceTree.overlays = [
      {
        name = "rknpu";
        # NOTE: filter is a plain SUBSTRING match in
        # apply_overlays.py, not a glob.
        filter = "rk3588";
        # The rate is the gated hardware.rknpu.npuClockHz option
        # (locked to 200 MHz by the assertion above until the
        # REVIEW.md validation is complete with hardware evidence).
        dtsFile = pkgs.writeText "rknpu-overlay.dts" (builtins.replaceStrings
          [ "@NPU_CLOCK_HZ@" ] [ (toString cfg.npuClockHz) ]
          (builtins.readFile ./overlay.dts.in));
      }
    ];
  };
}
