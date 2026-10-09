# linux-rknpu-rk3588

GPL-2.0 Rockchip RKNPU NPU driver (vendor **v0.9.8**, from
[armbian/linux-rockchip rk-6.1-rkr6.1](https://github.com/armbian/linux-rockchip/tree/82c6b3ef1c935064d4aa87f698412fdc37a4435f/drivers/rknpu)
at pinned commit `82c6b3e` (2026-03-04), byte-identical to
rockchip-linux develop-6.1), ported to mainline kernels (verified
against 7.2). No vendor blobs: kernel source only.

Reviewing the port against its source:

- [Port diff, driver only (GitHub compare)](https://github.com/heliosrun/linux-rknpu-rk3588/compare/vendor/v0.9.8...diff/vendor-v0.9.8) -
  every `driver/` change vs pristine vendor, file by file. The
  `vendor/v0.9.8` branch holds the unmodified source; `diff/vendor-v0.9.8`
  contains only `main`'s `driver/` subtree while retaining the vendor
  history, so unrelated repo files stay out of the compare.
  Refresh it with `scripts/update-vendor-diff.sh --push` after `driver/`
  moves; CI does this automatically on `main`.
- Locally: `git diff vendor/v0.9.8...diff/vendor-v0.9.8 -- driver/`
  after fetching both branches.

## Layout

| path | purpose |
| --- | --- |
| driver/ | the ported driver source, buildable out-of-tree |
| nix/ | nix packaging: module derivation, NixOS module, DT overlay |
| linux-integration/ | in-tree wiring reference (Kconfig, Makefile, vendor DT nodes) |
| scripts/ | CI build steps and vendor-diff updater as runnable scripts |
| .github/workflows/ | CI: out-of-tree build vs pristine torvalds tag + nix build |

## What the port changes (vs vendor v0.9.8)

- 7.x API drift: drm_driver date / gem_prime_mmap removed, void platform
  remove, MODULE_IMPORT_NS string literal, hrtimer_setup(), gfp
  iommu_map/iommu_map_sg, sg_dma_is_bus_address, raw-pfn
  vmf_insert_mixed, iommu_paging_domain_alloc, inline IOVA cookie
  replication.
- Vendor soc/rockchip OPP/monitor helpers replaced by stubs
  (driver/rknpu_soc_compat.h): fixed 200 MHz bring-up, no DVFS.
  Higher rates require power-domain/voltage sequencing and a return
  to 200 MHz before power-down; the stubs do not implement that.
- rknpu_devfreq.o replaced by rknpu_devfreq_stub.o; rknpu_mem.o
  (DMA_HEAP) and rknpu_mm.o (SRAM) excluded.
- DT: vendor rknpu@fdab0000 node is mutually exclusive with the
  mainline rocket (accel) cores (same MMIO). The nix overlay
  (nix/overlay.dts) disables rocket and its per-core IOMMUs, and
  creates the vendor node at 200 MHz without an `iommus` property.
  This uses physical DMA without NPU DMA isolation.

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

## Headless bring-up

For the first boot, set `hardware.rknpu.autoload = false`. This
installs the module and the 200 MHz overlay without explicitly loading
RKNPU at boot. Ensure the host does not request the module elsewhere.
Once SSH is available, run as root:

```sh
modprobe rknpu
npu-smoke-test
rknpu-test
```

The required device is the RKNPU `/dev/dri/renderD*` node. `/dev/rknpu`
is optional in this DRM/GEM-only build. A voltage query returns
`ENODEV` when the board's rail is managed by genpd rather than a
regulator acquired by the driver.

**Do not raise `assigned-clock-rates` above 200 MHz.** Linux applies
clock defaults before domain attachment and driver probe; programming
the NPU-local PVTPLL while its island is off can hang secure firmware.
DT compilation and a successful module load against an old DTB do not
validate this sequence. See [REVIEW.md](REVIEW.md) for source references
and the remaining hardware validation requirements.

A systemd rollback timer cannot recover a firmware hang. Have UART,
recovery media, or another independently tested recovery path before
rebooting a headless production board. A warm kexec is not proof of
cold-boot safety. After validation, restore `hardware.rknpu.autoload`
to its default (`true`) if automatic loading is wanted.

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
