# Radius v1 review and validation

Independent subagents have repeatedly reviewed browser behavior, module transactions, privacy boundaries, native design, Chromium lifecycle and application distribution. GPT-6 Astra at xhigh implemented and reviewed the Chrome-style engine integration. Findings are fixed and reviewed again. Review conclusions apply to inspected behavior; they do not prove that every possible browser or macOS defect has been eliminated.

## Current implementation

The app contains WebKit and optional Chrome-style Chromium, 18 removable module packages, native module settings/catalogs, advanced visual customization, profile cleanup and a verified whole-application installer. The complete scope is described in [RELEASE_STATUS.md](RELEASE_STATUS.md).

Recent review fixes cover worker EOF/shutdown, cancellation retries, profile-deletion callbacks and durable cleanup, dependency and setup activation, transactional package replacement, native toolbar focus, paired custom colors, staged installer cleanup and running-destination protection. Native tests exercise real workers and WebKit stores; packaged checks additionally exercise the actual browser windows and engine services.

## Evidence

Source `157c8441edd0a4719a6eaa6391301563f5c62537` passes the 63-test portable suite in [workflow 38036655074](https://github.com/starharbor2491/radius-browser/actions/runs/38036655074). All 18 factory packages validate. Current native tests and packaged acceptance are in progress in that workflow and the [ARM/Intel Chromium workflow 38036655006](https://github.com/starharbor2491/radius-browser/actions/runs/38036655006). Successful native results and current installer checksums must be recorded here before claiming executable acceptance.

The earlier successful `113e296d4a573657c015c27d3bbb58c0760a5421` WebKit/Alloy development artifacts belong to [workflow 37969314046](https://github.com/starharbor2491/radius-browser/actions/runs/37969314046) and [workflow 37969314011](https://github.com/starharbor2491/radius-browser/actions/runs/37969314011). They do not certify this expanded Chrome-style v1 implementation.

## Distribution and interactive checks

Developer ID and notarization credentials are not configured. Development artifacts use ad-hoc signatures. The production pipeline requires a real publisher identity and notarization; trusted updates remain disabled in development builds.

Automated native acceptance is complemented by the interactive checks in [TESTING.md](TESTING.md), particularly VoiceOver, IME, media permissions, multiple displays and broader website behavior. Chromium's defined MV3 target and download boundaries are documented in [CHROMIUM.md](CHROMIUM.md). No universal extension compatibility or performance benchmark is claimed.
