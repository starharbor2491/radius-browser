#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
"""Seal release compatibility and monotonic security metadata before signing."""
import json
import os
from pathlib import Path
import platform
import plistlib
import re
import subprocess
import sys


def version_tuple(text):
    if not re.fullmatch(r'\d+\.\d+(?:\.\d+)?', text):
        raise ValueError('Invalid minimum macOS version')
    parts = tuple(map(int, text.split('.')))
    return parts + (0,) * (3 - len(parts))


def runtime_minimum(runtime, baseline):
    """Use actual packaged load commands, including nested framework libraries."""
    minimum = baseline
    highest_file = None
    magic = {bytes.fromhex(value) for value in ('feedface', 'cefaedfe', 'feedfacf', 'cffaedfe', 'cafebabe', 'bebafeca', 'cafebabf', 'bfbafeca')}
    native_count = 0
    for path in runtime.rglob('*'):
        if path.is_symlink() or not path.is_file():
            continue
        with path.open('rb') as handle:
            if handle.read(4) not in magic:
                continue
        native_count += 1
        commands = subprocess.check_output(['/usr/bin/otool', '-l', str(path)], text=True)
        versions = []
        for block in re.split(r'Load command \d+', commands):
            if re.search(r'\bcmd LC_BUILD_VERSION\b', block):
                match = re.search(r'\bminos (\d+\.\d+(?:\.\d+)?)\b', block)
            elif re.search(r'\bcmd LC_VERSION_MIN_MACOSX\b', block):
                match = re.search(r'\bversion (\d+\.\d+(?:\.\d+)?)\b', block)
            else:
                continue
            if match:
                versions.append(version_tuple(match.group(1)))
        if not versions:
            raise ValueError('No macOS deployment requirement in native runtime: ' + str(path))
        required = max(versions)
        if required > minimum:
            minimum, highest_file = required, path.relative_to(runtime)
    if native_count == 0:
        raise ValueError('The Chromium runtime contains no native Mach-O code')
    print('Chromium Mach-O deployment minimum:', '.'.join(map(str, minimum)),
          '(' + str(native_count) + ' native files; ' + (str(highest_file) if highest_file else 'native host minimum') + ')')
    return minimum

app = Path(sys.argv[1])
info_path = app / 'Contents/Info.plist'
info = plistlib.loads(info_path.read_bytes())
build = int(os.environ.get('RADIUS_BUILD_NUMBER', info['CFBundleVersion']))
version = os.environ.get('RADIUS_VERSION', info['CFBundleShortVersionString'])
epoch = int(os.environ.get('RADIUS_SECURITY_EPOCH', '154'))
if not 1 <= build <= 2**63 - 1 or not 154 <= epoch <= 2**63 - 1 or len(version) > 64 or not re.fullmatch(r'\d+\.\d+\.\d+(?:[-+][A-Za-z0-9.-]+)?', version):
    raise ValueError('Invalid release version, build number, or security epoch')
manifest_path = app / 'Contents/Frameworks/Chromium.radiusengine/Contents/Resources/manifest.json'
architecture = 'universal'
chromium = manifest_path.exists()
minimum = version_tuple(info['LSMinimumSystemVersion'])
if chromium:
    manifest = json.loads(manifest_path.read_text())
    architecture = manifest['architecture']
    if architecture not in ('arm64', 'x86_64') or epoch < int(manifest['cefVersion'].split('.')[0]):
        raise ValueError('Invalid runtime architecture or security epoch')
    if platform.system() == 'Darwin':
        minimum = runtime_minimum(app / 'Contents/Frameworks/Chromium.radiusengine', minimum)
minimum_text = '.'.join(map(str, minimum if minimum[2] else minimum[:2]))
info['CFBundleVersion'] = str(build)
info['CFBundleShortVersionString'] = version
info['LSMinimumSystemVersion'] = minimum_text
info_path.write_bytes(plistlib.dumps(info, sort_keys=False))
(app / 'Contents/Resources/Distribution.json').write_text(json.dumps({
    'format': 1, 'build': build, 'version': version, 'securityEpoch': epoch,
    'architecture': architecture, 'chromium': chromium, 'minimumMacOS': minimum_text
}, indent=2) + '\n')
