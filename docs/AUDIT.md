# Development build review

The implementation received repeated independent GPT-6 Astra reviews of the complete source, tests, module storage, privacy boundaries, native interface, packaging, and documentation. Concrete findings were fixed and reviewed again. The final source review found no further actionable code defects within the inspected scope. This does not establish that every possible browser or macOS defect has been eliminated.

## Corrections

- Coalesced startup across windows, routed cold-open URLs after initialization, and scoped commands and focus to the active window.
- Recreated WebKit views when profiles change, preserved popup requests and openers, supported generated blob documents without persisting their temporary addresses, and bounded tab restoration.
- Preserved download destinations until completion, confirmed replacement races, retained completed files when committing fails, and handled window/app closure during active downloads.
- Prevented stale database writes and mutation of newer schemas; made failed saving visible; retained original data during native recovery.
- Rejected unsafe module paths and symlinks, preserved disabled/removed choices across updates, and recovered interrupted package transactions.
- Corrected native delegate concurrency compatibility and added real JavaScript confirmation tests. Scheduled the smoke test's quit through the run loop so its actor task can return before deferred termination.
- Clarified that current packages remove descriptors and stop access or sampling; their feature implementations remain compiled into Radius.
- Added explicit native surface backgrounds, accessibility-aware styling, universal packaging, source-license notices, and bounded launch diagnostics.

## Evidence and remaining gates

The automated suite contains 13 portable core tests and six macOS WebKit integration tests. CI also builds a universal application, verifies its local signature, launches the packaged binary with isolated data, captures four appearances and four control screens, browses a loopback HTTP page, extracts reader text, saves, and requests ordinary app termination. The CEF experiment has separate build and runtime provenance; it never registers itself as a Radius engine.

Current workflow results and artifacts are available in [GitHub Actions](https://github.com/starharbor2491/radius-browser/actions). Release verification must be assessed against the specific source commit and successful job, rather than inferred from a passing earlier run.

Interactive VoiceOver, media permissions, representative public websites, downloaded-app installation, comprehensive download failure tests, and performance measurements remain in [TESTING.md](TESTING.md). The engine-hosting and extension gates are in [CHROMIUM.md](CHROMIUM.md). Independently removable feature implementations, provider replacement, advanced layouts, and signed/notarized consumer distribution remain outside this development build; [RELEASE_STATUS.md](RELEASE_STATUS.md) records these gaps.
