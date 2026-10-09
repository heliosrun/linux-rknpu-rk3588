// SPDX-License-Identifier: GPL-2.0
/* Mainline OPP/devfreq support. SCMI PVTPLL access requires powered domains
 * and the complete NPU housekeeping clock bulk, owned by rknpu_power_on().
 */
#include <linux/clk.h>
#include <linux/devfreq.h>
#include <linux/devfreq_cooling.h>
#include <linux/pm_qos.h>
#include <linux/of.h>
#include <linux/pm_opp.h>

#include "rknpu_drv.h"
#include "rknpu_devfreq.h"

#define RKNPU_PARK_RATE 200000000UL
#define RKNPU_MAX_RATE 1000000000UL

/* freq_lock serializes every clock change with runtime suspend/resume.
 * Requests while off only update the remembered workload rate. In particular,
 * devfreq QoS/thermal notifiers must never access an unpowered PVTPLL.
 */
static int rknpu_target(struct device *dev, unsigned long *freq, u32 flags)
{
	struct rknpu_device *rknpu = dev_get_drvdata(dev);
	struct dev_pm_opp *opp;
	int ret = 0;

	opp = devfreq_recommended_opp(dev, freq, flags);
	if (IS_ERR(opp))
		return PTR_ERR(opp);
	dev_pm_opp_put(opp);
	if (*freq > RKNPU_MAX_RATE)
		return -EINVAL;

	mutex_lock(&rknpu->freq_lock);
	if (rknpu->frequency_fault) {
		ret = -EIO;
		goto out;
	}
	if (rknpu->frequency_active) {
		ret = dev_pm_opp_set_rate(dev, *freq);
		if (ret)
			WRITE_ONCE(rknpu->frequency_fault, true);
	}
	if (!ret)
		rknpu->current_freq = *freq;
out:
	mutex_unlock(&rknpu->freq_lock);
	return ret;
}

static int rknpu_get_cur_freq(struct device *dev, unsigned long *freq)
{
	struct rknpu_device *rknpu = dev_get_drvdata(dev);

	*freq = READ_ONCE(rknpu->current_freq);
	return 0;
}

int rknpu_devfreq_init(struct rknpu_device *rknpu)
{
	static const char * const clocks[] = { "clk_npu", NULL };
	static const char * const supplies[] = { "npu", NULL };
	struct dev_pm_opp_config config = {
		.clk_names = clocks,
		.regulator_names = supplies,
	};
	struct device *dev = rknpu->dev;
	struct dev_pm_opp *opp;
	unsigned long freq = ULONG_MAX;
	int ret;

	/* Older bring-up DTs retain their fixed 200 MHz behavior. Never invent
	 * voltage points or silently continue after an invalid supplied table.
	 */
	if (!of_find_property(dev->of_node, "operating-points-v2", NULL))
		return 0;

	ret = devm_pm_opp_set_config(dev, &config);
	if (ret)
		return dev_err_probe(dev, ret, "failed to configure NPU clock/supply\n");
	ret = devm_pm_opp_of_add_table(dev);
	if (ret)
		return dev_err_probe(dev, ret, "failed to load NPU OPP table\n");

	/* SCMI describes the firmware's rate set. Drop DT points that the
	 * installed firmware would round: never advertise 1 GHz while the
	 * clock provider silently programs a lower rate.
	 */
	for (freq = 0; ; freq++) {
		opp = dev_pm_opp_find_freq_ceil(dev, &freq);
		if (IS_ERR(opp)) {
			if (PTR_ERR(opp) != -ERANGE)
				return PTR_ERR(opp);
			break;
		}
		dev_pm_opp_put(opp);
		if (freq > RKNPU_MAX_RATE)
			return -EINVAL;
		if (clk_round_rate(rknpu->clks[0].clk, freq) != freq) {
			ret = dev_pm_opp_disable(dev, freq);
			if (ret)
				return ret;
		}
	}
	freq = ULONG_MAX;
	opp = dev_pm_opp_find_freq_floor(dev, &freq);
	if (IS_ERR(opp))
		return PTR_ERR(opp);
	dev_pm_opp_put(opp);
	if (freq > RKNPU_MAX_RATE)
		return -EINVAL;

	/* Parking is an actual OPP, so the OPP core's cached state agrees with
	 * the hardware before the workload OPP is restored on the next resume.
	 */
	freq = RKNPU_PARK_RATE;
	opp = dev_pm_opp_find_freq_exact(dev, freq, true);
	if (IS_ERR(opp))
		return PTR_ERR(opp);
	dev_pm_opp_put(opp);

	rknpu->opp_ready = true;
	rknpu->devfreq_profile.initial_freq = RKNPU_PARK_RATE;
	rknpu->devfreq_profile.target = rknpu_target;
	rknpu->devfreq_profile.get_cur_freq = rknpu_get_cur_freq;
	rknpu->current_freq = RKNPU_PARK_RATE;
	rknpu->devfreq = devm_devfreq_add_device(dev, &rknpu->devfreq_profile,
						DEVFREQ_GOV_PERFORMANCE, NULL);
	if (IS_ERR(rknpu->devfreq)) {
		ret = PTR_ERR(rknpu->devfreq);
		rknpu->devfreq = NULL;
		return dev_err_probe(dev, ret, "failed to register NPU devfreq\n");
	}
	if (of_find_property(dev->of_node, "#cooling-cells", NULL)) {
		rknpu->devfreq_cooling = of_devfreq_cooling_register(dev->of_node,
								 rknpu->devfreq);
		if (IS_ERR(rknpu->devfreq_cooling)) {
			ret = PTR_ERR(rknpu->devfreq_cooling);
			rknpu->devfreq_cooling = NULL;
			return dev_err_probe(dev, ret, "failed to register NPU cooling\n");
		}
	}
	dev_info(dev, "NPU OPP/devfreq enabled, workload rate %lu Hz\n",
		 rknpu->current_freq);
	return 0;
}

void rknpu_devfreq_remove(struct rknpu_device *rknpu)
{
	if (rknpu->devfreq_cooling) {
		devfreq_cooling_unregister(rknpu->devfreq_cooling);
		rknpu->devfreq_cooling = NULL;
	}
	if (rknpu->devfreq) {
		devm_devfreq_remove_device(rknpu->dev, rknpu->devfreq);
		rknpu->devfreq = NULL;
	}
}

int rknpu_devfreq_set_rate(struct rknpu_device *rknpu, unsigned long freq)
{
	struct devfreq *df = rknpu->devfreq;
	struct dev_pm_opp *opp;
	int ret;

	if (!df)
		return -EOPNOTSUPP;
	/* Accept only exact DT OPPs; no rounding to an unexpected voltage. */
	opp = dev_pm_opp_find_freq_exact(rknpu->dev, freq, true);
	if (IS_ERR(opp))
		return PTR_ERR(opp);
	dev_pm_opp_put(opp);
	/* Set the standard userspace ceiling. Performance selects it unless
	 * another QoS client (for example thermal cooling) imposes a lower cap.
	 * The notifier takes df->lock, so do not hold it across the QoS update.
	 */
	ret = dev_pm_qos_update_request(&df->user_max_freq_req, freq / 1000);
	if (ret < 0)
		return ret;
	mutex_lock(&df->lock);
	ret = update_devfreq(df);
	mutex_unlock(&df->lock);
	return ret;
}

int rknpu_devfreq_runtime_suspend(struct device *dev)
{
	struct rknpu_device *rknpu = dev_get_drvdata(dev);
	int ret;

	mutex_lock(&rknpu->freq_lock);
	/* Force the physical park even after a partially failed OPP change:
	 * the OPP core may still cache the old 200 MHz point and skip it.
	 * Voltage may only fall AFTER this clock operation succeeds.
	 */
	ret = clk_set_rate(rknpu->clks[0].clk, RKNPU_PARK_RATE);
	if (!ret && rknpu->opp_ready)
		ret = dev_pm_opp_set_rate(dev, RKNPU_PARK_RATE);
	if (ret) {
		/* Returning an error keeps the runtime-PM device active. Its
		 * caller must retain its domain/clock references as well.
		 */
		WRITE_ONCE(rknpu->frequency_fault, true);
		dev_err(dev, "cannot park NPU clock; retaining power: %d\n", ret);
		goto out;
	}
	if (rknpu->opp_ready) {
		ret = dev_pm_opp_set_rate(dev, 0);
		if (ret)
			goto out;
	}
	rknpu->frequency_active = false;
	WRITE_ONCE(rknpu->frequency_fault, false);
out:
	mutex_unlock(&rknpu->freq_lock);
	return ret;
}

int rknpu_devfreq_runtime_resume(struct device *dev)
{
	struct rknpu_device *rknpu = dev_get_drvdata(dev);
	int ret, park_ret;

	mutex_lock(&rknpu->freq_lock);
	if (rknpu->opp_ready)
		ret = dev_pm_opp_set_rate(dev, rknpu->current_freq);
	else
		ret = clk_set_rate(rknpu->clks[0].clk, RKNPU_PARK_RATE);
	if (!ret) {
		rknpu->frequency_active = true;
		goto out;
	}
	/* A failed raise may have partially changed the clock. Park before
	 * power_on unwinds. If even parking fails, forbid its power unwind.
	 */
	park_ret = clk_set_rate(rknpu->clks[0].clk, RKNPU_PARK_RATE);
	if (!park_ret && rknpu->opp_ready)
		park_ret = dev_pm_opp_set_rate(dev, 0);
	WRITE_ONCE(rknpu->frequency_fault, !!park_ret);
	if (park_ret)
		dev_crit(dev, "NPU clock recovery failed; retaining domains/clocks\n");
out:
	mutex_unlock(&rknpu->freq_lock);
	return ret;
}
