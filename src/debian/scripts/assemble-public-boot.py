#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Compose a vendor-free Host Boot, preserving the accepted boot handoff.

Accept a hash-pinned boot template and an independently verified kernel build.
The output carries no Recovery tail or initramfs firmware payloads.
"""
import argparse
import gzip
import hashlib
import json
import pathlib
import stat
import struct
import subprocess
import tempfile

p=argparse.ArgumentParser()
p.add_argument('template',type=pathlib.Path)
p.add_argument('template_sha256')
p.add_argument('kernel_build',type=pathlib.Path)
p.add_argument('output',type=pathlib.Path)
p.add_argument('--busybox',type=pathlib.Path,required=True,help='Debian busybox-static from the verified rootfs')
p.add_argument('--installer-rootfs',type=pathlib.Path,help='RAM installer directory containing build.json')
a=p.parse_args()
def sha(data): return hashlib.sha256(data).hexdigest()
raw=a.template.read_bytes()
if len(raw)!=67108864 or sha(raw)!=a.template_sha256:
    raise SystemExit('Boot template identity mismatch')
if a.output.exists(): raise SystemExit('Output already exists')
scripts=pathlib.Path(__file__).resolve().parent
subprocess.run([str(scripts/'../../public-release/scripts/verify-public-kernel.sh'),str(a.kernel_build)],check=True,stdout=subprocess.DEVNULL)
def unpack(data):
    if data[:8]!=b'ANDROID!': raise SystemExit('Invalid Android header')
    k,r,page=[struct.unpack_from('<I',data,o)[0] for o in (8,16,36)]
    if page not in (2048,4096): raise SystemExit('Unexpected page size')
    ro=page+((k+page-1)//page)*page
    if not k or ro+r>len(data): raise SystemExit('Truncated boot payload')
    cmd=data[64:576].split(b'\0',1)[0]+data[608:1632].split(b'\0',1)[0]
    return data[page:page+k],data[ro:ro+r],cmd
uefi,inner,_=unpack(raw)
if sha(uefi)!='1d3312dc255cc9d123c906fb456f6260b0b10dc3564fed7418c64c20c53e967b':
    raise SystemExit('Unexpected accepted UEFI loader')
_,ramdisk,cmd=unpack(inner)
if b'm1892.usb=off' not in cmd: raise SystemExit('Expected accepted Host profile')
archive=gzip.decompress(ramdisk)
entries=[]; offset=0; links={}
while offset+110<=len(archive):
    header=archive[offset:offset+110]
    if header[:6]!=b'070701': raise SystemExit('Unsupported cpio format')
    values=[int(header[6+j*8:14+j*8],16) for j in range(13)]
    inode,mode,_,_,nlink,_,size,_,_,_,_,namesize,_=values
    name=archive[offset+110:offset+110+namesize-1].decode()
    start=(offset+110+namesize+3)&~3
    data=archive[start:start+size]; offset=(start+size+3)&~3
    if name=='TRAILER!!!': break
    path=pathlib.PurePosixPath(name)
    if path.is_absolute() or '..' in path.parts: raise SystemExit('Unsafe cpio path')
    if nlink>1 and stat.S_ISREG(mode) and size: links[inode]=data
    entries.append((name,mode,inode,nlink,data))
kept={}; removed=[]
required_files={
    'init','bin/busybox','bin/m1892-display-auto-r59','bin/m1892-i2c5-auto',
    'bin/sysfs-write-errno','bin/reboot-fastboot',
    'lib/modules/m1892-panel/panel-samsung-sofef00m.ko',
}
for name,mode,inode,nlink,data in entries:
    if name.startswith(('lib/firmware/','usr/share/qcom/')):
        removed.append(name); continue
    if name in ('lib/firmware','usr/share/qcom'): continue
    if not stat.S_ISDIR(mode) and name not in required_files: continue
    if not (stat.S_ISDIR(mode) or stat.S_ISREG(mode) or stat.S_ISLNK(mode)):
        raise SystemExit('Unexpected special file in boot template')
    if nlink>1 and stat.S_ISREG(mode): data=links.get(inode,data)
    kept[name]=(mode,data)
if not required_files.issubset(kept): raise SystemExit('Incomplete boot provider dependency closure')
bootstrap=scripts.parent/'userspace/boot'
for name in ('m1892-display-auto-r59','m1892-i2c5-auto'):
    kept['bin/'+name]=(stat.S_IFREG|0o755,(bootstrap/name).read_bytes())
if b'INTERP' in subprocess.check_output(['aarch64-linux-gnu-readelf','-l',str(a.busybox)]):
    raise SystemExit('BusyBox must be static')
if b'AArch64' not in subprocess.check_output(['aarch64-linux-gnu-readelf','-h',str(a.busybox)]):
    raise SystemExit('BusyBox must be ARM64')
kept['bin/busybox']=(stat.S_IFREG|0o755,a.busybox.read_bytes())
with tempfile.TemporaryDirectory(prefix='m1892-bootstrap-toolbox-') as td:
    binary=pathlib.Path(td)/'toolbox'
    subprocess.run(['aarch64-linux-gnu-gcc','-static','-Os','-s','-Wl,--build-id=none',
                    '-o',str(binary),str(bootstrap/'m1892-toolbox.c')],check=True)
    for name in ('sysfs-write-errno','reboot-fastboot'):
        kept['bin/'+name]=(stat.S_IFREG|0o755,binary.read_bytes())
panel=a.kernel_build/'drivers/gpu/drm/panel/panel-samsung-sofef00m.ko'
panel_bytes=panel.read_bytes(); panel_sha=sha(panel_bytes)
kept['lib/modules/m1892-panel/panel-samsung-sofef00m.ko']=(stat.S_IFREG|0o644,panel_bytes)
init=kept['init'][1].decode()
import re
init,count=re.subn(r'(?m)^expected_panel_sha256=[0-9a-f]{64}$','expected_panel_sha256='+panel_sha,init)
if count!=1: raise SystemExit('Panel module contract absent')
kept['init']=(stat.S_IFREG|0o755,init.encode())
def cpio(files):
    result=bytearray()
    for number,(name,(mode,data)) in enumerate(sorted(files.items()),1):
        nb=name.encode()+b'\0'
        values=(number,mode,0,0,1,1788739200,len(data),0,0,0,0,len(nb),0)
        result.extend(b'070701'+b''.join(f'{v:08x}'.encode() for v in values)+nb)
        result.extend(b'\0'*((-len(result))%4)); result.extend(data)
        result.extend(b'\0'*((-len(result))%4))
    nb=b'TRAILER!!!\0'
    values=(0,0,0,0,1,0,0,0,0,0,0,len(nb),0)
    result.extend(b'070701'+b''.join(f'{v:08x}'.encode() for v in values)+nb)
    result.extend(b'\0'*((-len(result))%512))
    return bytes(result)
new_ram=gzip.compress(cpio(kept),compresslevel=9,mtime=0)
kernel=(a.kernel_build/'arch/arm64/boot/Image.gz').read_bytes()
dtb=(a.kernel_build/'arch/arm64/boot/dts/qcom/sdm845-meizu-m1892-current-product.dtb').read_bytes()
a.output.mkdir(parents=True)
with tempfile.TemporaryDirectory(prefix='m1892-public-boot-') as td:
    work=pathlib.Path(td)
    if a.installer_rootfs:
        ram_meta=json.loads((a.installer_rootfs/'build.json').read_text())
        if ram_meta.get('vendor_firmware')!='absent': raise SystemExit('RAM firmware scope')
        text=(scripts.parent/'initramfs/init-installer.in').read_text()
        for key,value in {
            'ARCHIVE_BYTES':ram_meta['artifact_size'],'ARCHIVE_SHA':ram_meta['artifact_sha256'],
            'IMAGE_BYTES':ram_meta['persistent_root_image_size'],'IMAGE_SHA':ram_meta['persistent_root_image_sha256'],
        }.items():text=text.replace('@'+key+'@',str(value))
        if re.search(r'@[A-Z_]+@',text):raise SystemExit('Unresolved RAM template')
        new_ram=gzip.compress(cpio({
            '.':(stat.S_IFDIR|0o755,b''),'bin':(stat.S_IFDIR|0o755,b''),
            'bin/busybox':kept['bin/busybox'],'bin/reboot-fastboot':kept['bin/reboot-fastboot'],
            'init':(stat.S_IFREG|0o755,text.encode()),
        }),compresslevel=9,mtime=0)
        dev_dtb=work/'device.dtb';dev_dtb.write_bytes(dtb)
        for node,prop,value in (
            ('/soc@0/usb@a6f8800/usb@a600000','dr_mode','peripheral'),
            ('/soc@0/spmi@c440000/pmic@2/typec@1300','status','disabled'),
            ('/soc@0/spmi@c440000/pmic@2/usb-vbus-regulator@1100','status','disabled'),
        ):
            subprocess.run(['fdtput','-t','s',str(dev_dtb),node,prop,value],check=True)
        dtb=dev_dtb.read_bytes()
        cmd=cmd.replace(b'm1892.usb=off',b'm1892.usb=acm-ncm')
    for name,data in [('uefi',uefi),('kernel-dtb',kernel+dtb),('initramfs.gz',new_ram)]:
        (work/name).write_bytes(data)
    inner_file=work/'inner.img'
    image=a.output/('m1892-installer-boot.img' if a.installer_rootfs else 'm1892-system-boot.img')
    subprocess.run(['mkbootimg','--header_version','0','--kernel',str(work/'kernel-dtb'),
        '--ramdisk',str(work/'initramfs.gz'),'--cmdline',cmd.decode(),'--base','0',
        '--kernel_offset','0x8000','--ramdisk_offset','0x01000000','--second_offset','0x00f00000',
        '--tags_offset','0x100','--pagesize','4096','--os_version','8.1.0','--os_patch_level','2021-06-01',
        '--output',str(inner_file)],check=True)
    subprocess.run(['mkbootimg','--header_version','1','--kernel',str(work/'uefi'),'--ramdisk',str(inner_file),
        '--base','0','--kernel_offset','0x10000000','--ramdisk_offset','0x10000000','--second_offset','0',
        '--tags_offset','0x10000000','--pagesize','2048','--os_version','9.0.0','--os_patch_level','2020-09-01',
        '--output',str(image)],check=True)
    payload_size=image.stat().st_size
    if a.installer_rootfs:
        if payload_size>=26091520:raise SystemExit('Recovery template overlaps stock tail')
        recovery=a.output/'m1892-recovery-template.bin'
        with recovery.open('xb') as f:
            f.write(image.read_bytes());f.truncate(67108864)
    subprocess.run(['avbtool','add_hash_footer','--image',str(image),'--partition_size','67108864',
        '--partition_name','boot','--salt','fc5e6fa1efbd6ebaf16a6ac186f72d5ebfc86316b1ffe568470fdd5d84945d6a'],check=True)
    (work/'boot.img').write_bytes(image.read_bytes())
    subprocess.run(['avbtool','verify_image','--image',str(work/'boot.img')],check=True,stdout=subprocess.DEVNULL)
metadata=dict(schema=1,template_sha256=a.template_sha256,boot_sha256=sha(image.read_bytes()),
    uefi_sha256=sha(uefi),kernel_sha256=sha(kernel),dtb_sha256=sha(dtb),initramfs_sha256=sha(new_ram),
    panel_sha256=panel_sha,firmware_payloads_removed=len(removed),vendor_firmware='absent',
    stock_recovery_tail='absent',usb_profile='installer-peripheral' if a.installer_rootfs else 'host',
    gpu_max_mhz=710,busybox_sha256=sha(a.busybox.read_bytes()),payload_size=payload_size)
if a.installer_rootfs:metadata['recovery_template_sha256']=sha(recovery.read_bytes())
(a.output/'build.json').write_text(json.dumps(metadata,indent=2)+'\n')
print(json.dumps(metadata,indent=2))
print('PUBLIC_BOOT_ASSEMBLY_PASS')
