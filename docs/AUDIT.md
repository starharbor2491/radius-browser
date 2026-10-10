# Radius v1 review and validation

Independent subagents repeatedly review browser behavior, module transactions, privacy, native design, Chromium lifecycle and application distribution. GPT-6 Astra at xhigh implements and reviews the Chrome integration. Concrete findings are fixed and checked again; reviews do not prove that every possible browser or macOS defect has been eliminated.

## Current implementation

Radius includes WebKit and optional normal Chrome windows with native grouped tabs, 18 removable module packages, native catalogs/settings, graphical theme and layout editing, profiles, recovery, and verified whole-application installation. See [release status](RELEASE_STATUS.md), [Chrome integration](CHROMIUM.md), and [design decisions](DESIGN.md).

The latest source fixes stable browser-view hosting, active-page readiness before engine switching, pristine panes with extension-created inactive tabs, and native window-control ownership. Module review also covers approved payloads across reentrant worker shutdown and preserving unrelated layout edits during rollback. Those changes require fresh native acceptance before their installers can be delivered.

## Recorded native evidence

Source `5dd97aba4da2d73108d7d1ad60cd81f381042dee` is recorded in [native workflow 38052369297](https://github.com/starharbor2491/radius-browser/actions/runs/38052369297) and [Chromium workflow 38052369293](https://github.com/starharbor2491/radius-browser/actions/runs/38052369293). The pull-request test checkout is `d0ff841b99c167d7de928de2aaf3c3e078dbcd28`.

| Check | Result for that source |
| --- | --- |
| Portable | 59 Swift Testing and 10 XCTest cases pass; all 18 official packages validate |
| macOS debug | 136 Swift Testing and 10 XCTest cases pass |
| Selected native release | 77 Swift Testing cases pass with real workers, WebKit storage, downloads, profile cleanup, save refusal and installation staging |
| Installed WebKit | Read-only DMG mount, all-architecture sealed copy and package checks, detach before launch, normal quit, owned process exit, copy removal and unchanged external library pass |
| Chromium ARM and Intel | Bridge, native tests, universal shell and DMG build pass; both installed tests fail the browser-view attachment check before extension acceptance |

The accepted WebKit DMG for that source is `Radius-1.0.0-WebKit-universal-development.dmg`, 10,162,478 bytes, SHA-256 `3fb6b4f87870373e287e73c23e6f6d7f909c1f910c94424fa4adcfca6e18de84`. Its receipt records all 18 actual module payloads and both host/worker architectures. This earlier candidate does not certify subsequent changes. Failed Chromium diagnostics are not delivery artifacts.

Actual screenshots include Modules Discover/Updates, General/Engine settings, light/dark appearance presets, customization at wide/narrow sizes, split panes and recovery. Independent visual review checks spacing, alignment, contrast, action hierarchy and responsive geometry.

## Distribution and measurement boundary

Developer ID and notarization credentials are not configured. Development artifacts use ad-hoc signatures; trusted network installation remains disabled. The production pipeline requires an authenticated publisher and notarization.

Installed smoke uses an isolated data directory and bounded loopback fixtures. Its optional performance record labels warmed-file window readiness, title/load navigation readiness and five-second process-tree CPU/RSS samples. These are diagnostic observations, not cold-start, paint/input latency, energy, physical-footprint or comparative browser benchmarks.

The interactive checks in [TESTING.md](TESTING.md) remain relevant for VoiceOver, IME, media permissions, multiple displays and representative websites. The defined MV3 target does not promise universal extension compatibility. No weekly usage-limit reset was used.
