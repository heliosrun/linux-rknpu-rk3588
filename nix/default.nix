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
      enabling a four-bank IOMMU and up to 1 GHz operation. Mutually
      exclusive with the mainline rocket (accel) driver: the overlay replaces
      core0 and disables the other rocket cores.
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
  };

  config = lib.mkIf cfg.enable {
    boot.kernelPatches = [ (import ./kernel-patch.nix { inherit lib; }) ];

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
