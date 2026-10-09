# RKNPU bring-up review: clock and power sequencing

This review describes the conservative bring-up changes in the source.
It is not a claim that this revision has been booted or tested on the
production CM3588. The deployed DTB, BL31 build, and a boot trace are
still needed to establish the exact historical failure.

## Critical: a 600 MHz DT clock default can hang boot

Linux v7.2's `platform_probe()` applies `of_clk_set_defaults()` before
`dev_pm_domain_attach()` and before calling the driver's probe:

```
platform_probe()
  of_clk_set_defaults()      # applies assigned-clock-rates
  dev_pm_domain_attach()
  rknpu_probe()
    attach the NPU domains
    rknpu_power_on()
```

Sources:

- [Linux v7.2 platform probe ordering](https://github.com/torvalds/linux/blob/v7.2/drivers/base/platform.c#L1429-L1440)
- [Linux v7.2 clock-default implementation](https://github.com/torvalds/linux/blob/v7.2/drivers/clk/clk-conf.c)
- [TF-A v2.12.0 RK3588 NPU clock implementation](https://github.com/ARM-software/arm-trusted-firmware/blob/v2.12.0/plat/rockchip/rk3588/drivers/scmi/rk3588_clk.c#L1044-L1090)
- [Independent RK3588 clock/power hardware observations](https://github.com/gregordinary/rockchip-npu-notes/blob/main/perf/clock.md#raising-the-clock-on-an-unpowered-domain)

TF-A's rate table uses the GPLL path at 200 MHz. At 600 MHz,
`clk_npu_set_rate()` instead writes PVTPLL registers through
`NPUGRF_BASE`, inside the NPU island. Programming that clock with the
island off can wedge secure firmware in the SCMI/SMC call. This can
happen before `rknpu_probe()` logs anything, and is not an ordinary
probe failure that merely leaves the NPU unavailable.

The overlay now requests **200 MHz**, and both DT checks assert that
value. The in-tree reference uses the same safe default. The actual
production firmware's implementation must still be checked; the
TF-A source is evidence of the mechanism, not proof of which binary
the board runs.

### Removing devfreq also removed required power-down handling

The build links `rknpu_devfreq_stub.o`, not `rknpu_devfreq.o`. The
vendor implementation parks the SCMI clock at `POWER_DOWN_FREQ`
(200 MHz) during runtime suspend and restores its operating rate
once powered. The stub callbacks do neither.

Probe itself powers the NPU down before returning. Consequently,
raising the clock just once in probe would not solve the complete
problem: the next power-up could occur with an unsafe clock source.

Higher rates remain unsupported by this fixed-rate port. Before
adding them, implement and validate all of the following:

1. Power the required domains at the safe boot rate.
2. Establish a board-validated voltage before raising frequency.
3. Raise the shared clock only while its required islands are on.
4. Return to 200 MHz before domain power-down, including error paths,
   remove, shutdown, and system-sleep transitions.
5. Serialize shared-clock changes against jobs and domain transitions.

Do not implement higher-rate operation by changing
`assigned-clock-rates` in either DT file.

## Other implemented corrections

### Power-domain failures

Every required named attachment in multi-domain mode must return a
valid virtual device. Errors, including `-EPROBE_DEFER`, now propagate
instead of being ignored; NULL attachments fail with `-ENODEV`.
Partially attached domains are detached and runtime PM is disabled
on the relevant probe error paths.

Power-up uses `pm_runtime_resume_and_get()` to normalize successful
returns and balance failed gets. Failures unwind the domains,
clocks, and regulators already acquired. A failed `rknpu_power_get()`
also rolls back its private reference count, and callers do not
submit ioctls or query clocks after a failed resume.

### Optional regulator queries

On upstream CM3588, the parent NPU domain has
`domain-supply = <&vdd_npu_s0>`:

- [Linux v7.2 CM3588 board include](https://github.com/torvalds/linux/blob/v7.2/arch/arm64/boot/dts/rockchip/rk3588-friendlyelec-cm3588.dtsi)
- [Linux v7.2 Rockchip power-domain implementation](https://github.com/torvalds/linux/blob/v7.2/drivers/pmdomain/rockchip/pm-domains.c)

Thus the rail can be controlled by genpd without an `rknpu-supply`
on the vendor node. The driver's optional `vdd` pointer is then
NULL. The voltage ioctl and debugfs reader now return `-ENODEV`
instead of passing NULL to `regulator_get_voltage()`. Other regulator
read errors also propagate without being converted to unsigned
voltage values. This does not add voltage scaling or duplicate the
power-domain regulator consumer.

### Smoke-test contract

Kbuild enables DRM/GEM and excludes DMA_HEAP. The required userspace
interface is a character device at `/dev/dri/renderD*` bound to
`RKNPU`. `/dev/rknpu` is informational only: it is a misc device in
DMA_HEAP builds or a host-provided compatibility symlink.

The overlay deliberately omits `iommus` and disables the rocket cores
and their MMUs. Non-IOMMU mode is therefore expected; it provides no
NPU DMA isolation. Restoring IOMMU support requires a separate topology,
clock, and power-sequencing review.

The smoke test no longer reads global `clk_summary`. That reads all
clock rates, potentially causing firmware to access powered-off
PVTPLL islands. It is not a passive or universally safe diagnostic.
The DT build checks verify the configured rate, not hardware readback.

## Headless validation and recovery

1. Prepare an independently tested recovery path (UART, recovery media,
   or out-of-band access) and retain a known-good boot configuration.
2. Rebuild the module and DT checks against the consuming kernel.
   Inspect the resulting CM3588 DTB: vendor node at 200 MHz, no
   `iommus`, rocket cores and MMUs disabled. Confirm the deployed
   bootloader actually selects that DTB.
3. Set `hardware.rknpu.autoload = false` for the first boot. This
   suppresses this module's explicit boot load; remove any separate
   host configuration that also requests RKNPU. The package and
   overlay remain installed.
4. Cold-boot the corrected DTB. Establish SSH before manually loading
   `rknpu`, with remote logging available. A load against the old DTB
   with no vendor node checks linking, not hardware probe safety.
5. Run `npu-smoke-test` and `rknpu-test`. The runner performs eight
   checks: two shapes on each of three cores and on all cores.
6. Validate idle power-down, later resume, and module unload/reload at
   200 MHz. Test system sleep only with a reliable recovery path.
7. Enable normal NPU workloads and autoload only after those gates pass.

A systemd rollback timer can help with a running but broken system;
it cannot guarantee recovery from an EL3/SCMI firmware hang. This repo
does not install a rollback timer. Warm kexec preserves hardware state
and is not evidence that the same DTB is safe on a cold boot.

## Kexec rehearsal (mandatory before any switch+reboot)

`scripts/kexec-rehearsal.sh` boots a freshly built generation without
touching the bootloader: build with `nixos-rebuild build` (never switch),
dry-run the script against the result's kernel/initrd/board DTB, then
run with `--confirm`. If the kexec'd kernel hangs, power-cycle: the boot
loader still points at the known-good generation. Green kexec boot plus
passing smoke/matmul gates is the precondition for switch+reboot; it
replaces the old runbook's direct reboot step entirely.

## Validation limits

DT compilation/application and module compilation do not exercise
firmware MMIO or runtime PM. The implementation must pass both existing
CI builds and hardware validation before deployment. Source-level
checks are useful regression guards, not substitutes for those tests.
