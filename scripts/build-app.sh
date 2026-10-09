#!/bin/bash
# SPDX-License-Identifier: MPL-2.0
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "$(uname -s)" != Darwin ]]; then
  echo 'Building Radius.app requires macOS 14+ and Xcode 16+ (or Swift 6 command-line tools).' >&2
  exit 1
fi
configuration="${CONFIGURATION:-release}"
if [[ "$configuration" != release && "$configuration" != debug ]]; then
  echo 'CONFIGURATION must be release or debug.' >&2
  exit 1
fi
# Build each architecture with the same SwiftPM driver used by the integration tests.
swift build -c "$configuration" --product Radius --triple arm64-apple-macosx14.0
swift build -c "$configuration" --product RadiusResourceMonitor --triple arm64-apple-macosx14.0
swift build -c "$configuration" --product RadiusMemoryMonitor --triple arm64-apple-macosx14.0
swift build -c "$configuration" --product RadiusReaderWorker --triple arm64-apple-macosx14.0
arm_binary_directory="$(swift build -c "$configuration" --triple arm64-apple-macosx14.0 --show-bin-path)"
swift build -c "$configuration" --product Radius --triple x86_64-apple-macosx14.0
swift build -c "$configuration" --product RadiusResourceMonitor --triple x86_64-apple-macosx14.0
swift build -c "$configuration" --product RadiusMemoryMonitor --triple x86_64-apple-macosx14.0
swift build -c "$configuration" --product RadiusReaderWorker --triple x86_64-apple-macosx14.0
intel_binary_directory="$(swift build -c "$configuration" --triple x86_64-apple-macosx14.0 --show-bin-path)"
app_directory="$PWD/dist/Radius.app"
mkdir -p "$app_directory/Contents/MacOS" "$app_directory/Contents/Resources/Legal"
lipo -create "$arm_binary_directory/Radius" "$intel_binary_directory/Radius" -output "$app_directory/Contents/MacOS/Radius"
lipo "$app_directory/Contents/MacOS/Radius" -verify_arch arm64 x86_64
# Store descriptor resources and real native worker payloads in their package directories.
rm -rf "$app_directory/Contents/Resources/Modules"
cp -R Sources/RadiusApp/Resources/Modules "$app_directory/Contents/Resources/Modules"
for worker in RadiusResourceMonitor RadiusMemoryMonitor RadiusReaderWorker; do
  case "$worker" in
    RadiusResourceMonitor) module_id=org.radius.resource-monitor ;;
    RadiusMemoryMonitor) module_id=org.radius.memory-monitor ;;
    RadiusReaderWorker) module_id=org.radius.reader ;;
  esac
  payload="$app_directory/Contents/Resources/Modules/$module_id/worker"
  lipo -create "$arm_binary_directory/$worker" "$intel_binary_directory/$worker" -output "$payload"
  lipo "$payload" -verify_arch arm64 x86_64
  chmod 755 "$payload"
  codesign --force --sign - "$payload"
  codesign --verify --strict "$payload"
done
cp Resources/Info.plist "$app_directory/Contents/Info.plist"
cp LICENSE COPYING.MPL docs/LICENSING.md "$app_directory/Contents/Resources/Legal/"
swift scripts/build-icon.swift dist/AppIcon.iconset
iconutil -c icns dist/AppIcon.iconset -o "$app_directory/Contents/Resources/AppIcon.icns"
# CEF's helper sandbox reads code inside the actual application bundle. Runtime
# packages in App Support cannot be loaded by sandboxed renderers. Embed the
# optional development runtime before sealing this app; base builds remove it.
rm -rf "$app_directory/Contents/Frameworks/Chromium.radiusengine"
if [[ -n "${RADIUS_CHROMIUM_PACKAGE:-}" ]]; then
  python3 scripts/chromium-runtime.py --embed-package "$RADIUS_CHROMIUM_PACKAGE" --app "$app_directory"
fi
# Ad-hoc signing is for a local build only. It is not Developer ID signing or notarization.
codesign --force --sign - "$app_directory"
codesign --verify --strict "$app_directory"
if otool -L "$app_directory/Contents/MacOS/Radius" | grep -E '/workspace|/tmp/radius' >/dev/null; then
  echo 'The executable has an unexpected development dependency.' >&2
  exit 1
fi
echo "Built $app_directory"
