// SPDX-License-Identifier: GPL-2.0
/*
 * Stub definitions for the rknpu_devfreq_* entry points declared in
 * include/rknpu_devfreq.h under CONFIG_PM_DEVFREQ.
 *
 * The real implementations live in rknpu_devfreq.o, which depends on the
 * vendor Rockchip OPP/monitor framework (rockchip_get_opp_data,
 * rockchip_init_opp_table, struct rockchip_opp_info handling) that has no
 * mainline equivalent. Porting DVFS is future work; until then the driver
 * runs at a fixed clock.
 *
 * Failure semantics (match the header's own !PM_DEVFREQ fallbacks where
 * they exist): init fails -> probe ignores the return value and continues
 * without devfreq -> runtime/lock paths operate on the zeroed state and
 * no-op. Verified against every call site in rknpu_drv.c / rknpu_debugger.c.
 */

#include "include/rknpu_drv.h"
#include "include/rknpu_devfreq.h"

int rknpu_devfreq_init(struct rknpu_device *rknpu_dev)
{
	(void)rknpu_dev;
	return -ENODEV;
}

void rknpu_devfreq_remove(struct rknpu_device *rknpu_dev)
{
	(void)rknpu_dev;
}

void rknpu_devfreq_lock(struct rknpu_device *rknpu_dev)
{
	(void)rknpu_dev;
}

void rknpu_devfreq_unlock(struct rknpu_device *rknpu_dev)
{
	(void)rknpu_dev;
}

int rknpu_devfreq_runtime_suspend(struct device *dev)
{
	(void)dev;
	return 0;
}

int rknpu_devfreq_runtime_resume(struct device *dev)
{
	(void)dev;
	return 0;
}
