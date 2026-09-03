#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Read selected 8.3 files from a FAT16 image without mounting it."""

from __future__ import annotations

import argparse
import os
import struct
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class Entry:
    name: str
    attributes: int
    cluster: int
    size: int

    @property
    def directory(self) -> bool:
        return bool(self.attributes & 0x10)


class Fat16:
    def __init__(self, image: Path) -> None:
        self.stream = image.open("rb")
        boot = self._read(0, 4096)
        self.bps = struct.unpack_from("<H", boot, 11)[0]
        self.spc = boot[13]
        self.reserved = struct.unpack_from("<H", boot, 14)[0]
        self.fats = boot[16]
        self.root_entries = struct.unpack_from("<H", boot, 17)[0]
        total16 = struct.unpack_from("<H", boot, 19)[0]
        self.spf = struct.unpack_from("<H", boot, 22)[0]
        total32 = struct.unpack_from("<I", boot, 32)[0]
        self.total = total16 or total32
        if (
            self.bps not in (512, 1024, 2048, 4096)
            or self.spc <= 0
            or self.spc & (self.spc - 1)
            or not all((self.reserved, self.fats, self.root_entries, self.spf, self.total))
        ):
            raise ValueError("invalid FAT16 BPB")
        self.root_sectors = (self.root_entries * 32 + self.bps - 1) // self.bps
        self.root_first = self.reserved + self.fats * self.spf
        self.data_first = self.root_first + self.root_sectors
        clusters = (self.total - self.data_first) // self.spc
        if not 4085 <= clusters < 65525:
            raise ValueError("image is not FAT16")

    def close(self) -> None:
        self.stream.close()

    def _read(self, offset: int, length: int) -> bytes:
        self.stream.seek(offset)
        data = self.stream.read(length)
        if len(data) != length:
            raise ValueError("truncated FAT16 image")
        return data

    def _cluster_offset(self, cluster: int) -> int:
        if cluster < 2:
            raise ValueError("invalid FAT16 cluster")
        sector = self.data_first + (cluster - 2) * self.spc
        return sector * self.bps

    def _next(self, cluster: int) -> int:
        raw = self._read(self.reserved * self.bps + cluster * 2, 2)
        return struct.unpack("<H", raw)[0]

    def _chain(self, first: int):
        cluster = first
        seen: set[int] = set()
        while cluster < 0xFFF8:
            if cluster < 2 or cluster in seen:
                raise ValueError("invalid FAT16 cluster chain")
            seen.add(cluster)
            yield cluster
            cluster = self._next(cluster)

    @staticmethod
    def _short_name(raw: bytes) -> str:
        base = raw[:8].decode("ascii", "replace").rstrip()
        ext = raw[8:11].decode("ascii", "replace").rstrip()
        return f"{base}.{ext}" if ext else base

    def _entries(self, directory: Entry | None) -> list[Entry]:
        if directory is None:
            raw = self._read(self.root_first * self.bps, self.root_sectors * self.bps)
        else:
            if not directory.directory:
                raise ValueError("path component is not a directory")
            raw = b"".join(
                self._read(self._cluster_offset(cluster), self.spc * self.bps)
                for cluster in self._chain(directory.cluster)
            )
        entries = []
        for offset in range(0, len(raw), 32):
            item = raw[offset : offset + 32]
            if len(item) < 32 or item[0] == 0:
                break
            if item[0] == 0xE5 or item[11] == 0x0F or item[11] & 0x08:
                continue
            entries.append(
                Entry(
                    self._short_name(item[:11]),
                    item[11],
                    struct.unpack_from("<H", item, 26)[0],
                    struct.unpack_from("<I", item, 28)[0],
                )
            )
        return entries

    def lookup(self, path: str) -> Entry:
        current: Entry | None = None
        for component in [part for part in path.strip("/").split("/") if part]:
            matches = [
                item
                for item in self._entries(current)
                if item.name.casefold() == component.casefold()
            ]
            if len(matches) != 1:
                raise FileNotFoundError(path)
            current = matches[0]
        if current is None:
            raise IsADirectoryError(path)
        return current

    def extract(self, source: str, target: Path) -> None:
        entry = self.lookup(source)
        if entry.directory:
            raise IsADirectoryError(source)
        remaining = entry.size
        target.parent.mkdir(parents=True, exist_ok=True)
        with target.open("xb") as out:
            for cluster in self._chain(entry.cluster):
                amount = min(remaining, self.spc * self.bps)
                out.write(self._read(self._cluster_offset(cluster), amount))
                remaining -= amount
                if not remaining:
                    break
            if remaining:
                raise ValueError(f"truncated cluster chain: {source}")
            out.flush()
            os.fsync(out.fileno())


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("image", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument(
        "members", nargs="+", help="SOURCE or SOURCE=relative/output/path"
    )
    args = parser.parse_args()
    fs = Fat16(args.image)
    try:
        for specification in args.members:
            source, separator, destination = specification.partition("=")
            relative = destination if separator else Path(source).name.lower()
            target = args.output / relative
            fs.extract(source, target)
            print(f"extracted {source} -> {target}")
    finally:
        fs.close()
    print(f"M1892_FAT16_EXTRACT_PASS files={len(args.members)}")


if __name__ == "__main__":
    main()
