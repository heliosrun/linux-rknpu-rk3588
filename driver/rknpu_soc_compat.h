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

struct opp_table;

/*
 * Minimal stand-ins for the vendor soc/rockchip OPP/monitor framework
 * (rockchip_opp_select.h et al.).
 *
 * NOTE: none of this is compiled today. The only consumer would be
 * rknpu_devfreq.c, which is EXCLUDED from both the in-tree and the
 * out-of-tree builds (see rknpu_devfreq_stub.c instead). These types
 * and stubs exist so a future DVFS port has the shapes ready, and so
 * struct rknpu_device (which embeds struct rockchip_opp_info) lays
 * out identically if devfreq support is ever re-enabled. The live
 * devfreq contract is the six no-op rknpu_devfreq_*() definitions in
 * rknpu_devfreq_stub.c, whose return-0 semantics are REQUIRED: the
 * driver calls pm_runtime_get_sync() on itself during power-on, so a
 * -EOPNOTSUPP from the runtime callbacks would fail probe.
 */
struct rockchip_opp_info {
	const struct rockchip_opp_data *data;
	struct clk *clk;
	struct clk_bulk_data *clks;
	struct clk_bulk_data *clocks;
	int nclocks;
	int num_clks;
	struct clk *scmi_clk;
	struct regmap *grf;
	const void *volt_rm_tbl;
	int bin;
	int volt_sel;
	u32 supported_hw[2];
	u32 current_rm;
	u32 target_rm;
	bool is_rate_volt_checked;
	bool is_runtime_active;
};

struct rockchip_opp_data {
	int (*set_read_margin)(struct device *dev,
			 struct rockchip_opp_info *opp_info, u32 rm);
	int (*set_soc_info)(struct device *dev, struct device_node *np,
			struct rockchip_opp_info *opp_info);
	int (*get_soc_info)(struct device *dev, struct device_node *np,
			int *bin, int *process);
	int (*config_regulators)(struct device *dev,
				 struct dev_pm_opp *old_opp,
				 struct dev_pm_opp *new_opp,
				 struct regulator **regulators,
				 unsigned int count,
				 struct rockchip_opp_info *opp_info);
	int (*config_clks)(struct device *dev, struct opp_table *opp_table,
			 struct dev_pm_opp *opp, void *data,
			 bool scaling_down,
			 struct rockchip_opp_info *opp_info);
	bool is_use_pvtpll;
};

#define MONITOR_TYPE_DEV 0

struct monitor_dev_profile {
	int type;
	int (*low_temp_adjust)(void *data);
	int (*high_temp_adjust)(void *data);
	int (*check_rate_volt)(void *data);
	void *data;
	struct rockchip_opp_info *opp_info;
	bool is_checked;
};

static inline void rockchip_get_opp_data(const struct of_device_id *match,
					 struct rockchip_opp_info *info)
{
	(void)match;
	(void)info;
}

static inline int rockchip_init_opp_table(struct device *dev,
					  struct rockchip_opp_info *info,
					  const char *clk_name,
					  const char *name)
{
	(void)dev;
	(void)info;
	(void)clk_name;
	(void)name;
	return -ENODEV;
}

static inline int rockchip_opp_config_regulators(
	struct device *dev, struct dev_pm_opp *old_opp,
	struct dev_pm_opp *new_opp, struct regulator **regulators,
	unsigned int count, struct rockchip_opp_info *info)
{
	(void)dev;
	(void)old_opp;
	(void)new_opp;
	(void)regulators;
	(void)count;
	(void)info;
	return 0;
}

static inline int rockchip_opp_config_clks(
	struct device *dev, struct opp_table *opp_table,
	struct dev_pm_opp *opp, void *data, bool scaling_down,
	struct rockchip_opp_info *info)
{
	(void)dev;
	(void)opp_table;
	(void)opp;
	(void)data;
	(void)scaling_down;
	(void)info;
	return 0;
}

static inline int rockchip_opp_set_low_length(
	struct device *dev, struct device_node *np,
	struct rockchip_opp_info *info)
{
	(void)dev;
	(void)np;
	(void)info;
	return 0;
}

static inline bool rockchip_opp_is_use_pvtpll(
	struct rockchip_opp_info *info)
{
	(void)info;
	return false;
}

static inline void rockchip_get_read_margin(
	struct device *dev, struct rockchip_opp_info *info,
	unsigned long u_volt, u32 *target_rm)
{
	(void)dev;
	(void)info;
	(void)u_volt;
	(void)target_rm;
}

static inline void rockchip_set_read_margin(
	struct device *dev, struct rockchip_opp_info *info, u32 rm,
	bool is_set_rm)
{
	(void)dev;
	(void)info;
	(void)rm;
	(void)is_set_rm;
}

static inline int rockchip_monitor_dev_low_temp_adjust(void *data)
{
	(void)data;
	return 0;
}

static inline int rockchip_monitor_dev_high_temp_adjust(void *data)
{
	(void)data;
	return 0;
}

static inline int rockchip_monitor_check_rate_volt(void *data)
{
	(void)data;
	return 0;
}

static inline void rockchip_monitor_volt_adjust_lock(void *mdev)
{
	(void)mdev;
}

static inline void rockchip_monitor_volt_adjust_unlock(void *mdev)
{
	(void)mdev;
}

static inline void *rockchip_system_monitor_register(
	struct device *dev, struct monitor_dev_profile *profile)
{
	(void)dev;
	(void)profile;
	return ERR_PTR(-ENODEV);
}

/*
 * Vendor rockchip_iommu_is_enabled(dev) reports whether the IOMMU is
 * enabled for @dev (nonzero = enabled). It is polled during power-off to
 * wait for the IOMMU to quiesce.
 *
 * Mainline consolidated rockchip-iommu into a single C file with no shared
 * header, so there is no equivalent to call. This stub reports "disabled",
 * which lets the power-off path proceed immediately.
 *
 * HARDWARE REVIEW: on the board, verify power-off sequencing cannot race an
 * in-flight NPU job. If it can, replace this with a real status read of the
 * MMU status register for the attached IOMMUs.
 */
static inline u32 rockchip_iommu_is_enabled(struct device *dev)
{
	(void)dev;
	return 0;
}

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
