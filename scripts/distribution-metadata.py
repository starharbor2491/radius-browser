#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
"""Seal release compatibility and monotonic security metadata before signing."""
import json
import os
from pathlib import Path
import plistlib
import re
import sys

app = Path(sys.argv[1])
info_path = app / 'Contents/Info.plist'
info = plistlib.loads(info_path.read_bytes())
build = int(os.environ.get('RADIUS_BUILD_NUMBER', info['CFBundleVersion']))
version = os.environ.get('RADIUS_VERSION', info['CFBundleShortVersionString'])
epoch = int(os.environ.get('RADIUS_SECURITY_EPOCH', '154'))
if build < 1 or epoch < 154 or not re.fullmatch(r'\d+\.\d+\.\d+(?:[-+][A-Za-z0-9.-]+)?', version):
    raise ValueError('Invalid release version, build number, or security epoch')
manifest_path = app / 'Contents/Frameworks/Chromium.radiusengine/Contents/Resources/manifest.json'
architecture = 'universal'
chromium = manifest_path.exists()
if chromium:
    manifest = json.loads(manifest_path.read_text())
    architecture = manifest['architecture']
    if architecture not in ('arm64', 'x86_64') or epoch < int(manifest['cefVersion'].split('.')[0]):
        raise ValueError('Invalid runtime architecture or security epoch')
info['CFBundleVersion'] = str(build)
info['CFBundleShortVersionString'] = version
info_path.write_bytes(plistlib.dumps(info, sort_keys=False))
(app / 'Contents/Resources/Distribution.json').write_text(json.dumps({
    'format': 1, 'build': build, 'version': version, 'securityEpoch': epoch,
    'architecture': architecture, 'chromium': chromium
}, indent=2) + '\n')
