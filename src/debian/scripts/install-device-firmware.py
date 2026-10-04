#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Read model firmware before erase, then install only its exact checked files."""
import argparse
import hashlib
import json
import os
import pathlib
import shutil
import subprocess

p = argparse.ArgumentParser()
p.add_argument('mode', choices=('prepare', 'verify', 'apply'))
p.add_argument('firmware', type=pathlib.Path)
p.add_argument('--root', type=pathlib.Path)
p.add_argument('--assets', type=pathlib.Path, default=pathlib.Path('/usr/share/m1892/installer-firmware'))
a = p.parse_args()
if os.geteuid() != 0 or pathlib.Path('/proc/device-tree/model').read_bytes().rstrip(b'\0') != b'Meizu 16th Plus (M1892)':
    raise SystemExit('FIRMWARE_FAIL: device identity/root')
firmware = a.firmware.resolve()
if not str(firmware).startswith('/run/m1892-'):
    raise SystemExit('FIRMWARE_FAIL: output must be in installer RAM')
assets = a.assets.resolve()
contract = assets / 'firmware-files.tsv'
def sha(path):
    h = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024*1024), b''): h.update(chunk)
    return h.hexdigest()
entries = []
for line in contract.read_text().splitlines():
    digest, size, relative = line.split('\t')
    path = pathlib.PurePosixPath(relative)
    if path.is_absolute() or '..' in path.parts or not relative.startswith(('lib/firmware/', 'usr/share/qcom/')):
        raise SystemExit('FIRMWARE_FAIL: unsafe contract')
    if len(digest) != 64 or any(c not in '0123456789abcdef' for c in digest):
        raise SystemExit('FIRMWARE_FAIL: invalid contract digest')
    entries.append((digest, int(size), relative))
if len(entries) != 146 or len({row[2] for row in entries}) != 146:
    raise SystemExit('FIRMWARE_FAIL: incomplete contract')
if a.mode == 'prepare':
    if firmware.exists(): raise SystemExit('FIRMWARE_FAIL: output already exists')
    env = dict(os.environ, ATH10K_BDENCODER=str(assets/'ath10k-bdencoder'),
               M1892_OPEN_FIRMWARE_CACHE=str(assets), M1892_EXPECTED_FIRMWARE_MANIFEST=str(contract))
    subprocess.run(['sh',str(assets/'extract-flyme-firmware.sh'),'--device',str(firmware)],env=env,check=True)
for digest, size, relative in entries:
    path = firmware / relative
    if path.is_symlink() or not path.is_file() or not path.resolve().is_relative_to(firmware):
        raise SystemExit(f'FIRMWARE_FAIL: path {relative}')
    if path.stat().st_size != size or sha(path) != digest:
        raise SystemExit(f'FIRMWARE_FAIL: content {relative}')
if a.mode == 'apply':
    if 'rootfs_id=m1892-debian13-installer-ram' not in pathlib.Path('/etc/m1892-rootfs-identity').read_text().splitlines():
        raise SystemExit('FIRMWARE_FAIL: writes require the RAM installer')
    if not a.root: raise SystemExit('FIRMWARE_FAIL: installation root required')
    root = a.root.resolve()
    result = subprocess.check_output(['findmnt','-rn','-M',str(root),'-o','SOURCE'],text=True).strip()
    if result != '/dev/sda19': raise SystemExit('FIRMWARE_FAIL: not mounted userdata')
    if 'rootfs_id=m1892-debian13-stage7-persistent' not in (root/'etc/m1892-rootfs-identity').read_text().splitlines():
        raise SystemExit('FIRMWARE_FAIL: unexpected installed system')
    for digest, size, relative in entries:
        target = root / relative
        if not target.resolve().is_relative_to(root): raise SystemExit('FIRMWARE_FAIL: destination escapes root')
        target.parent.mkdir(parents=True,exist_ok=True)
        if target.is_symlink(): raise SystemExit('FIRMWARE_FAIL: destination is a symlink')
        shutil.copyfile(firmware/relative,target)
        target.chmod(0o644)
        os.chown(target,0,0)
        if sha(target) != digest: raise SystemExit('FIRMWARE_FAIL: installed readback')
    alias=root/'lib/firmware/qcom/sdm845/m1892/wlanmdsp.mbn'
    if alias.exists() or alias.is_symlink(): alias.unlink()
    alias.symlink_to('/lib/firmware/ath10k/WCN3990/hw1.0/wlanmdsp.mbn')
    marker=root/'var/lib/m1892/firmware-import.json'
    marker.parent.mkdir(parents=True,exist_ok=True)
    marker.write_text(json.dumps(dict(source='own-stock-partitions',files=146,contract_sha256=sha(contract)))+'\n')
    marker.chmod(0o644)
    os.sync()
print(f'M1892_DEVICE_FIRMWARE_{a.mode.upper()}_PASS files=146')
