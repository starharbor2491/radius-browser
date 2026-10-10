# Radius v1 review and validation

Independent subagents have repeatedly reviewed browser behavior, module transactions, privacy boundaries, native design, Chromium lifecycle and application distribution. GPT-6 Astra at xhigh implemented and reviewed the Chrome-style engine integration. Findings are fixed and reviewed again. Review conclusions apply to inspected behavior; they do not prove that every possible browser or macOS defect has been eliminated.

## Current implementation

The app contains WebKit and optional Chrome-style Chromium, 18 removable module packages, native module settings/catalogs, advanced visual customization, profile cleanup and a verified whole-application installer. The complete scope is described in [RELEASE_STATUS.md](RELEASE_STATUS.md).

Recent review fixes cover worker EOF/shutdown, cancellation retries, profile-deletion callbacks and durable cleanup, dependency and setup activation, transactional package replacement, native toolbar focus, paired custom colors, staged installer cleanup and running-destination protection. Native tests exercise real workers and WebKit stores; packaged checks additionally exercise the actual browser windows and engine services.

## Evidence

The current local portable suite passes 66 tests: 56 Swift Testing cases and 10 XCTest cases. All 18 factory packages validate. New native regressions cover genuine WebKit Home/Back/Forward history, exclusive tab-provider changes, cross-window customization preview ownership, serialized website-data clear requests, final quit snapshots and startup database recovery. Those native changes are awaiting the next macOS run.

Source `2f80300028abeb3bf7b1d139e6815d91c30c8586` is recorded in [native workflow 38041105298](https://github.com/starharbor2491/radius-browser/actions/runs/38041105298) and [Chromium workflow 38041105366](https://github.com/starharbor2491/radius-browser/actions/runs/38041105366). Its portable suite passes 64 tests. The native run executes 122 Swift Testing cases and 10 XCTest cases; a Home-history fixture using `loadHTMLString` fails to produce the required history entry. The replacement fixture serves a genuine bounded loopback HTTP page.

Both Chromium architectures build the bridge, universal native app and graphical development installer; all ten native files meet the macOS 14.0 deployment minimum. Packaged checks pass HTTP/HTTPS, isolated Reader, PNG capture, normal/private profile isolation, popup policy/opener behavior and actual Chrome child-window geometry. A regular profile's expiry-free session cookie survives its last Chromium browser closing. Native screenshots confirm the Chrome toolbar stays within its page region, the second panel collapses at 800 points, and short-window onboarding remains reachable.

The current packaged shortcut and local extension-fixture acceptance still fail. The fixes enter AppKit's real event queue and use Chromium's supported browser-level extension loader. Genuine Web Store installation, whole-process restart and ordinary shutdown remain required. An Intel signal termination lacks a captured cause; the next run collects launch-scoped macOS crash reports. Failed diagnostic installers are not accepted delivery artifacts.

The previously accepted universal WebKit installer is from source `8ba318f104a8bab72222ea122a762da54df76794`, [workflow 38039455130](https://github.com/starharbor2491/radius-browser/actions/runs/38039455130). Its native suites and actual packaged launch pass. It is historical evidence, not an installer for the newer source. Fresh installer checksums and complete acceptance will replace this interim record after the new runs pass.

## Distribution and interactive checks

Developer ID and notarization credentials are not configured. Development artifacts use ad-hoc signatures. The production pipeline requires a real publisher identity and notarization; trusted updates remain disabled in development builds.

Automated native acceptance is complemented by the interactive checks in [TESTING.md](TESTING.md), particularly VoiceOver, IME, media permissions, multiple displays and broader website behavior. Chromium's defined MV3 target and download boundaries are documented in [CHROMIUM.md](CHROMIUM.md). No universal extension compatibility or performance benchmark is claimed.
