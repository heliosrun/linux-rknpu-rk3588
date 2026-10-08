# linux-rknpu-rk3588

GPL-2.0 Rockchip RKNPU NPU driver (vendor **v0.9.8**, from
[armbian/linux-rockchip rk-6.1-rkr6.1](https://github.com/armbian/linux-rockchip/tree/rk-6.1-rkr6.1/drivers/rknpu),
byte-identical to rockchip-linux develop-6.1), ported to mainline
kernels (verified against 7.2). No vendor blobs: kernel source only.

## Layout

| path | purpose |
| --- | --- |
| driver/ | the ported driver source, buildable out-of-tree |
| nix/ | nix packaging: module derivation, NixOS module, DT overlay |
| linux-integration/ | in-tree wiring reference (Kconfig, Makefile, vendor DT nodes) |
| .github/workflows/ | CI: out-of-tree build vs pristine torvalds tag + nix build |

## What the port changes (vs vendor v0.9.8)

- 7.x API drift: drm_driver date / gem_prime_mmap removed, void platform
  remove, MODULE_IMPORT_NS string literal, hrtimer_setup(), gfp
  iommu_map/iommu_map_sg, sg_dma_is_bus_address, raw-pfn
  vmf_insert_mixed, iommu_paging_domain_alloc, inline IOVA cookie
  replication.
- Vendor soc/rockchip OPP/monitor helpers replaced by failsafe stubs
  (driver/rknpu_soc_compat.h): fixed-clock mode, no DVFS. OPP/DVFS
  bring-up is future work.
- rknpu_devfreq.o replaced by rknpu_devfreq_stub.o; rknpu_mem.o
  (DMA_HEAP) and rknpu_mm.o (SRAM) excluded.
- DT: vendor rknpu@fdab0000 node is mutually exclusive with the
  mainline rocket (accel) cores (same MMIO). The nix overlay
  (nix/overlay.dts) disables rocket, enables the per-core IOMMUs
  (mainline rockchip-iommu binds them, all three merge into one IOMMU
  group sharing a default DMA domain) and creates the node at 600 MHz
  (BSP default is 200 MHz).

## NixOS

    {
      inputs.rknpu.url = "github:heliosrun/linux-rknpu-rk3588";
      outputs = { self, nixpkgs, rknpu, ... }: {
        nixosConfigurations.cm3588 = nixpkgs.lib.nixosSystem {
          modules = [ rknpu.nixosModules.rknpu { hardware.rknpu.enable = true; } ];
        };
      };
    }

The module builds out-of-tree against config.boot.kernelPackages, so
vermagic matches whichever kernel the host uses.

## Building manually

    make -C <kernel-tree> ARCH=arm64 O=<build-dir> M="$PWD/driver" modules

Requires a fully built kernel tree (Module.symvers). The nix
derivation handles this via kernel.dev.

## Bumping to a future kernel release

1. Bump KERNEL_REF in .github/workflows/build.yml and the nixpkgs pin
   in flake.nix.
2. Green CI = out-of-tree build + overlay apply verified against that
   tag. Fix-ups land in driver/rknpu_soc_compat.h (vendor helper drift)
   and the Kbuild ccflags (config symbol drift).
3. For in-tree builds, re-apply linux-integration/ on the new tree and
   refresh the rk3588-base.dtsi node block if the upstream file moved.

CI runs are path-filtered: docs-only pushes skip both workflows.
