/* SPDX-License-Identifier: GPL-2.0-only */
#ifndef __QCOM_PMI8998_TYPEC_PORT_H__
#define __QCOM_PMI8998_TYPEC_PORT_H__

#include <linux/platform_device.h>
#include <linux/regmap.h>

struct pmic_typec;

int qcom_pmi8998_typec_port_probe(struct platform_device *pdev,
                                  struct pmic_typec *tcpm,
                                  struct regmap *regmap, u32 base);

#endif
