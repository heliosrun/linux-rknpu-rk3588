{
  description =
    "Rockchip RKNPU v0.9.8 NPU driver, ported to mainline kernels";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      # aarch64-linux only: the driver is RK35xx-specific.
      system = "aarch64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      kernel = pkgs.linuxPackages_latest.kernel.override (args: {
        kernelPatches = (args.kernelPatches or [ ]) ++ [
          (import ./nix/kernel-patch.nix { inherit (pkgs) lib; })
        ];
      });
      kernelPackages = pkgs.linuxPackagesFor kernel;
    in
    {
      packages.${system} = {
        rknpu = kernelPackages.callPackage ./nix/package.nix { };

        # Bring-up test tools (compile anywhere, run on RK3588 HW only).
        rknpu-test = pkgs.callPackage ./nix/test.nix { };

        default = self.packages.${system}.rknpu;
      };

      # Validates nix/overlay.dts against the pinned nixpkgs kernel DTBs
      # using the same gating NixOS apply_overlays.py uses (substring
      # filter + root-compatible intersection), then asserts node states.
      checks.${system} = {
        device-tree = pkgs.callPackage ./nix/check-dt.nix {
          inherit kernel;
        };
      };

      # Consume from a NixOS host:
      #   imports = [ linux-rknpu-rk3588.nixosModules.rknpu ];
      #   hardware.rknpu.enable = true;
      nixosModules.rknpu = import ./nix;
    };
}
