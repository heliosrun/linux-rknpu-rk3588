# Adversarial review: RKNPU v0.9.8 bring-up on mainline (RK3588)

Date: 2026-10-08. Reviewed against torvalds v7.2,
nixpkgs linux 7.2.9, armbian rk-6.1-rkr6.1 vendor source. Every claim
below was checked against the actual sources; file:line references are
to torvalds v7.2 unless noted. Cross-validated 2026-10-08 against
gregordinary/rockchip-npu-notes (independent HW measurements on
RK3588, rknpu 0.9.8) - see "External cross-validation" at the end.

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

## Headless rollback options (researched 2026-10-08)

The CM3588 production box is headless with no practical U-Boot menu
access, so "pick the old generation from the boot menu" is not an
available recovery path. Options checked against the NixOS wiki,
manual and community sources:

1. **Canary/confirmator rollback (recommended; deployed)** - the
   declarative rknpu-rollback timer in nixos-config. This is the
   manual equivalent of
   deploy-rs "magic rollback", which is a documented serokell
   feature: it connects after profile activation to confirm the
   machine is still reachable and instructs the node to roll back
   automatically otherwise. If remote deploys are ever adopted
   (deploy-rs/colmena), the guard becomes redundant - the tool
   provides it natively.
2. **nixos-rebuild test** (NixOS manual, "what happens during a
   system switch"): switch-to-configuration test activates a
   configuration on the RUNNING system without touching the boot
   loader. Safe live validation of the module and tools; cannot test
   the DTB (needs reboot).
3. **switch-to-configuration boot on an arbitrary generation link**
   (discourse): /nix/var/nix/profiles/system-N-link/bin/
   switch-to-configuration boot sets ANY past generation as the boot
   default, remotely, without switching. Useful to flip the default
   back to the old generation after a green test, or as the
   guard-rollback primitive (the guard uses the --rollback variant).
4. **kexec rehearsal** (discourse, benaryorg; nixos-anywhere ships a
   kexec test): kexec -l the new kernel+initrd (+ --dtb on arm64)
   from the built toplevel and kexec -e, WITHOUT touching the boot
   loader. If the test system hangs, power-cycling lands in the
   untouched bootloader default (old system). This is the only
   pattern that rehearses "does this kernel+DTB boot at all"
   headlessly. Caveats: verify kexec on the 7.2 kernel/arm64 first,
   and note it consumes kernel+initrd memory temporarily.
5. **systemd runtime watchdog** (systemd.runtimeWatchdogSec):
   catches runtime hangs after deploy, not pre-systemd boot hangs.
6. **Out-of-band management** (discourse thread caveat): PiKVM/
   IPMI-class devices remove the headless constraint entirely - the
   only full solution to a pre-systemd boot failure.

Applicability to this deploy: the guard (1) covers boots-but-broken;
(2) and (4) shrink the residual "does not boot at all" risk by
rehearsing kexec and module-loadability before the reboot; (5) and
(6) are hardening beyond this change's scope. The DTB delta is
NPU-leaf-nodes only and the kernel binary is unchanged, so the
residual risk is small - but (6) is the only complete answer.

## Deploy runbook for the production CM3588 (headless)

Safety properties: the kernel binary is unchanged (out-of-tree module
vs stock nixpkgs 7.2.9), overlay application is at build time, the
running system is untouched until reboot, and the declarative guard
auto-rolls back 15 minutes after boot unless cancelled. NixOS
generations (configurationLimit = 3) keep the old system bootable.

Stage 0 - deploy (on the box, in a window where an unplanned reboot
is acceptable):

    sudo nixos-rebuild switch > /tmp/rknpu-switch.log 2>&1
    sudo modprobe rknpu && sudo rmmod rknpu   # loadability check; the
        # running DTB has no vendor node yet, so the probe is a no-op
    sudo reboot

Stage 1 - smoke (after reboot; the guard timer is ticking):

    npu-smoke-test

Checks: render node bound to RKNPU, /dev/rknpu, dmesg "using iommu
mode", IOMMU group holds exactly the rknpu device, clock lines.
Failure map: "non-iommu mode" = overlay not applied; no render node =
probe failed (read dmesg). If SSH is dead, the guard reverts at +15
min automatically.

Stage 2 - compute gate:

    rknpu-test

Ten fp16 matmul runs (tiny 4x32x16, large 64x256x256) pinned to core
0, 1, 2 individually, then all cores. This is the Finding-1
discriminator: unprogrammed MMUs show up here as failures on cores
0/1. Exit 0 + "ALL RKNPU TESTS PASSED" required.

Then cancel the guard and commit the marker:

    sudo touch /etc/rknpu-guard-cancelled

Stage 3 - soak:

Multi-core jobs in a loop + dmesg -w watching for rk_iommu_irq page
faults; a sleep/wake cycle (Finding 1 residual); confirm vdd_npu
>= 0.70 V before trusting 600 MHz results. Only after all of this:
re-enable the immich ML container with /dev/dri mapped.

Stage 4 - raise to 600 MHz:

Edit assigned-clock-rates in nix/overlay.dts (600000000 -> keep, or
drop to 200000000 if stage 2 showed instability), rebuild, reboot,
re-run rknpu-test. Keep the guard pattern if cautious.

Cleanup after full validation:

    # remove rknpuDeploy.guard.enable + the guard module import from
    # cm3588.nix, then: sudo rm /etc/rknpu-guard-cancelled

Rollback at any point before cancelling: the guard does it
automatically at +15 min; manually via
`sudo /run/current-system/sw/bin/nixos-rebuild switch --rollback`.
Rollback after cancelling (i.e. days later, NPU suspected bad):
`sudo /nix/var/nix/profiles/system-<old>-link/bin/switch-to-configuration
boot && sudo reboot` (find <old> with
`ls -d /nix/var/nix/profiles/system-*-link`).

Optional rehearsal (shrinks the residual "does not boot at all"
risk): kexec the built toplevel before ever rebooting - see the
headless rollback options section above.

## External cross-validation (rockchip-npu-notes, 2026-10-08)

Independent HW measurements on RK3588 with rknpu 0.9.8 confirm or
sharpen three of the above claims (all tags below are theirs):

- Single shared domain CONFIRMED: "maps every buffer through one
  IOMMU domain" [HW sweep]. This is the foundation Finding 1 rests
  on. No statement there contradicts the 4-window single-device
  model; their focus is the rocket path (per-core nodes, per-fd
  windows - explicitly "a property of rocket, not of the silicon").
- Clock CONFIRMED: scmi_clk_npu "boots pinned at 200 MHz (vendor
  POWER_DOWN_FREQ). Raising it to 600 MHz is worth ~1.43x" [HW
  sweep]. Our assigned-clock-rates approach targets the same end
  state as their in-driver raise.
- Voltage SHARPENS item 1: "Firmware does not couple voltage to
  frequency. The BL31 SCMI clock path programs only the PLL"
  [firmware behavior]. Vendor f->V map: 300-700 MHz needs 0.70 V
  (800->0.75, 900->0.80, 1000->0.85). Their board rail sits at
  0.80 V. Concrete check for the CM3588: confirm vdd_npu >= 0.70 V
  (BSP OPP minima are 0.775 V, so this is expected to pass). Their
  voltage-holding patch pattern (hold the regulator for device
  lifetime, scale with the clock from runtime-PM hooks) is the
  template if we ever need more than fixed-clock.
- NEW, immich-relevant: the shared domain budget is ~3.9 GB and the
  generic mapping path LEAKS it (persists until reboot). Flag bit 10
  RKNPU_MEM_IOMMU_LIMIT_IOVA_ALIGNMENT (>=0.9.7; our 0.9.8 honors
  it) avoids the leak; their provider sets it by default. If immich
  exhausts IOVA over days of uptime, check whether librknnrt sets
  this flag before suspecting the kernel - the fix would be
  userspace-side.
- Consistency note: their keep-attached finding (~20 us/submit saved
  on rocket) is moot here - the vendor driver never detaches (our
  stubbed switch path included), so we get keep-attached by default.
