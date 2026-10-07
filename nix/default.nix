{
  config,
  lib,
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

    hardware.deviceTree.overlays = [
      {
        name = "rknpu";
        filter = "rk3588*.dtb";
        dtsFile = ./overlay.dts;
      }
    ];
  };
}
