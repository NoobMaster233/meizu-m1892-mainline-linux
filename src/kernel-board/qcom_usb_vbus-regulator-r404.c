// SPDX-License-Identifier: GPL-2.0-only
//
// Qualcomm PMIC VBUS output regulator driver
//
// Copyright (c) 2020, The Linux Foundation. All rights reserved.

#include <linux/delay.h>
#include <linux/err.h>
#include <linux/interrupt.h>
#include <linux/kernel.h>
#include <linux/module.h>
#include <linux/mutex.h>
#include <linux/of.h>
#include <linux/platform_device.h>
#include <linux/regmap.h>
#include <linux/regulator/driver.h>
#include <linux/regulator/of_regulator.h>

#define OTG_STATUS			0x09
#define BOOST_SOFTSTART_DONE		BIT(3)
#define CMD_OTG				0x40
#define OTG_EN				BIT(0)
#define OTG_CURRENT_LIMIT_CFG		0x52
#define OTG_CURRENT_LIMIT_MASK		GENMASK(2, 0)
#define OTG_CFG				0x53
#define OTG_EN_SRC_CFG			BIT(1)

/* PMI8998 addresses expressed relative to its OTG peripheral at 0x1100. */
#define PMI8998_USBIN_INT_RT_STS		0x210
#define PMI8998_USBIN_PLUGIN_RT_STS	BIT(4)
#define PMI8998_POWER_PATH_STATUS	0x50b
#define PMI8998_USE_USBIN		BIT(4)
#define PMI8998_VALID_INPUT_SOURCE	BIT(0)

#define PMI8998_OTG_START_UA		250000
#define PMI8998_OTG_TARGET_UA		500000
#define PMI8998_OTG_SOFTSTART_TRIES	15

struct qcom_usb_vbus_match_data {
	const unsigned int *curr_table;
	unsigned int n_current_limits;
	bool pmi8998;
};

struct qcom_usb_vbus {
	struct device *dev;
	struct regmap *regmap;
	struct regulator_desc desc;
	struct regulator_dev *rdev;
	const struct qcom_usb_vbus_match_data *match;
	struct mutex lock;
	u32 base;
};

static const unsigned int pm8150b_curr_table[] = {
	500000, 1000000, 1500000, 2000000, 2500000, 3000000,
};

static const unsigned int pmi8998_curr_table[] = {
	250000, 500000, 750000, 1000000,
	1250000, 1500000, 1750000, 2000000,
};

static const struct qcom_usb_vbus_match_data pm8150b_data = {
	.curr_table = pm8150b_curr_table,
	.n_current_limits = ARRAY_SIZE(pm8150b_curr_table),
};

static const struct qcom_usb_vbus_match_data pmi8998_data = {
	.curr_table = pmi8998_curr_table,
	.n_current_limits = ARRAY_SIZE(pmi8998_curr_table),
	.pmi8998 = true,
};

static int pmi8998_external_vbus_present(struct qcom_usb_vbus *vbus)
{
	unsigned int plugin, path;
	int ret;

	ret = regmap_read(vbus->regmap,
			  vbus->base + PMI8998_USBIN_INT_RT_STS, &plugin);
	if (ret)
		return ret;

	ret = regmap_read(vbus->regmap,
			  vbus->base + PMI8998_POWER_PATH_STATUS, &path);
	if (ret)
		return ret;

	if (plugin & PMI8998_USBIN_PLUGIN_RT_STS)
		return 1;

	return (path & PMI8998_USE_USBIN) &&
	       (path & PMI8998_VALID_INPUT_SOURCE);
}

static int pmi8998_set_current_selector(struct qcom_usb_vbus *vbus,
					unsigned int selector)
{
	return regmap_update_bits(vbus->regmap,
				  vbus->base + OTG_CURRENT_LIMIT_CFG,
				  OTG_CURRENT_LIMIT_MASK, selector);
}

static int pmi8998_wait_for_softstart(struct qcom_usb_vbus *vbus)
{
	unsigned int status;
	unsigned int delay_us;
	int ret, i;

	for (i = 0; i < PMI8998_OTG_SOFTSTART_TRIES; i++) {
		delay_us = i > 5 ? 9000 : 2000;
		usleep_range(delay_us, delay_us + 100);

		ret = regmap_read(vbus->regmap, vbus->base + OTG_STATUS,
				  &status);
		if (ret)
			return ret;
		if (status & BOOST_SOFTSTART_DONE)
			return 0;
	}

	return -ETIMEDOUT;
}

static int pmi8998_otg_enable(struct qcom_usb_vbus *vbus)
{
	static const unsigned int start_selectors[] = { 0, 1 };
	int disable_ret, present, ret = -ETIMEDOUT;
	int i;

	present = pmi8998_external_vbus_present(vbus);
	if (present < 0)
		return dev_err_probe(vbus->dev, present,
				     "cannot verify external VBUS state\n");
	if (present)
		return dev_err_probe(vbus->dev, -EBUSY,
				     "refusing OTG while external VBUS is present\n");

	for (i = 0; i < ARRAY_SIZE(start_selectors); i++) {
		ret = regmap_update_bits(vbus->regmap, vbus->base + CMD_OTG,
					 OTG_EN, 0);
		if (ret)
			break;
		usleep_range(1000, 2000);

		ret = pmi8998_set_current_selector(vbus, start_selectors[i]);
		if (ret)
			break;

		ret = regmap_update_bits(vbus->regmap, vbus->base + CMD_OTG,
					 OTG_EN, OTG_EN);
		if (ret)
			break;

		ret = pmi8998_wait_for_softstart(vbus);
		if (!ret) {
			ret = pmi8998_set_current_selector(vbus, 1);
			if (!ret) {
				dev_info(vbus->dev,
					 "PMI8998 OTG VBUS enabled at %duA\n",
					 PMI8998_OTG_TARGET_UA);
				return 0;
			}
		}
	}

	disable_ret = regmap_update_bits(vbus->regmap, vbus->base + CMD_OTG,
					 OTG_EN, 0);
	if (disable_ret)
		ret = disable_ret;
	pmi8998_set_current_selector(vbus, 0);
	dev_err(vbus->dev, "PMI8998 OTG soft start failed: %d\n", ret);
	return ret;
}

static int qcom_usb_vbus_enable(struct regulator_dev *rdev)
{
	struct qcom_usb_vbus *vbus = rdev_get_drvdata(rdev);
	int ret;

	if (!vbus->match->pmi8998)
		return regulator_enable_regmap(rdev);

	mutex_lock(&vbus->lock);
	ret = pmi8998_otg_enable(vbus);
	mutex_unlock(&vbus->lock);

	return ret;
}

static int qcom_usb_vbus_disable(struct regulator_dev *rdev)
{
	struct qcom_usb_vbus *vbus = rdev_get_drvdata(rdev);
	int ret;

	if (!vbus->match->pmi8998)
		return regulator_disable_regmap(rdev);

	mutex_lock(&vbus->lock);
	ret = regmap_update_bits(vbus->regmap, vbus->base + CMD_OTG,
				 OTG_EN, 0);
	if (!ret)
		ret = pmi8998_set_current_selector(vbus, 0);
	mutex_unlock(&vbus->lock);

	if (!ret)
		dev_info(vbus->dev, "PMI8998 OTG VBUS disabled\n");
	return ret;
}

static const struct regulator_ops qcom_usb_vbus_reg_ops = {
	.enable = qcom_usb_vbus_enable,
	.disable = qcom_usb_vbus_disable,
	.is_enabled = regulator_is_enabled_regmap,
	.get_current_limit = regulator_get_current_limit_regmap,
	.set_current_limit = regulator_set_current_limit_regmap,
};

static irqreturn_t pmi8998_otg_fault_irq(int irq, void *data)
{
	struct qcom_usb_vbus *vbus = data;
	int ret;

	mutex_lock(&vbus->lock);
	ret = regmap_update_bits(vbus->regmap, vbus->base + CMD_OTG,
				 OTG_EN, 0);
	pmi8998_set_current_selector(vbus, 0);
	mutex_unlock(&vbus->lock);

	dev_err_ratelimited(vbus->dev,
			    "PMI8998 OTG fault IRQ %d; VBUS forced off (%d)\n",
			    irq, ret);
	return IRQ_HANDLED;
}

static int pmi8998_request_fault_irq(struct platform_device *pdev,
				     struct qcom_usb_vbus *vbus,
				     const char *name)
{
	int irq, ret;

	irq = platform_get_irq_byname(pdev, name);
	if (irq < 0)
		return irq;

	ret = devm_request_threaded_irq(vbus->dev, irq, NULL,
					pmi8998_otg_fault_irq, IRQF_ONESHOT,
					name, vbus);
	if (ret)
		return dev_err_probe(vbus->dev, ret,
				     "failed to request %s IRQ\n", name);

	return 0;
}

static int qcom_usb_vbus_regulator_probe(struct platform_device *pdev)
{
	struct device *dev = &pdev->dev;
	struct regulator_config config = { };
	struct regulator_init_data *init_data;
	struct qcom_usb_vbus *vbus;
	int ret;

	vbus = devm_kzalloc(dev, sizeof(*vbus), GFP_KERNEL);
	if (!vbus)
		return -ENOMEM;

	vbus->dev = dev;
	vbus->match = device_get_match_data(dev);
	if (!vbus->match)
		return -EINVAL;

	ret = of_property_read_u32(dev->of_node, "reg", &vbus->base);
	if (ret)
		return dev_err_probe(dev, ret, "no base address found\n");

	vbus->regmap = dev_get_regmap(dev->parent, NULL);
	if (!vbus->regmap)
		return dev_err_probe(dev, -ENOENT, "failed to get regmap\n");

	mutex_init(&vbus->lock);
	vbus->desc.name = "usb_vbus";
	vbus->desc.ops = &qcom_usb_vbus_reg_ops;
	vbus->desc.owner = THIS_MODULE;
	vbus->desc.type = REGULATOR_VOLTAGE;
	vbus->desc.curr_table = vbus->match->curr_table;
	vbus->desc.n_current_limits = vbus->match->n_current_limits;
	vbus->desc.enable_reg = vbus->base + CMD_OTG;
	vbus->desc.enable_mask = OTG_EN;
	vbus->desc.csel_reg = vbus->base + OTG_CURRENT_LIMIT_CFG;
	vbus->desc.csel_mask = OTG_CURRENT_LIMIT_MASK;

	init_data = of_get_regulator_init_data(dev, dev->of_node, &vbus->desc);
	if (!init_data)
		return -ENOMEM;

	/* Always start fail-closed, including when a bootloader left OTG on. */
	ret = regmap_update_bits(vbus->regmap, vbus->base + CMD_OTG,
				 OTG_EN, 0);
	if (ret)
		return dev_err_probe(dev, ret, "failed to force VBUS off\n");

	ret = regmap_update_bits(vbus->regmap, vbus->base + OTG_CFG,
				 OTG_EN_SRC_CFG, 0);
	if (ret)
		return dev_err_probe(dev, ret,
				     "failed to select software VBUS control\n");

	if (vbus->match->pmi8998) {
		ret = pmi8998_set_current_selector(vbus, 0);
		if (ret)
			return dev_err_probe(dev, ret,
					     "failed to set safe OTG current\n");
	}

	config.dev = dev;
	config.init_data = init_data;
	config.of_node = dev->of_node;
	config.regmap = vbus->regmap;
	config.driver_data = vbus;

	vbus->rdev = devm_regulator_register(dev, &vbus->desc, &config);
	if (IS_ERR(vbus->rdev))
		return dev_err_probe(dev, PTR_ERR(vbus->rdev),
				     "not able to register VBUS regulator\n");

	if (vbus->match->pmi8998) {
		ret = pmi8998_request_fault_irq(pdev, vbus, "otg-fail");
		if (ret)
			return ret;
		ret = pmi8998_request_fault_irq(pdev, vbus,
						"otg-overcurrent");
		if (ret)
			return ret;
	}

	platform_set_drvdata(pdev, vbus);
	if (vbus->match->pmi8998)
		dev_info(dev,
			 "PMI8998 OTG VBUS ready; default off, maximum 500mA\n");
	else
		dev_info(dev, "Qualcomm OTG VBUS regulator ready\n");
	return 0;
}

static void qcom_usb_vbus_regulator_shutdown(struct platform_device *pdev)
{
	struct qcom_usb_vbus *vbus = platform_get_drvdata(pdev);

	if (!vbus)
		return;
	regmap_update_bits(vbus->regmap, vbus->base + CMD_OTG, OTG_EN, 0);
}

static const struct of_device_id qcom_usb_vbus_regulator_match[] = {
	{ .compatible = "qcom,pmi8998-vbus-reg", .data = &pmi8998_data },
	{ .compatible = "qcom,pm8150b-vbus-reg", .data = &pm8150b_data },
	{ }
};
MODULE_DEVICE_TABLE(of, qcom_usb_vbus_regulator_match);

static struct platform_driver qcom_usb_vbus_regulator_driver = {
	.driver = {
		.name = "qcom-usb-vbus-regulator",
		.probe_type = PROBE_PREFER_ASYNCHRONOUS,
		.of_match_table = qcom_usb_vbus_regulator_match,
	},
	.probe = qcom_usb_vbus_regulator_probe,
	.shutdown = qcom_usb_vbus_regulator_shutdown,
};
module_platform_driver(qcom_usb_vbus_regulator_driver);

MODULE_DESCRIPTION("Qualcomm USB VBUS regulator driver");
MODULE_LICENSE("GPL v2");
