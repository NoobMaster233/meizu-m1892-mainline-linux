#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Seal a public installation candidate after actual filesystem inspection."""
import argparse,hashlib,json,pathlib,shutil,subprocess,zipfile
p=argparse.ArgumentParser()
p.add_argument('rootfs',type=pathlib.Path)
p.add_argument('boot',type=pathlib.Path)
p.add_argument('installer',type=pathlib.Path)
p.add_argument('installer_boot',type=pathlib.Path)
p.add_argument('output',type=pathlib.Path)
p.add_argument('--firmware-licenses',type=pathlib.Path,required=True)
a=p.parse_args()
tree=pathlib.Path(__file__).resolve().parents[1]
if a.output.exists():raise SystemExit('Output exists')
for name in ('LICENSE.qcom','NOTICE.qcom','LICENSE.QualcommAtheros_ath10k','notice.txt_wlanmdsp'):
    if not (a.firmware_licenses/name).is_file():raise SystemExit('Required firmware licence absent: '+name)
def sha(path):
    h=hashlib.sha256()
    with path.open('rb') as f:
        for b in iter(lambda:f.read(4*1024*1024),b''):h.update(b)
    return h.hexdigest()
rm=json.loads((a.rootfs/'build.json').read_text())
bm=json.loads((a.boot/'build.json').read_text())
im=json.loads((a.installer/'build.json').read_text())
ibm=json.loads((a.installer_boot/'build.json').read_text())
if rm.get('filesystem_origin')!='new-file-mkfs-d' or rm.get('firmware_scope')!='public-device-import':
    raise SystemExit('Not a fresh vendor-free rootfs build')
if bm.get('usb_profile')!='host' or ibm.get('usb_profile')!='installer-peripheral':
    raise SystemExit('Boot USB role mismatch')
if bm.get('vendor_firmware')!='absent' or im.get('vendor_firmware')!='absent':raise SystemExit('Firmware scope mismatch')
raw=a.rootfs/'m1892-userdata.ext4'
if sha(raw)!=rm['root_image_sha256']:raise SystemExit('Raw image changed since mkfs')
audit=json.loads(subprocess.check_output(['python3',str(tree/'scripts/verify-release-image-privacy.py'),
    str(raw),'--require-vendor-free','--artifact-sha256',rm['root_image_sha256']],text=True))
if audit['content_result']!='PASS':raise SystemExit('Privacy content gate failed')
items=(
 ('installer-boot',a.installer_boot/'m1892-installer-boot.img',ibm['boot_sha256']),
 ('installer-rootfs',a.installer/'m1892-installer-rootfs.ext4.gz',im['artifact_sha256']),
 ('system-boot',a.boot/'m1892-system-boot.img',bm['boot_sha256']),
 ('system-recovery',a.installer_boot/'m1892-recovery-template.bin',ibm['recovery_template_sha256']),
 ('userdata',a.rootfs/'m1892-userdata.ext4.gz',None),
)
assets=[]
for role,path,expected in items:
    actual=sha(path)
    if expected and actual!=expected:raise SystemExit('Asset metadata mismatch: '+role)
    assets.append(dict(role=role,file=path.name,bytes=path.stat().st_size,sha256=actual))
a.output.mkdir(parents=True,mode=0o700)
staging=a.output/'m1892-install';staging.mkdir()
for (role,path,_),entry in zip(items,assets):
    # Large immutable inputs are linked in staging; the ZIP is independent.
    (staging/path.name).hardlink_to(path)
for name in ('Install.ps1','Transport.psm1','install.cmd'):
    shutil.copy2(tree/'installer'/name,staging/name)
for name in ('PACKAGE_INSTALL.md','PACKAGE_INSTALL_EN.md','BACKUP.md','BACKUP_EN.md','KNOWN_ISSUES.md','KNOWN_ISSUES_EN.md'):
    shutil.copy2(tree/'publication'/name,staging/name)
shutil.copytree(tree.parent/'public-release/licenses',staging/'licenses')
for name in ('LICENSE.qcom','NOTICE.qcom','LICENSE.QualcommAtheros_ath10k','notice.txt_wlanmdsp'):
    shutil.copy2(a.firmware_licenses/name,staging/'licenses'/name)
(staging/'COPYING.md').write_text('# 许可证 / Licenses\n\n'
    '系统软件保留其上游许可证，具体版权资料在镜像的 /usr/share/doc 中。\n'
    '内核、启动辅助程序及集成源码位于同版本项目源码；GPL/BSD/MIT 等正文随包放在 licenses/。\n'
    '可再分发的上游 GPU/WLAN 固件附有 Qualcomm 许可及 notice；Flyme 固件仅在目标手机本地导入。\n\n'
    'Software retains its upstream licenses; package copyright files are in /usr/share/doc. '
    'Kernel and boot/integration sources are in the matching project source. License texts and '
    'redistributable upstream GPU/WLAN firmware notices are included in licenses/. '
    'Flyme firmware is imported locally on the target only.\n\n'
    'https://github.com/NoobMaster233/meizu-m1892-mainline-linux/tree/codex/debian13-plasma-mobile\n')
(staging/'README.md').write_text('# M1892 Debian 13 + Plasma Mobile\n\n简体中文 | [English](README_EN.md)\n\n'
    '请先阅读 [中文安装手册](PACKAGE_INSTALL.md)。这是待最终真机验收的完整候选包。\n'
    '安装会清除 userdata；只能用于已解锁的 M1892。请勿手工刷 Recovery 模板。\n')
(staging/'README_EN.md').write_text('# M1892 Debian 13 + Plasma Mobile\n\n[简体中文](README.md) | English\n\n'
    'Read the [installation guide](PACKAGE_INSTALL_EN.md). This complete candidate awaits final hardware acceptance.\n'
    'Installation erases userdata. Unlocked M1892 only. Never manually flash the Recovery template.\n')
manifest=dict(schema=2,model='Meizu 16th Plus (M1892)',scope='public-device-firmware',
    root_image_bytes=rm['root_image_bytes'],root_image_sha256=rm['root_image_sha256'],
    firmware_manifest_sha256=sha(tree/'contracts/firmware-files.tsv'),assets=assets,
    validation='candidate-not-fresh-install-accepted')
(staging/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
summary=dict(schema=1,raw_sha256=rm['root_image_sha256'],scoped_content_scan='PASS',
    unallocated_data_origin='new-empty-file-mkfs',vendor_files='imported-only-on-target',
    stock_recovery_tail='composed-only-on-target',fresh_install='PENDING',gpu_default_mhz=710,
    suspend_default='masked',owner_credentials='not-preinstalled')
(staging/'VERIFICATION.json').write_text(json.dumps(summary,indent=2)+'\n')
with (staging/'SHA256SUMS').open('w') as f:
    known={item['file']:item['sha256'] for item in assets}
    for path in sorted(staging.rglob('*')):
        if not path.is_file() or path.name=='SHA256SUMS':continue
        relative=path.relative_to(staging).as_posix()
        f.write(f'{known.get(relative) or sha(path)}  {relative}\n')
archive=a.output/'m1892-debian13-plasma-mobile-install.zip'
with zipfile.ZipFile(archive,'x',allowZip64=True) as z:
    for path in sorted(staging.rglob('*')):
        if not path.is_file():continue
        z.write(path,'m1892-install/'+path.relative_to(staging).as_posix(),compress_type=zipfile.ZIP_STORED if path.suffix=='.gz' else zipfile.ZIP_DEFLATED,compresslevel=6)
(a.output/(archive.name+'.sha256')).write_text(sha(archive)+'  '+archive.name+'\n')
print(f'archive={archive}\nbytes={archive.stat().st_size}')
print('PUBLIC_INSTALL_CANDIDATE_PACKAGE_PASS')
