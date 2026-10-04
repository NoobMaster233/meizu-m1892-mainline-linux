#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Rebuild a pristine OEM filesystem, never a running device or a disk clone.

The input is an explicitly hashed, never-booted OEM build. All output is created
under a new directory; mkfs on a new sparse file prevents deleted-data residue.
"""
import argparse
import gzip
import hashlib
import json
import os
import pathlib
import shutil
import subprocess

p = argparse.ArgumentParser()
p.add_argument('base_gzip', type=pathlib.Path)
p.add_argument('base_sha256')
p.add_argument('raw_sha256')
p.add_argument('modules', type=pathlib.Path)
p.add_argument('output', type=pathlib.Path)
a = p.parse_args()
tree = pathlib.Path(__file__).resolve().parents[1]
output = a.output.resolve()
if output.exists():
    raise SystemExit('Output already exists')
if not os.environ.get('FAKEROOTKEY'):
    raise SystemExit('Run this builder under fakeroot to preserve filesystem ownership')
for name in ('debugfs', 'mkfs.ext4', 'e2fsck', 'depmod', 'gzip'):
    if not shutil.which(name):
        raise SystemExit(f'Missing tool: {name}')
def sha(path):
    h = hashlib.sha256()
    with path.open('rb') as f:
        for b in iter(lambda: f.read(4*1024*1024), b''): h.update(b)
    return h.hexdigest()
if sha(a.base_gzip) != a.base_sha256:
    raise SystemExit('Base archive hash mismatch')
if not (a.modules / 'modules.dep').is_file():
    raise SystemExit('Complete kernel modules required')
output.mkdir(mode=0o700)
raw = output / 'input.ext4'
with gzip.open(a.base_gzip, 'rb') as src, raw.open('xb') as dst:
    shutil.copyfileobj(src, dst, 4*1024*1024)
if raw.stat().st_size != 5368709120 or sha(raw) != a.raw_sha256:
    raise SystemExit('Base raw filesystem hash/size mismatch')
root = output / 'root'
root.mkdir()
with (output / 'extract.log').open('wb') as log:
    subprocess.run(['debugfs', '-R', f'rdump / {root}', str(raw)], stdout=log, stderr=log, check=True)
if not (root / 'etc/passwd').is_file() or not (root / 'usr/bin/plasmashell').exists():
    raise SystemExit('Incomplete OEM filesystem extraction')
raw.unlink()
passwd = [line.split(':') for line in (root / 'etc/passwd').read_text().splitlines()]
if any(1000 <= int(row[2]) < 65534 for row in passwd):
    raise SystemExit('Input contains a personal account; this is not an OEM base')
if not any(row[0] == 'm1892-setup' for row in passwd):
    raise SystemExit('Missing temporary OEM system account')
def safe(relative):
    path = root / relative
    # Follow usrmerge, but never an input symlink escaping the new build tree.
    if not path.resolve().is_relative_to(root):
        raise SystemExit(f'Unsafe base path: {relative}')
    return path
def remove(relative):
    path = safe(relative)
    if path.is_symlink() or path.is_file(): path.unlink()
    elif path.is_dir(): shutil.rmtree(path)
def write(relative, content, mode=0o644):
    path = safe(relative)
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists(): path.chmod(0o600)
    path.write_text(content)
    path.chmod(mode)
def install(source, relative):
    target = safe(relative)
    target.parent.mkdir(parents=True, exist_ok=True)
    if target.exists(): target.chmod(0o600)
    shutil.copyfile(source, target)
    target.chmod(0o755 if source.stat().st_mode & 0o111 else 0o644)

# Only the accepted redistributable GPU pair survives the firmware boundary.
firmware = safe('lib/firmware')
keep = {
    'qcom/a630_gmu.bin': 'da8d9b1b1f5c1a0b311f32567093b4828f3c80031dd8435f91ac13c664e173a6',
    'qcom/a630_sqe.fw': '1c21b527d9183487cc550dabbb3f43e555df5a977a461934fc61f0635a9aa90c',
}
gpu = {}
for name, expected in keep.items():
    path = firmware / name
    if sha(path) != expected: raise SystemExit('GPU firmware contract differs')
    gpu[name] = path.read_bytes()
remove('lib/firmware')
for name, data in gpu.items():
    target = safe('lib/firmware/' + name)
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(data)
    target.chmod(0o644)
remove('usr/share/qcom')

# Carry forward only existing managed integration files, plus explicitly new
# accepted network/power helpers. Never copy development account overlays wholesale.
new = {
    'etc/systemd/system/m1892-wifi-identity.service',
    'etc/systemd/system/NetworkManager.service.d/15-m1892-wifi-identity.conf',
    'usr/libexec/m1892/wifi-identity',
    'usr/libexec/m1892/wake-policy',
    'etc/systemd/system/m1892-wake-policy.service',
    'etc/udev/rules.d/92-m1892-wifi-wake.rules',
    'usr/lib/tmpfiles.d/m1892-cpufreq-boost.conf',
}
overlay = tree / 'rootfs-overlay'
installed = []
for source in sorted(overlay.rglob('*')):
    if not source.is_file(): continue
    relative = source.relative_to(overlay).as_posix()
    if relative in ('etc/m1892-rootfs-identity', 'etc/m1892-stage3-rootfs-identity'):
        continue
    if safe(relative).is_file() or relative in new or relative.startswith('etc/skel/.config/'):
        install(source, relative)
        installed.append(relative)

remove('lib/modules/7.1.0-rc1-sdm845')
destination = safe('lib/modules/7.1.0-rc1-sdm845')
shutil.copytree(a.modules, destination, symlinks=True, ignore=shutil.ignore_patterns('build', 'source'))
subprocess.run(['depmod', '-b', str(root), '7.1.0-rc1-sdm845'], check=True)
write('etc/hostname', 'm1892\n')
write('etc/machine-id', '')
for directory in ('root', 'home', 'var/log', 'var/lib/bluetooth', 'run', 'tmp'):
    remove(directory)
    safe(directory).mkdir(parents=True, exist_ok=True)
safe('root').chmod(0o700)
safe('tmp').chmod(0o1777)
for name in ('passwd-', 'shadow-', 'group-', 'gshadow-'):
    remove('etc/' + name)
for path in safe('etc/ssh').glob('ssh_host_*'):
    path.unlink()
for path in safe('etc/NetworkManager/system-connections').glob('*'):
    if path.name != 'm1892-cellular.nmconnection':
        path.unlink()
for directory in ('etc/systemd/system/multi-user.target.wants', 'etc/systemd/system/graphical.target.wants'):
    for name in ('ssh.service', 'sshd.service', 'm1892-stage3-acm-shell.service'):
        path = root / directory / name
        if path.is_symlink(): path.unlink()
for name in ('sleep.target', 'suspend.target', 'hibernate.target', 'hybrid-sleep.target', 'suspend-then-hibernate.target'):
    path = root / 'etc/systemd/system' / name
    if path.is_symlink() or path.exists(): path.unlink()
    path.symlink_to('/dev/null')
identity = safe('etc/m1892-rootfs-identity')
rows = dict(line.split('=', 1) for line in identity.read_text().splitlines() if '=' in line)
rows.update(development_console='disabled', suspend_policy='masked', firmware_policy='device-import-before-install')
write('etc/m1892-rootfs-identity', ''.join(f'{k}={v}\n' for k, v in rows.items()))

setup = next(row for row in passwd if row[0] == 'm1892-setup')
setup_home = safe(setup[5].lstrip('/'))
for source in sorted((overlay/'etc/skel/.config').iterdir()):
    if source.is_file():
        install(source, (setup_home.relative_to(root)/'.config'/source.name).as_posix())
for path in [setup_home, *setup_home.rglob('*')]:
    os.chown(path, int(setup[2]), int(setup[3]), follow_symlinks=False)
epoch = 1788739200
for path in [root, *root.rglob('*')]:
    os.utime(path, (epoch, epoch), follow_symlinks=False)
image = output / 'm1892-userdata.ext4'
with image.open('xb') as f: f.truncate(5368709120)
env = dict(os.environ, E2FSPROGS_FAKE_TIME=str(epoch))
uuid = 'de131892-0000-4000-8000-000000000007'
subprocess.run(['mkfs.ext4','-q','-F','-m','0','-L','M1892_DEB13','-U',uuid,'-E',
                'lazy_itable_init=0,lazy_journal_init=0','-d',str(root),str(image)],env=env,check=True)
subprocess.run(['debugfs','-w','-R',f'set_super_value hash_seed {uuid}',str(image)],env=env,check=True,stdout=subprocess.DEVNULL)
with (output/'e2fsck.log').open('wb') as log:
    subprocess.run(['e2fsck','-fn',str(image)],stdout=log,stderr=log,check=True)
image_sha = sha(image)
metadata = dict(schema=1,source_base_sha256=a.base_sha256,root_image_sha256=image_sha,
                root_image_bytes=image.stat().st_size,filesystem_origin='new-file-mkfs-d',
                owner_accounts='absent',firmware_scope='public-device-import',
                development_console='disabled',suspend_policy='masked',updated_files=installed)
(output/'build.json').write_text(json.dumps(metadata,indent=2)+'\n')
print(json.dumps(metadata, indent=2))
print('PUBLIC_ROOTFS_ASSEMBLY_PASS')
