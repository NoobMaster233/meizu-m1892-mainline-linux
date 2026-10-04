#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Build an offline RAM installer with read-only, per-device firmware import."""
import argparse,gzip,hashlib,json,os,pathlib,shutil,subprocess
p=argparse.ArgumentParser()
p.add_argument('base',type=pathlib.Path)
p.add_argument('assets',type=pathlib.Path)
p.add_argument('encoder',type=pathlib.Path)
p.add_argument('output',type=pathlib.Path)
p.add_argument('--base-sha256',default='1f5ba79345204d198f75e3d705d7c3e55f8dec38915a93ec67f09c317afc9757')
a=p.parse_args()
tree=pathlib.Path(__file__).resolve().parents[1]
def sha(path):
    h=hashlib.sha256()
    with path.open('rb') as f:
        for b in iter(lambda:f.read(1024*1024),b''):h.update(b)
    return h.hexdigest()
if not os.environ.get('FAKEROOTKEY'):raise SystemExit('Use fakeroot')
if a.output.exists():raise SystemExit('Output exists')
if sha(a.base)!=a.base_sha256:raise SystemExit('RAM base identity')
for name,digest in {
 'board-2.bin':'867e1010787764020653812167d93f5952cbbea05f576209d953d8c9322f18aa',
 'wlanmdsp.mbn':'92e1501254e6de78c0f2e2cf091507d488b608d07e53acd14813a82744823ec2',
}.items():
    if sha(a.assets/name)!=digest:raise SystemExit('Redistributable firmware input mismatch')
for name in ('LICENSE.QualcommAtheros_ath10k','notice.txt_wlanmdsp'):
    if not (a.assets/name).is_file():raise SystemExit('Firmware licence/notice absent')
a.output.mkdir(parents=True,mode=0o700)
raw=a.output/'input.ext4'
with gzip.open(a.base,'rb') as src,raw.open('xb') as dst:shutil.copyfileobj(src,dst)
root=a.output/'root';root.mkdir()
with (a.output/'extract.log').open('wb') as log:
    subprocess.run(['debugfs','-R',f'rdump / {root}',str(raw)],check=True,stdout=log,stderr=log)
raw.unlink()
if not (root/'usr/bin/python3').exists():raise SystemExit('RAM runtime missing')
dest=root/'usr/share/m1892/installer-firmware';dest.mkdir(parents=True,exist_ok=True)
for name in ('extract-flyme-firmware.sh','fat16-extract.py','sdat2img.py','build-m1892-board2.py'):
    shutil.copy2(tree.parent/'public-release/scripts'/name,dest/name)
shutil.copy2(tree/'contracts/firmware-files.tsv',dest/'firmware-files.tsv')
shutil.copy2(a.encoder,dest/'ath10k-bdencoder');(dest/'ath10k-bdencoder').chmod(0o755)
for name in ('board-2.bin','wlanmdsp.mbn','LICENSE.QualcommAtheros_ath10k','notice.txt_wlanmdsp'):
    shutil.copy2(a.assets/name,dest/name)
helpers=root/'usr/libexec/m1892';helpers.mkdir(parents=True,exist_ok=True)
for source,target in (
 ('install-device-firmware.py','install-device-firmware'),
 ('install-final-boot.py','install-final-boot'),
 ('commission-stage7-userdata.sh','commission-stage7-userdata'),
):
    shutil.copyfile(tree/'scripts'/source,helpers/target);(helpers/target).chmod(0o755)
(root/'etc/hostname').write_text('m1892\n')
(root/'etc/machine-id').write_text('')
for entry in (root/'var/log').rglob('*'):
    if entry.is_file():entry.write_bytes(b'')
epoch=1788739200
for entry in [root,*root.rglob('*')]:os.utime(entry,(epoch,epoch),follow_symlinks=False)
image=a.output/'m1892-installer-rootfs.ext4'
with image.open('xb') as f:f.truncate(536870912)
env=dict(os.environ,E2FSPROGS_FAKE_TIME=str(epoch));uuid='de131892-0000-4000-8000-000000000020'
subprocess.run(['mkfs.ext4','-q','-F','-m','0','-L','M1892_INSTALL','-U',uuid,'-E','lazy_itable_init=0,lazy_journal_init=0','-d',str(root),str(image)],env=env,check=True)
subprocess.run(['debugfs','-w','-R',f'set_super_value hash_seed {uuid}',str(image)],env=env,stdout=subprocess.DEVNULL,check=True)
with (a.output/'e2fsck.log').open('wb') as log:subprocess.run(['e2fsck','-fn',str(image)],stdout=log,stderr=log,check=True)
archive=a.output/'m1892-installer-rootfs.ext4.gz'
with archive.open('xb') as f:subprocess.run(['gzip','-n','-6','-c',str(image)],stdout=f,check=True)
meta=dict(schema=1,artifact_sha256=sha(archive),artifact_size=archive.stat().st_size,
 persistent_root_image_sha256=sha(image),persistent_root_image_size=image.stat().st_size,
 filesystem_origin='new-file-mkfs-d',vendor_firmware='absent',firmware_import='read-only-stock-partitions')
(a.output/'build.json').write_text(json.dumps(meta,indent=2)+'\n')
print(json.dumps(meta,indent=2));print('PUBLIC_INSTALLER_ROOTFS_PASS')
