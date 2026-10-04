#!/bin/bash
# SPDX-License-Identifier: MIT
set -euo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
tree_dir=$(CDPATH= cd -- "$script_dir/.." && pwd)
overlay=$tree_dir/rootfs-overlay
test_root=

fail()
{
	printf 'M1892_OEM_ACCOUNT_STATE_MACHINE_TEST_FAIL: %s\n' "$*" >&2
	exit 1
}

cleanup()
{
	if [ -n "$test_root" ]; then
		case "$test_root" in
			/tmp/m1892-oem-account-test.*)
				[ ! -e "$test_root" ] || find "$test_root" -depth -delete 2>/dev/null || true
				;;
			*) printf 'M1892_OEM_ACCOUNT_STATE_MACHINE_TEST_FAIL: unsafe-cleanup-path\n' >&2 ;;
		esac
	fi
}
trap cleanup EXIT HUP INT TERM

for command in awk bash chmod cmp cp cut find getent grep groupdel id install \
	mkdir mktemp mount passwd sed sha256sum stat sync systemd-sysusers tr \
	unshare userdel wc; do
	command -v "$command" >/dev/null 2>&1 || fail "missing-command:$command"
done
for source in \
	$overlay/usr/libexec/m1892/oem-owner-prepare \
	$overlay/usr/libexec/m1892/oem-owner-finalize \
		$overlay/usr/libexec/m1892/oem-setup-cleanup \
		$overlay/usr/libexec/m1892/oem-setup-recover \
		$overlay/usr/lib/sysusers.d/m1892-oem-setup.conf \
		$overlay/usr/local/share/applications/calamares.desktop \
		/etc/nsswitch.conf /etc/login.defs /etc/shells /etc/alternatives; do
	[ -e "$source" ] || fail "fixture-input-absent:$source"
done
unshare --user --map-root-user true 2>/dev/null || fail unprivileged-userns

test_root=$(mktemp -d /tmp/m1892-oem-account-test.XXXXXXXX)
mock_systemctl=$test_root/systemctl-mock
cat >"$mock_systemctl" <<'EOF'
#!/bin/sh
done_state=absent
if [ -f /var/lib/m1892/oem-setup-cleanup.pass ] &&
	[ "$(wc -l </var/lib/m1892/oem-setup-cleanup.pass)" = 3 ] &&
	grep -Fxc 'result=pass' /var/lib/m1892/oem-setup-cleanup.pass | grep -Fxq 1 &&
	grep -Fxc 'setup_user=removed' /var/lib/m1892/oem-setup-cleanup.pass | grep -Fxq 1; then
	done_state=valid
fi
printf '%s done=%s\n' "$*" "$done_state" >>/var/lib/m1892/systemctl.calls
if [ "${M1892_TEST_SYSTEMCTL_FAIL_ACTION:-}" = "${1:-}" ]; then
	exit 1
fi
case "${M1892_TEST_SYSTEMCTL_RESULT:-pass}" in
	pass) exit 0 ;;
	fail) exit 1 ;;
	*) exit 64 ;;
esac
EOF
chmod 0755 "$mock_systemctl"

make_base()
{
	case_root=$1
	mkdir -p "$case_root/etc/sddm.conf.d" "$case_root/etc/polkit-1/rules.d" \
		"$case_root/etc/xdg/autostart" "$case_root/etc/sudoers.d" \
		"$case_root/home" "$case_root/run" "$case_root/var/lib/m1892" \
		"$case_root/var/lib/m1892-oem-setup" \
		"$case_root/var/lib/AccountsService/users" \
		"$case_root/usr/libexec/m1892" "$case_root/usr/lib/sysusers.d" \
		"$case_root/usr/local/share/applications"
	chmod 0700 "$case_root/var/lib/m1892"
	cp /etc/nsswitch.conf /etc/login.defs /etc/shells "$case_root/etc/"
	cp -a /etc/alternatives "$case_root/etc/"
	cp "$overlay/usr/libexec/m1892/oem-owner-prepare" \
		"$overlay/usr/libexec/m1892/oem-owner-finalize" \
		"$overlay/usr/libexec/m1892/oem-setup-cleanup" \
		"$overlay/usr/libexec/m1892/oem-setup-recover" \
		"$case_root/usr/libexec/m1892/"
	chmod 0755 "$case_root/usr/libexec/m1892/"*
	cp "$overlay/usr/lib/sysusers.d/m1892-oem-setup.conf" \
		"$case_root/usr/lib/sysusers.d/"
	printf 'account_mode=oem-owner\n' >"$case_root/etc/m1892-rootfs-identity"
	printf 'fixture-policy\n' >"$case_root/etc/polkit-1/rules.d/49-m1892-oem-setup.rules"
	printf 'fixture-autostart\n' >"$case_root/etc/xdg/autostart/m1892-oem-account-setup.desktop"
	printf 'fixture-desktop\n' \
		>"$case_root/usr/local/share/applications/m1892-oem-account-setup.desktop"
	cp "$overlay/usr/local/share/applications/calamares.desktop" \
		"$case_root/usr/local/share/applications/calamares.desktop"
	cat >"$case_root/etc/sddm.conf.d/90-m1892-oem-account.conf" <<'EOF'
[Autologin]
User=m1892-setup
Session=plasma-mobile.desktop
Relogin=true
EOF
}

# ACCOUNT specs have the form name:uid:valid-or-invalid. The duplicate uid-0
# NSS entries in valid fixtures are test-only: a single-id user namespace cannot
# chown to uid 1000, so they make stat(1) resolve fixture ownership to the tested
# owner while getpwnam() still returns the first, normal-uid entry.
write_accounts()
{
	case_root=$1
	shift
	owners=("$@")
	{
		for owner_spec in "${owners[@]}"; do
			owner=${owner_spec%%:*}
			tail=${owner_spec#*:}
			uid=${tail%%:*}
			valid=${owner_spec##*:}
			printf '%s:x:%s:%s::/home/%s:/bin/bash\n' \
				"$owner" "$uid" "$uid" "$owner"
			if [ "$valid" = valid ]; then
				printf '%s:x:0:0:fixture-owner:/nonexistent:/usr/sbin/nologin\n' "$owner"
			fi
		done
		printf 'root:x:0:0:root:/root:/bin/bash\n'
		printf 'm1892-setup:x:999:999:M1892 OEM Setup:/var/lib/m1892-oem-setup:/bin/bash\n'
		printf 'nobody:x:65534:65534:nobody:/nonexistent:/usr/sbin/nologin\n'
	} >"$case_root/etc/passwd"
	{
		for owner_spec in "${owners[@]}"; do
			owner=${owner_spec%%:*}
			valid=${owner_spec##*:}
			if [ "$valid" = valid ]; then password=x; else password='!*'; fi
			printf '%s:%s:20703:0:99999:7:::\n' "$owner" "$password"
		done
		printf 'root:!*:20703:0:99999:7:::\n'
		printf 'm1892-setup:!*:20703:0:99999:7:::\n'
	} >"$case_root/etc/shadow"
	chmod 0600 "$case_root/etc/shadow"
	{
		for owner_spec in "${owners[@]}"; do
			owner=${owner_spec%%:*}
			tail=${owner_spec#*:}
			uid=${tail%%:*}
			valid=${owner_spec##*:}
			printf '%s:x:%s:\n' "$owner" "$uid"
			[ "$valid" != valid ] || printf '%s:x:0:\n' "$owner"
		done
		printf 'root:x:0:\n'
		printf 'm1892-setup:x:999:\n'
		gid=100
		for group in users sudo audio video input render netdev bluetooth docker; do
			members=
			for owner_spec in "${owners[@]}"; do
				owner=${owner_spec%%:*}
				valid=${owner_spec##*:}
				[ "$valid" = valid ] || continue
				members=${members:+$members,}$owner
			done
			printf '%s:x:%s:%s\n' "$group" "$gid" "$members"
			gid=$((gid + 1))
		done
		printf 'nobody:x:65534:\n'
	} >"$case_root/etc/group"
	awk -F: '{ print $1 ":!::" $4 ":" }' "$case_root/etc/group" \
		>"$case_root/etc/gshadow"
	chmod 0600 "$case_root/etc/gshadow"
	find "$case_root/home" -mindepth 1 -maxdepth 1 -type d \
		-exec find {} -depth -delete \;
	for owner_spec in "${owners[@]}"; do
		owner=${owner_spec%%:*}
		mkdir -p "$case_root/home/$owner"
		chmod 0700 "$case_root/home/$owner"
	done
	chmod 0700 "$case_root/var/lib/m1892-oem-setup"
}

run_isolated()
{
	case_root=$1
	systemctl_result=$2
	command=$3
	unshare --user --map-root-user --mount --fork \
		env M1892_TEST_SYSTEMCTL_RESULT="$systemctl_result" \
		bash -eu -c '
		case_root=$1
		mount --bind "$case_root/etc" /etc
		mount --bind "$case_root/home" /home
		mount --bind "$case_root/run" /run
		mount --bind "$case_root/var/lib" /var/lib
		mount --bind "$case_root/usr/libexec" /usr/libexec
		mount --bind "$case_root/usr/lib/sysusers.d" /usr/lib/sysusers.d
		mount --bind "$case_root/usr/local/share" /usr/local/share
		# The setup account is already present in every fixture. Avoid an
		# unmapped system-uid chown that a single-id userns cannot represent.
		mount --bind /bin/true /usr/bin/systemd-sysusers
		mount --bind "$2" /usr/bin/systemctl
		eval "$3"
	' _ "$case_root" "$mock_systemctl" "$command"
}

require_line()
{
	grep -Fxq "$2" "$1" || fail "line:$1:$2"
}

require_no_regular_owner()
{
	if awk -F: '$3 >= 1000 && $3 < 65534 { found=1 } END { exit found ? 0 : 1 }' \
		"$1/etc/passwd"; then
		fail "unexpected-regular-owner:$1"
	fi
}

# 1. Fresh recovery and a repeated pending transaction with no created user.
case_root=$test_root/01-fresh-and-pending
make_base "$case_root"
write_accounts "$case_root"
run_isolated "$case_root" pass \
	'/usr/libexec/m1892/oem-setup-recover; /usr/libexec/m1892/oem-setup-recover' \
	>"$case_root/fresh.log" 2>&1
require_line "$case_root/var/lib/m1892/oem-setup-recovery.log" state=fresh-setup
[ "$(stat -c %a "$case_root/var/lib/m1892")" = 755 ] || fail fresh-state-directory-mode
[ "$(stat -c %a "$case_root/var/lib/m1892/oem-setup-recovery.log")" = 600 ] ||
	fail recovery-log-mode
if run_isolated "$case_root" pass '/usr/libexec/m1892/oem-owner-prepare audio' \
	>"$case_root/group-collision.log" 2>&1; then
	fail existing-group-owner-name-passed
fi
require_line "$case_root/group-collision.log" \
	'M1892_OEM_OWNER_PREPARE_FAIL: owner-group-preexisting'
[ ! -e "$case_root/var/lib/m1892/oem-owner-pending" ] || fail group-collision-created-pending
run_isolated "$case_root" pass \
	"/usr/libexec/m1892/oem-owner-prepare 'owner$'; /usr/libexec/m1892/oem-owner-prepare 'owner$'" \
	>"$case_root/prepare.log" 2>&1
require_line "$case_root/var/lib/m1892/oem-owner-pending" 'owner=owner$'
[ "$(stat -c %a "$case_root/var/lib/m1892")" = 755 ] || fail pending-state-directory-mode
[ "$(stat -c %a "$case_root/var/lib/m1892/oem-owner-pending")" = 600 ] ||
	fail pending-marker-mode
pending_hash=$(sha256sum "$case_root/var/lib/m1892/oem-owner-pending" | awk '{print $1}')
run_isolated "$case_root" pass "/usr/libexec/m1892/oem-owner-prepare 'owner$'" \
	>"$case_root/prepare-again.log" 2>&1
[ "$(sha256sum "$case_root/var/lib/m1892/oem-owner-pending" | awk '{print $1}')" = \
	"$pending_hash" ] || fail pending-not-idempotent
run_isolated "$case_root" pass \
	'/usr/libexec/m1892/oem-setup-recover; /usr/libexec/m1892/oem-setup-recover' \
	>"$case_root/pending-recover.log" 2>&1
[ ! -e "$case_root/var/lib/m1892/oem-owner-pending" ] || fail pending-not-cleared
require_no_regular_owner "$case_root"

# 2. Valid owner ending in $, autologin, injected enable failure, finalize and
# cleanup re-entry, and completed-state enable/disable ordering.
case_root=$test_root/02-valid-autologin-dollar
make_base "$case_root"
write_accounts "$case_root"
run_isolated "$case_root" pass \
	"/usr/libexec/m1892/oem-owner-prepare 'owner$'; /usr/libexec/m1892/oem-owner-prepare 'owner$'" \
	>"$case_root/prepare.log" 2>&1
write_accounts "$case_root" 'owner$:1000:valid'
cat >"$case_root/etc/sddm.conf.d/90-m1892-oem-account.conf" <<'EOF'
[Autologin]
User=owner$
Session=plasma-mobile.desktop
Relogin=true
EOF
if run_isolated "$case_root" fail "/usr/libexec/m1892/oem-owner-finalize 'owner$'" \
	>"$case_root/atomic-fail.log" 2>&1; then
	fail injected-systemctl-failure-passed
fi
[ ! -e "$case_root/var/lib/m1892/oem-owner-created" ] || fail marker-after-failed-enable
[ -e "$case_root/var/lib/m1892/oem-owner-pending" ] || fail pending-lost-after-failed-enable
if find "$case_root/var/lib/m1892" -maxdepth 1 -name '.oem-owner-created.*' \
	-print -quit | grep -q .; then
	fail temporary-marker-leaked
fi
run_isolated "$case_root" pass \
	"/usr/libexec/m1892/oem-owner-finalize 'owner$'; /usr/libexec/m1892/oem-owner-finalize 'owner$'" \
	>"$case_root/finalize.log" 2>&1
[ "$(stat -c %a "$case_root/var/lib/m1892")" = 755 ] || fail owner-state-directory-mode
[ "$(stat -c %a "$case_root/var/lib/m1892/oem-owner-created")" = 644 ] ||
	fail owner-marker-mode
require_line "$case_root/var/lib/m1892/oem-owner-created" 'owner=owner$'
require_line "$case_root/var/lib/m1892/oem-owner-created" autologin=yes
[ ! -e "$case_root/var/lib/m1892/oem-owner-pending" ] || fail pending-after-finalize
marker_hash=$(sha256sum "$case_root/var/lib/m1892/oem-owner-created" | awk '{print $1}')
if run_isolated "$case_root" pass \
	'M1892_TEST_SYSTEMCTL_FAIL_ACTION=disable /usr/libexec/m1892/oem-setup-cleanup' \
	>"$case_root/cleanup-interrupted.log" 2>&1; then
	fail cleanup-disable-failure-passed
fi
require_line "$case_root/var/lib/m1892/oem-setup-cleanup.pass" 'owner=owner$'
[ "$(stat -c %a "$case_root/var/lib/m1892/oem-setup-cleanup.pass")" = 600 ] ||
	fail cleanup-marker-mode
run_isolated "$case_root" pass '/usr/libexec/m1892/oem-setup-cleanup' \
	>"$case_root/cleanup-reentry.log" 2>&1
[ "$(stat -c %a "$case_root/var/lib/m1892")" = 755 ] || fail cleanup-state-directory-mode
[ ! -e "$case_root/usr/local/share/applications/m1892-oem-account-setup.desktop" ] ||
	fail setup-launcher-retained
cmp -s "$case_root/usr/local/share/applications/calamares.desktop" \
	"$overlay/usr/local/share/applications/calamares.desktop" ||
	fail calamares-hidden-override-changed
if grep -F 'disable m1892-oem-setup-recovery.service m1892-oem-setup-cleanup.service done=absent' \
	"$case_root/var/lib/m1892/systemctl.calls" >/dev/null; then
	fail cleanup-disabled-before-durable-marker
fi
require_line "$case_root/var/lib/m1892/systemctl.calls" \
	'disable m1892-oem-setup-recovery.service m1892-oem-setup-cleanup.service done=valid'
enable_before=$(grep -c '^enable ' "$case_root/var/lib/m1892/systemctl.calls")
disable_before=$(grep -c '^disable ' "$case_root/var/lib/m1892/systemctl.calls")
run_isolated "$case_root" pass "/usr/libexec/m1892/oem-owner-finalize 'owner$'" \
	>"$case_root/completed-finalize.log" 2>&1
[ "$(grep -c '^enable ' "$case_root/var/lib/m1892/systemctl.calls")" = "$enable_before" ] ||
	fail completed-finalize-reenabled-service
[ "$(grep -c '^disable ' "$case_root/var/lib/m1892/systemctl.calls")" = \
	"$((disable_before + 1))" ] || fail completed-finalize-did-not-maintain-disable
[ "$(sha256sum "$case_root/var/lib/m1892/oem-owner-created" | awk '{print $1}')" = \
	"$marker_hash" ] || fail completed-finalize-changed-marker

# 3. Valid owner with explicitly disabled autologin.
case_root=$test_root/03-valid-no-autologin
make_base "$case_root"
write_accounts "$case_root"
run_isolated "$case_root" pass '/usr/libexec/m1892/oem-owner-prepare alice' \
	>"$case_root/prepare.log" 2>&1
write_accounts "$case_root" 'alice:1000:valid'
cat >"$case_root/etc/sddm.conf.d/90-m1892-oem-account.conf" <<'EOF'
[Autologin]
User=
Session=plasma-mobile.desktop
Relogin=true
EOF
run_isolated "$case_root" pass \
	'/usr/libexec/m1892/oem-owner-finalize alice; /usr/libexec/m1892/oem-setup-cleanup' \
	>"$case_root/run.log" 2>&1
require_line "$case_root/var/lib/m1892/oem-owner-created" autologin=no
require_line "$case_root/etc/sddm.conf.d/90-m1892-oem-account.conf" User=

# 4. A unique regular account without a pending transaction is never deleted.
case_root=$test_root/04-unowned-unique
make_base "$case_root"
write_accounts "$case_root" 'stranger:1000:valid'
accounts_before=$(sha256sum "$case_root/etc/passwd" "$case_root/etc/group")
if run_isolated "$case_root" pass '/usr/libexec/m1892/oem-setup-recover' \
	>"$case_root/recover.log" 2>&1; then
	fail unowned-account-recovery-passed
fi
require_line "$case_root/recover.log" \
	'M1892_OEM_SETUP_RECOVERY_FAIL: unowned-regular-account'
accounts_after=$(sha256sum "$case_root/etc/passwd" "$case_root/etc/group")
[ "$accounts_before" = "$accounts_after" ] || fail unowned-account-database-changed
grep -q '^stranger:x:1000:' "$case_root/etc/passwd" || fail unowned-account-deleted
[ -d "$case_root/home/stranger" ] || fail unowned-home-deleted

# 5. An invalid half-account is deleted only when an exact pending transaction
# names it; the following recovery is a clean fresh-state no-op.
case_root=$test_root/05-pending-partial
make_base "$case_root"
write_accounts "$case_root"
run_isolated "$case_root" pass '/usr/libexec/m1892/oem-owner-prepare broken' \
	>"$case_root/prepare.log" 2>&1
write_accounts "$case_root" 'broken:1000:invalid'
run_isolated "$case_root" pass '/usr/libexec/m1892/oem-setup-recover' \
	>"$case_root/recover.log" 2>&1
grep -Fq 'M1892_OEM_OWNER_FINALIZE_FAIL:' "$case_root/recover.log" ||
	fail partial-owner-was-not-rejected
require_line "$case_root/var/lib/m1892/oem-setup-recovery.log" \
	state=partial-owner-rolled-back
[ "$(stat -c %a "$case_root/var/lib/m1892")" = 755 ] ||
	fail partial-recovery-state-directory-mode
[ "$(stat -c %a "$case_root/var/lib/m1892/oem-setup-recovery.log")" = 600 ] ||
	fail partial-recovery-log-mode
if grep -q '^broken:' "$case_root/etc/passwd"; then fail partial-owner-retained; fi
[ ! -e "$case_root/home/broken" ] || fail partial-home-retained
[ ! -e "$case_root/var/lib/m1892/oem-owner-pending" ] || fail partial-pending-retained
run_isolated "$case_root" pass '/usr/libexec/m1892/oem-setup-recover' \
	>"$case_root/rerun.log" 2>&1
require_line "$case_root/var/lib/m1892/oem-setup-recovery.log" state=fresh-setup

# 6. A malformed final marker without pending provenance fails closed and does
# not change or delete the account.
case_root=$test_root/06-malformed-no-pending
make_base "$case_root"
write_accounts "$case_root" 'alice:1000:valid'
printf 'owner=alice\n' >"$case_root/var/lib/m1892/oem-owner-created"
accounts_before=$(sha256sum "$case_root/etc/passwd" "$case_root/etc/group")
if run_isolated "$case_root" pass '/usr/libexec/m1892/oem-setup-recover' \
	>"$case_root/recover.log" 2>&1; then
	fail malformed-unowned-marker-recovery-passed
fi
require_line "$case_root/recover.log" \
	'M1892_OEM_SETUP_RECOVERY_FAIL: unowned-regular-account'
accounts_after=$(sha256sum "$case_root/etc/passwd" "$case_root/etc/group")
[ "$accounts_before" = "$accounts_after" ] || fail malformed-marker-changed-account
[ "$(cat "$case_root/var/lib/m1892/oem-owner-created")" = owner=alice ] ||
	fail malformed-marker-changed
[ -d "$case_root/home/alice" ] || fail malformed-marker-deleted-home

# 7. The same malformed marker is repaired when an exact, valid pending
# transaction exists, then the completed state remains re-entrant.
case_root=$test_root/07-malformed-with-pending
make_base "$case_root"
write_accounts "$case_root"
run_isolated "$case_root" pass '/usr/libexec/m1892/oem-owner-prepare alice' \
	>"$case_root/prepare.log" 2>&1
write_accounts "$case_root" 'alice:1000:valid'
printf 'owner=alice\n' >"$case_root/var/lib/m1892/oem-owner-created"
cat >"$case_root/etc/sddm.conf.d/90-m1892-oem-account.conf" <<'EOF'
[Autologin]
User=alice
Session=plasma-mobile.desktop
Relogin=true
EOF
run_isolated "$case_root" pass '/usr/libexec/m1892/oem-setup-recover' \
	>"$case_root/recover.log" 2>&1
require_line "$case_root/var/lib/m1892/oem-owner-created" result=pass
require_line "$case_root/var/lib/m1892/oem-owner-created" owner=alice
[ ! -e "$case_root/var/lib/m1892/oem-owner-pending" ] || fail repaired-pending-retained
require_line "$case_root/var/lib/m1892/oem-setup-cleanup.pass" setup_user=removed
[ "$(stat -c %a "$case_root/var/lib/m1892")" = 755 ] || fail repaired-state-directory-mode
[ "$(stat -c %a "$case_root/var/lib/m1892/oem-owner-created")" = 644 ] ||
	fail repaired-owner-marker-mode
[ "$(stat -c %a "$case_root/var/lib/m1892/oem-setup-cleanup.pass")" = 600 ] ||
	fail repaired-cleanup-marker-mode
run_isolated "$case_root" pass \
	'/usr/libexec/m1892/oem-setup-cleanup; /usr/libexec/m1892/oem-setup-recover' \
	>"$case_root/rerun.log" 2>&1

# 8. Multiple normal accounts always fail closed without changing either one.
case_root=$test_root/08-multiple
make_base "$case_root"
write_accounts "$case_root" 'alice:1000:valid' 'bob:1001:valid'
accounts_before=$(sha256sum "$case_root/etc/passwd" "$case_root/etc/group")
if run_isolated "$case_root" pass '/usr/libexec/m1892/oem-setup-recover' \
	>"$case_root/run-1.log" 2>&1; then
	fail multiple-account-recovery-passed
fi
if run_isolated "$case_root" pass '/usr/libexec/m1892/oem-setup-recover' \
	>"$case_root/run-2.log" 2>&1; then
	fail multiple-account-recovery-rerun-passed
fi
accounts_after=$(sha256sum "$case_root/etc/passwd" "$case_root/etc/group")
[ "$accounts_before" = "$accounts_after" ] || fail multiple-account-database-changed
require_line "$case_root/run-1.log" \
	'M1892_OEM_SETUP_RECOVERY_FAIL: multiple-owner-candidates'

echo M1892_OEM_ACCOUNT_STATE_MACHINE_TEST_PASS
