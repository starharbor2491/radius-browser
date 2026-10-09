#!/bin/bash
# SPDX-License-Identifier: MPL-2.0
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "$(uname -s)" == Darwin ]]; then
  configuration=debug
  previous_argument=""
  for argument in "$@"; do
    if [[ "$previous_argument" == -c || "$previous_argument" == --configuration ]]; then configuration="$argument"; fi
    previous_argument="$argument"
  done
  swift build -c "$configuration" --product RadiusResourceMonitor
  swift build -c "$configuration" --product RadiusMemoryMonitor
fi
swift test "$@"
python3 scripts/validate-packages.py
