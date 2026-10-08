# Adversarial review: RKNPU v0.9.8 bring-up on mainline (RK3588)

Date: 2026-10-08. Reviewed against torvalds v7.2,
nixpkgs linux 7.2.9, armbian rk-6.1-rkr6.1 vendor source. Every claim
below was checked against the actual sources; file:line references are
to torvalds v7.2 unless noted.

## Finding 1 (HIGH, fixed): wrong IOMMU topology in the DT overlay

The shipped overlay enabled three separate per-core IOMMU nodes
(rknn_mmu_0/1/2) and listed all three in the vendor node's iommus.
On mainline that programs exactly ONE of the three MMUs:

- of_iommu_configure (drivers/iommu/of_iommu.c) calls rk_iommu_of_xlate
  once per phandle, in order. That function unconditionally overwrites
  dev_iommu_priv_set() - so the private pointer ends up at the LAST
  entry (mmu2).
- device_group is generic_single_device_group, which returns the
  singleton group of that same (last) instance.
- The default DMA domain therefore attaches to exactly one MMU
  (rk_iommu_attach_device follows the same private pointer).

The driver's whole runtime mapping path (rknpu_iommu_dma_map_sg ->
iommu_get_domain_for_dev -> iommu_map_sg on that domain) lands in one
set of page tables. Cores 0 and 1 would run with unprogrammed MMUs:
page faults at best, silent wrong-address DMA at worst, depending on
the block's reset state. With core_mask 0x7 the scheduler uses all
three cores, so most jobs would fail - after a completely
healthy-looking probe (rknpu_is_iommu_enable only checks DT
availability).

Fix applied: single rknpu-mmu@fdab9000 device with all four register
windows (BSP layout), iommus = <&rknpu_mmu>. Mainline rockchip-iommu
binds it via the rk3568-iommu compatible, counts num_mmu = 4 from the
resources, and its enable/disable loops program every window.
dma_bit_mask for the v2 ops is 40-bit, matching the driver.

Clocks on that node are deliberately ABSENT. Mainline rockchip-iommu
bulk-gets exactly "aclk"/"iface"; any other name set fails probe with
-EINVAL (a missing clock name resolves to -EINVAL in
of_parse_clkspec, not the tolerated -ENOENT), while a missing clocks
property is tolerated (num_clocks = 0). Probe, attach
(pm_runtime_get_if_in_use returns 0 while suspended: records the
domain, touches no registers) and all runtime register writes are
therefore sequenced by the NPU driver itself, which enables its own 8
clocks (the same physical gates) in rknpu_power_on BEFORE its
pm_runtime_get_sync() can trigger the mmu resume that programs the
DTEs. Verified by reading the call order in rknpu_drv.c.

Residual: system-sleep suspend ordering (mmu rk_iommu_disable writes
vs NPU clock disable) is untested. Test a sleep/wake cycle on
hardware; headless servers rarely sleep, so this is noted, not
blocking.

## Finding 2 (MEDIUM, fixed): NixOS overlay never applied

hardware.deviceTree.overlays silently skipped ours for two independent
reasons (pkgs/os-specific/linux/device-tree/apply_overlays.py):

1. filter is a plain SUBSTRING check, not a glob: "rk3588*.dtb"
   never matches. (The documented "*rpi*.dtb" example cannot match
   either.)
2. Overlays whose own root has no compatible fail the
   compatible-intersection check and are skipped.

Fix applied: root "/ { compatible = "rockchip,rk3588"; }" in the
plugin (overlay-root properties are metadata, never merged into the
base), filter = "rk3588". Verified by building
hardware.deviceTree.package for cm3588 and reading back every node
with fdtget.

## Finding 3 (LOW, fixed): dead-code comment in rknpu_soc_compat.h

The OPP/monitor stub block claimed to "satisfy the real call sites in
rknpu_devfreq.c" - but that file is excluded from every build; the six
rknpu_devfreq_*() symbols come from rknpu_devfreq_stub.c. Comment
corrected. Live compat surface is only the nvmem reader and the
iommu-enabled poll stub, both used by rknpu_drv.c.

## Verified safe (checked, no change needed)

- Allocator locking: alloc_iova/alloc_iova_fast take iova_rbtree_lock
  internally, so the driver's private allocations from the shared
  default-domain iovad cannot race the DMA core.
- Stub returns 0, not -EOPNOTSUPP: REQUIRED, not just safe.
  rknpu_power_on calls pm_runtime_get_sync() on itself, which invokes
  the driver's own runtime_resume callback; an error return there
  would fail probe. (The vendor's own !PM_DEVFREQ inline returning
  -EOPNOTSUPP would break this flow - in BSP, devfreq is always on,
  so it never bites there.)
- Power-off poll stub (rockchip_iommu_is_enabled -> 0):
  readx_poll_timeout exits immediately and power-off proceeds. Safe
  because power-off only runs at refcount 0 after the 3 s quiesce
  delay - no in-flight DMA can exist. Downgraded from hardware-review
  to documented.
- Cookie layout: mainline struct iommu_dma_cookie keeps iovad first
  (verified in-tree). The cast in rknpu_iommu_dma_alloc_iova is
  therefore correct - but it depends on a mainline-private layout
  with no compile-time check possible (opaque forward declaration).
  On every kernel bump, manually confirm iovad is still first in
  drivers/iommu/dma-iommu.c. CI compiles against the new tree but
  cannot catch a silent layout move.
- nvmem reader: of_nvmem_cell_get / nvmem_cell_read / kfree ordering
  correct; callers fall back to safe defaults.
- vmf_insert_mixed raw pfn: correct for the pages[] path (real struct
  pages get proper refcounted insertion); the PFN_DEV device-memory
  branches are in version-gated dead code on 7.x.
- Kbuild -D defines match the object list exactly
  (DRM_GEM/FENCE/DEBUG_FS on; DMA_HEAP/SRAM/PROC_FS off). Proven by
  the clean link (zero warnings) on two different kernel configs
  (7.2.0 defconfig, 7.2.9 nixpkgs).
- Vermagic: out-of-tree builds against the consuming kernel give exact
  matches both ways (GHA 7.2.0 on v7.2 tag; nix 7.2.9 on the running
  kernel). The 7.2.0 artifact will NOT load on 7.2.9 - deploy only
  the nix-built module.
- CI caching: kernel-source cache keyed on KERNEL_REF, ccache keyed on
  driver hash with prefix restore-keys (a driver-only change reuses
  the warm kernel cache: full run 3m35s). Source cache strips .git
  (runner-specific git-mirror alternates broke kbuild's git calls);
  make all (not make modules) feeds modpost correctly; dtbs need
  DTC_FLAGS="-@" for the label-based overlay check.
- boot.kernelModules = [ "rknpu" ] is host-scoped (cm3588 only); a
  probe failure logs but cannot break boot.

## Open items (hardware or owner decisions)

1. 600 MHz assigned-clock-rates: sets rate only; nothing sets the NPU
   rail voltage (no OPP stack). The BSP default is 200 MHz. If the
   CM3588 rail boots below what 600 MHz needs, expect silent compute
   errors, not clean failures. Validate on the board (known-checksum
   inference batch); drop to 200 MHz in nix/overlay.dts until then if
   you want the conservative bring-up.
2. PRIME mmap dispatch: the 7.2 drm_driver has no .gem_prime_mmap slot
   anymore; rknpu_gem_prime_mmap is now unreferenced dead code. Prime
   import/export still wires up, and the fault handler is intact, but
   confirm the rknn userspace mmap path on hardware.
3. Source drift: nixos-config/modules/rknpu/src is a vendored copy of
   driver/. Consider making nixos-config consume this repo
   (inputs.rknpu.url = "github:heliosrun/linux-rknpu-rk3588",
   imports = [ rknpu.nixosModules.rknpu ]) once the private-repo fetch
   story for the cm3588 is confirmed.
4. flake.lock is now committed (auto-generated on first nix eval).
   Keep it pinned and bump deliberately via `nix flake lock
   --update-input nixpkgs` when port-verifying a new kernel.
5. NO_GKI-guarded code (init_domain/switch_domain, the 7.2 cookie
   replication there) never compiles on mainline. Kept as
   future-proofing, but if it rots, delete it rather than maintain
   dead code - the live port surface is the common wrappers plus the
   struct layout.

## Hardware bring-up checklist (in order)

1. Deploy, check dmesg for "rknpu iommu is enabled, using iommu mode".
2. ls /sys/kernel/iommu_groups/*/devices | grep fdab - expect the
   rknpu device in a group whose .../iommu_devices lists ONLY the
   rknpu-mmu device (not three separate ones).
3. Single-core inference (mask to core 2, then 0, then 1) with known
   checksums before enabling all three.
4. Multi-core soak + dmesg watch for rk_iommu_irq page faults.
5. Sleep/wake cycle (see Finding 1 residual).
6. Then raise to 600 MHz (see item 1) with checksum validation.
