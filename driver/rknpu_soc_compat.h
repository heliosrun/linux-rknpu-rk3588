/* SPDX-License-Identifier: GPL-2.0 */
/*
 * Minimal replacements for vendor-only soc/rockchip helpers.
 * Each entry is flagged for review against real RK3588 hardware behavior.
 */

#ifndef __RKNPU_SOC_COMPAT_H
#define __RKNPU_SOC_COMPAT_H

#include <linux/clk.h>
#include <linux/device.h>
#include <linux/err.h>
#include <linux/nvmem-consumer.h>
#include <linux/of.h>
#include <linux/pm_opp.h>
#include <linux/regmap.h>
#include <linux/regulator/consumer.h>
#include <linux/slab.h>
#include <linux/types.h>

/*
 * Vendor rockchip_nvmem_cell_read_u8(np, cell, val): read one byte from a
 * named nvmem cell. Implemented on the mainline nvmem consumer API; returns
 * 0 on success with *val filled, negative errno otherwise (the caller
 * falls back to a safe default core mask on error).
 */
static inline int rockchip_nvmem_cell_read_u8(struct device_node *np,
					      const char *cell_id, u8 *val)
{
	struct nvmem_cell *cell;
	void *buf;
	size_t len;

	cell = of_nvmem_cell_get(np, cell_id);
	if (IS_ERR(cell))
		return PTR_ERR(cell);
	buf = nvmem_cell_read(cell, &len);
	nvmem_cell_put(cell);
	if (IS_ERR(buf))
		return PTR_ERR(buf);
	if (len < 1) {
		kfree(buf);
		return -EINVAL;
	}
	*val = ((u8 *)buf)[0];
	kfree(buf);
	return 0;
}

#endif /* __RKNPU_SOC_COMPAT_H */
