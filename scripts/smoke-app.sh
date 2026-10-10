#!/bin/bash
# SPDX-License-Identifier: MPL-2.0
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p dist
smoke_server_pid=""
smoke_app_pid=""
smoke_watchdog_pid=""
smoke_started_at="$(date +%s)"
smoke_deadline=90
if [[ -n "${RADIUS_CHROMIUM_PACKAGE:-}" ]]; then smoke_deadline=420; fi
cleanup() {
  smoke_status=$?
  trap - EXIT HUP INT TERM
  if [[ -n "$smoke_watchdog_pid" ]]; then
    kill "$smoke_watchdog_pid" 2>/dev/null || true
    wait "$smoke_watchdog_pid" 2>/dev/null || true
  fi
  if [[ -n "$smoke_app_pid" ]]; then
    kill "$smoke_app_pid" 2>/dev/null || true
    sleep 0.2
    kill -KILL "$smoke_app_pid" 2>/dev/null || true
    wait "$smoke_app_pid" 2>/dev/null || true
  fi
  if [[ -n "$smoke_server_pid" ]]; then
    kill "$smoke_server_pid" 2>/dev/null || true
    wait "$smoke_server_pid" 2>/dev/null || true
  fi
  if [[ -f dist/smoke-app.log ]]; then cat dist/smoke-app.log; fi
  if [[ "$smoke_status" -ne 0 ]]; then
    echo "Packaged-app smoke test exited with status $smoke_status." >&2
    cat dist/smoke-server.log >&2
    if [[ -f dist/smoke-sample.log ]]; then cat dist/smoke-sample.log >&2; fi
    if [[ "$smoke_status" -ge 128 ]]; then
      # ReportCrash can finish after the app exits. Collect only this launch's
      # Radius reports, with a short deadline and a bounded artifact size.
      python3 - "$smoke_started_at" <<'PY' || true
import pathlib, shutil, sys, time
started = int(sys.argv[1])
destination = pathlib.Path('dist/smoke-crashes')
locations = [pathlib.Path.home() / 'Library/Logs/DiagnosticReports', pathlib.Path('/Library/Logs/DiagnosticReports')]
copied = set()
for _ in range(10):
    for directory in locations:
        for report in directory.glob('Radius*'):
            try:
                if report.suffix not in {'.ips', '.crash'} or report.is_symlink() or report in copied:
                    continue
                info = report.stat()
                if info.st_mtime < started or info.st_size > 16 * 1024 * 1024 or len(copied) >= 8:
                    continue
                destination.mkdir(exist_ok=True)
                shutil.copyfile(report, destination / report.name)
                copied.add(report)
            except OSError:
                continue
    if copied:
        break
    time.sleep(0.5)
print(f'Collected {len(copied)} current Radius crash reports.')
PY
    fi
  fi
  exit "$smoke_status"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
: >dist/smoke-app.log
rm -f dist/smoke-sample.txt dist/smoke-sample.log dist/smoke-port.txt
python3 -u scripts/smoke-server.py --port-file dist/smoke-port.txt >dist/smoke-server.log 2>&1 &
smoke_server_pid=$!
smoke_server_ready=false
for attempt in {1..120}; do
  if [[ -s dist/smoke-port.txt ]]; then
    smoke_server_ready=true
    break
  fi
  if ! kill -0 "$smoke_server_pid" 2>/dev/null; then break; fi
  sleep 0.5
done
if [[ "$smoke_server_ready" != true ]]; then
  echo 'The HTTP smoke fixture did not start.' >&2
  exit 1
fi
smoke_port="$(cat dist/smoke-port.txt)"
if [[ ! "$smoke_port" =~ ^[0-9]+$ ]]; then
  echo 'The HTTP fixture returned an invalid port.' >&2
  exit 1
fi
smoke_url="http://127.0.0.1:$smoke_port/"
curl --noproxy '*' --connect-timeout 2 --max-time 5 -fsS "$smoke_url" >/dev/null
RADIUS_SMOKE_TEST_DATA="$PWD/dist/smoke-data" \
RADIUS_SMOKE_TEST_OUTPUT="$PWD/dist/screenshots" \
RADIUS_SMOKE_TEST_URL="$smoke_url" \
RADIUS_SMOKE_TEST_EXTENSION_FIXTURE="$PWD/Tests/Fixtures/ChromiumExtension" \
  dist/Radius.app/Contents/MacOS/Radius --smoke-test >dist/smoke-app.log 2>&1 &
smoke_app_pid=$!
(
  timer_pid=""
  sample_pid=""
  stop_watchdog() {
    trap - EXIT HUP INT TERM
    for child_pid in "$timer_pid" "$sample_pid"; do
      if [[ -n "$child_pid" ]]; then
        kill "$child_pid" 2>/dev/null || true
        wait "$child_pid" 2>/dev/null || true
      fi
    done
  }
  trap stop_watchdog EXIT
  trap 'exit 0' HUP INT TERM
  sleep 45 &
  timer_pid=$!
  wait "$timer_pid"
  timer_pid=""
  if kill -0 "$smoke_app_pid" 2>/dev/null; then
    echo "Radius is still running after 45 seconds; sampling process $smoke_app_pid."
    /usr/bin/sample "$smoke_app_pid" 3 -file dist/smoke-sample.txt >dist/smoke-sample.log 2>&1 &
    sample_pid=$!
  fi
  sleep "$((smoke_deadline - 45))" &
  timer_pid=$!
  wait "$timer_pid"
  timer_pid=""
  if kill -0 "$smoke_app_pid" 2>/dev/null; then
    echo "Radius exceeded the $smoke_deadline-second smoke-test deadline; sending TERM." >&2
    kill -TERM "$smoke_app_pid" 2>/dev/null || true
    sleep 5 &
    timer_pid=$!
    wait "$timer_pid"
    timer_pid=""
    kill -KILL "$smoke_app_pid" 2>/dev/null || true
  fi
) &
smoke_watchdog_pid=$!
if wait "$smoke_app_pid"; then smoke_status=0; else smoke_status=$?; fi
smoke_app_pid=""
exit "$smoke_status"
