#!/usr/bin/env python3
"""Deterministically concatenate an arm64 Image.gz and one DTB."""

import argparse
import hashlib
from pathlib import Path


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--image", type=Path, required=True)
    parser.add_argument("--dtb", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    image = args.image.read_bytes()
    dtb = args.dtb.read_bytes()
    if not image.startswith(b"\x1f\x8b"):
        raise SystemExit("input Image.gz does not start with gzip magic")
    if not dtb.startswith(b"\xd0\x0d\xfe\xed"):
        raise SystemExit("input DTB does not start with FDT magic")

    combined = image + dtb
    args.output.write_bytes(combined)
    if args.output.read_bytes() != combined:
        raise SystemExit("output verification failed")

    print(f"Image.gz bytes: {len(image)}")
    print(f"DTB bytes: {len(dtb)}")
    print(f"Image.gz-dtb bytes: {len(combined)}")
    print(f"Image.gz-dtb SHA-256: {hashlib.sha256(combined).hexdigest()}")


if __name__ == "__main__":
    main()
