// SPDX-License-Identifier: MIT
// Derived from postmarketOS q6voiced 0.3.1.
// M1892 requires an explicit 1024-frame period / 4096-frame buffer contract;
// snd_pcm_set_params(..., 500000us) chooses 4000 frames and the product
// VoiceMMode1 DAI rejects that layout with -EINVAL.

#include <alsa/asoundlib.h>
#include <dbus/dbus.h>
#include <errno.h>
#include <stdbool.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

struct q6voiced {
	char card[64];
	snd_pcm_t *tx;
	snd_pcm_t *rx;
};

static bool mixer_switch_is_on(const char *pcm, const char *name)
{
	snd_ctl_elem_value_t *value;
	snd_ctl_elem_id_t *id;
	snd_ctl_t *ctl = NULL;
	char card[64];
	char *device;
	bool enabled = false;

	strncpy(card, pcm, sizeof(card) - 1);
	card[sizeof(card) - 1] = '\0';
	device = strrchr(card, ',');
	if (device)
		*device = '\0';
	if (snd_ctl_open(&ctl, card, 0) < 0)
		return false;

	snd_ctl_elem_id_alloca(&id);
	snd_ctl_elem_value_alloca(&value);
	snd_ctl_elem_id_set_interface(id, SND_CTL_ELEM_IFACE_MIXER);
	snd_ctl_elem_id_set_name(id, name);
	snd_ctl_elem_value_set_id(value, id);
	if (snd_ctl_elem_read(ctl, value) == 0)
		enabled = snd_ctl_elem_value_get_boolean(value, 0);
	snd_ctl_close(ctl);
	return enabled;
}

static bool voice_route_ready(const struct q6voiced *voice)
{
	return mixer_switch_is_on(voice->card,
		"QUAT_MI2S_RX Voice Mixer VoiceMMode1") &&
	       mixer_switch_is_on(voice->card,
		"VoiceMMode1 Capture Mixer SLIMBUS_0_TX");
}

static int prepare_pcm(snd_pcm_t **pcm, const char *card,
		       snd_pcm_stream_t stream, const char *name)
{
	snd_pcm_hw_params_t *params;
	unsigned int rate = 8000;
	unsigned int periods = 4;
	snd_pcm_uframes_t period_size = 1024;
	snd_pcm_uframes_t buffer_size = 4096;
	int direction = 0;
	int ret;

	ret = snd_pcm_open(pcm, card, stream, SND_PCM_NONBLOCK);
	if (ret < 0)
		goto fail;
	snd_pcm_hw_params_alloca(&params);
	if ((ret = snd_pcm_hw_params_any(*pcm, params)) < 0 ||
	    (ret = snd_pcm_hw_params_set_access(*pcm, params,
					     SND_PCM_ACCESS_RW_INTERLEAVED)) < 0 ||
	    (ret = snd_pcm_hw_params_set_format(*pcm, params,
					     SND_PCM_FORMAT_S16_LE)) < 0 ||
	    (ret = snd_pcm_hw_params_set_channels(*pcm, params, 1)) < 0 ||
	    (ret = snd_pcm_hw_params_set_rate_near(*pcm, params, &rate,
						    &direction)) < 0 ||
	    rate != 8000 ||
	    (ret = snd_pcm_hw_params_set_period_size_near(*pcm, params,
							    &period_size,
							    &direction)) < 0 ||
	    period_size != 1024 ||
	    (ret = snd_pcm_hw_params_set_periods_near(*pcm, params, &periods,
						       &direction)) < 0 ||
	    periods != 4 ||
	    (ret = snd_pcm_hw_params_set_buffer_size_near(*pcm, params,
							    &buffer_size)) < 0 ||
	    buffer_size != 4096 ||
	    (ret = snd_pcm_hw_params(*pcm, params)) < 0 ||
	    (ret = snd_pcm_prepare(*pcm)) < 0) {
		if (ret >= 0)
			ret = -EINVAL;
		goto fail;
	}

	fprintf(stderr, "%s prepared: 8000 Hz mono, period=1024, buffer=4096\n",
		name);
	return 0;

fail:
	fprintf(stderr, "Failed to prepare %s: %s\n", name,
		snd_strerror(ret));
	if (*pcm) {
		snd_pcm_close(*pcm);
		*pcm = NULL;
	}
	return ret;
}

static void q6voiced_close(struct q6voiced *voice)
{
	if (voice->rx) {
		snd_pcm_close(voice->rx);
		voice->rx = NULL;
	}
	if (voice->tx) {
		snd_pcm_close(voice->tx);
		voice->tx = NULL;
	}
	fprintf(stderr, "VoiceMMode1 PCMs closed\n");
}

static void q6voiced_open(struct q6voiced *voice)
{
	unsigned int attempt;
	unsigned int stable_samples = 0;

	if (voice->tx || voice->rx)
		return;

	/* GNOME Calls and q6voiced receive the same ACTIVE signal.  Calls then
	 * switches the UCM profile asynchronously.  Mixer bits appear early, while
	 * PulseAudio may still be closing the HiFi PCMs and opening the Voice Call
	 * endpoints.  Starting VoiceMMode1 in that interval races the WCD9340 SLIM
	 * channel transaction and intermittently produces DEF_ACT_CHAN (0x21)
	 * timeouts with silent uplink and downlink.  Require the route to remain
	 * present for one full second before opening the hostless PCMs. */
	for (attempt = 1; attempt <= 50; attempt++) {
		if (!voice_route_ready(voice)) {
			stable_samples = 0;
			if (attempt == 1)
				fprintf(stderr, "Waiting for Voice Call UCM route\n");
			usleep(100000);
			continue;
		}
		stable_samples++;
		if (stable_samples < 10) {
			usleep(100000);
			continue;
		}
		fprintf(stderr, "Voice Call UCM route stable for 1000 ms\n");
		/* The accepted M1892 kernel starts the bidirectional DSP path from
		 * the second DAI prepare callback, after both directions have received
		 * hw_params.  Prepare playback first and capture second consistently;
		 * either order is valid with that kernel, while keeping one canonical
		 * order makes service logs and regressions directly comparable. */
		if (prepare_pcm(&voice->rx, voice->card, SND_PCM_STREAM_PLAYBACK,
				"VoiceMMode1 playback") == 0 &&
		    prepare_pcm(&voice->tx, voice->card, SND_PCM_STREAM_CAPTURE,
				"VoiceMMode1 capture") == 0) {
			fprintf(stderr, "VoiceMMode1 PCMs opened on attempt %u\n",
				attempt);
			return;
		}
		if (voice->rx) {
			snd_pcm_close(voice->rx);
			voice->rx = NULL;
		}
		if (voice->tx) {
			snd_pcm_close(voice->tx);
			voice->tx = NULL;
		}
		if (attempt < 50)
			usleep(100000);
	}
	fprintf(stderr, "VoiceMMode1 PCMs unavailable after 5 seconds\n");
}

static bool state_is_active(dbus_int32_t state)
{
	return state == 1 || state == 2 || state == 4;
}

static bool read_state_change(DBusMessage *message, dbus_int32_t *old_state,
			      dbus_int32_t *new_state)
{
	DBusMessageIter iter;

	if (!dbus_message_iter_init(message, &iter) ||
	    dbus_message_iter_get_arg_type(&iter) != DBUS_TYPE_INT32)
		return false;
	dbus_message_iter_get_basic(&iter, old_state);
	if (!dbus_message_iter_next(&iter) ||
	    dbus_message_iter_get_arg_type(&iter) != DBUS_TYPE_INT32)
		return false;
	dbus_message_iter_get_basic(&iter, new_state);
	/* ModemManager adds a third uint32 reason argument.  It is intentionally
	 * ignored, while legacy two-argument emitters remain accepted. */
	return true;
}

static void handle_signal(struct q6voiced *voice, DBusMessage *message)
{
	dbus_int32_t old_state;
	dbus_int32_t new_state;

	if (dbus_message_is_signal(message, "org.ofono.VoiceCallManager",
				   "CallAdded")) {
		q6voiced_open(voice);
	} else if (dbus_message_is_signal(message, "org.ofono.VoiceCallManager",
					  "CallRemoved")) {
		q6voiced_close(voice);
	} else if (dbus_message_is_signal(message,
					  "org.freedesktop.ModemManager1.Call",
					  "StateChanged") &&
		   read_state_change(message, &old_state, &new_state)) {
		fprintf(stderr, "ModemManager call state %d -> %d\n",
			old_state, new_state);
		if (state_is_active(new_state))
			q6voiced_open(voice);
		else if (state_is_active(old_state) && !state_is_active(new_state))
			q6voiced_close(voice);
	}
}

int main(int argc, char **argv)
{
	struct q6voiced voice = {0};
	DBusConnection *connection;
	DBusMessage *message;
	DBusError error;

	if (argc != 2) {
		fprintf(stderr, "Usage: %s hw:<card>,<device>\n", argv[0]);
		return 2;
	}
	strncpy(voice.card, argv[1], sizeof(voice.card) - 1);
	dbus_error_init(&error);
	connection = dbus_bus_get(DBUS_BUS_SYSTEM, &error);
	if (!connection) {
		fprintf(stderr, "D-Bus connection failed: %s\n",
			error.message ? error.message : "unknown error");
		return 1;
	}
	dbus_bus_add_match(connection,
		"type='signal',interface='org.ofono.VoiceCallManager'", &error);
	dbus_bus_add_match(connection,
		"type='signal',interface='org.freedesktop.ModemManager1.Call'", &error);
	dbus_connection_flush(connection);
	if (dbus_error_is_set(&error)) {
		fprintf(stderr, "D-Bus match failed: %s\n", error.message);
		return 1;
	}

	while (dbus_connection_read_write(connection, -1)) {
		while ((message = dbus_connection_pop_message(connection))) {
			handle_signal(&voice, message);
			dbus_message_unref(message);
		}
	}
	q6voiced_close(&voice);
	return 0;
}
