#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Read-only, bounded privacy contract for an unbooted M1892 OEM ext4 image.

Exit 0 means SCOPED_CONTENT_PASS, not a complete release privacy certificate.
Free blocks, deleted inodes, journal/slack bytes and files outside the declared
scope are NOT assessed. Release orchestration must bind this report to its own
full-image SHA256 and independently prove fresh-mkfs provenance (or separately
verify residual storage). --artifact-sha256 labels external evidence; it does
not calculate or validate that hash. No mount, device access or image writes.

Expected layout: real /etc, /usr, /var, /home, /root; optional /lib -> usr/lib;
locked root and temporary m1892-setup system account; no normal owner; empty
machine-id; generic hostname m1892; source-controlled OEM/skel configuration;
only the exact carrier-neutral GSM profile; no populated user/runtime stores.
Only named sensitive trees are traversed. Directory listings are batched by
depth and all selected regular-file contents are dumped in ONE debugfs batch.
Unknown types, symlink redirects, malformed listing and bounds violations fail
closed. Reports contain categories and redacted paths, never file contents.
"""

import argparse
import dataclasses
import datetime
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import stat
import struct
import subprocess
import tempfile
import time


SETUP_HOME = "/var/lib/m1892-oem-setup"
EMPTY_TREES = (
    "/home", "/tmp", "/var/tmp", "/run", "/lost+found",
    "/var/lib/bluetooth", "/var/lib/NetworkManager", "/var/lib/iwd",
    "/var/lib/connman", "/var/lib/dhcp", "/var/lib/AccountsService",
    "/var/lib/sddm", "/var/cache/sddm", "/var/mail", "/var/spool/mail",
    "/var/spool/cron", "/var/lib/m1892", "/var/lib/systemd/coredump",
    "/var/lib/systemd/pstore", "/var/lib/private", "/var/backups",
    "/etc/credstore", "/etc/credstore.encrypted",
)
EMPTY_ALLOWED_DIRS = {
    "/var/lib/AccountsService/users", "/var/lib/AccountsService/icons",
    "/var/spool/cron/atjobs", "/var/spool/cron/atspool", "/var/spool/cron/crontabs",
    "/run/lock", "/run/user", "/run/systemd",
}
NETWORK_TREES = (
    "/etc/NetworkManager", "/etc/wpa_supplicant", "/etc/iwd",
    "/etc/connman", "/etc/network", "/usr/lib/NetworkManager/system-connections",
)
FIRMWARE_ROOTS = ("/lib/firmware", "/usr/lib/firmware")
VENDOR_DIRS = (
    "qcom/sdm845/m1892", "qcom/sdm845/Meizu/m1892", "qcom/m1892",
    "qca/m1892", "qcom/venus-5.2",
)
QCOM_DATA = "/usr/share/qcom/sdm845/Meizu/m1892"
RECURSIVE = (*EMPTY_TREES, *NETWORK_TREES, "/root", "/etc/skel", "/etc/ssh",
             "/var/log", SETUP_HOME)
ACCOUNT_FILES = ("passwd", "shadow", "group", "gshadow")
# Debian wpasupplicant 2:2.10-24 and systemd 257.13-1~deb13u1 install
# these aliases. Both their package ownership and target-file checksums were
# verified against the pristine candidate's dpkg records. Permit only these
# exact path/target pairs, not arbitrary links under /etc/network or /etc/ssh.
# The resolved destinations must be regular files and are included in the
# same bounded content scan; package origin remains the external source gate.
PACKAGE_SYMLINKS = {
    **{f"/etc/network/{phase}.d/wpasupplicant": (
        "../../wpa_supplicant/ifupdown.sh", "/etc/wpa_supplicant/ifupdown.sh")
       for phase in ("if-pre-up", "if-up", "if-down", "if-post-down")},
    "/etc/ssh/ssh_config.d/20-systemd-ssh-proxy.conf": (
        "/usr/lib/systemd/ssh_config.d/20-systemd-ssh-proxy.conf",
        "/usr/lib/systemd/ssh_config.d/20-systemd-ssh-proxy.conf"),
}
FIXED_FILES = (
    *(f"/etc/{name}{suffix}" for name in ACCOUNT_FILES for suffix in ("", "-")),
    "/etc/machine-id", "/etc/hostname", "/etc/hosts", "/etc/machine-info",
    "/etc/resolv.conf", "/etc/m1892-rootfs-identity",
    "/var/lib/dbus/machine-id", "/var/lib/systemd/random-seed",
    "/usr/lib/sysusers.d/m1892-oem-setup.conf",
    *sorted({target for _, target in PACKAGE_SYMLINKS.values()}),
)
MAX_ENTRIES = 12000
MAX_DEPTH = 16
MAX_FILE_BYTES = 2 * 1024 * 1024
MAX_DUMP_BYTES = 32 * 1024 * 1024
SHELL_DEFAULTS = (".bashrc", ".profile", ".bash_logout")
CONFIG_FILES = ("applications-blacklistrc", "kglobalshortcutsrc", "kwinrulesrc")
SETUP_DEFAULTS = {
    "plasmamobilerc": b"[InitialStart]\nwizardRun=true\n",
    "kscreenlockerrc": b"[Daemon]\nAutolock=false\nLockOnResume=false\n",
    "powerdevilrc": (b"[AC][Display]\nLockBeforeTurnOffDisplay=false\n"
                    b"[Battery][Display]\nLockBeforeTurnOffDisplay=false\n"
                    b"[LowBattery][Display]\nLockBeforeTurnOffDisplay=false\n"),
    "kwalletrc": b"[Wallet]\nEnabled=false\nFirst Use=false\n",
}
GSM_PROFILE = (b"[connection]\nid=m1892-cellular\ntype=gsm\nautoconnect=true\n"
               b"autoconnect-priority=-10\nautoconnect-retries=0\n\n[gsm]\n"
               b"auto-config=true\n\n[ipv4]\nmethod=auto\nroute-metric=1200\n\n"
               b"[ipv6]\naddr-gen-mode=default\nmethod=auto\nroute-metric=1200\n\n[proxy]\n")
# These are public upstream bytes, not the Flyme B01-augmented board database.
PUBLIC_WLAN_HASHES = {
    "board-2.bin": "867e1010787764020653812167d93f5952cbbea05f576209d953d8c9322f18aa",
    "wlanmdsp.mbn": "92e1501254e6de78c0f2e2cf091507d488b608d07e53acd14813a82744823ec2",
    "firmware-5.bin": hashlib.sha256(bytes.fromhex(
        "5143412d41544831304b00770100000004000000a4e4be5b0200000003000000"
        "40000c77050000000400000004000000060000000400000003000000")).hexdigest(),
}
SECRET_PATTERN = re.compile(
    rb"-----BEGIN [A-Z ]*PRIVATE KEY-----|(?:ssh-(?:rsa|ed25519)|ecdsa-sha2-\S+)\s+[A-Za-z0-9+/]{32,}"
    rb"|(?im:^\s*(?:ssid|psk|wep-key\d*|password|pin|private-key-password|imsi|iccid)\s*=\s*\S+)"
)


class AuditError(Exception):
    """Only predefined category/path strings may be exposed from this error."""

    def __init__(self, category, path="/"):
        self.category, self.path = category, path


@dataclasses.dataclass(frozen=True)
class Node:
    inode: int
    mode: int
    uid: int
    gid: int
    size: int


def under(path, root):
    return path == root or path.startswith(root + "/")


def safe_report_path(path):
    """User names/SSID-like filenames in unexpected stores must not leak."""
    source_defaults = {parent + "/.config/" + name
                       for parent in ("/etc/skel", SETUP_HOME)
                       for name in (*CONFIG_FILES, *SETUP_DEFAULTS)}
    if (path in FIXED_FILES or path in RECURSIVE or path in PACKAGE_SYMLINKS
            or path in source_defaults or path == "/"):
        return path
    scopes = (*RECURSIVE, *FIRMWARE_ROOTS, QCOM_DATA, "/etc", "/usr", "/var")
    for scope in sorted(scopes, key=len, reverse=True):
        if path.startswith(scope + "/"):
            return scope + "/<entry>"
    return "/<entry>"


class DebugFS:
    def __init__(self, image, work):
        self.image, self.work = image, work
        self.calls = 0
        self.dump_bytes = 0

    def batch(self, commands):
        if not commands:
            return []
        self.calls += 1
        try:
            result = subprocess.run(
                ["debugfs", "-f", "-", str(self.image)],
                input=("\n".join(commands) + "\n").encode(),
                stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                timeout=60, env={**os.environ, "LC_ALL": "C"}, check=False,
            )
        except (OSError, subprocess.TimeoutExpired):
            raise AuditError("debugfs-execution-failed") from None
        # debugfs often returns zero for failed commands. Never trust rc alone.
        stderr = result.stderr.decode("utf-8", "replace").splitlines()
        if result.returncode or any(not line.startswith("debugfs ") for line in stderr):
            raise AuditError("debugfs-diagnostic-failure")
        try:
            output = result.stdout.decode("utf-8", "strict")
        except UnicodeError:
            raise AuditError("debugfs-output-encoding") from None
        sections = re.split(r"(?m)^debugfs:  ?", output)
        if sections[0].strip() or len(sections) != len(commands) + 1:
            raise AuditError("debugfs-batch-framing")
        bodies = []
        for command, section in zip(commands, sections[1:]):
            first, separator, body = section.partition("\n")
            if first != command or not separator:
                raise AuditError("debugfs-batch-command-mismatch")
            bodies.append(body)
        return bodies

    def listings(self, directories):
        bodies = self.batch([f"ls -p <{node.inode}>" for _, node in directories])
        output = {}
        for (parent, _), body in zip(directories, bodies):
            dots = set()
            for line in body.splitlines():
                if not line:
                    continue
                match = re.fullmatch(r"/(\d+)/(\d{6})/(\d+)/(\d+)/(.*)/(\d*)/", line)
                if not match:
                    raise AuditError("malformed-directory-listing", parent)
                inode, mode, uid, gid, name, size = match.groups()
                if name in (".", ".."):
                    dots.add(name)
                    continue
                if int(inode) == 0:
                    continue  # An unused directory slot is not a live entry.
                if not name or "/" in name or any(ord(char) < 32 for char in name):
                    raise AuditError("unsafe-directory-entry", parent)
                path = parent.rstrip("/") + "/" + name
                if path in output:
                    raise AuditError("duplicate-directory-entry", parent)
                output[path] = Node(int(inode), int(mode, 8), int(uid), int(gid), int(size or 0))
            if dots != {".", ".."}:
                raise AuditError("incomplete-directory-listing", parent)
        return output

    def contents(self, files):
        commands, destinations = [], []
        total = 0
        for path, node in sorted(files.items()):
            if not stat.S_ISREG(node.mode) or node.size > MAX_FILE_BYTES:
                raise AuditError("content-size-or-type-bound", path)
            total += node.size
            if total > MAX_DUMP_BYTES:
                raise AuditError("total-content-bound")
            target = self.work / f"payload-{len(destinations)}"
            destinations.append((path, node, target))
            commands.append(f"dump <{node.inode}> {target}")
        if any(body.strip() for body in self.batch(commands)):
            raise AuditError("unexpected-dump-output")
        result = {}
        for path, node, target in destinations:
            if not target.is_file() or target.stat().st_size != node.size:
                raise AuditError("dump-missing-or-short", path)
            result[path] = target.read_bytes()
        self.dump_bytes = total
        return result


class Audit:
    def __init__(self, image, work, require_vendor_free=False):
        self.reader = DebugFS(image, work)
        self.require_vendor_free = require_vendor_free
        self.nodes = {"/": Node(2, stat.S_IFDIR | 0o755, 0, 0, 0)}
        self.data = {}
        self.findings = []
        self.vendor_present = []
        self.vendor_directories = []
        self.source = Path(__file__).resolve().parents[1] / "rootfs-overlay"
        self.targets = set(FIXED_FILES) | set(RECURSIVE) | {QCOM_DATA, "/lib"}
        for prefix in FIRMWARE_ROOTS:
            self.targets.update(prefix + "/" + item for item in VENDOR_DIRS)
            self.targets.add(prefix + "/qca/crbtfw21.tlv")
            self.targets.add(prefix + "/ath10k/WCN3990/hw1.0")
        self.recursive = (*RECURSIVE, QCOM_DATA,
                          *(root + "/" + item for root in FIRMWARE_ROOTS for item in VENDOR_DIRS),
                          *(root + "/ath10k/WCN3990/hw1.0" for root in FIRMWARE_ROOTS))

    def fail(self, category, path):
        finding = {"category": category, "path": safe_report_path(path)}
        if finding not in self.findings:
            self.findings.append(finding)

    def relevant(self, path):
        return any(under(path, tree) for tree in self.recursive) or any(
            target.startswith(path + "/") for target in self.targets)

    def discover(self):
        pending = [("/", self.nodes["/"])]
        visited = set()
        for _ in range(MAX_DEPTH):
            if not pending:
                break
            for path, node in pending:
                if node.inode in visited:
                    raise AuditError("directory-inode-cycle", path)
                visited.add(node.inode)
            entries = self.reader.listings(pending)
            self.nodes.update(entries)
            if len(self.nodes) > MAX_ENTRIES:
                raise AuditError("directory-entry-bound")
            pending = [(p, n) for p, n in entries.items()
                       if stat.S_ISDIR(n.mode) and self.relevant(p)]
        if pending:
            raise AuditError("directory-depth-bound")
        for required in ("/etc", "/usr", "/var", "/home", "/root", "/etc/skel", SETUP_HOME):
            node = self.nodes.get(required)
            if not node or not stat.S_ISDIR(node.mode):
                self.fail("required-directory-layout", required)
        # A redirect anywhere along a checked path is a failure, except these
        # explicit Debian merged-/usr / mail / dbus aliases. Never follow links.
        links = {p: n for p, n in self.nodes.items() if stat.S_ISLNK(n.mode)
                 and (self.relevant(p) or p in self.targets)}
        bodies = self.reader.batch([f"stat <{n.inode}>" for n in links.values()])
        for (path, _), body in zip(links.items(), bodies):
            match = re.search(r'^Fast link dest: "([^"\n]*)"$', body, re.M)
            target = match.group(1) if match else None
            allowed = {
                "/lib": {"usr/lib", "/usr/lib"},
                "/var/spool/mail": {"../mail", "/var/mail"},
                "/var/lib/dbus/machine-id": {"/etc/machine-id", "../../../etc/machine-id"},
                "/etc/resolv.conf": {"../run/NetworkManager/resolv.conf", "/run/NetworkManager/resolv.conf"},
                **{name: {value[0]} for name, value in PACKAGE_SYMLINKS.items()},
            }
            if path.endswith("/qcom/sdm845/m1892/wlanmdsp.mbn"):
                allowed[path] = {"../../../ath10k/WCN3990/hw1.0/wlanmdsp.mbn",
                                 "/lib/firmware/ath10k/WCN3990/hw1.0/wlanmdsp.mbn"}
            if target not in allowed.get(path, set()):
                self.fail("unexpected-symlink", path)
            elif path in PACKAGE_SYMLINKS:
                resolved = PACKAGE_SYMLINKS[path][1]
                destination = self.nodes.get(resolved)
                if not destination or not stat.S_ISREG(destination.mode):
                    self.fail("package-symlink-target-not-regular", path)
        return links

    def collect(self):
        files = {}
        for path, node in self.nodes.items():
            content_scope = (path in FIXED_FILES or any(under(path, tree) for tree in
                             (*NETWORK_TREES, "/etc/skel", "/root", "/etc/ssh", SETUP_HOME)))
            wlan = any(path == root + "/ath10k/WCN3990/hw1.0/" + name
                       for root in FIRMWARE_ROOTS for name in PUBLIC_WLAN_HASHES)
            if (content_scope or wlan) and stat.S_ISREG(node.mode):
                files[path] = node
        self.data = self.reader.contents(files)

    def text(self, path, required=True):
        data = self.data.get(path)
        if data is None:
            if required:
                self.fail("required-regular-file", path)
            return ""
        try:
            return data.decode("utf-8", "strict")
        except UnicodeError:
            self.fail("invalid-text-encoding", path)
            return ""

    def table(self, path, count):
        records = {}
        for line in self.text(path).splitlines():
            fields = line.split(":")
            if len(fields) != count or not fields[0] or fields[0] in records:
                self.fail("malformed-account-database", path)
                continue
            records[fields[0]] = fields
        if not records:
            self.fail("empty-account-database", path)
        return records

    def accounts(self):
        passwd = self.table("/etc/passwd", 7)
        shadow = self.table("/etc/shadow", 9)
        self.table("/etc/group", 4)
        gshadow = self.table("/etc/gshadow", 4)
        for name, fields in passwd.items():
            if not fields[2].isdigit() or not fields[3].isdigit():
                self.fail("invalid-account-id", "/etc/passwd")
                continue
            uid = int(fields[2])
            nobody = name == "nobody" and uid == 65534 and fields[6] in ("/usr/sbin/nologin", "/sbin/nologin", "/bin/false")
            if (uid >= 1000 and not nobody) or (uid == 0 and name != "root"):
                self.fail("owner-or-extra-root-account", "/etc/passwd")
            if fields[1] != "x" or name not in shadow:
                self.fail("passwd-shadow-contract", "/etc/passwd")
            if name not in ("root", "m1892-setup", "sync") and fields[6] not in ("/usr/sbin/nologin", "/sbin/nologin", "/bin/false", "/usr/bin/false"):
                self.fail("unexpected-interactive-system-account", "/etc/passwd")
            if name == "sync" and (uid != 4 or fields[6] not in ("/bin/sync", "/usr/bin/sync")):
                self.fail("unexpected-sync-account", "/etc/passwd")
        if passwd.get("root", [None] * 7)[2:] != ["0", "0", "root", "/root", "/bin/bash"]:
            self.fail("root-account-contract", "/etc/passwd")
        setup = passwd.get("m1892-setup")
        if not setup or not setup[2].isdigit() or not 0 < int(setup[2]) < 1000 or setup[5:] != [SETUP_HOME, "/bin/bash"]:
            self.fail("temporary-setup-account-contract", "/etc/passwd")
        for name, fields in shadow.items():
            # A locked password hash (!<hash>) still contains private material.
            if fields[1] not in ("!", "*", "!*", "!!") or name not in passwd:
                self.fail("shadow-password-material-or-orphan", "/etc/shadow")
        for fields in gshadow.values():
            if fields[1] not in ("", "!", "*", "!*", "!!"):
                self.fail("group-password-material", "/etc/gshadow")
        for name in ACCOUNT_FILES:
            backup = f"/etc/{name}-"
            if backup in self.nodes and self.data.get(backup) != self.data.get(f"/etc/{name}"):
                self.fail("stale-account-backup", backup)
        sysusers = "/usr/lib/sysusers.d/m1892-oem-setup.conf"
        self.canonical(sysusers, self.source / sysusers.lstrip("/"))

    def canonical(self, image_path, source):
        if not source.is_file():
            raise AuditError("missing-source-contract", image_path)
        if self.data.get(image_path) != source.read_bytes():
            self.fail("source-configuration-mismatch", image_path)

    def user_stores(self):
        allowed_files = {"/etc/skel/" + name for name in SHELL_DEFAULTS}
        allowed_files.update("/root/" + name for name in SHELL_DEFAULTS)
        for name in CONFIG_FILES:
            for parent in ("/etc/skel", SETUP_HOME):
                path = parent + "/.config/" + name
                allowed_files.add(path)
                self.canonical(path, self.source / "etc/skel/.config" / name)
        for name, expected in SETUP_DEFAULTS.items():
            path = SETUP_HOME + "/.config/" + name
            allowed_files.add(path)
            if self.data.get(path) != expected:
                self.fail("setup-default-mismatch", path)
        for path, node in self.nodes.items():
            for tree in EMPTY_TREES:
                if path.startswith(tree + "/") and not (
                    stat.S_ISDIR(node.mode) and path in EMPTY_ALLOWED_DIRS
                ):
                    self.fail("populated-runtime-or-user-store", path)
            if path.startswith("/home/"):
                self.fail("owner-home-present", path)
            if path.startswith("/var/log/") and (not stat.S_ISDIR(node.mode)):
                if not stat.S_ISREG(node.mode) or node.size:
                    self.fail("nonempty-log-or-special-entry", path)
            if path.startswith("/var/log/journal/"):
                self.fail("persistent-journal-identity", path)
            for tree in ("/root", "/etc/skel", SETUP_HOME):
                if path.startswith(tree + "/"):
                    allowed_dirs = {tree + "/.config"} if tree != "/root" else set()
                    if (stat.S_ISDIR(node.mode) and path not in allowed_dirs) or (
                        not stat.S_ISDIR(node.mode) and path not in allowed_files
                    ):
                        self.fail("unexpected-user-state", path)
            if path in self.data and under(path, "/root"):
                counterpart = "/etc/skel/" + PurePosixPath(path).name
                if path in allowed_files and self.data[path] != self.data.get(counterpart):
                    self.fail("root-default-not-skel", path)
            if any(under(path, scope) for scope in (*RECURSIVE, *FIXED_FILES)):
                if node.uid >= 1000 and node.uid != 65534:
                    self.fail("owner-uid-in-scanned-metadata", path)
                if not (stat.S_ISREG(node.mode) or stat.S_ISDIR(node.mode) or stat.S_ISLNK(node.mode)):
                    self.fail("special-file-in-sensitive-scope", path)

    def identities_network(self):
        if self.data.get("/etc/machine-id") != b"":
            self.fail("machine-id-not-empty", "/etc/machine-id")
        if self.data.get("/etc/hostname") != b"m1892\n":
            self.fail("hostname-not-generic", "/etc/hostname")
        for path in ("/var/lib/dbus/machine-id", "/var/lib/systemd/random-seed"):
            if path in self.data and self.data[path] != b"":
                self.fail("persistent-machine-identity", path)
        for path in ("/etc/hosts", "/etc/resolv.conf", "/etc/machine-info"):
            if path not in self.data:
                continue
            for line in self.text(path).splitlines():
                stripped = line.strip()
                if not stripped or stripped.startswith("#"):
                    continue
                fields = stripped.split()
                hosts_ok = (path == "/etc/hosts" and fields[0] in
                            {"127.0.0.1", "127.0.1.1", "::1", "ff02::1", "ff02::2"}
                            and bool(fields[1:]) and all(name in {
                                "localhost", "localhost.localdomain", "m1892", "ip6-localhost",
                                "ip6-loopback", "ip6-allnodes", "ip6-allrouters"} for name in fields[1:]))
                if not hosts_ok and not (path == "/etc/machine-info" and stripped == "CHASSIS=handset"):
                    self.fail("non-generic-host-configuration", path)
        identity = self.text("/etc/m1892-rootfs-identity")
        for item in ("distribution=debian", "version=13", "account_mode=oem-owner", "root_mode=persistent-userdata"):
            if identity.splitlines().count(item) != 1:
                self.fail("non-oem-rootfs-identity", "/etc/m1892-rootfs-identity")
        for path, node in self.nodes.items():
            name = PurePosixPath(path).name
            if name.startswith("ssh_host_") or name in ("authorized_keys", "authorized_keys2", "known_hosts"):
                self.fail("ssh-identity-or-authorized-key", path)
            if path.startswith("/etc/NetworkManager/system-connections/"):
                if (path != "/etc/NetworkManager/system-connections/m1892-cellular.nmconnection"
                        or self.data.get(path) != GSM_PROFILE):
                    self.fail("non-generic-network-profile", path)
            if path.startswith("/usr/lib/NetworkManager/system-connections/"):
                self.fail("unexpected-vendor-network-profile", path)
        for path, data in self.data.items():
            if SECRET_PATTERN.search(data):
                self.fail("sensitive-content-pattern", path)

    def firmware(self):
        for path, node in self.nodes.items():
            is_vendor = under(path, QCOM_DATA) or any(
                under(path, prefix + "/" + directory)
                for prefix in FIRMWARE_ROOTS for directory in VENDOR_DIRS)
            is_vendor |= any(path == prefix + "/qca/crbtfw21.tlv" for prefix in FIRMWARE_ROOTS)
            alias = path.endswith("/qcom/sdm845/m1892/wlanmdsp.mbn") and stat.S_ISLNK(node.mode)
            if is_vendor and stat.S_ISDIR(node.mode) and (path == QCOM_DATA or any(
                    path == prefix + "/" + directory
                    for prefix in FIRMWARE_ROOTS for directory in VENDOR_DIRS)):
                self.vendor_directories.append(path)
            if is_vendor and not stat.S_ISDIR(node.mode) and not alias:
                self.vendor_present.append(safe_report_path(path))
            for prefix in FIRMWARE_ROOTS:
                wlan = prefix + "/ath10k/WCN3990/hw1.0/"
                if path.startswith(wlan) and not stat.S_ISDIR(node.mode):
                    expected = PUBLIC_WLAN_HASHES.get(path[len(wlan):])
                    if expected is None or hashlib.sha256(self.data.get(path, b"")).hexdigest() != expected:
                        self.vendor_present.append(safe_report_path(path))
        if self.require_vendor_free and self.vendor_present:
            self.fail("owner-vendor-payload-present", QCOM_DATA)

    def run(self):
        self.discover()
        self.collect()
        self.accounts()
        self.user_stores()
        self.identities_network()
        self.firmware()


def fingerprint(path):
    info = path.stat()
    return {"device": info.st_dev, "inode": info.st_ino, "size": info.st_size,
            "mtime_ns": info.st_mtime_ns, "ctime_ns": info.st_ctime_ns}


def verify(image, require_vendor_free=False, artifact_sha256=None):
    started = time.monotonic()
    report = {
        "schema": "m1892-release-image-privacy-v1",
        "started_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "result": "FAIL", "content_result": "FAIL", "findings": [],
        "free_space_result": "NOT_ASSESSED",
        "release_privacy_complete": False,
        "external_artifact_sha256": artifact_sha256,
        "external_artifact_sha256_verified_here": False,
        "require_vendor_free": require_vendor_free,
        "scope": {"recursive_trees": list(RECURSIVE), "fixed_files": list(FIXED_FILES)},
        "limitations": [
            "No free-block, deleted-inode, journal or file-slack inspection; independent fresh-mkfs provenance or residual-storage verification is required.",
            "No whole-image hash; release orchestration must bind an independently verified hash to this unchanged image.",
            "No full-rootfs or arbitrary-secret/encoded-data scan. Source/package provenance and independent review remain required.",
            "Optional root shell defaults must match /etc/skel and pass sensitive-pattern checks; Debian package provenance for those skel defaults is an external gate.",
            "Vendor gate covers the known Flyme extraction paths and WLAN bytes, not arbitrary relocated firmware or a full licence audit.",
        ],
    }
    report["scope"]["firmware_roots"] = list(FIRMWARE_ROOTS)
    report["scope"]["known_vendor_directories"] = list(VENDOR_DIRS) + [QCOM_DATA]
    report["scope"]["bounds"] = {"entries": MAX_ENTRIES, "depth": MAX_DEPTH,
                                  "file_bytes": MAX_FILE_BYTES, "dump_bytes": MAX_DUMP_BYTES}
    try:
        if not shutil.which("debugfs"):
            raise AuditError("missing-debugfs")
        if image.is_symlink() or not image.is_file():
            raise AuditError("input-not-regular-raw-image")
        before = fingerprint(image)
        report["artifact_stat_before"] = before
        if before["size"] < 1024 * 1024 or before["size"] % 1024:
            raise AuditError("raw-image-size")
        with image.open("rb") as stream:
            stream.seek(1024)
            superblock = stream.read(1024)
        if (superblock[56:58] != b"\x53\xef" or
                not struct.unpack_from("<I", superblock, 96)[0] & 0x40):
            raise AuditError("not-raw-ext4-with-extents")
        with tempfile.TemporaryDirectory(prefix="m1892-privacy-") as directory:
            audit = Audit(image.resolve(), Path(directory), require_vendor_free)
            audit.run()
            report["findings"] = audit.findings
            report["inspection"] = {"listed_entries": len(audit.nodes),
                                    "debugfs_batches": audit.reader.calls,
                                    "content_dump_batches": 1,
                                    "dumped_files": len(audit.data),
                                    "dumped_bytes": audit.reader.dump_bytes}
            report["known_vendor_payloads"] = sorted(set(audit.vendor_present))
            report["known_vendor_directories_present"] = sorted(set(audit.vendor_directories))
            report["vendor_result"] = "PRESENT" if audit.vendor_present else "ABSENT_IN_KNOWN_SCOPE"
            report["artifact_stat_after"] = fingerprint(image)
            if before != report["artifact_stat_after"]:
                raise AuditError("image-changed-during-audit")
            if not audit.findings:
                report["content_result"] = "PASS"
                report["result"] = "SCOPED_CONTENT_PASS"
    except AuditError as error:
        report["findings"].append({"category": error.category, "path": safe_report_path(error.path)})
    except (OSError, ValueError, struct.error):
        report["findings"].append({"category": "input-or-evidence-io-error", "path": "/"})
    report["duration_seconds"] = round(time.monotonic() - started, 3)
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("image", type=Path, help="uncompressed regular raw ext4 image (never a block device)")
    parser.add_argument("--require-vendor-free", action="store_true")
    parser.add_argument("--artifact-sha256", help="already independently verified image hash; NOT recomputed here")
    args = parser.parse_args()
    if args.artifact_sha256 and not re.fullmatch(r"[a-f0-9]{64}", args.artifact_sha256):
        parser.error("artifact SHA256 must be 64 lowercase hexadecimal characters")
    report = verify(args.image, args.require_vendor_free, args.artifact_sha256)
    print(json.dumps(report, indent=2, ensure_ascii=True))
    return 0 if report["content_result"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
