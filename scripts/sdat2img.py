#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Reconstruct an Android block image from a new.dat transfer list.

Only the non-incremental operations used by the official M1892 Flyme package
are accepted.  Incremental patch/move commands fail closed.
"""

from __future__ import annotations

import argparse
import os
from pathlib import Path


BLOCK = 4096


def ranges(spec: str) -> list[tuple[int, int]]:
    values = [int(value) for value in spec.split(",")]
    if not values or values[0] != len(values) - 1 or values[0] % 2:
        raise ValueError(f"invalid range set: {spec}")
    result = list(zip(values[1::2], values[2::2]))
    if any(start < 0 or end <= start for start, end in result):
        raise ValueError(f"invalid range: {spec}")
    return result


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("transfer_list", type=Path)
    parser.add_argument("new_dat", type=Path)
    parser.add_argument("output_image", type=Path)
    args = parser.parse_args()

    lines = args.transfer_list.read_text(encoding="ascii").splitlines()
    if len(lines) < 4:
        raise SystemExit("truncated transfer list")
    version = int(lines[0])
    total_blocks = int(lines[1])
    if version not in (2, 3, 4) or total_blocks <= 0:
        raise SystemExit("unsupported transfer-list header")

    args.output_image.parent.mkdir(parents=True, exist_ok=True)
    consumed = 0
    with args.new_dat.open("rb") as source, args.output_image.open("w+b") as out:
        out.truncate(total_blocks * BLOCK)
        for line_number, line in enumerate(lines[4:], 5):
            if not line:
                continue
            operation, _, spec = line.partition(" ")
            if operation in {"erase", "zero"}:
                # A newly truncated sparse file already reads as zero.  Parse
                # and validate the range set without allocating those blocks.
                ranges(spec)
                continue
            if operation != "new":
                raise SystemExit(
                    f"incremental operation is forbidden at line {line_number}: {operation}"
                )
            for start, end in ranges(spec):
                length = (end - start) * BLOCK
                data = source.read(length)
                if len(data) != length:
                    raise SystemExit("new.dat ended before the transfer list")
                out.seek(start * BLOCK)
                out.write(data)
                consumed += length
        if source.read(1):
            raise SystemExit("new.dat has trailing data")
        out.flush()
        os.fsync(out.fileno())

    if consumed != args.new_dat.stat().st_size:
        raise SystemExit("new.dat byte count does not match transfer list")
    print(
        f"M1892_SDAT2IMG_PASS blocks={total_blocks} new_bytes={consumed} "
        f"output={args.output_image}"
    )


if __name__ == "__main__":
    main()
