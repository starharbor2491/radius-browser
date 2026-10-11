# Radius

A native macOS browser with WebKit and optional Chrome-style Chromium, local profiles, private windows, visual customization, split panes, and 18 module packages. Swift 6, SwiftUI, AppKit, and SQLite; no third-party Swift dependencies.

Radius v1 includes Chrome extension management, a graphical module center, layout/theme editing, profile removal, and verified app installation/update/offline-DMG flows. See [release status](docs/RELEASE_STATUS.md), [acceptance evidence](docs/AUDIT.md), and [distribution](docs/DISTRIBUTION.md).

## Install on a Mac

Requires macOS 14 or later. Download a DMG from the [Radius 1.0.0 release](https://github.com/starharbor2491/radius-browser/releases/tag/v1.0.0), open it, drag Radius to Applications, eject the disk image, and open Radius.

| Mac | Download |
| --- | --- |
| Apple Silicon (M-series), Chromium + WebKit | [Complete installer](https://github.com/starharbor2491/radius-browser/releases/download/v1.0.0/Radius-1.0.0-Chromium-arm64-development.dmg) |
| Intel, Chromium + WebKit | [Complete installer](https://github.com/starharbor2491/radius-browser/releases/download/v1.0.0/Radius-1.0.0-Chromium-x86_64-development.dmg) |
| Either CPU, WebKit only | [Smaller installer](https://github.com/starharbor2491/radius-browser/releases/download/v1.0.0/Radius-1.0.0-WebKit-universal-development.dmg) |

The complete installers bundle Chromium's framework, sandbox helpers, resources, and all 18 modules. WebKit uses the framework supplied by macOS. No package manager, developer tools, or additional engine download is required. The release includes checksums and installation receipts; see [AUDIT.md](docs/AUDIT.md).

Choose **WebKit universal** for either Apple Silicon or Intel, **Chromium arm64** for Apple Silicon, or **Chromium x86_64** for Intel. Chromium installers also contain WebKit; change the default in **Settings → Browsing engines** or reopen the active page with another engine. Website sign-ins and unsaved forms remain separate.

Developer ID and notarization credentials are not configured, so these development installers are ad-hoc signed and unnotarized. If macOS blocks the app, review its source and the installer checksum, then use **System Settings → Privacy & Security → Open Anyway** and confirm **Open**. The trusted in-app updater requires a publisher-signed release. [Distribution instructions](docs/DISTRIBUTION.md) describe installation and the production signing pipeline.

## Build from source

Requires Xcode 16+ or Swift 6 command-line tools.

```sh
./scripts/test.sh
./scripts/build-app.sh
open dist/Radius.app
```

You can also open `Package.swift` in Xcode and run the Radius executable. [Chromium build instructions and constraints](docs/CHROMIUM.md) describe the optional runtime.

## Included

- Multiple windows; tabs on all four edges; pinning, reordering, duplication, reopening, and expandable tab trees.
- Resizable side-by-side or stacked browsing panes with independent pages and shared controls for the active pane.
- Navigation, search, find, page zoom, popup controls, JavaScript dialogs, and web-process crash recovery.
- Profile-separated website storage, bookmarks, history, and notes; private windows with temporary website storage and no saved browsing metadata.
- Bookmark HTML import/export and native downloads in both engines, with destination, replacement and cancellation controls.
- Resource Monitor, Memory Breakdown and Reader as removable executable packages; Notes, Capture and Focus as bounded behavior programs; alternate tab systems, themes, layouts, icon packs, menus and widgets as declarative packages. Dependencies, updates, role replacement, local import and community catalogs have native controls.
- macOS, Material-inspired, Liquid Glass-inspired, and Graphite appearance; light/dark/system modes, accent, density, corners, transparency, and accessibility preferences.
- Navigation at top/bottom, draggable toolbar regions, keyboard placement/reorder, fonts/colors/component styling, icon packs, responsive sidebars and widgets.
- Preview, undo, named setups, configuration and required-module import/export, and native recovery independent of website engines.

Data lives in `~/Library/Application Support/org.radius.browser`. Regular browsing metadata is local SQLite. Each engine owns its separate profile stores; reopening a page in another engine reloads its safe URL and does not transfer cookies, forms, or JavaScript state. No telemetry, sync service, password database, or arbitrary native plugin loading is included. Community data catalogs can be added graphically; their publishers are self-reported.

The original repository license remains MIT. New Radius implementation files use MPL-2.0; see [licensing](docs/LICENSING.md).
