#!/bin/sh
# SPDX-License-Identifier: MIT
# Package existing, independently checked assets. Never clone a live phone.
set -eu
ram_boot=${1:-} ram_root=${2:-} system_boot=${3:-} system_recovery=${4:-} userdata=${5:-} output=${6:-}
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
fail() { echo "M1892_LOCAL_PACKAGE_FAIL: $*" >&2; exit 1; }
for command in python3 sha256sum stat install git ln; do command -v "$command" >/dev/null || fail "command:$command"; done
for input in "$ram_boot" "$ram_root" "$system_boot" "$system_recovery" "$userdata"; do [ -f "$input" ] || fail input-absent; done
for name in Install.ps1 Transport.psm1 install.cmd README.md README_EN.md; do
 git -C "$script_dir/.." ls-files --error-unmatch "installer/$name" >/dev/null 2>&1 || fail "untracked-installer-source:$name"
done
case "$output" in /*) ;; *) fail output-not-absolute ;; esac
[ ! -e "$output" ] || fail output-exists
root_metadata=$(dirname "$userdata")/BUILD-METADATA.txt
ram_metadata=$(dirname "$ram_root")/BUILD-METADATA.txt
[ -f "$root_metadata" ] && [ -f "$ram_metadata" ] || fail metadata-absent
grep -Fxq 'account_mode=oem-owner' "$root_metadata" || fail non-oem
grep -Fxq 'owner_firmware_scope=owner-local-complete' "$root_metadata" || fail firmware-incomplete
grep -Fxq 'private_network_injected=no' "$root_metadata" || fail private-network
grep -Fxq 'development_ssh_key_injected=no' "$root_metadata" || fail private-key
grep -Fxq 'owner_credentials_injected=no' "$root_metadata" || fail private-account
grep -Fxq 'vendor_firmware=absent' "$ram_metadata" || fail installer-vendor-files
for input in "$ram_boot" "$system_boot" "$system_recovery"; do [ "$(stat -c %s "$input")" = 67108864 ] || fail boot-size; done
install -d -m 0700 "$output" "$output/m1892-direct-install"
package=$output/m1892-direct-install
install -m 0644 "$script_dir/../installer/Install.ps1" "$script_dir/../installer/Transport.psm1" \
 "$script_dir/../installer/install.cmd" "$script_dir/../installer/README.md" "$script_dir/../installer/README_EN.md" "$package/"
# Immutable build inputs and the unpacked staging directory share one native
# filesystem. Hard-link them instead of duplicating multi-GiB compressed files;
# the final ZIP is a separate sealed delivery artifact with its own checksum.
ln "$ram_boot" "$package/m1892-installer-boot.img"
ln "$ram_root" "$package/m1892-installer-rootfs.ext4.gz"
ln "$system_boot" "$package/m1892-system-boot.img"
ln "$system_recovery" "$package/m1892-system-recovery.img"
ln "$userdata" "$package/m1892-userdata.ext4.gz"
python3 - "$package" "$root_metadata" "$(git -C "$script_dir" rev-parse HEAD)" <<'PY'
import hashlib, json, pathlib, sys
root = pathlib.Path(sys.argv[1]); metadata = {}
for line in pathlib.Path(sys.argv[2]).read_text().splitlines():
    if '=' in line:
        key, value = line.split('=', 1)
        if key in metadata: raise SystemExit('duplicate metadata key')
        metadata[key] = value
def digest(path):
    sha = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024*1024), b''): sha.update(block)
    return sha.hexdigest()
assets = []
for role, name in (
    ('installer-boot','m1892-installer-boot.img'),
    ('installer-rootfs','m1892-installer-rootfs.ext4.gz'),
    ('system-boot','m1892-system-boot.img'),
    ('system-recovery','m1892-system-recovery.img'),
    ('userdata','m1892-userdata.ext4.gz')):
    path = root / name
    assets.append(dict(role=role,file=name,bytes=path.stat().st_size,sha256=digest(path)))
if assets[-1]['sha256'] != metadata['artifact_sha256']: raise SystemExit('userdata metadata hash mismatch')
manifest = dict(schema=1,model='Meizu 16th Plus (M1892)',scope='owner-local-complete',
    source_revision=sys.argv[3],root_image_bytes=int(metadata['persistent_root_image_size']),
    root_image_sha256=metadata['persistent_root_image_sha256'],assets=assets)
(root/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
with (root/'SHA256SUMS').open('w') as sums:
    verified = {entry['file']:entry['sha256'] for entry in assets}
    for path in sorted(root.iterdir()):
        if path.is_file() and path.name != 'SHA256SUMS':
            sha = verified[path.name] if path.name in verified else digest(path)
            sums.write(f'{sha}  {path.name}\n')
PY
# ZIP_STORED for already compressed rootfs; deflate the boot partition's padding.
python3 - "$package" "$output/m1892-debian13-plasma-mobile-local-direct-install.zip" <<'PY'
import pathlib, sys, zipfile
root=pathlib.Path(sys.argv[1])
with zipfile.ZipFile(sys.argv[2], 'x', allowZip64=True) as archive:
    for path in sorted(root.iterdir()):
        compression = zipfile.ZIP_STORED if path.name.endswith('.gz') else zipfile.ZIP_DEFLATED
        archive.write(path,root.name+'/'+path.name,compress_type=compression,compresslevel=6)
PY
(cd "$output" && sha256sum m1892-debian13-plasma-mobile-local-direct-install.zip >m1892-debian13-plasma-mobile-local-direct-install.zip.sha256)
echo "package=$package"
echo M1892_LOCAL_PACKAGE_BUILD_PASS
