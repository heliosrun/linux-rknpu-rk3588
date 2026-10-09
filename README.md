# linux-rknpu-rk3588

GPL-2.0 Rockchip RKNPU NPU driver (vendor **v0.9.8**, from
[armbian/linux-rockchip rk-6.1-rkr6.1](https://github.com/armbian/linux-rockchip/tree/82c6b3ef1c935064d4aa87f698412fdc37a4435f/drivers/rknpu)
at pinned commit `82c6b3e` (2026-03-04), byte-identical to
rockchip-linux develop-6.1), ported to mainline kernels (verified
against 7.2). No vendor blobs: kernel source only.

Reviewing the port against its source:

- [Port diff, driver only (GitHub compare)](https://github.com/heliosrun/linux-rknpu-rk3588/compare/vendor/v0.9.8...diff/vendor-v0.9.8#files_bucket) -
  every `driver/` change vs pristine vendor, file by file. The
  `vendor/v0.9.8` branch holds the unmodified source; `diff/vendor-v0.9.8`
  contains only `main`'s `driver/` subtree while retaining the vendor
  history, so unrelated repo files stay out of the compare.
  Refresh it with `scripts/update-vendor-diff.sh --push` after `driver/`
  moves; CI does this automatically on `main`.
- Locally: `git diff vendor/v0.9.8...diff/vendor-v0.9.8 -- driver/`
  after fetching both branches.

## Layout

| path               | purpose                                                       |
| ------------------ | ------------------------------------------------------------- |
| driver/            | the ported driver source, buildable out-of-tree               |
| nix/               | nix packaging: module derivation, NixOS module, DT overlay    |
| linux-integration/ | in-tree wiring reference (Kconfig, Makefile, vendor DT nodes) |
| scripts/           | CI build steps and vendor-diff updater as runnable scripts    |
| .github/workflows/ | CI: out-of-tree build vs IOMMU-patched torvalds tag + nix build    |

## What the port changes (vs vendor v0.9.8)

- 7.x API drift: drm_driver date / gem_prime_mmap removed, void platform
  remove, MODULE_IMPORT_NS string literal, hrtimer_setup(), gfp
  iommu_map/iommu_map_sg, sg_dma_is_bus_address, raw-pfn
  vmf_insert_mixed, iommu_paging_domain_alloc, inline IOVA cookie
  replication.
- Vendor OPP/monitor helpers replaced with mainline OPP/devfreq. The default
  performance governor selects the highest point supported by the board's
  regulator and SCMI firmware, up to **1 GHz at 950 mV**. Firmware rate rounding
  filters unsupported points. Thermal cooling starts at 85 °C.
- The powered driver parks the shared clock at **200 MHz** before releasing
  domains or clocks, then restores the workload OPP after power-up. Failed
  parking retains power and reports an error.
- A companion `rockchip-iommu` kernel patch supplies six bus clocks and three
  runtime-PM domain links to one four-bank IOMMU. Every NPU core shares the same
  DMA page table. This requires rebuilding the consuming kernel.
- The overlay replaces `rknn_core_0` in place, retaining the board's NPU supply,
  and disables the other rocket cores and standalone MMUs. Clock assignment
  is zero (skip early SCMI programming); the driver sets rates while powered.
- `rknpu_mem.o` (DMA_HEAP) and `rknpu_mm.o` (SRAM) remain excluded.

The voltage table follows the linked Orange Pi implementation with conservative
voltage margins. It is **not CM3588 hardware validation** or a replacement for
Rockchip's silicon-bin/read-margin/temperature calibration. See [REVIEW.md](REVIEW.md)
for source evidence and the remaining cold-boot and lifecycle tests.

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
installs the patched kernel, module and OPP/IOMMU overlay without explicitly loading
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

**Keep `assigned-clock-rates = <0>`.** The zero tells Linux to skip the early
rate change; it does not request a zero-Hz clock. Only the powered driver may
program the NPU-local PVTPLL. Its normal idle, remove and shutdown paths park
at 200 MHz. An unsafe clock-recovery failure deliberately retains physical
references and requires recovery rather than continuing power-down.

The powered debugfs reader at `/sys/kernel/debug/rknpu/freq` reports the current
rate. Writing an exact DT OPP there (or using `RKNPU_SET_FREQ`) sets the standard
devfreq userspace ceiling; thermal limits can select a lower rate. Normal
devfreq `max_freq`/`governor` controls are also available. Never read the global
`clk_summary` to inspect powered-off SCMI islands.

A systemd rollback timer cannot recover a firmware hang. Have UART,
recovery media, or another independently tested recovery path before
rebooting a headless production board. A warm kexec is not proof of
cold-boot safety. After validation, restore `hardware.rknpu.autoload`
to its default (`true`) if automatic loading is wanted.

## Building manually

```sh
scripts/build-kernel.sh <kernel-tree> <jobs>
scripts/build-module.sh <kernel-tree> "$PWD/driver" <jobs>
scripts/check-dt-overlay.sh <kernel-tree> "$PWD/nix/overlay.dts" <jobs>
```

Set `CROSS_COMPILE=aarch64-linux-gnu-` when building on x86_64. The kernel
script applies `linux-integration/rk3588-npu-iommu.patch` and enables the
performance governor and thermal devfreq support. A fully built matching
kernel (`Module.symvers`) is required for the module link. NixOS and the flake
build apply the same patch automatically. An unpatched kernel cannot bind the
new dedicated IOMMU compatible, so the NPU probe defers rather than touching
unpowered MMU banks.

For an existing built kernel, apply the patch with
`scripts/apply-kernel-patches.sh <kernel-tree>`, enable PM/devfreq, OPP,
`DEVFREQ_GOV_PERFORMANCE` and `DEVFREQ_THERMAL`, and rebuild it before linking
and deploying the module. The DT validator checks the shared IOMMU, board
supply, OPP voltages and thermal wiring; five regression tests reject unsafe
DT mutations.

## Bumping to a future kernel release

1. Bump KERNEL_REF in .github/workflows/build.yml and the nixpkgs pin
   in flake.nix.
2. Green CI = out-of-tree build + overlay apply verified against that
   tag plus the companion IOMMU patch. Fix-ups land in driver/rknpu_soc_compat.h (vendor helper drift)
   and the Kbuild ccflags (config symbol drift).
3. For in-tree builds, re-apply linux-integration/ on the new tree and
   refresh the rk3588-base.dtsi node block if the upstream file moved.

CI runs are path-filtered: docs-only pushes skip both workflows.
