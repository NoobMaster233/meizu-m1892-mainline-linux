#!/bin/sh
# SPDX-License-Identifier: MIT
# Measure an attended M1892 suspend cycle from a host that does not suspend.
set -eu

fail() { echo "M1892_HOST_SUSPEND_FAIL: $*" >&2; exit 1; }
target=${M1892_SSH_TARGET:-}
timeout_seconds=${M1892_HOST_SUSPEND_TIMEOUT_SECONDS:-43200}
remote_test=${M1892_REMOTE_SUSPEND_TEST:-/run/m1892-test-manual-suspend-real}
remote_cellular_acceptance=${M1892_REMOTE_CELLULAR_ACCEPTANCE:-/usr/libexec/m1892/cellular-acceptance}

[ -n "$target" ] || fail missing-ssh-target
case $target in *@*);; *) fail invalid-ssh-target ;; esac
case $timeout_seconds in ''|*[!0-9]*) fail invalid-timeout ;; esac
[ "$timeout_seconds" -ge 30 ] || fail timeout-too-short
case $remote_test in /run/m1892-*) ;; *) fail invalid-remote-test ;; esac
case ${remote_test#/run/m1892-} in ''|*[!A-Za-z0-9_.-]*) fail invalid-remote-test ;; esac
case $remote_cellular_acceptance in
	/usr/libexec/m1892/cellular-acceptance|/run/m1892-cellular-acceptance) ;;
	*) fail invalid-remote-cellular-acceptance ;;
esac
for command in date sed ssh; do
	command -v "$command" >/dev/null 2>&1 || fail "missing-command:$command"
done

remote()
{
	ssh -o BatchMode=yes -o ConnectTimeout=3 "$target" "$@"
}

model=$(remote 'tr -d "\000" </sys/firmware/devicetree/base/model') ||
	fail authentication
[ "$model" = 'Meizu 16th Plus (M1892)' ] || fail wrong-hardware
boot_id=$(remote 'cat /proc/sys/kernel/random/boot_id') || fail boot-id
unit=m1892-host-s2idle-$(date -u +%Y%m%dT%H%M%SZ)-$$
host_start=$(date +%s)
remote "systemd-run --unit=$unit --property=RemainAfterExit=yes env M1892_CELLULAR_ACCEPTANCE=$remote_cellular_acceptance $remote_test" \
	>/dev/null || fail start

saw_unreachable=no
attempts=0
max_attempts=$((timeout_seconds / 3 + 1))
while [ "$attempts" -lt "$max_attempts" ]; do
	attempts=$((attempts + 1))
	if current=$(remote 'printf "%s\n" "$(tr -d "\000" </sys/firmware/devicetree/base/model)"; cat /proc/sys/kernel/random/boot_id' 2>/dev/null); then
		if [ "$saw_unreachable" = yes ]; then
			current_model=$(printf '%s\n' "$current" | sed -n '1p')
			current_boot=$(printf '%s\n' "$current" | sed -n '2p')
			[ "$current_model" = 'Meizu 16th Plus (M1892)' ] || fail resume-wrong-hardware
			[ "$current_boot" = "$boot_id" ] || fail resume-rebooted
			host_resume=$(date +%s)
			validation_wait=0
			while [ "$validation_wait" -le 330 ]; do
				unit_state=$(remote "systemctl show $unit -p ActiveState -p SubState -p Result -p ExecMainStatus" \
					2>/dev/null || true)
				active_state=$(printf '%s\n' "$unit_state" |
					sed -n 's/^ActiveState=//p')
				sub_state=$(printf '%s\n' "$unit_state" |
					sed -n 's/^SubState=//p')
				unit_result=$(printf '%s\n' "$unit_state" |
					sed -n 's/^Result=//p')
				exec_status=$(printf '%s\n' "$unit_state" |
					sed -n 's/^ExecMainStatus=//p')
				if [ "$active_state" = active ] && [ "$sub_state" = exited ]; then
					[ "$unit_result" = success ] && [ "$exec_status" = 0 ] ||
						fail remote-validation-result
					break
				fi
				[ "$active_state" != failed ] || fail remote-validation-failed
				sleep 1
				validation_wait=$((validation_wait + 1))
			done
			[ "$validation_wait" -le 330 ] || fail remote-validation-timeout
			remote "journalctl -u $unit --no-pager | grep -Fxq M1892_S2IDLE_PASS" ||
				fail remote-validation-missing-pass
			remote "systemctl stop $unit; systemctl reset-failed $unit 2>/dev/null || true" \
				>/dev/null || true
			host_end=$(date +%s)
			echo format=m1892-host-suspend-test-v1
			echo boot_id="$boot_id"
			echo unit="$unit"
			echo host_start_epoch="$host_start"
			echo host_resume_epoch="$host_resume"
			echo host_elapsed_seconds="$((host_resume - host_start))"
			echo remote_validation_seconds="$((host_end - host_resume))"
			echo unreachable_observed=yes
			echo M1892_HOST_SUSPEND_PASS
			exit 0
		fi
	else
		saw_unreachable=yes
	fi
	sleep 3
done

[ "$saw_unreachable" = yes ] || fail never-became-unreachable
fail resume-timeout
