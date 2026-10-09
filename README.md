# Radius

A native macOS browser with WebKit browsing, local profiles, and a customizable interface. Swift 6, SwiftUI, AppKit, and SQLite; no third-party Swift dependencies.

This is a **v1 development build**, not a signed consumer release. Chromium, Chrome extensions, and automatic application updates are not available yet. See [release status](docs/RELEASE_STATUS.md) and [Chromium integration](docs/CHROMIUM.md).

## Run on a Mac

Requires macOS 14+ and Xcode 16+ or Swift 6 command-line tools.

```sh
./scripts/test.sh
./scripts/build-app.sh
open dist/Radius.app
```

You can also open `Package.swift` in Xcode and run the Radius executable. CI produces a zipped `.app` artifact for local testing. Downloaded development builds are ad-hoc signed, not notarized; they are not ready for ordinary Gatekeeper distribution.

## Included

- Multiple windows, horizontal/vertical tabs, tab pinning and reordering, navigation, search, find, page zoom, and crash reload.
- Profile-separated website storage, bookmarks, history, and notes; private windows with temporary website storage.
- Bookmark HTML import/export and downloads with a native destination picker.
- Five declarative feature packages: Resource Monitor, Notes, Reader, Page Capture, and Focus Mode. Install, disable, uninstall, and inspect their permissions.
- macOS, Material-inspired, Liquid Glass-inspired, and Graphite appearance; light/dark/system modes, accent, density, corners, and transparency.
- Tabs on all four edges, navigation at top/bottom, left/right sidebar, adjustable sidebar width, bookmarks and status bars.
- Preview, undo, named setups, configuration-only setup import/export, and engine-independent recovery.

Data lives in `~/Library/Application Support/org.radius.browser`. Regular browsing metadata is local SQLite. WebKit owns each profile's website data; Radius does not copy cookies between profiles. No telemetry, sync service, password database, arbitrary native plugins, or remote module catalog is included.

The original repository license remains MIT. New Radius implementation files are available under MPL-2.0; see [licensing](docs/LICENSING.md).
