# Radius v1 review and acceptance

Radius v1 includes WebKit and optional normal Chrome windows with native grouped tabs, 18 removable module packages, graphical theme/layout editing, isolated profiles, private browsing, recovery, and verified whole-application installation. See [release status](RELEASE_STATUS.md), [Chrome integration](CHROMIUM.md), and [design decisions](DESIGN.md).

Independent subagents repeatedly reviewed the complete implementation and then rechecked concrete fixes. The reviews cover browser/session/privacy behavior, module permissions and transactions, native worker shutdown, customization, Chrome ownership, downloads/quit, and installer trust/recovery. GPT-6 Astra at xhigh implemented and reviewed the Chrome integration. The final inspected source has no remaining actionable review finding; that conclusion is bounded to the inspected source and recorded native checks.

## Accepted source and native checks

Accepted implementation: [`f91a8c4c2779fd21795711438c4da0f2ea15c701`](https://github.com/starharbor2491/radius-browser/commit/f91a8c4c2779fd21795711438c4da0f2ea15c701). CI tested PR merge checkout `f9a92a53145192904d233c4e144c7ed0a6ec10e8`; its tree exactly matches implementation tree `ca2376c0b731a1fae68e1cca53c34e8c44df8169`. Later documentation-only changes do not change the accepted executable source.

- [Portable/native WebKit build and installed acceptance](https://github.com/starharbor2491/radius-browser/actions/runs/38089121425).
- [Chromium ARM and Intel native builds and installed acceptance](https://github.com/starharbor2491/radius-browser/actions/runs/38089121427).

| Check | Recorded result |
| --- | --- |
| Portable | Six installed-acceptance driver regressions, 59 Swift Testing tests and 10 XCTest tests pass; all 18 official packages validate |
| macOS debug | 144 Swift Testing tests plus 10 XCTest tests pass; two signed-app fixtures skip before packaging and execute in release |
| Selected native release | 85 Swift Testing tests pass with real workers, WebKit stores, downloads, profile cleanup, save refusal and installation staging |
| Installed WebKit | Read-only DMG mount, all-architecture sealed copy/package checks, detach before launch, normal quit, owned helper exit, app removal and unchanged external user library |
| Chromium Apple Silicon and Intel | Real HTTP/HTTPS rendering, Reader/capture, profile/private isolation, native input and toolbar geometry, popups and slow-download ownership, MV3 APIs/auxiliary windows, genuine Web Store installation, full-process extension persistence/removal, and ordinary quit with the native manager sheet open all pass |

Installed acceptance rejects watchdog TERM even when it returns status zero. Both launches must finish their acceptance checks, enter the application delegate's termination path and receive an affirmative termination reply before a receipt records normal quit.

Native management and Reader sheets allow Quit to reach the existing application delegate while remaining open. Chromium acceptance verifies the actual sheet policy, then leaves its native manager and child window alive for the normal shutdown test.

Fresh Chromium pane acceptance retains exact target/loading/toolbar conditions with the same bounded 25-second allowance as other fresh-page checks, then verifies the actual document and native owner/child geometry.

The real worker regression stops an owned process and exercises run-loop reentry during replacement and rollback. Approved package bytes and installed configuration remain consistent; unrelated layout edits survive rollback.

## Downloads

Accepted artifacts contain the DMG and its package/installation receipts. Sign in to GitHub if prompted, download the ZIP, extract it, open the DMG, and drag Radius to Applications. [Installation instructions](DISTRIBUTION.md) describe the architecture choices and development-build opening behavior.

| Variant | Installer download | DMG inside the ZIP | DMG bytes |
| --- | --- | --- | --- |
| WebKit universal (Apple Silicon or Intel) | [Download ZIP](https://github.com/starharbor2491/radius-browser/actions/runs/38089121425/artifacts/11683717786) | `Radius-1.0.0-WebKit-universal-development.dmg` | 10,388,132 |
| Chromium + WebKit (Apple Silicon) | [Download ZIP](https://github.com/starharbor2491/radius-browser/actions/runs/38089121427/artifacts/11683192133) | `Radius-1.0.0-Chromium-arm64-development.dmg` | 172,578,704 |
| Chromium + WebKit (Intel) | [Download ZIP](https://github.com/starharbor2491/radius-browser/actions/runs/38089121427/artifacts/11683913532) | `Radius-1.0.0-Chromium-x86_64-development.dmg` | 184,209,895 |

| DMG | SHA-256 |
| --- | --- |
| `Radius-1.0.0-WebKit-universal-development.dmg` | `09c24e9128c6f653104b2642246ef9237e2d80a385e8e415b39b49a10cfeae71` |
| `Radius-1.0.0-Chromium-arm64-development.dmg` | `77851aae7d71845f9e22b5addcdda4d2f8f7d58447e48f74baded8f480ec028e` |
| `Radius-1.0.0-Chromium-x86_64-development.dmg` | `05343043802a75bc69ec82ce68599404e8f3e5fa0bcc2b54fc4d4d678cf07873` |

These CI artifact downloads expire on **January 8, 2027**. Retain the extracted DMGs for later installation. The checksum above covers the DMG, not its containing artifact ZIP.

Each receipt identifies the workflow, tested checkout, installer bytes, architecture, signing status, and all 18 actual module payloads. The host and three native workers are universal; the package includes an updater helper for each architecture. Chromium payloads match the chosen native CPU. Failed diagnostics are retained separately and are not accepted installers.

## Visual review and remaining measurement boundary

Actual macOS screenshots cover Modules Discover/Updates, General/Engine settings, light/dark appearance systems, customization at wide/narrow sizes, split panes and recovery. Independent visual review checks spacing, alignment, contrast, action hierarchy and responsive geometry. Both accepted Chrome variants require actual rendered native-window evidence in addition to ownership/geometry flags.

Developer ID and notarization credentials are not configured. The accepted development artifacts use ad-hoc signatures and are unnotarized; trusted network installation remains unavailable. The production pipeline requires authenticated publisher signing and notarization.

Installed smoke uses isolated data and bounded loopback fixtures; its Web Store check uses the real site, a native permission prompt, and a fixed MV3 extension. Optional performance records label warmed-file window/navigation upper bounds and short CPU/RSS samples with their process scope. They do not establish cold-start, paint/input latency, energy use, physical footprint, or comparative browser performance.

The interactive checks in [TESTING.md](TESTING.md) remain relevant for clean-Mac Gatekeeper/TCC behavior, VoiceOver, IME, media permissions, multiple displays and representative websites. The defined MV3 target does not promise universal extension compatibility. No weekly usage-limit reset was used.
