# RK3588 RKNPU: 1 GHz OPPs and shared IOMMU

This implementation has build and merged-DT validation, not CM3588 hardware
validation. A deployed BL31 binary, cold-boot trace and workload/lifecycle
results are still required. Firmware source establishes supported operations;
it does not establish which firmware a particular board runs.

## Firmware maximum and clock sequencing

TF-A **v2.12.0**, commit `4ec2948fe3f65dba2f19e691e702f7de2949179c`, defines
RK3588's NPU clock data in C rather than a firmware device tree:

- [NPU PVTPLL table](https://github.com/ARM-software/arm-trusted-firmware/blob/4ec2948fe3f65dba2f19e691e702f7de2949179c/plat/rockchip/rk3588/drivers/scmi/rk3588_clk.c#L245):
  200 through **1000 MHz**; 1 GHz uses ring select 1 and length 12.
- [NPU rate programming](https://github.com/ARM-software/arm-trusted-firmware/blob/4ec2948fe3f65dba2f19e691e702f7de2949179c/plat/rockchip/rk3588/drivers/scmi/rk3588_clk.c#L1044):
  200 MHz uses GPLL; higher rates write the NPU-local PVTPLL via NPU GRF.
- [SCMI clock registration](https://github.com/ARM-software/arm-trusted-firmware/blob/4ec2948fe3f65dba2f19e691e702f7de2949179c/plat/rockchip/rk3588/drivers/scmi/rk3588_clk.c#L2347):
  the NPU exposes the shared 200 MHz–1 GHz rate list. Low-bit flags in the
  final table entry do not advertise an overclock above 1 GHz.

Linux applies DT clock defaults before power-domain attachment and driver
probe. The overlay therefore uses `assigned-clock-rates = <0>` to skip early
SCMI rate programming, including a later rebind. Zero is not a zero-Hz rate.
The driver parks at 200 MHz only after all domains and clocks are available.

The complete clock bulk includes all three cores' ACLK/HCLK gates and
`PCLK_NPU_ROOT`, `PCLK_NPU_GRF`, the NPU PVTM clocks and `HCLK_NPU_ROOT`.
These remain enabled across every frequency change. The supplied Orange Pi
reference demonstrates why merely changing a boot-time clock default is not
sufficient:

- [Reference overlay and OPPs](https://github.com/ULTIMATE215/OrangePi5Plus/blob/ac58828d78fcfdcda4674ec6201e985fb26a99e7/npu-patches/rk3588-rknpu-mc-4bank.dts)
- [Reference devfreq implementation](https://github.com/ULTIMATE215/OrangePi5Plus/blob/ac58828d78fcfdcda4674ec6201e985fb26a99e7/npu-patches/rknpu_devfreq.c)
- [Reference pre-bind domain/clock pins](https://github.com/ULTIMATE215/OrangePi5Plus/blob/ac58828d78fcfdcda4674ec6201e985fb26a99e7/npu-patches/rknpu-multicore.patch)

## Voltage and mainline OPP/devfreq

The overlay reuses the original core0 node at `/npu@fdab0000`, preserving the
board's `npu-supply` and `sram-supply` phandles. On CM3588 the rail is
`vdd_npu_s0`, capped at **950000 microvolts** by the upstream board DT. The
power domain also holds a consumer of that same regulator.

The OPP table uses conservative reference voltages: 200/300/400 MHz at
800 mV, then 825/850/875/900/925/950 mV at 500/600/700/800/900/1000 MHz.
The OPP framework rejects points unsupported by the board's regulator, and
the driver disables points that SCMI would round to a different rate. The
performance governor selects the maximum remaining point, up to 1 GHz.
Voltage is raised before frequency and lowered after frequency.

These voltages were reported working on an Orange Pi 5 Plus. They are **not**
a CM3588 qualification result. The mainline port does not reproduce BSP
silicon-bin selection, voltage-dependent memory read margins or
low-temperature voltage calibration. Those remain hardware validation risks.

A devfreq cooling device is connected to the NPU thermal zone, with a passive
85 °C trip and 5 °C hysteresis. The upstream 115 °C critical trip remains.
Cooling and userspace `max_freq` limits bound the performance governor.
Debugfs frequency writes and `RKNPU_SET_FREQ` accept exact supported OPPs and
set the userspace ceiling; they cannot override thermal QoS constraints.

## Complete power lifecycle

The workload frequency is stored separately from the physical parked rate:

1. Enable regulator/clock references and resume all core domains.
2. Restore the remembered OPP while powered, then allow work.
3. On idle, force the physical clock to 200 MHz before lowering voltage.
4. Update the OPP core to the parking point, then release its regulator
   reference. This prevents its cached OPP from skipping a later restore.
5. Release runtime-PM, domain, ordinary-clock and driver regulator references.

The frequency mutex serializes devfreq changes with runtime suspend/resume.
QoS changes while powered off only change the remembered workload rate; they
perform no clock or regulator accesses. A failed OPP transition blocks new
power acquisitions until a successful parking/recovery cycle. Resume failures
attempt parking before unwinding. A failed park returns an error and retains
physical power/clock references; probe/remove cleanup deliberately retains
those references if recovery also fails. This can leak references and require
recovery, but does not intentionally power down an unsafe PVTPLL island.

Remove powers down before removing devfreq. System sleep rejects outstanding
jobs, balances its temporary PM reference, and restores frequency before
releasing that reference on resume. Shutdown prevents new power acquisitions,
waits for jobs to drain, and parks before teardown. A shutdown timeout retains
power after attempting to park. These paths require physical-board tests;
returning an error cannot recover an already wedged SCMI firmware call.

## Four-bank IOMMU supplier dependencies

One logical translation device covers:

| Bank | Core | Register window |
| --- | --- | --- |
| 0 | 0 | `0xfdab9000` |
| 1 | 0 | `0xfdaba000` |
| 2 | 1 | `0xfdaca000` |
| 3 | 2 | `0xfdada000` |

A single `iommus` phandle maps all cores through one DMA page table. Three
separate phandles would bind the mainline driver's last translation device
and leave other cores outside that mapping. The driver rejects unsupported
RK3588 IOMMU topologies instead of silently permitting multicore DMA.

`linux-integration/rk3588-npu-iommu.patch` adds a dedicated
`rockchip,rk3588-rknpu-iommu` compatible. Its supplier gets all six bus clocks
and attaches all three domains with runtime-PM device links. Supplier resume
can run **before** the RKNPU probe; its own links power every bank in that
case. Its own clocks cover register/IRQ/TLB operations. Supplier suspend may
complete asynchronously after the consumer releases a reference, but its
links keep the domains powered until its MMU register accesses finish.
No RKNPU module-init domain pins or separate housekeeping-clock module are
used. An unpatched kernel cannot bind this compatible, preventing an unsafe
fallback to the stock two-clock supplier.

The NPU register mappings end at `0x9000`, before the MMU windows. Other rocket
cores and standalone MMUs are disabled. NixOS and flake builds apply the
companion patch and required kernel configuration; manual builds must rebuild
the patched kernel, not just replace `rknpu.ko`.

## Validation and remaining board gates

Build validation must cover the patched kernel and linked ARM64 module.
Merged-DT checks assert the clock default, voltage points, four MMU windows,
shared phandle, six MMU clocks, three domains, board supplies and thermal map.
Five negative regression tests reject unsafe tree mutations.

Before deployment, retain a known-good kernel/DTB and independent recovery:

1. Confirm the actual BL31/SCMI firmware and supported rate list, regulator
   limits and cooling. Use `hardware.rknpu.autoload = false` initially.
2. Cold-boot the matching patched kernel and overlay, establish SSH, then
   manually load the module. A load without the new DT does not test probe.
3. Run `npu-smoke-test`, then all eight `rknpu-test` cases (two shapes on
   each core and on all cores) at the selected maximum and lower ceilings.
4. Exercise repeated idle power-off/resume, unload/reload, shutdown/reboot,
   system sleep, thermal throttling, and injected clock/regulator errors.
5. Validate NPU memory correctness and IOMMU faults on every core; measure
   voltage, temperature and stability at 1 GHz across operating conditions.

Do not read global `clk_summary`: it can query powered-off PVTPLL islands.
The driver's debugfs frequency reader explicitly powers the NPU first. UART,
recovery media or another independent recovery path is necessary for hardware
bring-up; a software rollback timer cannot recover an EL3/SCMI hang. Warm
kexec is not evidence of cold-boot safety. Enable autoload after these gates.
