#!/bin/bash
# SPDX-License-Identifier: MPL-2.0
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p dist
python3 scripts/smoke-server.py >dist/smoke-server.log 2>&1 &
smoke_server_pid=$!
trap 'kill "$smoke_server_pid" 2>/dev/null || true' EXIT
for attempt in {1..20}; do
  if curl -fsS http://127.0.0.1:8765/ >/dev/null; then break; fi
  sleep 0.1
done
RADIUS_SMOKE_TEST_DATA="$PWD/dist/smoke-data" \
RADIUS_SMOKE_TEST_OUTPUT="$PWD/dist/screenshots" \
RADIUS_SMOKE_TEST_URL=http://127.0.0.1:8765/ \
  dist/Radius.app/Contents/MacOS/Radius --smoke-test
