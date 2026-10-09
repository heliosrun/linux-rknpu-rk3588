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

        # Bring-up test tools (compile anywhere, run on RK3588 HW only).
        rknpu-test = pkgs.callPackage ./nix/test.nix { };

        default = self.packages.${system}.rknpu;
      };

      # Validates nix/overlay.dts.in against the pinned nixpkgs kernel DTBs
      # using the same gating NixOS apply_overlays.py uses (substring
      # filter + root-compatible intersection), then asserts node states.
      checks.${system} = {
        device-tree = pkgs.callPackage ./nix/check-dt.nix {
          kernel = pkgs.linuxPackages_latest.kernel;
        };
        # Proves the NixOS module actually wires hardware.rknpu.npuClockHz
        # into the generated overlay. Plain flake evaluation never
        # instantiates the module for a host, so this evaluates a minimal
        # test system and greps the generated file: substituted 200 MHz
        # present, no placeholder left behind.
        module-overlay =
          let
            testSystem = nixpkgs.lib.nixosSystem {
              system = system;
              modules = [
                self.nixosModules.rknpu
                { hardware.rknpu.enable = true; }
              ];
            };
            overlayFile = (builtins.head
              testSystem.config.hardware.deviceTree.overlays).dtsFile;
          in
          pkgs.runCommand "rknpu-overlay-wiring-check" { } ''
            if ! grep -q "assigned-clock-rates = <200000000>;" ${overlayFile}; then
              echo "FAIL: generated overlay lacks substituted 200 MHz rate"
              exit 1
            fi
            if grep -q "@NPU_CLOCK_HZ@" ${overlayFile}; then
              echo "FAIL: unsubstituted placeholder left in overlay"
              exit 1
            fi
            echo "ok: module generates 200 MHz overlay from npuClockHz"
            touch $out
          '';
      };

      # Consume from a NixOS host:
      #   imports = [ linux-rknpu-rk3588.nixosModules.rknpu ];
      #   hardware.rknpu.enable = true;
      nixosModules.rknpu = import ./nix;
    };
}
