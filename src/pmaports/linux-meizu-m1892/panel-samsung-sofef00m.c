// SPDX-License-Identifier: GPL-2.0-only
/*
 * Samsung SOFEF00M AMOLED panel used by the Meizu 16th Plus (M1892).
 *
 * The initialization sequence and power/reset timings are decoded from the
 * stock M1892 device tree.  In particular, the 64-byte E2 calibration payload
 * is specific to this stock panel and differs from the older public M1892
 * Linux 6.1 port.
 */

#include <linux/backlight.h>
#include <linux/delay.h>
#include <linux/gpio/consumer.h>
#include <linux/module.h>
#include <linux/of.h>
#include <linux/regulator/consumer.h>

#include <drm/drm_mipi_dsi.h>
#include <drm/drm_modes.h>
#include <drm/drm_panel.h>
#include <drm/drm_probe_helper.h>

#include <video/mipi_display.h>

struct sofef00m_panel {
	struct drm_panel panel;
	struct mipi_dsi_device *dsi;
	struct regulator *vddio;
	struct regulator *vdd;
	struct gpio_desc *reset_gpio;
	bool prepared;
	bool enabled;
};

static inline struct sofef00m_panel *to_sofef00m_panel(struct drm_panel *panel)
{
	return container_of(panel, struct sofef00m_panel, panel);
}

static int sofef00m_power_on(struct sofef00m_panel *ctx)
{
	int ret;

	/* Stock supply order: 1.8 V VDDIO, 1 ms, then 3.0 V VDD. */
	ret = regulator_enable(ctx->vddio);
	if (ret)
		return ret;

	usleep_range(1000, 2000);

	ret = regulator_enable(ctx->vdd);
	if (ret) {
		regulator_disable(ctx->vddio);
		return ret;
	}

	return 0;
}

static void sofef00m_power_off(struct sofef00m_panel *ctx)
{
	/* Reverse the stock power-on order; VDD has a 1 ms post-off delay. */
	regulator_disable(ctx->vdd);
	usleep_range(1000, 2000);
	regulator_disable(ctx->vddio);
}

static void sofef00m_reset(struct sofef00m_panel *ctx)
{
	/*
	 * Stock physical sequence is high/low/high, 10 ms per level.
	 * reset-gpios is active-low, hence logical 0/1/0 here.
	 */
	gpiod_set_value_cansleep(ctx->reset_gpio, 0);
	usleep_range(10000, 11000);
	gpiod_set_value_cansleep(ctx->reset_gpio, 1);
	usleep_range(10000, 11000);
	gpiod_set_value_cansleep(ctx->reset_gpio, 0);
	usleep_range(10000, 11000);
}

static int sofef00m_panel_init(struct sofef00m_panel *ctx)
{
	struct mipi_dsi_multi_context dsi_ctx = { .dsi = ctx->dsi };

	/*
	 * Exact 37-packet stock command stream, with DCS display-on split into
	 * ->enable().  All commands are sent in low-power command mode.
	 */
	mipi_dsi_dcs_exit_sleep_mode_multi(&dsi_ctx);
	mipi_dsi_msleep(&dsi_ctx, 21);

	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0xf0, 0x5a, 0x5a);
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0xfc, 0x5a, 0x5a);
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0xb0, 0x03);
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0xd2, 0x9e);
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0xf0, 0xa5, 0xa5);
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0xfc, 0xa5, 0xa5);
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0xf0, 0x5a, 0x5a);
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, MIPI_DCS_SET_TEAR_ON, 0x00);
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0xf0, 0xa5, 0xa5);
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, MIPI_DCS_SET_PAGE_ADDRESS,
				     0x00, 0x00, 0x08, 0x6f);
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0xf0, 0x5a, 0x5a);
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0xb0, 0x01);
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0xbb, 0x03);
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0xb0, 0x03);
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0xef, 0x33, 0x31, 0x14);
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0xf0, 0xa5, 0xa5);
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, MIPI_DCS_WRITE_CONTROL_DISPLAY,
				     0x28);
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, MIPI_DCS_SET_DISPLAY_BRIGHTNESS,
				     0x00, 0x00);
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, MIPI_DCS_WRITE_POWER_SAVE, 0x00);
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0xf0, 0x5a, 0x5a);
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0xf0, 0x5a, 0x5a);
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0xb0, 0x05);
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0xb1, 0x03);
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0xf0, 0xa5, 0xa5);
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0xb0, 0x02);
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0xe2,
				     0xb3, 0x0c, 0x04, 0x39, 0xce, 0x13, 0x07,
				     0x04, 0xaf, 0x44, 0xe6, 0xcd, 0xc9, 0x11,
				     0xc2, 0xea, 0xe6, 0x18, 0xff, 0xff, 0xff,
				     0xf1, 0x10, 0x07, 0x00, 0xc0, 0x00, 0x07,
				     0x05, 0xb5, 0x00, 0xd7, 0xc0, 0xff, 0x16,
				     0xc4, 0xe7, 0xe4, 0x0f, 0xff, 0xff, 0xff,
				     0xbd, 0x02, 0x00, 0x0c, 0xd6, 0x01, 0x06,
				     0x04, 0xa5, 0x06, 0xee, 0xc9, 0xc8, 0x0a,
				     0xdf, 0xd1, 0xe7, 0x06, 0xff, 0xfe, 0xfe);
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0xf0, 0xa5, 0xa5);
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0xf0, 0x5a, 0x5a);
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0xb0, 0x01);
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0xe2, 0x01);
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0xf0, 0xa5, 0xa5);
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0xf0, 0x5a, 0x5a);
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0xb0, 0x02);
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0xd5, 0x02, 0x00, 0x14, 0x14);
	mipi_dsi_dcs_write_seq_multi(&dsi_ctx, 0xf0, 0xa5, 0xa5);
	mipi_dsi_msleep(&dsi_ctx, 110);

	return dsi_ctx.accum_err;
}

static int sofef00m_prepare(struct drm_panel *panel)
{
	struct sofef00m_panel *ctx = to_sofef00m_panel(panel);
	int ret;

	if (ctx->prepared)
		return 0;

	ret = sofef00m_power_on(ctx);
	if (ret)
		return ret;

	sofef00m_reset(ctx);

	ret = sofef00m_panel_init(ctx);
	if (ret) {
		gpiod_set_value_cansleep(ctx->reset_gpio, 1);
		sofef00m_power_off(ctx);
		return ret;
	}

	ctx->prepared = true;
	return 0;
}

static int sofef00m_enable(struct drm_panel *panel)
{
	struct sofef00m_panel *ctx = to_sofef00m_panel(panel);
	struct mipi_dsi_multi_context dsi_ctx = { .dsi = ctx->dsi };

	if (ctx->enabled)
		return 0;

	mipi_dsi_dcs_set_display_on_multi(&dsi_ctx);
	if (!dsi_ctx.accum_err)
		ctx->enabled = true;

	return dsi_ctx.accum_err;
}

static int sofef00m_disable(struct drm_panel *panel)
{
	struct sofef00m_panel *ctx = to_sofef00m_panel(panel);
	struct mipi_dsi_multi_context dsi_ctx = { .dsi = ctx->dsi };

	if (!ctx->enabled)
		return 0;

	mipi_dsi_dcs_set_display_off_multi(&dsi_ctx);
	if (!dsi_ctx.accum_err)
		ctx->enabled = false;

	return dsi_ctx.accum_err;
}

static int sofef00m_unprepare(struct drm_panel *panel)
{
	struct sofef00m_panel *ctx = to_sofef00m_panel(panel);
	struct mipi_dsi_multi_context dsi_ctx = { .dsi = ctx->dsi };

	if (!ctx->prepared)
		return 0;

	mipi_dsi_dcs_enter_sleep_mode_multi(&dsi_ctx);
	mipi_dsi_msleep(&dsi_ctx, 120);

	gpiod_set_value_cansleep(ctx->reset_gpio, 1);
	sofef00m_power_off(ctx);
	ctx->prepared = false;

	return dsi_ctx.accum_err;
}

static const struct drm_display_mode sofef00m_mode = {
	.clock = (1080 + 128 + 24 + 60) * (2160 + 8 + 4 + 12) * 60 / 1000,

	.hdisplay = 1080,
	.hsync_start = 1080 + 128,
	.hsync_end = 1080 + 128 + 24,
	.htotal = 1080 + 128 + 24 + 60,

	.vdisplay = 2160,
	.vsync_start = 2160 + 8,
	.vsync_end = 2160 + 8 + 4,
	.vtotal = 2160 + 8 + 4 + 12,

	.width_mm = 73,
	.height_mm = 146,

	.type = DRM_MODE_TYPE_DRIVER | DRM_MODE_TYPE_PREFERRED,
};

static int sofef00m_get_modes(struct drm_panel *panel,
			      struct drm_connector *connector)
{
	return drm_connector_helper_get_modes_fixed(connector, &sofef00m_mode);
}

static const struct drm_panel_funcs sofef00m_panel_funcs = {
	.prepare = sofef00m_prepare,
	.enable = sofef00m_enable,
	.disable = sofef00m_disable,
	.unprepare = sofef00m_unprepare,
	.get_modes = sofef00m_get_modes,
};

static int sofef00m_bl_update_status(struct backlight_device *bl)
{
	struct mipi_dsi_device *dsi = bl_get_data(bl);
	u16 brightness = backlight_get_brightness(bl);

	return mipi_dsi_dcs_set_display_brightness_large(dsi, brightness);
}

static const struct backlight_ops sofef00m_bl_ops = {
	.update_status = sofef00m_bl_update_status,
};

static struct backlight_device *
sofef00m_create_backlight(struct mipi_dsi_device *dsi)
{
	struct device *dev = &dsi->dev;
	const struct backlight_properties props = {
		.type = BACKLIGHT_PLATFORM,
		.brightness = 128,
		.max_brightness = 1023,
	};

	return devm_backlight_device_register(dev, dev_name(dev), dev, dsi,
					      &sofef00m_bl_ops, &props);
}

static int sofef00m_probe(struct mipi_dsi_device *dsi)
{
	struct device *dev = &dsi->dev;
	struct sofef00m_panel *ctx;
	int ret;

	ctx = devm_drm_panel_alloc(dev, struct sofef00m_panel, panel,
				   &sofef00m_panel_funcs,
				   DRM_MODE_CONNECTOR_DSI);
	if (IS_ERR(ctx))
		return PTR_ERR(ctx);

	ctx->vddio = devm_regulator_get(dev, "vddio");
	if (IS_ERR(ctx->vddio))
		return dev_err_probe(dev, PTR_ERR(ctx->vddio),
				     "failed to get vddio regulator\n");

	ctx->vdd = devm_regulator_get(dev, "vdd");
	if (IS_ERR(ctx->vdd))
		return dev_err_probe(dev, PTR_ERR(ctx->vdd),
				     "failed to get vdd regulator\n");

	ctx->reset_gpio = devm_gpiod_get(dev, "reset", GPIOD_OUT_HIGH);
	if (IS_ERR(ctx->reset_gpio))
		return dev_err_probe(dev, PTR_ERR(ctx->reset_gpio),
				     "failed to get reset GPIO\n");

	ctx->dsi = dsi;
	mipi_dsi_set_drvdata(dsi, ctx);

	dsi->lanes = 4;
	dsi->format = MIPI_DSI_FMT_RGB888;
	dsi->mode_flags = MIPI_DSI_MODE_LPM | MIPI_DSI_CLOCK_NON_CONTINUOUS;

	ctx->panel.prepare_prev_first = true;
	ctx->panel.backlight = sofef00m_create_backlight(dsi);
	if (IS_ERR(ctx->panel.backlight))
		return dev_err_probe(dev, PTR_ERR(ctx->panel.backlight),
				     "failed to create backlight\n");

	drm_panel_add(&ctx->panel);

	ret = mipi_dsi_attach(dsi);
	if (ret) {
		drm_panel_remove(&ctx->panel);
		return dev_err_probe(dev, ret, "failed to attach DSI host\n");
	}

	return 0;
}

static void sofef00m_remove(struct mipi_dsi_device *dsi)
{
	struct sofef00m_panel *ctx = mipi_dsi_get_drvdata(dsi);

	mipi_dsi_detach(dsi);
	drm_panel_remove(&ctx->panel);
}

static const struct of_device_id sofef00m_of_match[] = {
	{ .compatible = "samsung,sofef00m" },
	{ }
};
MODULE_DEVICE_TABLE(of, sofef00m_of_match);

static struct mipi_dsi_driver sofef00m_driver = {
	.probe = sofef00m_probe,
	.remove = sofef00m_remove,
	.driver = {
		.name = "panel-samsung-sofef00m",
		.of_match_table = sofef00m_of_match,
	},
};
module_mipi_dsi_driver(sofef00m_driver);

MODULE_AUTHOR("M1892 mainline bring-up project");
MODULE_DESCRIPTION("Samsung SOFEF00M AMOLED panel driver");
MODULE_LICENSE("GPL");
