#!/bin/sh
# SPDX-License-Identifier: MIT
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
python3 "$root/tools/verify-source.py" "$root"
python3 "$root/tools/test-source-privacy.py"
python3 - "$root" <<'PY'
import pathlib, re, subprocess, sys
root = pathlib.Path(sys.argv[1])
count = 0
for path in sorted((root / 'src/debian').rglob('*')):
    if not path.is_file():
        continue
    first = path.read_bytes().split(b'\n', 1)[0]
    if first in (b'#!/bin/sh', b'#!/bin/bash', b'#!/usr/bin/env bash'):
        subprocess.run(['bash' if b'bash' in first else 'sh', '-n', str(path)], check=True)
        count += 1
for path in root.glob('*.md'):
    for target in re.findall(r'\]\(([^)]+)\)', path.read_text()):
        if '://' in target or target.startswith('#'):
            continue
        if not (path.parent / target.split('#', 1)[0]).exists():
            raise SystemExit(f'Broken documentation link: {path.name}: {target}')
print(f'SHELL_SYNTAX_AND_DOC_LINKS_PASS scripts={count}')
PY
scripts=$root/src/debian/scripts
sh "$scripts/test-commission-stage7-geometry.sh"
bash "$scripts/test-oem-account-state-machine.sh"
sh "$scripts/test-initialstart-policy.sh"
for name in stage6-oem-image.env stage6-oem-development-image.env; do
    (
        M1892_DEBIAN_CONFIG_DIR=$root/src/debian/config
        export M1892_DEBIAN_CONFIG_DIR
        . "$M1892_DEBIAN_CONFIG_DIR/$name"
        test "$M1892_ACCOUNT_MODE" = oem-owner
        test "$M1892_STAGE3_SUSPEND_POLICY" = masked
    )
done
echo SOURCE_CONTRACT_PASS
