# V1 status and release gates

The implementation is a native WebKit browser development build. It is **not yet the complete dual-engine consumer product** defined in PRODUCT_PLAN.md. Unsupported capabilities are omitted or clearly marked unavailable in the app.

| Capability | Current scope |
| --- | --- |
| Native browsing | WebKit, windows, tabs, navigation, search, find, zoom, popup controls, JavaScript dialogs, media permission prompts, process-crash recovery |
| Profiles and privacy | Separate WebKit stores per profile; ephemeral per-private-window store; no private history or session persistence; saved downloads remain on disk |
| Local data | Actor-backed SQLite, transactionally saved JSON state, stale-save protection, bounded imports; no password storage or database encryption claim |
| Modules | Five installed declarative descriptors for constrained native host capabilities; dependencies, activation, disable, descriptor removal, local-manifest import. Feature implementations remain compiled into Radius; independently removable behavior code and provider replacement are not implemented |
| Module updates | Newer packages bundled with a newer Radius build only; no network catalog or update service |
| Appearance | Four native-rendered style presets, modes, accent, density, transparency, corner controls; Material and Liquid Glass are interpretations, not full vendor implementations |
| Layout | Tabs on all four edges; tab drag/keyboard-menu reordering; navigation top/bottom; sidebar left/right/hidden and width; bookmarks/status bars |
| Setup sharing | Configuration only; preview, undo, saved setups, bounded import/export |
| Recovery | Restore interface; back up/reset modules; retry writes; fresh database recovery without deleting the original |
| Chromium and extensions | Not installed and not available. Pinned integration experiment and acceptance matrix in CHROMIUM.md |
| Advanced layouts | Tree tabs, split panes, arbitrary multi-toolbars, component drag-between-regions, component fonts/icon packs and setup packs with dependencies are not implemented |
| Distribution | Local ad-hoc signed app builder and CI zip; no Developer ID certificate, notarization, DMG, offline Chromium installer, or automatic app updater |

## Verification

The 13 portable tests exercise input validation, SQLite round trips and stale saves, module lifecycles/dependencies/cycles, symlink rejection, interrupted updates, configuration sanitization, and bookmark import/export. Six native integration tests cover private persistence, profile context changes, popup openers, generated documents, tab limits, and real JavaScript confirmations. The packaged-app smoke check captures native screens and verifies HTTP browsing, reader extraction, saving, and normal termination. CI results apply to the tested commit; interactive clean-Mac checks remain separate gates. See [the review record](AUDIT.md).

Before calling this a consumer v1 release:

1. Pass the macOS CI compiler and core tests on the release commit.
2. Run the clean-Mac checklist in TESTING.md, including VoiceOver, window closure during downloads, private data isolation, imported links, and recovery.
3. Implement and pass the Chromium/extension gates in CHROMIUM.md before advertising engine switching or Chrome extension support.
4. Sign with Developer ID, enable and verify the appropriate hardened runtime configuration, notarize, staple, and install the packaged app on a clean Mac.
5. Measure launch, idle CPU, memory with actual web-process accounting, keyboard latency, and battery use. No performance claim is made without these measurements.

No weekly usage-limit reset was invoked by this implementation.
