#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Small synthetic ext4 positive/negative tests; no real device or private data."""

import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


SCRIPT = Path(__file__).with_name("verify-release-image-privacy.py")
SPEC = importlib.util.spec_from_file_location("release_privacy", SCRIPT)
PRIVACY = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = PRIVACY
SPEC.loader.exec_module(PRIVACY)


@unittest.skipUnless(shutil.which("mkfs.ext4") and shutil.which("debugfs"), "e2fsprogs required")
class ImagePrivacyTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="m1892-privacy-test-")
        self.base = Path(self.temp.name)
        self.root = self.base / "root"
        self.root.mkdir()
        for path in ("etc/skel/.config", "etc/ssh", "home", "root", "usr/lib", "var/log",
                     "var/lib/m1892-oem-setup/.config", "etc/NetworkManager/system-connections"):
            (self.root / path).mkdir(parents=True, exist_ok=True)
        self.write("etc/passwd", "root:x:0:0:root:/root:/bin/bash\n"
                   "m1892-setup:x:988:988:M1892 OEM Setup:/var/lib/m1892-oem-setup:/bin/bash\n"
                   "nobody:x:65534:65534:nobody:/nonexistent:/usr/sbin/nologin\n")
        self.write("etc/shadow", "root:*:20000:0:99999:7:::\n"
                   "m1892-setup:!*:20000:0:99999:7:::\nnobody:*:20000:0:99999:7:::\n")
        self.write("etc/group", "root:x:0:\nm1892-setup:x:988:\nnogroup:x:65534:\n")
        self.write("etc/gshadow", "root:*::\nm1892-setup:!::\nnogroup:*::\n")
        self.write("etc/machine-id", "")
        self.write("etc/hostname", "m1892\n")
        self.write("etc/m1892-rootfs-identity", "distribution=debian\nversion=13\n"
                   "account_mode=oem-owner\nroot_mode=persistent-userdata\n")
        self.write("etc/NetworkManager/system-connections/m1892-cellular.nmconnection", PRIVACY.GSM_PROFILE)
        overlay = SCRIPT.parent.parent / "rootfs-overlay"
        sysusers = "usr/lib/sysusers.d/m1892-oem-setup.conf"
        self.write(sysusers, (overlay / sysusers).read_bytes())
        for name in PRIVACY.CONFIG_FILES:
            source = (overlay / "etc/skel/.config" / name).read_bytes()
            self.write("etc/skel/.config/" + name, source)
            self.write("var/lib/m1892-oem-setup/.config/" + name, source)
        for name, data in PRIVACY.SETUP_DEFAULTS.items():
            self.write("var/lib/m1892-oem-setup/.config/" + name, data)
        self.write("etc/skel/.bashrc", "# Synthetic distribution shell default\n")
        self.write("root/.bashrc", "# Synthetic distribution shell default\n")
        (self.root / "lib").symlink_to("usr/lib")

    def tearDown(self):
        self.temp.cleanup()

    def write(self, path, contents):
        target = self.root / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(contents.encode() if isinstance(contents, str) else contents)

    def audit(self, *, vendor_free=True):
        image = self.base / "fixture.ext4"
        with image.open("wb") as stream:
            stream.truncate(16 * 1024 * 1024)
        subprocess.run(["mkfs.ext4", "-q", "-F", "-d", str(self.root), str(image)],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        # mkfs -d preserves the invoking user's ownership. The synthetic image
        # contract explicitly models root-owned package contents, independent of
        # host UID; this setup changes the fixture only, never the audited image.
        commands = []
        for path in [self.root, *self.root.rglob("*")]:
            name = "/" + path.relative_to(self.root).as_posix() if path != self.root else "/"
            if not any(char in name for char in ('"', '\n')):
                commands.append(f'set_inode_field "{name}" uid 0')
                commands.append(f'set_inode_field "{name}" gid 0')
        subprocess.run(["debugfs", "-w", "-f", "-", str(image)],
                       input=("\n".join(commands) + "\n").encode(), check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        return PRIVACY.verify(image, vendor_free, "a" * 64)

    def rejects(self, category, *, vendor_free=True):
        report = self.audit(vendor_free=vendor_free)
        self.assertEqual(report["content_result"], "FAIL", report)
        self.assertIn(category, [item["category"] for item in report["findings"]], report)
        self.assertNotIn("SYNTHETIC_SECRET_42", json.dumps(report))
        return report

    def test_clean_fixture_passes_scoped_only_and_one_dump_batch(self):
        report = self.audit()
        self.assertEqual(report["result"], "SCOPED_CONTENT_PASS", report)
        self.assertEqual(report["free_space_result"], "NOT_ASSESSED")
        self.assertFalse(report["release_privacy_complete"])
        self.assertFalse(report["external_artifact_sha256_verified_here"])
        self.assertEqual(report["inspection"]["content_dump_batches"], 1)
        self.assertLess(report["inspection"]["dumped_bytes"], 16384)
        self.assertEqual(report["artifact_stat_before"], report["artifact_stat_after"])

    def test_owner_account_rejected(self):
        with (self.root / "etc/passwd").open("a") as stream:
            stream.write("SYNTHETIC_SECRET_42:x:1000:1000:Owner:/home/owner:/bin/bash\n")
        self.rejects("owner-or-extra-root-account")

    def test_unlocked_root_rejected(self):
        self.write("etc/shadow", "root:SYNTHETIC_SECRET_42:20000:0:99999:7:::\n")
        self.rejects("shadow-password-material-or-orphan")

    def test_locked_hash_is_still_private(self):
        self.write("etc/shadow", "root:!$6$SYNTHETIC_SECRET_42:20000:0:99999:7:::\n")
        self.rejects("shadow-password-material-or-orphan")

    def test_stale_shadow_backup_rejected(self):
        self.write("etc/shadow-", "root:SYNTHETIC_SECRET_42:20000:0:99999:7:::\n")
        self.rejects("stale-account-backup")

    def test_host_key_and_authorized_key_rejected_even_empty(self):
        self.write("etc/ssh/ssh_host_ed25519_key", "")
        self.write("root/.ssh/authorized_keys", "SYNTHETIC_SECRET_42")
        self.rejects("ssh-identity-or-authorized-key")

    def test_machine_identity_rejected(self):
        self.write("etc/machine-id", "SYNTHETIC_SECRET_42\n")
        self.rejects("machine-id-not-empty")

    def test_hostname_rejected(self):
        self.write("etc/hostname", "SYNTHETIC_SECRET_42\n")
        self.rejects("hostname-not-generic")

    def test_nm_profile_secret_rejected_without_leak(self):
        self.write("etc/NetworkManager/system-connections/SYNTHETIC_SECRET_42", "[wifi]\nssid=SYNTHETIC_SECRET_42\n")
        self.rejects("non-generic-network-profile")

    def test_secret_in_system_nm_configuration(self):
        self.write("etc/NetworkManager/conf.d/generic.conf", "[wifi]\npsk=SYNTHETIC_SECRET_42\n")
        self.rejects("sensitive-content-pattern")

    def test_bluetooth_pairing_rejected_without_reading_payload(self):
        self.write("var/lib/bluetooth/SYNTHETIC_SECRET_42/info", "SYNTHETIC_SECRET_42")
        self.rejects("populated-runtime-or-user-store")

    def test_empty_bluetooth_identity_directory_is_not_clean(self):
        (self.root / "var/lib/bluetooth/SYNTHETIC_SECRET_42").mkdir(parents=True)
        self.rejects("populated-runtime-or-user-store")

    def test_empty_persistent_journal_identity_is_not_clean(self):
        (self.root / "var/log/journal/SYNTHETIC_SECRET_42").mkdir(parents=True)
        self.rejects("persistent-journal-identity")

    def test_private_hosts_entry_rejected(self):
        self.write("etc/hosts", "192.0.2.1 SYNTHETIC_SECRET_42\n")
        self.rejects("non-generic-host-configuration")

    def test_resolver_symlink_and_dbus_alias_allowed(self):
        (self.root / "etc/resolv.conf").symlink_to("../run/NetworkManager/resolv.conf")
        (self.root / "var/lib/dbus").mkdir()
        (self.root / "var/lib/dbus/machine-id").symlink_to("/etc/machine-id")
        self.assertEqual(self.audit()["content_result"], "PASS")

    def install_package_symlinks(self):
        for path, (literal_target, resolved_target) in PRIVACY.PACKAGE_SYMLINKS.items():
            self.write(resolved_target.lstrip("/"), "# Synthetic package target\n")
            link = self.root / path.lstrip("/")
            link.parent.mkdir(parents=True, exist_ok=True)
            link.symlink_to(literal_target)

    def test_exact_debian_package_symlinks_allowed(self):
        self.install_package_symlinks()
        report = self.audit()
        self.assertEqual(report["content_result"], "PASS", report)
        self.assertEqual(report["inspection"]["content_dump_batches"], 1)

    def test_modified_wpasupplicant_symlink_target_rejected(self):
        self.install_package_symlinks()
        link = self.root / "etc/network/if-up.d/wpasupplicant"
        link.unlink()
        link.symlink_to("/root/.bashrc")
        self.rejects("unexpected-symlink")

    def test_modified_systemd_ssh_symlink_target_rejected(self):
        self.install_package_symlinks()
        link = self.root / "etc/ssh/ssh_config.d/20-systemd-ssh-proxy.conf"
        link.unlink()
        link.symlink_to("/root/.bashrc")
        self.rejects("unexpected-symlink")

    def test_package_symlink_target_must_exist(self):
        self.install_package_symlinks()
        (self.root / "etc/wpa_supplicant/ifupdown.sh").unlink()
        self.rejects("package-symlink-target-not-regular")

    def test_package_symlink_second_hop_is_rejected(self):
        self.install_package_symlinks()
        target = self.root / "usr/lib/systemd/ssh_config.d/20-systemd-ssh-proxy.conf"
        target.unlink()
        target.symlink_to("/root/.bashrc")
        self.rejects("package-symlink-target-not-regular")

    def test_package_symlink_target_content_is_checked(self):
        self.install_package_symlinks()
        self.write("usr/lib/systemd/ssh_config.d/20-systemd-ssh-proxy.conf", "psk=SYNTHETIC_SECRET_42\n")
        self.rejects("sensitive-content-pattern")

    def test_wallet_browser_and_home_rejected(self):
        self.write("home/SYNTHETIC_SECRET_42/.mozilla/profile", "SYNTHETIC_SECRET_42")
        self.write("var/lib/m1892-oem-setup/.local/share/kwalletd/kdewallet.kwl", "SYNTHETIC_SECRET_42")
        self.rejects("unexpected-user-state")

    def test_nonempty_log_rejected(self):
        self.write("var/log/dpkg.log", "SYNTHETIC_SECRET_42")
        self.rejects("nonempty-log-or-special-entry")

    def test_symlink_scope_cannot_hide_state(self):
        (self.root / "home").rmdir()
        (self.root / "home").symlink_to("/opt/hidden")
        self.write("opt/hidden/private", "SYNTHETIC_SECRET_42")
        self.rejects("required-directory-layout")

    def test_vendor_rejected_but_public_gpu_not_blanket_banned(self):
        self.write("usr/lib/firmware/qcom/a630_gmu.bin", b"distribution firmware fixture")
        self.assertEqual(self.audit()["content_result"], "PASS")
        self.write("usr/lib/firmware/qcom/sdm845/m1892/modem.mbn", b"synthetic vendor fixture")
        self.rejects("owner-vendor-payload-present")

    def test_vendor_presence_report_without_require_flag(self):
        self.write("usr/share/qcom/sdm845/Meizu/m1892/sensors/config/a.json", b"fixture")
        report = self.audit(vendor_free=False)
        self.assertEqual(report["content_result"], "PASS", report)
        self.assertEqual(report["vendor_result"], "PRESENT")
        self.assertIn("/usr/share/qcom/sdm845/Meizu/m1892", report["known_vendor_directories_present"])

    def test_empty_vendor_namespace_reports_directory_without_payload(self):
        (self.root / "usr/lib/firmware/qcom/sdm845/m1892").mkdir(parents=True)
        report = self.audit()
        self.assertEqual(report["content_result"], "PASS", report)
        self.assertEqual(report["vendor_result"], "ABSENT_IN_KNOWN_SCOPE")
        self.assertIn("/usr/lib/firmware/qcom/sdm845/m1892", report["known_vendor_directories_present"])

    def test_modified_wlan_board_rejected(self):
        self.write("usr/lib/firmware/ath10k/WCN3990/hw1.0/board-2.bin", b"synthetic modified board")
        self.rejects("owner-vendor-payload-present")

    def test_missing_required_file_fails_closed(self):
        (self.root / "etc/passwd").unlink()
        self.rejects("required-regular-file")

    def test_oversized_content_fails_closed(self):
        self.write("etc/ssh/oversized", b"x" * (PRIVACY.MAX_FILE_BYTES + 1))
        self.rejects("content-size-or-type-bound")

    def test_corrupt_ext4_fails_closed(self):
        image = self.base / "invalid.ext4"
        with image.open("wb") as stream:
            stream.truncate(2 * 1024 * 1024)
        report = PRIVACY.verify(image)
        self.assertEqual(report["content_result"], "FAIL")
        self.assertEqual(report["findings"][0]["category"], "not-raw-ext4-with-extents")

    def test_debugfs_zero_exit_diagnostic_is_failure(self):
        reader = PRIVACY.DebugFS(self.base / "unused.ext4", self.base)
        result = subprocess.CompletedProcess([], 0, b"debugfs: ls -p <2>\n", b"debugfs 1.0\nSYNTHETIC_SECRET_42: read failed\n")
        with mock.patch.object(PRIVACY.subprocess, "run", return_value=result):
            with self.assertRaises(PRIVACY.AuditError) as caught:
                reader.batch(["ls -p <2>"])
        self.assertEqual(caught.exception.category, "debugfs-diagnostic-failure")
        self.assertNotIn("SYNTHETIC_SECRET_42", str(caught.exception))

    def test_malformed_debugfs_directory_output_is_failure(self):
        reader = PRIVACY.DebugFS(self.base / "unused.ext4", self.base)
        with mock.patch.object(reader, "batch", return_value=["SYNTHETIC_SECRET_42\n"]):
            with self.assertRaises(PRIVACY.AuditError) as caught:
                reader.listings([("/", PRIVACY.Node(2, 0o40755, 0, 0, 0))])
        self.assertEqual(caught.exception.category, "malformed-directory-listing")

    def test_raw_image_symlink_is_rejected(self):
        target = self.base / "target.ext4"
        target.touch()
        link = self.base / "alias.ext4"
        link.symlink_to(target)
        report = PRIVACY.verify(link)
        self.assertEqual(report["content_result"], "FAIL")
        self.assertEqual(report["findings"][0]["category"], "input-not-regular-raw-image")


if __name__ == "__main__":
    unittest.main(verbosity=2)
