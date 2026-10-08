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
    in
    {
      packages.${system} = {
        rknpu = pkgs.linuxPackages_latest.callPackage ./nix/package.nix { };
        default = self.packages.${system}.rknpu;
      };

      # Validates nix/overlay.dts against the pinned nixpkgs kernel DTBs
      # using the same gating NixOS apply_overlays.py uses (substring
      # filter + root-compatible intersection), then asserts node states.
      checks.${system} = {
        device-tree = pkgs.callPackage ./nix/check-dt.nix {
          kernel = pkgs.linuxPackages_latest.kernel;
        };
      };

      # Consume from a NixOS host:
      #   imports = [ linux-rknpu-rk3588.nixosModules.rknpu ];
      #   hardware.rknpu.enable = true;
      nixosModules.rknpu = import ./nix;
    };
}
