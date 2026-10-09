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
- Rejected malformed XML before tree construction, kept Reader serialization in isolated engine worlds, and canceled capture/worker operations on navigation, module changes, sheet dismissal, and quit. Prevented legacy Reader descriptors from shadowing the executable package and restarted open resource panels if engine shutdown refuses termination.
- Replaced an orientation-dependent native divider and reserved space for accent selection rings. Used native surface backgrounds, accessibility-aware styling, universal packaging, source-license notices, bounded launch diagnostics, and run-loop-scheduled normal quit.

## Evidence

Source `113e296d4a573657c015c27d3bbb58c0760a5421` passed all three packaged native jobs. The standard workflow [37969314046](https://github.com/starharbor2491/radius-browser/actions/runs/37969314046) passed 49 debug tests (30 portable, including five Reader parser tests, and 19 native integration tests), all 19 native tests again in release mode, universal app/worker builds, signature verification, and packaged WebKit HTTP/split/reader/save/normal-quit checks. All 16 native appearance/control screenshots were independently inspected on the preceding `3b164bd` source; the final executable revision changes only diagnostic capture. No further actionable issue was found in that inspected scope.

The standard application artifact is [11635450916](https://github.com/starharbor2491/radius-browser/actions/runs/37969314046/artifacts/11635450916); its inner ZIP SHA-256 is `f970d63705cce43c55753713f40df38733d9eecf46d26a7917f478b4d5807157`. These are development signatures, not Developer ID/notarization. Artifacts have GitHub's retention limit; rebuild from this source when an artifact expires.

The actual Radius embedded-engine workflow [37969314011](https://github.com/starharbor2491/radius-browser/actions/runs/37969314011) passed on both native ARM and Intel. It checked HTTP/HTTPS, isolated Reader serialization despite a page-world serializer override, context cancellation before initialization, normal/profile/two-private-window storage isolation, blocked and allowed popups with preserved openers, native view attachment, Chromium content PNG, engine closure preserving WebKit and the native window, and ordinary save/quit. Development bundles are available for [ARM](https://github.com/starharbor2491/radius-browser/actions/runs/37969314011/artifacts/11635870481) and [Intel](https://github.com/starharbor2491/radius-browser/actions/runs/37969314011/artifacts/11635342210). Runtime provenance records the workflow's tested PR merge commit; the workflow head identifies the branch source above.

Packaged screenshots establish native control rendering; reader/renderer assertions establish website behavior. The final ARM own-window WindowServer capture visibly shows the loaded HTTPS page inside Radius, resolving the earlier gray Cocoa bitmap as a capture omission. Intel's Cocoa bitmap also shows the embedded page. The OS capture is optional when recording permission is unavailable, scoped to the app's own test window, bounded by a deadline, and stopped/reaped on cancellation. No recording permissions are granted or privacy settings changed by the smoke test. Interactive clean-Mac acceptance remains a separate release gate.

Independent portable validation also passed all 30 tests and an additional malformed-input Reader crash corpus. Later revisions must be checked against their own [GitHub Actions](https://github.com/starharbor2491/radius-browser/actions) results; this evidence certifies the named source and artifacts only.

## Remaining gates

Interactive VoiceOver/IME, broader website compatibility, media permissions, clean installation, comprehensive download failure cases, crash recovery, and measured performance remain in [TESTING.md](TESTING.md). Consumer Chromium installation/extensions are constrained as described in [CHROMIUM.md](CHROMIUM.md). The full [release status](RELEASE_STATUS.md) distinguishes implemented development behavior from consumer requirements.
