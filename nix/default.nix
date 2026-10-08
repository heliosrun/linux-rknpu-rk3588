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
      enabling the vendor npu@fdab0000 node. Mutually exclusive with
      the mainline rocket (accel) driver: the overlay also disables
      the rknn_core_* nodes.
    '';
  };

  config = lib.mkIf cfg.enable {
    boot.extraModulePackages = [
      (config.boot.kernelPackages.callPackage ./package.nix { })
    ];

    boot.kernelModules = [ "rknpu" ];

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
