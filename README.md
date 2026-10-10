# Radius

A native macOS browser with WebKit and optional Chrome-style Chromium, local profiles, private windows, visual customization, split panes, and 18 module packages. Swift 6, SwiftUI, AppKit, and SQLite; no third-party Swift dependencies.

The v1 implementation includes Chrome extension management, a graphical module center, deep layout/theme editing, profile removal, and verified app installation/update/offline-DMG flows. Current native acceptance is in progress. Developer ID and notarization credentials remain unconfigured; development artifacts are ad-hoc signed. See [release status](docs/RELEASE_STATUS.md) and [distribution](docs/DISTRIBUTION.md).

## Run on a Mac

Requires macOS 14+ and Xcode 16+ or Swift 6 command-line tools.

```sh
./scripts/test.sh
./scripts/build-app.sh
open dist/Radius.app
```

You can also open `Package.swift` in Xcode and run the Radius executable. CI produces zipped application and graphical DMG artifacts. Development builds are ad-hoc signed; they are not notarized for ordinary Gatekeeper distribution. [Chromium build instructions and constraints](docs/CHROMIUM.md) describe the optional runtime.

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

Data lives in `~/Library/Application Support/org.radius.browser`. Regular browsing metadata is local SQLite. Each engine owns its separate profile stores; reopening a page in another engine reloads its safe URL and does not transfer cookies, forms, or JavaScript state. No telemetry, sync service, password database, arbitrary native plugins, or arbitrary native plugin loading is included. Community data catalogs can be added graphically; their publishers are self-reported.

The original repository license remains MIT. New Radius implementation files use MPL-2.0; see [licensing](docs/LICENSING.md).
