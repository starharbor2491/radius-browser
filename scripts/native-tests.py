#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
"""Run native tests with owned-process diagnostics and a finite CI deadline."""
import os
import re
from pathlib import Path
import signal
import subprocess
import sys
import threading
import time

output = Path("dist")
output.mkdir(exist_ok=True)
log_path = output / "native-tests.log"
started = time.monotonic()
process = subprocess.Popen(["swift", "test", *sys.argv[1:]], stdout=subprocess.PIPE,
                           stderr=subprocess.STDOUT, text=True, errors="replace", bufsize=1, start_new_session=True)


def forward():
    with log_path.open("w") as log:
        for line in process.stdout:
            log.write(line)
            log.flush()
            sys.stdout.write(line)
            sys.stdout.flush()


def sample_owned_processes():
    listing = subprocess.check_output(["/bin/ps", "-axo", "pid=,ppid=,comm="], text=True)
    rows = [line.strip().split(None, 2) for line in listing.splitlines()]
    owned = {process.pid}
    for _ in range(16):
        descendants = {int(row[0]) for row in rows if len(row) == 3 and int(row[1]) in owned}
        if descendants.issubset(owned):
            break
        owned.update(descendants)
    (output / "native-tests-processes.txt").write_text("\n".join(
        " ".join(row) for row in rows if len(row) == 3 and int(row[0]) in owned) + "\n")
    targets = [row for row in rows if len(row) == 3 and int(row[0]) in owned
               and (int(row[0]) == process.pid or "PackageTests" in row[2] or "swiftpm-testing" in row[2])]
    for row in targets[:4]:
        try:
            subprocess.run(["/usr/bin/sample", row[0], "3", "-file",
                            str(output / ("native-tests-sample-" + row[0] + ".txt"))],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=8, check=False)
        except (OSError, subprocess.TimeoutExpired):
            pass


reader = threading.Thread(target=forward, daemon=True)
reader.start()
def interrupted(_signum, _frame):
    raise KeyboardInterrupt
signal.signal(signal.SIGTERM, interrupted)
try:
    try:
        status = process.wait(timeout=180)
    except subprocess.TimeoutExpired:
        print("Native tests remain active after three minutes; sampling owned processes.", flush=True)
        sample_owned_processes()
        status = process.wait(timeout=180)
    # SwiftPM can exit while buffered output is still being forwarded. Give the
    # reader the remaining six-minute budget before inspecting its receipt.
    reader.join(timeout=max(0, 360 - (time.monotonic() - started)))
    if reader.is_alive():
        raise subprocess.TimeoutExpired(process.args, 360)
except (subprocess.TimeoutExpired, KeyboardInterrupt) as error:
    if isinstance(error, subprocess.TimeoutExpired):
        print("Native tests exceeded the six-minute deadline.", file=sys.stderr, flush=True)
        sample_owned_processes()
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait(timeout=5)
    status = 1 if isinstance(error, subprocess.TimeoutExpired) else 130
reader.join(timeout=5)
if status == 0 and not re.search(r"Test run with [1-9][0-9]* tests(?: in [0-9]+ suites)? passed", log_path.read_text()):
    print("Native test process exited without a completed Swift Testing suite.", file=sys.stderr, flush=True)
    status = 1
sys.exit(status)
