#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Compose recovery locally, then write/read back only validated boot targets."""
import argparse,hashlib,json,os,pathlib,stat,struct,subprocess
import re
p=argparse.ArgumentParser()
p.add_argument('mode',choices=('prepare','write'))
p.add_argument('manifest',type=pathlib.Path)
a=p.parse_args()
if os.geteuid()!=0 or pathlib.Path('/proc/device-tree/model').read_bytes().rstrip(b'\0')!=b'Meizu 16th Plus (M1892)':
    raise SystemExit('BOOT_FAIL: device/root')
identity=pathlib.Path('/etc/m1892-rootfs-identity').read_text()
if 'rootfs_id=m1892-debian13-installer-ram' not in identity.splitlines():raise SystemExit('BOOT_FAIL: not RAM installer')
if not subprocess.check_output(['findmnt','-rn','-o','SOURCE','/'],text=True).strip().startswith('/dev/loop'):
    raise SystemExit('BOOT_FAIL: root is not RAM loopback')
manifest_bytes=a.manifest.read_bytes()
manifest=json.loads(manifest_bytes)
if manifest.get('schema')!=2 or manifest.get('scope')!='public-device-firmware':raise SystemExit('BOOT_FAIL: manifest scope')
assets={entry['role']:entry for entry in manifest['assets']}
if len(manifest['assets'])!=5 or set(assets)!={'installer-boot','installer-rootfs','system-boot','system-recovery','userdata'}:
    raise SystemExit('BOOT_FAIL: asset roles')
contract=pathlib.Path('/usr/share/m1892/installer-firmware/firmware-files.tsv')
if hashlib.sha256(contract.read_bytes()).hexdigest()!=manifest.get('firmware_manifest_sha256'):
    raise SystemExit('BOOT_FAIL: firmware contract mismatch')
if not re.fullmatch('[0-9a-f]{64}',manifest.get('root_image_sha256','')):
    raise SystemExit('BOOT_FAIL: userdata digest')
offset=26091520; size=67108864
tail_sha='8189de1bf028138490644a22e975444cad468b7bfa9c4590c1bcd2c0d1f9b34b'
def sha(data):return hashlib.sha256(data).hexdigest()
def target(label,expected):
    path=pathlib.Path('/dev/disk/by-partlabel')/label
    if path.resolve()!=pathlib.Path(expected) or not stat.S_ISBLK(path.stat().st_mode):raise SystemExit('BOOT_FAIL: partition identity')
    if int(subprocess.check_output(['blockdev','--getsize64',str(path)]))!=size:raise SystemExit('BOOT_FAIL: partition size')
    return path
boot_target=target('boot','/dev/sde11');recovery_target=target('recovery','/dev/sda13')
def asset(role):
    entry=assets[role];name=entry['file']
    if pathlib.PurePosixPath(name).name!=name:raise SystemExit('BOOT_FAIL: asset path')
    path=pathlib.Path('/run')/name
    data=path.read_bytes()
    if len(data)!=size or sha(data)!=entry['sha256'] or data[:8]!=b'ANDROID!':raise SystemExit('BOOT_FAIL: asset integrity')
    return data
boot=asset('system-boot');template=asset('system-recovery')
with recovery_target.open('rb') as f:f.seek(offset);tail=f.read()
if sha(tail)!=tail_sha:raise SystemExit('BOOT_FAIL: unsupported stock recovery tail; userdata must not be erased')
if any(template[offset:]):raise SystemExit('BOOT_FAIL: recovery template contains a vendor tail')
recovery=template[:offset]+tail
prepared=pathlib.Path('/run/m1892-final-boot-prepared.json')
expected=dict(boot_sha256=sha(boot),recovery_sha256=sha(recovery),tail_sha256=tail_sha,
              manifest_sha256=sha(manifest_bytes))
if a.mode=='prepare':
    prepared.write_text(json.dumps(expected)+'\n')
else:
    if json.loads(prepared.read_text())!=expected:raise SystemExit('BOOT_FAIL: preparation receipt differs')
    receipt_path=pathlib.Path('/run/m1892-stage7-commission.pass')
    if not receipt_path.is_file():raise SystemExit('BOOT_FAIL: userdata not commissioned')
    receipt={}
    for line in receipt_path.read_text().splitlines():
        if '=' not in line:raise SystemExit('BOOT_FAIL: malformed userdata receipt')
        key,value=line.split('=',1)
        if key in receipt:raise SystemExit('BOOT_FAIL: duplicate userdata receipt key')
        receipt[key]=value
    required=dict(result='pass',target='/dev/sda19',transaction_manifest_sha256=sha(manifest_bytes),
                  archive_sha256=assets['userdata']['sha256'],source_image_sha256=manifest['root_image_sha256'],
                  firmware_contract_sha256=manifest['firmware_manifest_sha256'],
                  filesystem_uuid='de131892-0000-4000-8000-000000000007')
    if any(receipt.get(k)!=v for k,v in required.items()):raise SystemExit('BOOT_FAIL: userdata receipt belongs to another transaction')
    for path,data in ((recovery_target,recovery),(boot_target,boot)):
        with path.open('r+b',buffering=0) as f:
            for start in range(0,len(data),1024*1024):
                block=data[start:start+1024*1024]
                if f.write(block)!=len(block):raise SystemExit('BOOT_FAIL: short partition write')
            os.fsync(f.fileno())
        subprocess.run(['blockdev','--flushbufs',str(path)],check=True)
        with path.open('rb',buffering=0) as f:
            if sha(f.read())!=sha(data):raise SystemExit('BOOT_FAIL: partition readback')
    os.sync()
    receipt_path.unlink();prepared.unlink()
print(json.dumps(expected));print('M1892_FINAL_BOOT_'+a.mode.upper()+'_PASS')
