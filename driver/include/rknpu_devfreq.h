/* SPDX-License-Identifier: GPL-2.0 */
#ifndef __LINUX_RKNPU_DEVFREQ_H
#define __LINUX_RKNPU_DEVFREQ_H

int rknpu_devfreq_init(struct rknpu_device *rknpu_dev);
void rknpu_devfreq_remove(struct rknpu_device *rknpu_dev);
int rknpu_devfreq_set_rate(struct rknpu_device *rknpu_dev, unsigned long freq);
int rknpu_devfreq_runtime_suspend(struct device *dev);
int rknpu_devfreq_runtime_resume(struct device *dev);

#endif
