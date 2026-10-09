# Development build review

Repeated independent subagent reviews inspected the source, storage/import boundaries, engine lifecycle, native interface, packaging, and documentation. GPT-6 Astra at xhigh handled CEF feasibility, native integration, and real executable module work. Concrete findings were fixed and reviewed again. A clean review is limited to the inspected source and tested behaviors; it does not establish that every browser/macOS defect has been eliminated.

## Corrections

- Coalesced multiwindow startup, routed cold-open URLs, and scoped focus/commands to the active window.
- Recreated engine views when profiles change; preserved popup requests/openers; kept generated pages live without persisting unsafe temporary addresses; bounded tab restoration.
- Preserved download destinations, confirmed replacement races, retained completed files after commit failure, and handled closure during downloads.
- Prevented stale writes/newer-schema mutation; exposed save failures; retained original database/backups during recovery.
- Rejected unsafe module paths/symlinks and recovered interrupted transactions. Preserved intentional disable/removal through app updates.
- Replaced a potentially quadratic bookmark regex with a bounded linear parser; fixed numeric entities, double decoding, and fake anchors in comments/script/style.
- Kept layout preview from creating persistent tabs. Preserved a window's return-to-one-pane choice across appearance edits; allowed explicit split reopening; repaired hidden selected ancestors and tree cycles/depth.
- Kept active-pane focus/address synchronized, retained default engines for implicit new tabs, retained source engines for duplication, and protected pinned ordering during reorders.
- Exposed missing-engine recovery for blank tabs and captured reader source context/title rather than labeling old text with a newly selected tab.
- Cleared Chromium load errors on new navigation; routed unsupported downloads as notices; recorded successful main-frame visits only; disclosed default-denied media access.
- Fixed actual native CEF failures in framework bundle layout, code-signing build settings, sandbox-compatible placement, and profile root paths. Browser creation waits for request-context readiness; cancellation does not retain an uncreated page. Chromium close detaches its child view while keeping the Radius window open.
- Moved Mach sampling, cadence, and metric calculation into two real worker packages. Stop/reap precedes replacement/removal; installed bytes must match the bundled trusted payload. Added exclusive provider selection, reinstall/repair, retained-data checks, and generation-based open-panel restart.
- Prevented closed windows from recreating engine views or private website contexts when retained native views update. Used Chromium's supported command-line hook to make Radius's own popup policy authoritative in normal and private contexts.
- Validated replacement resource workers before stopping a healthy provider. Moved Reader parsing into a removable one-shot worker with bounded serialized HTML input, entity/DTD rejection, cancellation, and no private persistence.
- Replaced an orientation-dependent native divider and reserved space for accent selection rings. Used native surface backgrounds, accessibility-aware styling, universal packaging, source-license notices, bounded launch diagnostics, and run-loop-scheduled normal quit.

## Evidence

Independent portable validation passes 30 tests, including five Reader parser tests. Native CI must verify the 19 integration tests and the final app/worker packaging. Packaged screenshots establish native control rendering; reader/renderer assertions establish website behavior. AppKit bitmap capture does not always include separately composited web content; Chromium content PNG is checked separately.

The standard app run [37958588777](https://github.com/starharbor2491/radius-browser/actions/runs/37958588777), source `72b39e517fca464de1522bb1059ac3ca016d7d92`, passed all 40 tests (25 portable, 15 native), the native suite again in release mode, universal build/signature verification, native screens, and WebKit HTTP/split/reader/save/normal-quit checks. The tested application artifact is [11630451988](https://github.com/starharbor2491/radius-browser/actions/runs/37958588777/artifacts/11630451988); its inner ZIP SHA-256 is `8ac2bf5bce9efdc90fa4f4e285f9f6200f894e25e0cbcc1cf95336d61bd00d57`. Subsequent smoke-capture/documentation changes require their own verification.

The separate upstream CEF sample proof passed all four native ARM/Intel Chrome-style/Alloy renderer-and-quit probes in [37944960439](https://github.com/starharbor2491/radius-browser/actions/runs/37944960439). The actual Radius embedded-engine workflow is separate; sample success is not extension or Radius integration evidence.

Final source-specific runs and downloadable artifacts are recorded here once they pass. Current [GitHub Actions](https://github.com/starharbor2491/radius-browser/actions) results must be read against their commit.

## Remaining gates

Interactive VoiceOver/IME, broader website compatibility, media permissions, clean installation, comprehensive download failure cases, crash recovery, and measured performance remain in [TESTING.md](TESTING.md). Consumer Chromium installation/extensions are constrained as described in [CHROMIUM.md](CHROMIUM.md). The full [release status](RELEASE_STATUS.md) distinguishes implemented development behavior from consumer requirements.
