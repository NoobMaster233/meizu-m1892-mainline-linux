#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Append the exact M1892 B01 entry to the pinned upstream WCN3990 database."""

from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import subprocess
import tempfile
from pathlib import Path


EXPECTED_B01 = "5be6feab025013b4e8a876239af06c7dca717971a3eee7efe7e8c2510157da73"
NAMES = [
    "bus=snoc,qmi-board-id=1,qmi-chip-id=30214,variant=Meizu_m1892",
    "bus=snoc,qmi-board-id=1,qmi-chip-id=30214",
    "bus=snoc,qmi-board-id=1",
]
NAME_SET = set(NAMES)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source-dir", type=Path, required=True)
    parser.add_argument("--encoder", type=Path, required=True)
    parser.add_argument("--upstream-board", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    b01 = args.source_dir / "BDWLAN.B01"
    if b01.stat().st_size != 19152 or sha256(b01) != EXPECTED_B01:
        raise SystemExit("official M1892 B01 does not match the accepted input")

    args.output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="m1892-board2.") as temporary:
        work = Path(temporary)
        subprocess.run(
            [str(args.encoder), "--extract", str(args.upstream_board)],
            cwd=work,
            check=True,
        )
        mapping = work / "board-2.json"
        entries = json.loads(mapping.read_text(encoding="utf-8"))
        if len(entries) != 35:
            raise SystemExit(f"unexpected upstream WCN3990 board count: {len(entries)}")
        existing_names = {name for entry in entries for name in entry["names"]}
        collision = existing_names.intersection(NAME_SET)
        if collision:
            raise SystemExit(f"M1892 lookup collision: {sorted(collision)}")
        # Preserve the accepted most-specific-to-generic lookup order.  The
        # encoder serializes this array order, so alphabetic sorting changes
        # otherwise equivalent board-2 bytes and breaks the pinned hash.
        entries.append({"names": NAMES, "data": str(b01.resolve())})
        mapping.write_text(
            json.dumps(entries, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
        first = work / "board-2-first.bin"
        subprocess.run(
            [str(args.encoder), "--create", str(mapping), "--output", str(first)],
            cwd=work,
            check=True,
        )

        audit = work / "audit"
        audit.mkdir()
        subprocess.run(
            [str(args.encoder), "--extract", str(first)], cwd=audit, check=True
        )
        audit_mapping = audit / "board-2.json"
        rebuilt = json.loads(audit_mapping.read_text(encoding="utf-8"))
        if len(rebuilt) != 36:
            raise SystemExit(f"unexpected candidate board count: {len(rebuilt)}")
        meizu = [entry for entry in rebuilt if set(entry["names"]) == NAME_SET]
        if len(meizu) != 1 or sha256(audit / meizu[0]["data"]) != EXPECTED_B01:
            raise SystemExit("candidate does not contain the exact M1892 B01 lookup")
        second = work / "board-2-second.bin"
        subprocess.run(
            [str(args.encoder), "--create", str(audit_mapping), "--output", str(second)],
            cwd=audit,
            check=True,
        )
        if sha256(first) != sha256(second):
            raise SystemExit("board-2 deterministic rebuild mismatch")
        shutil.copyfile(first, args.output)

    print(
        "M1892_BOARD2_BUILD_PASS "
        f"entries=36 sha256={sha256(args.output)} output={args.output}"
    )


if __name__ == "__main__":
    main()
