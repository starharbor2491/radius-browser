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
# Use one SwiftPM compiler path for tests and both architectures. Its multi-arch
# Xcode build path imports different WebKit concurrency annotations on Xcode 16.4.
swift build -c "$configuration" --product Radius --triple arm64-apple-macosx14.0
arm_binary_directory="$(swift build -c "$configuration" --triple arm64-apple-macosx14.0 --show-bin-path)"
swift build -c "$configuration" --product Radius --triple x86_64-apple-macosx14.0
intel_binary_directory="$(swift build -c "$configuration" --triple x86_64-apple-macosx14.0 --show-bin-path)"
app_directory="$PWD/dist/Radius.app"
mkdir -p "$app_directory/Contents/MacOS" "$app_directory/Contents/Resources"
lipo -create "$arm_binary_directory/Radius" "$intel_binary_directory/Radius" -output "$app_directory/Contents/MacOS/Radius"
lipo -verify_arch arm64 x86_64 "$app_directory/Contents/MacOS/Radius"
# Store declarative resources in the standard app resource directory.
rm -rf "$app_directory/Contents/Resources/Modules"
cp -R Sources/RadiusApp/Resources/Modules "$app_directory/Contents/Resources/Modules"
cp Resources/Info.plist "$app_directory/Contents/Info.plist"
swift scripts/build-icon.swift dist/AppIcon.iconset
iconutil -c icns dist/AppIcon.iconset -o "$app_directory/Contents/Resources/AppIcon.icns"
# Ad-hoc signing is for a local build only. It is not Developer ID signing or notarization.
codesign --force --sign - "$app_directory"
codesign --verify --strict "$app_directory"
if otool -L "$app_directory/Contents/MacOS/Radius" | grep -E '/workspace|/tmp/radius' >/dev/null; then
  echo 'The executable has an unexpected development dependency.' >&2
  exit 1
fi
echo "Built $app_directory"
