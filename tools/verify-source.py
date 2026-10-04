#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Check an exported source tree. Report paths/categories, never secret values."""
import hashlib
import ipaddress
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".").resolve()
manifest = root / "SOURCE-MANIFEST.sha256"
errors = []
expected = {}
for line in manifest.read_text().splitlines():
    match = re.fullmatch(r"([0-9a-f]{64})  (.+)", line)
    if not match:
        raise SystemExit("Invalid source manifest")
    digest, name = match.groups()
    if name in expected or pathlib.PurePosixPath(name).is_absolute() or ".." in pathlib.PurePosixPath(name).parts:
        raise SystemExit("Unsafe or duplicate source manifest path")
    expected[name] = digest

rules = {
    "private-key": re.compile(rb"-----BEGIN (?:OPENSSH |RSA |EC |DSA |ENCRYPTED )?PRIVATE KEY-----"),
    "ssh-public-key": re.compile(rb"\b(?:ssh-(?:ed25519|rsa|dss)|ecdsa-sha2-nistp(?:256|384|521))\s+[A-Za-z0-9+/]{60,}"),
    "github-token": re.compile(rb"\b(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{40,})"),
    "password-hash": re.compile(rb"\$(?:6|y)\$[A-Za-z0-9./]{4,}\$[A-Za-z0-9./]{20,}"),
    "network-secret": re.compile(rb"(?m)^\s*(?:ssid|psk|password|private-key-password|wep-key[0-3])\s*=\s*[^\s$#'\"{][^\r\n]{3,}$"),
    "personal-host-path": re.compile(rb"(?:/mnt/[a-z]/Users/[^/\s]+|[A-Za-z]:\\Users\\[^\\\s]+|/home/(?!\$|\[|m1892|\*|%)[A-Za-z0-9_-]+/)"),
}
ip_pattern = re.compile(rb"(?<![0-9.])(?:[0-9]{1,3}\.){3}[0-9]{1,3}(?![0-9.])")
forbidden_parts = {".codex", "local-private", "owner-local", "__pycache__", "device-capture"}
forbidden_suffixes = {".img", ".gz", ".zip", ".raw", ".ext4", ".mbn", ".elf", ".ko", ".pyc", ".log"}
files = {}
for path in root.rglob("*"):
    relative = path.relative_to(root)
    if ".git" in relative.parts:
        continue
    name = relative.as_posix()
    if path.is_symlink():
        errors.append((name, "symlink"))
        continue
    if not path.is_file():
        continue
    if name == "SOURCE-MANIFEST.sha256":
        continue
    if forbidden_parts.intersection(relative.parts) or path.suffix in forbidden_suffixes:
        errors.append((name, "forbidden-file"))
    data = path.read_bytes()
    files[name] = hashlib.sha256(data).hexdigest()
    if b"\0" in data:
        errors.append((name, "binary-content"))
    for label, pattern in rules.items():
        if pattern.search(data):
            errors.append((name, label))
    for raw in ip_pattern.findall(data):
        try:
            ip = ipaddress.ip_address(raw.decode())
        except ValueError:
            continue
        if ip.is_private and not (ip.is_loopback or ip.is_unspecified or ip.is_link_local or ip.is_reserved) and not (
            ip in ipaddress.ip_network("192.168.77.0/24") or
            ip in ipaddress.ip_network("192.0.2.0/24") or
            ip in ipaddress.ip_network("198.51.100.0/24") or
            ip in ipaddress.ip_network("203.0.113.0/24")):
            errors.append((name, "owner-network-address"))
            break
for name in sorted(set(expected) | set(files)):
    if expected.get(name) != files.get(name):
        errors.append((name, "manifest-mismatch"))
for name, label in sorted(set(errors)):
    print(f"FAIL {label}: {name}")
if errors:
    raise SystemExit(1)
print(f"SOURCE_PRIVACY_MANIFEST_PASS files={len(files)}")
