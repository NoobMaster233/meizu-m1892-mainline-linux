#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Create or verify an Android sparse image containing RAW chunks only.

Unlike img2simg, this deliberately emits no DONT_CARE chunks.  It is intended
for bootloaders that overlay sparse images without first zeroing the target.
"""

from __future__ import annotations

import os
import struct
import sys
from pathlib import Path


MAGIC = 0xED26FF3A
RAW = 0xCAC1
FILE_HEADER_SIZE = 28
CHUNK_HEADER_SIZE = 12
BLOCK_SIZE = 4096
CHUNK_BYTES = 512 * 1024 * 1024
COPY_BYTES = 16 * 1024 * 1024


def fail(message: str) -> "NoReturn":
    raise SystemExit(f"M1892_FULL_SPARSE_FAIL: {message}")


def read_exact(stream, size: int) -> bytes:
    data = stream.read(size)
    if len(data) != size:
        fail("truncated")
    return data


def verify(path: Path) -> None:
    size = path.stat().st_size
    with path.open("rb") as stream:
        header = read_exact(stream, FILE_HEADER_SIZE)
        magic, major, minor, file_header, chunk_header, block_size, total_blocks, total_chunks, _ = struct.unpack(
            "<IHHHHIIII", header
        )
        if magic != MAGIC or major != 1 or minor != 0:
            fail("header")
        if file_header < FILE_HEADER_SIZE or chunk_header < CHUNK_HEADER_SIZE:
            fail("header-size")
        if block_size != BLOCK_SIZE or total_blocks == 0 or total_chunks == 0:
            fail("geometry")
        stream.seek(file_header)
        logical_blocks = 0
        for _index in range(total_chunks):
            raw_header = read_exact(stream, chunk_header)
            chunk_type, _reserved, chunk_blocks, total_size = struct.unpack(
                "<HHII", raw_header[:CHUNK_HEADER_SIZE]
            )
            if chunk_type != RAW:
                fail("non-raw-chunk")
            payload = chunk_blocks * block_size
            if chunk_blocks == 0 or total_size != chunk_header + payload:
                fail("chunk-geometry")
            stream.seek(payload, os.SEEK_CUR)
            logical_blocks += chunk_blocks
        if logical_blocks != total_blocks:
            fail("logical-size")
        if stream.tell() != size:
            fail("trailing-or-missing-data")
    print(
        f"M1892_FULL_SPARSE_PASS blocks={total_blocks} chunks={total_chunks} bytes={size}"
    )


def generate(source: Path, output: Path) -> None:
    source_size = source.stat().st_size
    if source_size == 0 or source_size % BLOCK_SIZE:
        fail("input-size")
    if output.exists():
        fail("output-exists")
    total_blocks = source_size // BLOCK_SIZE
    if total_blocks > 0xFFFFFFFF:
        fail("too-many-blocks")
    chunk_bytes = CHUNK_BYTES
    total_chunks = (source_size + chunk_bytes - 1) // chunk_bytes
    partial = output.with_name(output.name + ".partial")
    if partial.exists():
        fail("partial-output-exists")
    with source.open("rb") as src, partial.open("xb") as dst:
        dst.write(
            struct.pack(
                "<IHHHHIIII",
                MAGIC,
                1,
                0,
                FILE_HEADER_SIZE,
                CHUNK_HEADER_SIZE,
                BLOCK_SIZE,
                total_blocks,
                total_chunks,
                0,
            )
        )
        remaining = source_size
        while remaining:
            payload_size = min(chunk_bytes, remaining)
            chunk_blocks = payload_size // BLOCK_SIZE
            dst.write(
                struct.pack(
                    "<HHII",
                    RAW,
                    0,
                    chunk_blocks,
                    CHUNK_HEADER_SIZE + payload_size,
                )
            )
            pending = payload_size
            while pending:
                data = read_exact(src, min(COPY_BYTES, pending))
                dst.write(data)
                pending -= len(data)
            remaining -= payload_size
        dst.flush()
        os.fsync(dst.fileno())
    partial.replace(output)
    verify(output)


def verify_against(sparse: Path, raw: Path) -> None:
    """Compare every logical sparse byte with the source raw without a temp file."""
    with sparse.open("rb") as encoded, raw.open("rb") as plain:
        header = read_exact(encoded, FILE_HEADER_SIZE)
        magic, major, minor, file_header, chunk_header, block_size, total_blocks, total_chunks, _ = struct.unpack(
            "<IHHHHIIII", header
        )
        if magic != MAGIC or major != 1 or minor != 0:
            fail("header")
        if file_header < FILE_HEADER_SIZE or chunk_header < CHUNK_HEADER_SIZE:
            fail("header-size")
        if block_size != BLOCK_SIZE or raw.stat().st_size != total_blocks * block_size:
            fail("raw-geometry")
        encoded.seek(file_header)
        logical_blocks = 0
        for _index in range(total_chunks):
            raw_header = read_exact(encoded, chunk_header)
            chunk_type, _reserved, chunk_blocks, total_size = struct.unpack(
                "<HHII", raw_header[:CHUNK_HEADER_SIZE]
            )
            payload = chunk_blocks * block_size
            if chunk_type != RAW or chunk_blocks == 0 or total_size != chunk_header + payload:
                fail("chunk-geometry")
            remaining = payload
            while remaining:
                size = min(COPY_BYTES, remaining)
                if read_exact(encoded, size) != read_exact(plain, size):
                    fail("content-mismatch")
                remaining -= size
            logical_blocks += chunk_blocks
        if logical_blocks != total_blocks or plain.read(1) or encoded.read(1):
            fail("logical-size")
    print(
        f"M1892_FULL_SPARSE_ROUNDTRIP_PASS blocks={total_blocks} chunks={total_chunks}"
    )


def main() -> None:
    if len(sys.argv) == 4 and sys.argv[1] == "--verify-against":
        verify_against(Path(sys.argv[2]), Path(sys.argv[3]))
        return
    if len(sys.argv) == 3 and sys.argv[1] == "--verify":
        verify(Path(sys.argv[2]))
        return
    if len(sys.argv) == 3:
        generate(Path(sys.argv[1]), Path(sys.argv[2]))
        return
    fail("usage: img2fullsimg.py [--verify] INPUT [OUTPUT] | --verify-against SPARSE RAW")


if __name__ == "__main__":
    main()
