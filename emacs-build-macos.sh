#!/bin/bash
# SPDX-FileCopyrightText: 2026 Chen Zhexuan
# SPDX-License-Identifier: MIT
set -euo pipefail
root="$(cd -- "$(dirname -- "$0")" && pwd -P)"
exec python3 "$root/scripts/macos/build.py" "$@"
