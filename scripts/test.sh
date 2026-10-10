#!/bin/bash
# SPDX-License-Identifier: MPL-2.0
set -euo pipefail
cd "$(dirname "$0")/.."
python3 scripts/test-installed-acceptance.py
if [[ "$(uname -s)" == Darwin ]]; then
  configuration=debug
  previous_argument=""
  for argument in "$@"; do
    if [[ "$previous_argument" == -c || "$previous_argument" == --configuration ]]; then configuration="$argument"; fi
    previous_argument="$argument"
  done
  swift build -c "$configuration" --product RadiusResourceMonitor
  swift build -c "$configuration" --product RadiusMemoryMonitor
  swift build -c "$configuration" --product RadiusReaderWorker
  python3 scripts/native-tests.py "$@"
else
  swift test "$@"
fi
python3 scripts/validate-packages.py
