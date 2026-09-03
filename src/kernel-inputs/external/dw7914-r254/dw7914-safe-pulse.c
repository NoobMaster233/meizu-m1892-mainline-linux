// SPDX-License-Identifier: GPL-2.0-only
/*
 * Recovery-only, deliberately constrained DW7914 pulse gate for Meizu M1892.
 *
 * This is not the final input/FF driver.  It exposes one exact, low-amplitude
 * acceptance pulse only after staging the byte-identical stock RAM image.
 * The output path has three stop layers:
 *
 *  1. RAM sequencer: stock wave 19, one slot, loop count zero;
 *  2. hrtimer: directly drives the non-sleeping GPIO44 enable line low;
 *  3. process cleanup: balances the regulator enable count and powers off.
 *
 * The hrtimer is armed before GO=1.  No I2C transaction or workqueue is needed
 * for its power cut, so a stalled I2C controller or worker cannot extend the
 * pulse.  The module refuses to bind if the emergency GPIO can sleep.
 */

#include <linux/completion.h>
#include <linux/delay.h>
#include <linux/firmware.h>
#include <linux/gpio/consumer.h>
#include <linux/hrtimer.h>
#include <linux/i2c.h>
#ifdef DW7914_STANDARD_FF
#include <linux/input.h>
#endif
#include <linux/module.h>
#include <linux/mutex.h>
#include <linux/of.h>
#ifndef DW7914_DIRECT_GPIO_POWER
#include <linux/regulator/consumer.h>
#endif
#include <linux/slab.h>
#ifdef DW7914_STANDARD_FF
#include <linux/workqueue.h>
#endif

#define DW7914_REG_ID                  0x00
#define DW7914_REG_MODE                0x0b
#define DW7914_REG_GO                  0x0c
#define DW7914_REG_VD_CLAMP            0x0a
#define DW7914_REG_WAVEQ1              0x0f
#define DW7914_REG_WAVE_LOOP1          0x17
#define DW7914_REG_RAM_INPUT           0x46
#define DW7914_REG_FIFO_BASE_H         0x49

#define DW7914_M1892_ID                0x40
#define DW7914_MODE_MEM                BIT(0)
#define DW7914_M1892_FW_SIZE           12288
#define DW7914_M1892_RAM_CHUNK         1024
#define DW7914_M1892_FW_FNV1A64        0x7de856ef0fc3b332ULL
#define DW7914_M1892_FW_NAME           "m1892/dw_172hz.bin"

/* Stock 4.9 calls dw7914_vd_clamp_set(8520), which writes 8520 / 100. */
#define DW7914_M1892_VD_CLAMP          0x55

/* Exact stock timed-output waveform, but without stock's loop value 15. */
#define DW7914_M1892_SAFE_WAVE          19
#define DW7914_M1892_WAVE19_START       0x2ae5
#define DW7914_M1892_WAVE19_LENGTH      0x0115
#define DW7914_M1892_WAVE19_DESC_OFFSET (1 + (DW7914_M1892_SAFE_WAVE - 1) * 5)
#define DW7914_M1892_WAVE19_HEADER_SIZE (DW7914_M1892_WAVE19_DESC_OFFSET + 5)
#define DW7914_M1892_SAFE_PULSE_MS      20
#define DW7914_M1892_WAIT_MS            100
#define DW7914_M1892_ARM_TOKEN          "ARMED_SINGLE_20MS_WAVE19"
#define DW7914_M1892_CUT_TEST_MS         5
#define DW7914_M1892_CUT_TEST_TOKEN      "ARMED_GPIO_CUT_TEST_NO_GO"
#define DW7914_M1892_STAGE_TEST_TOKEN    "STAGE_STOCK_172HZ_NO_GO"
#define DW7914_M1892_SPARSE_TEST_TOKEN   "STAGE_WAVE19_SPARSE_NO_GO"

struct dw7914_safe_pulse {
	struct i2c_client *client;
#ifndef DW7914_DIRECT_GPIO_POWER
	struct regulator *enable_supply;
#endif
	struct gpio_desc *emergency_stop;
	struct mutex lock; /* serializes all sleeping hardware operations */
	struct hrtimer hard_stop_timer;
	struct completion hard_stop_done;
	u8 device_id;
	bool powered;
	bool firmware_staged;
	bool timer_fired;
	u32 pulse_count;
	u32 cut_test_count;
#ifdef DW7914_STANDARD_FF
	struct input_dev *input;
	struct work_struct ff_work;
	u16 ff_magnitude;
	bool ff_command_active;
	u32 stage_test_count;
	u64 stage_last_us;
	u32 sparse_test_count;
	u64 sparse_last_us;
#endif
};

static int dw7914_write(struct dw7914_safe_pulse *dw, u8 reg, u8 value)
{
	return i2c_smbus_write_byte_data(dw->client, reg, value);
}

static void dw7914_emergency_cut(struct dw7914_safe_pulse *dw)
{
	/* Probe rejects sleeping GPIO controllers, so this is atomic-safe. */
	gpiod_set_value(dw->emergency_stop, 0);
}

static enum hrtimer_restart dw7914_hard_stop(struct hrtimer *timer)
{
	struct dw7914_safe_pulse *dw =
		container_of(timer, struct dw7914_safe_pulse, hard_stop_timer);

	dw7914_emergency_cut(dw);
	WRITE_ONCE(dw->timer_fired, true);
	complete(&dw->hard_stop_done);
	return HRTIMER_NORESTART;
}

static void dw7914_power_off(struct dw7914_safe_pulse *dw)
{
	dw7914_emergency_cut(dw);
	if (dw->powered) {
#ifndef DW7914_DIRECT_GPIO_POWER
		regulator_disable(dw->enable_supply);
#endif
		dw->powered = false;
	}
	dw->firmware_staged = false;
}

static void dw7914_power_off_action(void *data)
{
	struct dw7914_safe_pulse *dw = data;

	hrtimer_cancel(&dw->hard_stop_timer);
	dw7914_power_off(dw);
}

static int dw7914_require_stopped(struct dw7914_safe_pulse *dw)
{
	int ret = i2c_smbus_read_byte_data(dw->client, DW7914_REG_GO);

	if (ret < 0)
		return ret;
	return ret == 0 ? 0 : -EBUSY;
}

static int dw7914_power_and_identify(struct dw7914_safe_pulse *dw)
{
	int ret;

	dw7914_power_off(dw);
	msleep(20);
#ifdef DW7914_DIRECT_GPIO_POWER
	gpiod_set_value(dw->emergency_stop, 1);
#else
	ret = regulator_enable(dw->enable_supply);
	if (ret)
		return ret;
#endif
	dw->powered = true;
	usleep_range(10000, 12000);

	ret = i2c_smbus_read_byte_data(dw->client, DW7914_REG_ID);
	if (ret < 0)
		return ret;
	if (ret != DW7914_M1892_ID)
		return -ENODEV;
	dw->device_id = ret;
	return 0;
}

static int dw7914_init_no_output(struct dw7914_safe_pulse *dw)
{
	static const struct {
		u8 reg;
		u8 value;
	} pre_fifo[] = {
		{ DW7914_REG_GO, 0x00 },
		{ 0xaf, 0x97 },
		{ 0xa3, 0x10 },
		{ 0xae, 0x79 },
	}, post_fifo[] = {
		{ 0x03, 0x2f },
		{ 0x1f, 0x03 },
		{ 0x22, 0x05 },
		{ 0x06, 0x00 },
		{ DW7914_REG_VD_CLAMP, DW7914_M1892_VD_CLAMP },
	};
	u8 fifo_base[] = { DW7914_REG_FIFO_BASE_H, 0x2f, 0xfc };
	unsigned int i;
	int ret;

	for (i = 0; i < ARRAY_SIZE(pre_fifo); i++) {
		ret = dw7914_write(dw, pre_fifo[i].reg, pre_fifo[i].value);
		if (ret)
			return ret;
	}
	ret = dw7914_require_stopped(dw);
	if (ret)
		return ret;

	ret = i2c_master_send(dw->client, fifo_base, sizeof(fifo_base));
	if (ret < 0)
		return ret;
	if (ret != sizeof(fifo_base))
		return -EIO;

	for (i = 0; i < ARRAY_SIZE(post_fifo); i++) {
		ret = dw7914_write(dw, post_fifo[i].reg, post_fifo[i].value);
		if (ret)
			return ret;
	}
	ret = i2c_master_send(dw->client, fifo_base, sizeof(fifo_base));
	if (ret < 0)
		return ret;
	if (ret != sizeof(fifo_base))
		return -EIO;
	return dw7914_require_stopped(dw);
}

static u64 dw7914_fnv1a64(const u8 *data, size_t size)
{
	u64 hash = 0xcbf29ce484222325ULL;
	size_t i;

	for (i = 0; i < size; i++) {
		hash ^= data[i];
		hash *= 0x100000001b3ULL;
	}
	return hash;
}

static int dw7914_validate_firmware(const struct firmware *fw)
{
	/* Wave 19 descriptor: start 0x2ae5, length 0x0115, amplitude 0x1e. */
	static const u8 wave19_descriptor[] = { 0x2a, 0xe5, 0x01, 0x15, 0x1e };

	if (fw->size != DW7914_M1892_FW_SIZE)
		return -EINVAL;
	if (dw7914_fnv1a64(fw->data, fw->size) != DW7914_M1892_FW_FNV1A64)
		return -EBADMSG;
	if (memcmp(fw->data + DW7914_M1892_WAVE19_DESC_OFFSET,
		   wave19_descriptor,
		   sizeof(wave19_descriptor)))
		return -EBADMSG;
	return 0;
}

static int dw7914_upload(struct dw7914_safe_pulse *dw,
			 const struct firmware *fw)
{
	u8 *transfer;
	size_t offset;
	int ret;

	transfer = kmalloc(DW7914_M1892_RAM_CHUNK + 3, GFP_KERNEL);
	if (!transfer)
		return -ENOMEM;

	ret = i2c_smbus_read_byte_data(dw->client, DW7914_REG_MODE);
	if (ret < 0)
		goto out;
	ret = dw7914_write(dw, DW7914_REG_MODE, ret | DW7914_MODE_MEM);
	if (ret)
		goto out;

	for (offset = 0; offset < fw->size;
	     offset += DW7914_M1892_RAM_CHUNK) {
		transfer[0] = DW7914_REG_RAM_INPUT;
		transfer[1] = offset >> 8;
		transfer[2] = offset;
		memcpy(transfer + 3, fw->data + offset,
		       DW7914_M1892_RAM_CHUNK);
		ret = i2c_master_send(dw->client, transfer,
				      DW7914_M1892_RAM_CHUNK + 3);
		if (ret < 0)
			goto out_stop;
		if (ret != DW7914_M1892_RAM_CHUNK + 3) {
			ret = -EIO;
			goto out_stop;
		}
	}
	ret = 0;
out_stop:
	if (dw7914_write(dw, DW7914_REG_GO, 0x00) && !ret)
		ret = -EIO;
out:
	kfree(transfer);
	return ret;
}

static int dw7914_upload_range(struct dw7914_safe_pulse *dw,
			       struct firmware const *fw,
			       size_t offset, size_t length)
{
	u8 *transfer;
	int ret;

	if (offset + length > fw->size)
		return -EINVAL;
	transfer = kmalloc(length + 3, GFP_KERNEL);
	if (!transfer)
		return -ENOMEM;
	transfer[0] = DW7914_REG_RAM_INPUT;
	transfer[1] = offset >> 8;
	transfer[2] = offset;
	memcpy(transfer + 3, fw->data + offset, length);
	ret = i2c_master_send(dw->client, transfer, length + 3);
	kfree(transfer);
	if (ret < 0)
		return ret;
	return ret == length + 3 ? 0 : -EIO;
}

static int dw7914_upload_sparse(struct dw7914_safe_pulse *dw,
				struct firmware const *fw)
{
	int ret;

	ret = i2c_smbus_read_byte_data(dw->client, DW7914_REG_MODE);
	if (ret < 0)
		return ret;
	ret = dw7914_write(dw, DW7914_REG_MODE, ret | DW7914_MODE_MEM);
	if (ret)
		return ret;

	/* Upload the table through wave 19, then its exact stock payload. */
	ret = dw7914_upload_range(dw, fw, 0, DW7914_M1892_WAVE19_HEADER_SIZE);
	if (ret)
		goto out_stop;
	ret = dw7914_upload_range(dw, fw, DW7914_M1892_WAVE19_START,
				  DW7914_M1892_WAVE19_LENGTH);
out_stop:
	if (dw7914_write(dw, DW7914_REG_GO, 0x00) && !ret)
		ret = -EIO;
	return ret;
}

static int dw7914_stage_mode(struct dw7914_safe_pulse *dw, bool sparse)
{
	const struct firmware *fw;
	int ret;

	ret = request_firmware_direct(&fw, DW7914_M1892_FW_NAME,
				      &dw->client->dev);
	if (ret)
		return ret;
	ret = dw7914_validate_firmware(fw);
	if (ret)
		goto out_release;
	ret = dw7914_power_and_identify(dw);
	if (ret)
		goto out_power;
	ret = dw7914_init_no_output(dw);
	if (ret)
		goto out_power;
	ret = sparse ? dw7914_upload_sparse(dw, fw) :
		      dw7914_upload(dw, fw);
	if (!ret)
		dw->firmware_staged = true;
out_power:
	if (ret)
		dw7914_power_off(dw);
out_release:
	release_firmware(fw);
	return ret;
}

static int dw7914_stage(struct dw7914_safe_pulse *dw)
{
	return dw7914_stage_mode(dw, false);
}

static int dw7914_program_single_wave19(struct dw7914_safe_pulse *dw)
{
	unsigned int i;
	int ret;

	ret = dw7914_require_stopped(dw);
	if (ret)
		return ret;
	for (i = 0; i < 8; i++) {
		u8 wave = i == 0 ? DW7914_M1892_SAFE_WAVE : 0;

		ret = dw7914_write(dw, DW7914_REG_WAVEQ1 + i, wave);
		if (ret)
			return ret;
	}
	for (i = 0; i < 5; i++) {
		ret = dw7914_write(dw, DW7914_REG_WAVE_LOOP1 + i, 0);
		if (ret)
			return ret;
	}
	return dw7914_require_stopped(dw);
}

static ssize_t safety_show(struct device *dev,
			   struct device_attribute *attr, char *buf)
{
	struct dw7914_safe_pulse *dw = dev_get_drvdata(dev);

	return sysfs_emit(buf,
		"id=0x%02x gpio_atomic=1 wave=19 loop=0 hard_stop_ms=20 pulses=%u powered=%u\n",
		dw->device_id, dw->pulse_count, dw->powered);
}
static DEVICE_ATTR_RO(safety);

static ssize_t hard_stop_status_show(struct device *dev,
				     struct device_attribute *attr, char *buf)
{
	struct dw7914_safe_pulse *dw = dev_get_drvdata(dev);

	return sysfs_emit(buf, "tests=%u last_fired=%u powered=%u\n",
		dw->cut_test_count, READ_ONCE(dw->timer_fired), dw->powered);
}
static DEVICE_ATTR_RO(hard_stop_status);

#ifndef DW7914_STANDARD_FF
static ssize_t hard_stop_test_store(struct device *dev,
				    struct device_attribute *attr,
				    const char *buf, size_t count)
{
	struct dw7914_safe_pulse *dw = dev_get_drvdata(dev);
	unsigned long waited;
	unsigned long timeout = msecs_to_jiffies(DW7914_M1892_WAIT_MS);
	int ret = 0;

	if (sysfs_streq(buf, DW7914_M1892_CUT_TEST_TOKEN) == 0)
		return -EPERM;

	mutex_lock(&dw->lock);
	dw7914_power_off(dw);
	msleep(20);
	reinit_completion(&dw->hard_stop_done);
	WRITE_ONCE(dw->timer_fired, false);

	/* This path performs no I2C transaction and cannot write GO. */
	dw->powered = true;
	gpiod_set_value(dw->emergency_stop, 1);
	hrtimer_start(&dw->hard_stop_timer,
		      ms_to_ktime(DW7914_M1892_CUT_TEST_MS), HRTIMER_MODE_REL);
	waited = wait_for_completion_timeout(&dw->hard_stop_done, timeout);
	if (!waited || !READ_ONCE(dw->timer_fired))
		ret = -ETIMEDOUT;
	hrtimer_cancel(&dw->hard_stop_timer);
	dw7914_power_off(dw);
	if (!ret) {
		dw->cut_test_count++;
		dev_info(dev,
			 "GPIO-only hrtimer hard-stop selftest passed at 5 ms; GO untouched\n");
	}
	mutex_unlock(&dw->lock);
	return ret ? ret : count;
}
static DEVICE_ATTR_WO(hard_stop_test);
#endif

static int dw7914_execute_single_pulse(struct dw7914_safe_pulse *dw)
{
	unsigned long waited;
	unsigned long timeout = msecs_to_jiffies(DW7914_M1892_WAIT_MS);
	int ret;

	reinit_completion(&dw->hard_stop_done);
	WRITE_ONCE(dw->timer_fired, false);

#ifdef DW7914_STANDARD_FF
	ret = dw7914_stage_mode(dw, true);
#else
	ret = dw7914_stage(dw);
#endif
	if (ret)
		goto out_cut;
	ret = dw7914_program_single_wave19(dw);
	if (ret)
		goto out_cut;

	/* Arm the I2C-independent power cut before the only GO=1 write. */
	hrtimer_start(&dw->hard_stop_timer,
		      ms_to_ktime(DW7914_M1892_SAFE_PULSE_MS),
		      HRTIMER_MODE_REL);
	ret = dw7914_write(dw, DW7914_REG_GO, 0x01);
	if (ret)
		goto out_cancel;

	waited = wait_for_completion_timeout(&dw->hard_stop_done, timeout);
	if (!waited || !READ_ONCE(dw->timer_fired)) {
		ret = -ETIMEDOUT;
		goto out_cancel;
	}

	hrtimer_cancel(&dw->hard_stop_timer);
	dw7914_power_off(dw);
	dw->pulse_count++;
	dev_info(&dw->client->dev,
		 "single wave19 pulse completed; GPIO hard stop fired at 20 ms\n");
	return 0;

out_cancel:
	hrtimer_cancel(&dw->hard_stop_timer);
out_cut:
	dw7914_power_off(dw);
	return ret;
}

#ifndef DW7914_STANDARD_FF
static ssize_t pulse_store(struct device *dev, struct device_attribute *attr,
			   const char *buf, size_t count)
{
	struct dw7914_safe_pulse *dw = dev_get_drvdata(dev);
	int ret;

	if (sysfs_streq(buf, DW7914_M1892_ARM_TOKEN) == 0)
		return -EPERM;

	mutex_lock(&dw->lock);
	ret = dw7914_execute_single_pulse(dw);
	mutex_unlock(&dw->lock);
	return ret ? ret : count;
}
static DEVICE_ATTR_WO(pulse);
#endif

#ifdef DW7914_STANDARD_FF
static void dw7914_ff_work(struct work_struct *work)
{
	struct dw7914_safe_pulse *dw =
		container_of(work, struct dw7914_safe_pulse, ff_work);
	u16 magnitude = READ_ONCE(dw->ff_magnitude);
	int ret = 0;

	mutex_lock(&dw->lock);
	if (!magnitude) {
		dw->ff_command_active = false;
		hrtimer_cancel(&dw->hard_stop_timer);
		dw7914_power_off(dw);
	} else if (!dw->ff_command_active) {
		/*
		 * Treat any nonzero rumble magnitude as the already-validated
		 * fixed wave-19 click.  Never scale above its stock amplitude and
		 * never extend beyond the independent 20-ms GPIO cutoff.
		 */
		dw->ff_command_active = true;
		ret = dw7914_execute_single_pulse(dw);
		if (ret) {
			dw->ff_command_active = false;
			dev_err(&dw->client->dev,
				"bounded FF pulse failed with errno %d\n", ret);
		}
	}
	mutex_unlock(&dw->lock);
}

/* Called with the input device event lock held; it must not sleep. */
static int dw7914_ff_play_effect(struct input_dev *input, void *data,
				 struct ff_effect *effect)
{
	struct dw7914_safe_pulse *dw = data;
	u16 magnitude;

	magnitude = effect->u.rumble.strong_magnitude;
	if (!magnitude)
		magnitude = effect->u.rumble.weak_magnitude;
	WRITE_ONCE(dw->ff_magnitude, magnitude);
	schedule_work(&dw->ff_work);
	return 0;
}

static void dw7914_ff_close(struct input_dev *input)
{
	struct dw7914_safe_pulse *dw = input_get_drvdata(input);

	WRITE_ONCE(dw->ff_magnitude, 0);
	cancel_work_sync(&dw->ff_work);
	mutex_lock(&dw->lock);
	dw->ff_command_active = false;
	hrtimer_cancel(&dw->hard_stop_timer);
	dw7914_power_off(dw);
	mutex_unlock(&dw->lock);
}

static ssize_t firmware_stage_status_show(struct device *dev,
					  struct device_attribute *attr,
					  char *buf)
{
	struct dw7914_safe_pulse *dw = dev_get_drvdata(dev);

	return sysfs_emit(buf, "tests=%u last_us=%llu powered=%u pulses=%u\n",
			  dw->stage_test_count, dw->stage_last_us,
			  dw->powered, dw->pulse_count);
}
static DEVICE_ATTR_RO(firmware_stage_status);

static ssize_t firmware_stage_test_store(struct device *dev,
					 struct device_attribute *attr,
					 const char *buf, size_t count)
{
	struct dw7914_safe_pulse *dw = dev_get_drvdata(dev);
	ktime_t started;
	int ret;

	if (sysfs_streq(buf, DW7914_M1892_STAGE_TEST_TOKEN) == 0)
		return -EPERM;

	mutex_lock(&dw->lock);
	started = ktime_get();
	ret = dw7914_stage(dw);
	if (!ret)
		ret = dw7914_require_stopped(dw);
	dw7914_power_off(dw);
	if (!ret) {
		dw->stage_test_count++;
		dw->stage_last_us = ktime_us_delta(ktime_get(), started);
		dev_info(dev,
			 "stock firmware no-output stage passed in %llu us\n",
			 dw->stage_last_us);
	}
	mutex_unlock(&dw->lock);
	return ret ? ret : count;
}
static DEVICE_ATTR_WO(firmware_stage_test);

static ssize_t sparse_stage_status_show(struct device *dev,
					struct device_attribute *attr,
					char *buf)
{
	struct dw7914_safe_pulse *dw = dev_get_drvdata(dev);

	return sysfs_emit(buf, "tests=%u last_us=%llu powered=%u pulses=%u\n",
			  dw->sparse_test_count, dw->sparse_last_us,
			  dw->powered, dw->pulse_count);
}
static DEVICE_ATTR_RO(sparse_stage_status);

static ssize_t sparse_stage_test_store(struct device *dev,
				       struct device_attribute *attr,
				       const char *buf, size_t count)
{
	struct dw7914_safe_pulse *dw = dev_get_drvdata(dev);
	ktime_t started;
	int ret;

	if (sysfs_streq(buf, DW7914_M1892_SPARSE_TEST_TOKEN) == 0)
		return -EPERM;

	mutex_lock(&dw->lock);
	started = ktime_get();
	ret = dw7914_stage_mode(dw, true);
	if (!ret)
		ret = dw7914_require_stopped(dw);
	dw7914_power_off(dw);
	if (!ret) {
		dw->sparse_test_count++;
		dw->sparse_last_us = ktime_us_delta(ktime_get(), started);
		dev_info(dev,
			 "wave19 sparse no-output stage passed in %llu us\n",
			 dw->sparse_last_us);
	}
	mutex_unlock(&dw->lock);
	return ret ? ret : count;
}
static DEVICE_ATTR_WO(sparse_stage_test);
#endif

static struct attribute *dw7914_attrs[] = {
	&dev_attr_safety.attr,
	&dev_attr_hard_stop_status.attr,
#ifndef DW7914_STANDARD_FF
	&dev_attr_hard_stop_test.attr,
	&dev_attr_pulse.attr,
#else
	&dev_attr_firmware_stage_status.attr,
	&dev_attr_firmware_stage_test.attr,
	&dev_attr_sparse_stage_status.attr,
	&dev_attr_sparse_stage_test.attr,
#endif
	NULL,
};

static const struct attribute_group dw7914_group = {
	.attrs = dw7914_attrs,
};

static int dw7914_probe(struct i2c_client *client)
{
	struct device *dev = &client->dev;
	struct dw7914_safe_pulse *dw;
	const char *gpio_name;
	enum gpiod_flags gpio_flags;
	int ret;

	if (!i2c_check_functionality(client->adapter,
				     I2C_FUNC_SMBUS_BYTE_DATA | I2C_FUNC_I2C))
		return dev_err_probe(dev, -EOPNOTSUPP,
				     "required I2C operations unavailable\n");

	dw = devm_kzalloc(dev, sizeof(*dw), GFP_KERNEL);
	if (!dw)
		return -ENOMEM;
	dw->client = client;
	mutex_init(&dw->lock);
	init_completion(&dw->hard_stop_done);
	hrtimer_setup(&dw->hard_stop_timer, dw7914_hard_stop,
		      CLOCK_MONOTONIC, HRTIMER_MODE_REL);

#ifdef DW7914_DIRECT_GPIO_POWER
	if (!of_find_property(dev->of_node, "enable-gpios", NULL))
		return dev_err_probe(dev, -EINVAL,
			"enable GPIO is required\n");
#else
	if (!of_find_property(dev->of_node, "emergency-stop-gpios", NULL))
		return dev_err_probe(dev, -EINVAL,
			"emergency-stop GPIO is required\n");
#endif

#ifndef DW7914_DIRECT_GPIO_POWER
	if (!of_find_property(dev->of_node, "enable-supply", NULL))
		return dev_err_probe(dev, -EINVAL,
			"enable supply is required\n");
	dw->enable_supply = devm_regulator_get_exclusive(dev, "enable");
	if (IS_ERR(dw->enable_supply))
		return dev_err_probe(dev, PTR_ERR(dw->enable_supply),
				     "failed to acquire enable supply\n");
#endif
#ifdef DW7914_DIRECT_GPIO_POWER
	gpio_name = "enable";
	gpio_flags = GPIOD_OUT_LOW;
#else
	gpio_name = "emergency-stop";
	gpio_flags = GPIOD_OUT_LOW | GPIOD_FLAGS_BIT_NONEXCLUSIVE;
#endif
	dw->emergency_stop = devm_gpiod_get(dev, gpio_name, gpio_flags);
	if (IS_ERR(dw->emergency_stop)) {
		ret = PTR_ERR(dw->emergency_stop);
		dev_err(dev, "power-cut GPIO acquisition failed: %d\n", ret);
		return dev_err_probe(dev, ret,
				     "failed to acquire emergency-stop GPIO\n");
	}
	if (gpiod_cansleep(dw->emergency_stop))
		return dev_err_probe(dev, -EOPNOTSUPP,
				     "emergency-stop GPIO is not atomic-safe\n");
	dev_info(dev, "direct atomic power-cut GPIO acquired low\n");

	ret = devm_add_action_or_reset(dev, dw7914_power_off_action, dw);
	if (ret)
		return ret;
	ret = dw7914_power_and_identify(dw);
	dw7914_power_off(dw);
	if (ret) {
		dev_err(dev, "safe identification failed with errno %d\n", ret);
		return dev_err_probe(dev, ret, "safe identification failed\n");
	}

	i2c_set_clientdata(client, dw);
	ret = devm_device_add_group(dev, &dw7914_group);
	if (ret)
		return ret;

#ifdef DW7914_STANDARD_FF
	INIT_WORK(&dw->ff_work, dw7914_ff_work);
	dw->input = devm_input_allocate_device(dev);
	if (!dw->input)
		return -ENOMEM;
	dw->input->name = "gpio-vibrator";
	dw->input->phys = "m1892/dw7914";
	dw->input->id.bustype = BUS_I2C;
	dw->input->dev.parent = dev;
	dw->input->close = dw7914_ff_close;
	input_set_drvdata(dw->input, dw);
	input_set_capability(dw->input, EV_FF, FF_RUMBLE);
	ret = input_ff_create_memless(dw->input, dw, dw7914_ff_play_effect);
	if (ret)
		return dev_err_probe(dev, ret,
				     "failed to create force-feedback device\n");
	ret = input_register_device(dw->input);
	if (ret)
		return dev_err_probe(dev, ret,
				     "failed to register force-feedback device\n");
#endif

	dev_info(dev,
		 "ID 0x%02x; bounded atomic-cutoff haptics ready; powered off\n",
		 dw->device_id);
	return 0;
}

#ifdef DW7914_STANDARD_FF
static void dw7914_remove(struct i2c_client *client)
{
	struct dw7914_safe_pulse *dw = i2c_get_clientdata(client);

	WRITE_ONCE(dw->ff_magnitude, 0);
	cancel_work_sync(&dw->ff_work);
	mutex_lock(&dw->lock);
	dw->ff_command_active = false;
	hrtimer_cancel(&dw->hard_stop_timer);
	dw7914_power_off(dw);
	mutex_unlock(&dw->lock);
}
#endif

#ifdef DW7914_STANDARD_FF
static const struct of_device_id dw7914_of_match[] = {
	{ .compatible = "dongwoon,dw7914-r259" },
	{ }
};
#elif defined(DW7914_DIRECT_GPIO_POWER)
static const struct of_device_id dw7914_of_match[] = {
	{ .compatible = "dongwoon,dw7914-r256" },
	{ .compatible = "dongwoon,dw7914-r255" },
	{ }
};
#else
static const struct of_device_id dw7914_of_match[] = {
	{ .compatible = "dongwoon,dw7914-r254" },
	{ }
};
#endif
MODULE_DEVICE_TABLE(of, dw7914_of_match);

static struct i2c_driver dw7914_driver = {
	.probe = dw7914_probe,
#ifdef DW7914_STANDARD_FF
	.remove = dw7914_remove,
#endif
	.driver = {
		.name = "m1892-dw7914-safe-pulse",
		.of_match_table = dw7914_of_match,
	},
};
module_i2c_driver(dw7914_driver);

#ifdef DW7914_STANDARD_FF
MODULE_DESCRIPTION("Meizu M1892 DW7914 bounded force-feedback driver");
#else
MODULE_DESCRIPTION("Meizu M1892 DW7914 constrained safe-pulse gate");
#endif
MODULE_LICENSE("GPL");
