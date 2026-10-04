#!/bin/sh
# SPDX-License-Identifier: MIT
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
M1892_DEBIAN_STAGE=3 exec "$script_dir/build-stage2-recovery.sh" "$@"
