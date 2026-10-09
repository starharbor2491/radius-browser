# V1 development status

Radius is a usable native browser development build. It is **not the complete consumer product** defined in PRODUCT_PLAN.md. The standard app browses with WebKit; the optional development bundle adds embedded Chromium Alloy. The interface identifies available engines and unsupported capabilities.

| Capability | Current scope |
| --- | --- |
| Native browsing | WebKit windows/tabs, navigation, search, find, zoom, popup controls, dialogs, media prompts, downloads, crash reload |
| Chromium variant | Native CEF Alloy tab adapter; explicit reopen and default for future tabs; separate engine stores; reader and capture. Runtime must be embedded at build time; Chromium downloads, media, and Chrome extensions are unavailable |
| Profiles/privacy | Separate persistent stores per profile and engine; a separate temporary context per private window; no private history/session/notes persistence |
| Local data | Actor-backed SQLite, transactional state, stale-save protection, bounded imports, original-data-preserving recovery; no password database or encryption claim |
| Executable modules | Resource Monitor, Memory Breakdown, and Reader use independently installed native worker packages. Reader extracts text from a bounded HTML snapshot on request and exits. Exclusive provider replacement stops/reaps the prior worker; disable stops execution; uninstall deletes the installed executable. Factory reinstall payloads remain in the sealed application |
| Host modules | Notes, Page Capture, and Focus Mode are removable capability descriptors; their implementations remain compiled into the native host |
| Package trust/updates | Native workers must exactly match a trusted bundled package. Arbitrary imported native code is rejected. Bundled updates and explicit repair/reinstall are available; no remote catalog/update service or OS permission sandbox for workers |
| Appearance | macOS, Material-inspired, Liquid Glass-inspired, Graphite; light/dark/system, accent, density, corners, transparency, reduced motion. Vendor design systems are interpretations |
| Layout/tabs | All four tab edges, pin/drag/menu reorder, vertical trees, independent resizable side-by-side/stacked panes, navigation top/bottom, sidebar left/right/hidden and width, bookmarks/status bars |
| Setup sharing | Configuration only; preview, undo, named setups, bounded import/export. Split preview leaves browsing tabs unchanged |
| Recovery | Native interface restore, module reset/backups, write retry, database recovery preserving originals, explicit return to WebKit |
| Distribution | Universal app/worker builder and architecture-specific optional Chromium bundles; development signatures only. No Developer ID/notarization, DMG, automatic app updater, or consumer engine installer |
| Other plan items | Arbitrary component rearrangement, fonts/icon packs, dependency-bearing setup packs, general removable behavior providers, password/sync/translation providers, and a curated remote catalog are not implemented |

## Verification

The suite currently contains 30 portable tests (25 core and 5 reader-parser tests) and 19 native integration tests. Portable checks include SQLite/state recovery, bounded imports, bookmark entities and hostile malformed input, tree/split normalization, package transactions, executable payload removal, exclusive resource-provider selection, damaged-package repair, interrupted updates, and symlink rejection. Native checks use real WebKit views and native resource workers for privacy, profile changes, popup openers, generated subframes, dialogs, split state, engine descriptors, worker replacement/removal, rejection of damaged replacement candidates, retained notes, repair after relaunch, and one-shot Reader extraction/uninstall.

The standard application workflow builds both CPU architectures, verifies signatures, and launches the packaged app with isolated data. It captures appearance/control screens and checks real HTTP browsing, split panes, reader extraction, saving, and ordinary termination. The separate embedded Chromium workflow runs on native ARM and Intel, including HTTPS, content capture, context isolation, popup adoption, pre-initialization cancellation, close, and ordinary quit. See [AUDIT.md](AUDIT.md) for the specific successful source/run evidence; failed or earlier runs do not certify a later commit.

## Consumer release gates

1. Preserve passing native CI for the packaged source and perform the interactive [clean-Mac checklist](TESTING.md), including ARM visible Chromium composition, VoiceOver, IME, representative websites, media permissions, download races, recovery, and session/focus behavior. The source and artifacts in AUDIT.md pass native CI; those automated checks do not replace interactive acceptance.
2. Provide a supported Chrome-style embedding architecture for the required Chrome extensions, then pass consumer installation, Manifest V3 APIs, restart/update/removal, and isolation checks in [CHROMIUM.md](CHROMIUM.md). CEF native-parent Alloy is insufficient.
3. Implement a signed consumer engine install/update/removal flow and an offline installer with the same application behavior.
4. Complete the remaining module/component requirements before advertising the broader plan's modularity. Three current optional behaviors remain in the host, and the catalog/update service is local only.
5. Supply Developer ID and notarization credentials; configure/verify hardened runtime; notarize/staple and install on a clean Mac. No signing identity is configured in this workspace.
6. Measure launch, idle CPU, full browser-process memory, keyboard latency, and battery behavior before making performance claims.

No weekly usage-limit reset was invoked.
