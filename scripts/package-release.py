#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
"""Create a graphical offline installer; production mode signs/notarizes/staples.

The disk image contains the same Radius.app with its selected engine and default
module payloads. Development mode is explicit and never emits a consumer catalog.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import tempfile


def digest(path):
    hasher = hashlib.sha256()
    with path.open('rb') as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b''):
            hasher.update(block)
    return hasher.hexdigest()


def checked(command):
    subprocess.run([str(x) for x in command], check=True)


def notarize(path):
    command = ['xcrun', 'notarytool', 'submit', path, '--wait', '--timeout', '30m']
    profile = os.environ.get('RADIUS_NOTARY_PROFILE')
    if profile:
        command += ['--keychain-profile', profile]
    else:
        names = ['RADIUS_NOTARY_KEY', 'RADIUS_NOTARY_KEY_ID', 'RADIUS_NOTARY_ISSUER']
        if not all(os.environ.get(name) for name in names):
            raise RuntimeError('Notarization credentials are required for consumer packaging')
        command += ['--key', os.environ[names[0]], '--key-id', os.environ[names[1]], '--issuer', os.environ[names[2]]]
    checked(command)
    checked(['xcrun', 'stapler', 'staple', path])
    checked(['xcrun', 'stapler', 'validate', path])


def package(app, output, development):
    if platform.system() != 'Darwin':
        raise RuntimeError('Disk image packaging requires macOS')
    app = app.resolve(strict=True)
    output.mkdir(parents=True, exist_ok=True)
    metadata = json.loads((app / 'Contents/Resources/Distribution.json').read_text())
    variant = ('Chromium-' + metadata['architecture']) if metadata['chromium'] else 'WebKit-universal'
    prefix = 'Radius-' + metadata['version'] + '-' + variant
    identity = os.environ.get('RADIUS_SIGNING_IDENTITY')
    if not development:
        if not identity or not identity.startswith('Developer ID Application: '):
            raise RuntimeError('Consumer packaging requires Developer ID Application signing')
        checked(['codesign', '--verify', '--deep', '--strict', '--all-architectures', app])
        with tempfile.TemporaryDirectory(prefix='radius-notary-') as temporary:
            archive = Path(temporary) / 'Radius.zip'
            checked(['ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', app, archive])
            # notarytool accepts the archive; staple the submitted application.
            command = ['xcrun', 'notarytool', 'submit', archive, '--wait', '--timeout', '30m']
            profile = os.environ.get('RADIUS_NOTARY_PROFILE')
            if profile:
                command += ['--keychain-profile', profile]
            else:
                names = ['RADIUS_NOTARY_KEY', 'RADIUS_NOTARY_KEY_ID', 'RADIUS_NOTARY_ISSUER']
                if not all(os.environ.get(name) for name in names):
                    raise RuntimeError('Notarization credentials are required')
                command += ['--key', os.environ[names[0]], '--key-id', os.environ[names[1]], '--issuer', os.environ[names[2]]]
            checked(command)
        checked(['xcrun', 'stapler', 'staple', app])
        checked(['xcrun', 'stapler', 'validate', app])
        checked(['spctl', '--assess', '--type', 'execute', app])
    dmg = output / (prefix + ('-development' if development else '') + '.dmg')
    if dmg.exists():
        dmg.unlink()
    with tempfile.TemporaryDirectory(prefix='radius-installer-') as temporary:
        root = Path(temporary)
        checked(['ditto', app, root / 'Radius.app'])
        (root / 'Applications').symlink_to('/Applications', target_is_directory=True)
        (root / 'Install Radius.txt').write_text(
            'Drag Radius to Applications, then open it.\n\n'
            'This is the same Radius application with ' + ('Chromium and WebKit' if metadata['chromium'] else 'system WebKit') + '. '
            'Its default modules are included for offline installation. Existing browser data, customized layouts and intentionally removed modules are kept.\n\n'
            + ('Development build: ad-hoc signed and unnotarized. Consumer installation and updates are disabled.\n' if development else
               'To install this package from an existing Radius app, choose Settings > Browsing engines > Import offline installer. Radius verifies the publisher and replaces the app after quitting.\n')
            + 'Source and licenses: https://github.com/starharbor2491/radius-browser\n')
        checked(['hdiutil', 'create', '-volname', 'Radius', '-srcfolder', root, '-format', 'UDZO', '-ov', dmg])
    if not development:
        checked(['codesign', '--force', '--timestamp', '--sign', identity, dmg])
        notarize(dmg)
        checked(['spctl', '--assess', '--type', 'open', '--context', 'context:primary-signature', dmg])
    evidence = {'release': metadata, 'developerID': not development, 'notarized': not development,
                'file': dmg.name, 'bytes': dmg.stat().st_size,
                'sha256': digest(dmg)}
    (output / (prefix + '-package.json')).write_text(json.dumps(evidence, indent=2) + '\n')
    if not development:
        tag = os.environ.get('RADIUS_RELEASE_TAG', 'v' + metadata['version'])
        if '/' in tag or '..' in tag or not tag:
            raise ValueError('Invalid release tag')
        asset = {'release': metadata, 'url': 'https://github.com/starharbor2491/radius-browser/releases/download/' + tag + '/' + dmg.name,
                 'sha256': evidence['sha256'], 'bytes': evidence['bytes']}
        (output / (prefix + '-catalog-entry.json')).write_text(json.dumps(asset, indent=2) + '\n')
    print(dmg)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, default=Path('dist/Radius.app'))
    parser.add_argument('--output', type=Path, default=Path('dist'))
    parser.add_argument('--development', action='store_true')
    args = parser.parse_args()
    package(args.app, args.output, args.development)
