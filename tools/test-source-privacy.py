#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Negative tests use synthetic strings, never local owner credentials."""
import hashlib
import pathlib
import subprocess
import tempfile

checker = pathlib.Path(__file__).with_name('verify-source.py')
cases = {
    'plain-source': (b'# harmless source\n', True),
    'private-key': (b'-----BEGIN ' + b'OPENSSH PRIVATE KEY-----\n', False),
    'encrypted-key': (b'-----BEGIN ' + b'ENCRYPTED PRIVATE KEY-----\n', False),
    'public-key': (b'ssh-' + b'ed25519 ' + b'A' * 80, False),
    'ecdsa-key': (b'ecdsa-' + b'sha2-nistp256 ' + b'A' * 80, False),
    'network-password': (b'psk=' + b'synthetic-test-secret\n', False),
    'wep-key': (b'wep-key0=' + b'synthetic-test-secret\n', False),
    'network-name': (b'ssid=' + b'synthetic-network-name\n', False),
    'token': (b'ghp' + b'_' + b'B' * 36, False),
    'owner-address': (bytes([49,57,50,46,49,54,56,46,49,50,46,49,51]), False),
    'binary': (b'ELF\0payload', False),
}
with tempfile.TemporaryDirectory(prefix='m1892-public-source-test-') as work:
    root = pathlib.Path(work)
    for name, (content, expected) in cases.items():
        (root / 'fixture.txt').write_bytes(content)
        (root / 'SOURCE-MANIFEST.sha256').write_text(hashlib.sha256(content).hexdigest() + '  fixture.txt\n')
        result = subprocess.run(['python3', str(checker), str(root)], capture_output=True)
        if (result.returncode == 0) != expected:
            raise SystemExit(f'Privacy test failed: {name}')
    (root / 'fixture.txt').write_text('changed after manifest\n')
    if subprocess.run(['python3', str(checker), str(root)], capture_output=True).returncode == 0:
        raise SystemExit('Manifest tamper accepted')
print(f'SOURCE_PRIVACY_NEGATIVE_TEST_PASS cases={len(cases) + 1}')
