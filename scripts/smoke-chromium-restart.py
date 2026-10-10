#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
"""Second native launch after the successful isolated Web Store install probe."""
import os
from pathlib import Path
import subprocess
import sys

root = Path(__file__).resolve().parent.parent
data = root / "dist/smoke-data"
receipt = data / "Chromium/ExtensionAcceptance/webstore-restart.json"
if not receipt.is_file():
    sys.exit("The first native smoke launch did not record a successful Web Store install.")
environment = os.environ.copy()
environment.update({
    "RADIUS_SMOKE_TEST_DATA": str(data),
    "RADIUS_SMOKE_TEST_OUTPUT": str(root / "dist/screenshots"),
    "RADIUS_CHROMIUM_EXTENSION_RESTART": "1",
})
log = root / "dist/smoke-chromium-restart.log"
try:
    with log.open("w") as output:
        result = subprocess.run([str(root / "dist/Radius.app/Contents/MacOS/Radius"), "--smoke-test"],
                                cwd=root, env=environment, stdout=output, stderr=subprocess.STDOUT,
                                timeout=90, check=False)
    status = result.returncode
except subprocess.TimeoutExpired:
    status = 1
    print("The second Chromium launch exceeded its 90-second deadline.", file=sys.stderr)
finally:
    if log.exists():
        print(log.read_text())
sys.exit(status)
