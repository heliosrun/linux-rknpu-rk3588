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
At runtime the smoke test instead reads the configured rate back from
the live device tree (/proc/device-tree, a passive in-memory blob, no
firmware MMIO) and fails on any mismatch with EXPECTED_HZ (default
200 MHz): a wrong rate means the booted DTB is not the deployed
overlay. All system paths in the script are overridable for testing,
and `--self-test` covers the healthy, rate-mismatch, stale-DTB,
iommu-mode, and unbound-render-node cases.

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

## Higher-frequency acceptance protocol (600 MHz target)

Do not change the npuClockHz assertion until every gate below passes
with recorded evidence. Work in a scratch branch; the relaxation must
not reach pushed history before validation is complete.

Gate 0 - instrumentation. Serial console attached (USB-TTL on the debug
UART) and a known-good boot configuration retained. Identify the vdd_npu
readback path first (probe point or regulator interface): no rail
number, no frequency work.

Gate 1 - rail measurement. With the NPU idle at 200 MHz, record vdd_npu
at rest and under a matmul sweep. Reference points, not transferable
blindly: the OPi 5 Pro validates 300-700 MHz at 0.70 V and 800 MHz at
0.90 V. Proceed only if the measured CM3588 rail covers the target OPP
with margin. A fixed rail below the OPP voltage blocks frequency work
on hardware grounds, not software.

Gate 2 - build, never deploy. Relax the assertion locally, set npuClockHz
to the target, `nixos-rebuild build` only. Confirm the generated overlay,
DT checks, and installed smoke expectation all carry the new rate (the
option wiring makes this mechanical, not manual).

Gate 3 - kexec rehearsal. Dry-run, then `--confirm`, per the section
above. Any hang: power-cycle, record where the boot stopped from the
serial log, stop the protocol.

Gate 4 - validate under kexec. The smoke test must report the new rate;
run the full matmul sweep on every core mask and compare against the
200 MHz baselines. Tolerate only the documented lane-0 2^-16 divergences
per the RK3588 notes. Record SoC temperature throughout, against a 200
MHz thermal baseline taken first, so the delta is meaningful.

Gate 5 - power sequencing. Suspend/resume cycle, module unload/reload at
the new rate, and an idle gap long enough to trigger runtime suspend.
Confirm the clock returns to a safe state on every transition - this
driver stubs devfreq, so any failure here means implementing park-to-200
first, not waiving the gate.

Gate 6 - promote. Commit the assertion change together with the
measurement log (rail numbers, sweep results, thermals, serial logs of
every kexec boot). Switch with the rollback guard armed and no
cancellation marker; reboot in a maintenance window; touch the marker
only after the on-hardware gates repeat green.

Any gate that fails stops the protocol. Record the failure next to the
gate; do not skip gates.

## Validation limits

DT compilation/application and module compilation do not exercise
firmware MMIO or runtime PM. The implementation must pass both existing
CI builds and hardware validation before deployment. Source-level
checks are useful regression guards, not substitutes for those tests.

## OrangePi5Pro bug-class audit (source-level, no hardware)

The mack42/OrangePi5Pro RK3588 NPU stack fixed four bug classes on its
way to validated 800 MHz. Each was audited against this tree (DRM_GEM
build); three do not apply here, and the fourth was already fixed:

| Upstream fix | Status in this tree | Evidence |
|---|---|---|
| RKNPU_GET_VOLT ioctl NULL-deref on missing regulator | Already guarded | driver/rknpu_drv.c:443 returns ENODEV when vdd is NULL, with comment |
| volt debugfs NULL-deref | Already guarded | driver/rknpu_debugger.c:261 returns before regulator_get_voltage |
| CMA-heap probe failure (-ENOMEM, no BSP heap on mainline) | Not compiled | block lives under CONFIG_ROCKCHIP_RKNPU_DMA_HEAP (driver/rknpu_drv.c:1506); this build defines DRM_GEM only |
| fake_dev undeclared in DMA_HEAP builds | Not applicable | field declared under DRM_GEM (include/rknpu_drv.h:117) and registered at probe; their failure was DMA_HEAP-only |
| ioctl copy-back clobber (MEM_CREATE results overwritten) | Absent | w568w misc-handler pattern; no kdata copy-back block exists in this vendor source |
| unguarded regulator_get_voltage in rknpu_devfreq.c | Dead code | file excluded from Kbuild; the stub object is linked instead |

If this project ever builds DMA_HEAP for librknnrt, the heap-fatal
block and the fake_dev declaration must be revisited first, with the
mack42 patches as reference. Until then, no code change: this audit is
recorded so a future vendor re-sync can re-check each line.
