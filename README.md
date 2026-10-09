# Radius

A native macOS browser with local profiles, private windows, configurable appearance, tree tabs, split panes, and removable resource providers. Swift 6, SwiftUI, AppKit, and SQLite; no third-party Swift dependencies.

This is a **v1 development build**. WebKit works in the standard build. An optional build embeds Chromium with native tabs and explicit engine switching. Chrome extensions, consumer engine installation, automatic application updates, and notarized distribution remain release gates. See [release status](docs/RELEASE_STATUS.md).

## Run on a Mac

Requires macOS 14+ and Xcode 16+ or Swift 6 command-line tools.

```sh
./scripts/test.sh
./scripts/build-app.sh
open dist/Radius.app
```

You can also open `Package.swift` in Xcode and run the Radius executable. CI produces zipped application artifacts. Development builds are ad-hoc signed; they are not notarized for ordinary Gatekeeper distribution. [Chromium build instructions and constraints](docs/CHROMIUM.md) describe the optional runtime.

## Included

- Multiple windows; tabs on all four edges; pinning, reordering, duplication, reopening, and expandable tab trees.
- Resizable side-by-side or stacked browsing panes with independent pages and shared controls for the active pane.
- Navigation, search, find, page zoom, popup controls, JavaScript dialogs, and web-process crash recovery.
- Profile-separated website storage, bookmarks, history, and notes; private windows with temporary website storage and no saved browsing metadata.
- Bookmark HTML import/export and WebKit downloads with a native destination picker.
- Resource Monitor and Memory Breakdown as real executable packages: install, disable, replace the active provider, or uninstall its code. Sampling runs only while the Resources panel is open. Notes, Reader, Page Capture, and Focus Mode use removable descriptors whose implementations remain in the native host.
- macOS, Material-inspired, Liquid Glass-inspired, and Graphite appearance; light/dark/system modes, accent, density, corners, transparency, and accessibility preferences.
- Navigation at top/bottom, left/right/hidden sidebar, adjustable width, bookmarks and status bars.
- Preview, undo, named setups, configuration-only import/export, and native recovery independent of website engines.

Data lives in `~/Library/Application Support/org.radius.browser`. Regular browsing metadata is local SQLite. Each engine owns its separate profile stores; reopening a page in another engine reloads its safe URL and does not transfer cookies, forms, or JavaScript state. No telemetry, sync service, password database, arbitrary native plugins, or remote module catalog is included.

The original repository license remains MIT. New Radius implementation files use MPL-2.0; see [licensing](docs/LICENSING.md).
