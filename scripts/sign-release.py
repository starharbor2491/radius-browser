#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
"""Developer ID sign all nested native code before sealing Radius.app.

No library-validation or Gatekeeper exception is granted. All native code must
be signed by the configured publisher. Chromium helpers permit hardened JIT;
consumer acceptance must verify this configuration on a notarized clean Mac.
"""
import os
from pathlib import Path
import platform
import subprocess
import sys

if platform.system() != 'Darwin':
    raise SystemExit('Developer ID signing requires macOS')
identity = os.environ.get('RADIUS_SIGNING_IDENTITY')
if not identity or not identity.startswith('Developer ID Application: '):
    raise SystemExit('RADIUS_SIGNING_IDENTITY must name a Developer ID Application identity')
app = Path(sys.argv[1]).resolve(strict=True)
root = Path(__file__).resolve().parent.parent
mach_magic = {bytes.fromhex(x) for x in ('feedface', 'cefaedfe', 'feedfacf', 'cffaedfe', 'cafebabe', 'bebafeca', 'cafebabf', 'bfbafeca')}

def sign(path, *, identifier=None, entitlements=None):
    command = ['codesign', '--force', '--options', 'runtime', '--timestamp', '--sign', identity]
    if identifier:
        command += ['--identifier', identifier]
    if entitlements:
        command += ['--entitlements', str(root / ('Resources/Entitlements/' + entitlements + '.plist'))]
    subprocess.run(command + [str(path)], check=True)

# Mach-O leaves may be buried in CEF.framework/Libraries and module packages.
for path in sorted(app.rglob('*'), key=lambda x: len(x.parts), reverse=True):
    if not path.is_file() or path.is_symlink():
        continue
    with path.open('rb') as handle:
        magic = handle.read(4)
    if magic not in mach_magic:
        continue
    if path.name == 'RadiusUpdater':
        sign(path, identifier='org.radius.updater')
    elif path.name == 'Radius':
        # The browser process can run V8 for Chrome UI/extension management.
        sign(path, identifier='org.radius.browser', entitlements='ChromiumBrowser' if (app / 'Contents/Frameworks/Chromium.radiusengine').exists() else 'Browser')
    else:
        sign(path, entitlements=('ChromiumBrowser' if 'RadiusChromium Helper.app' in str(path) else 'Chromium') if 'RadiusChromium Helper' in str(path) else None)
# Sign nested code containers after their executables/libraries.
for path in sorted(app.rglob('*'), key=lambda x: len(x.parts), reverse=True):
    if path.is_symlink() or not path.is_dir():
        continue
    if path.suffix in ('.app', '.framework', '.radiusengine'):
        sign(path, entitlements=('ChromiumBrowser' if path.name == 'RadiusChromium Helper.app' else 'Chromium') if path.name.startswith('RadiusChromium Helper') else None)
sign(app, identifier='org.radius.browser', entitlements='ChromiumBrowser' if (app / 'Contents/Frameworks/Chromium.radiusengine').exists() else 'Browser')
subprocess.run(['codesign', '--verify', '--deep', '--strict', '--all-architectures', str(app)], check=True)
subprocess.run(['codesign', '--display', '--verbose=4', str(app)], check=True)
