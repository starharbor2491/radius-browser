# Radius v1 implementation and release status

The v1 implementation combines a native WebKit browser, optional Chrome-style Chromium, 18 module packages, a graphical customization editor, and a verified complete-application installer. Native acceptance is being rerun for the current source; the earlier Alloy artifacts do not certify this implementation.

| Area | Implemented behavior |
| --- | --- |
| Browsing | Multiple windows/profiles, tabs on four edges, pin/reorder/reopen, native history/bookmarks/import, find, zoom, downloads, popup/dialog/media controls, and engine crash recovery |
| Engines | WebKit by default; Chrome-style CEF Views with Chromium browser services. Tabs can reopen with another engine; each engine retains separate sign-ins |
| Extensions | Native profile selector, Chrome extension manager and Web Store. Target: MV3 content scripts, service workers, scripting/storage, permissions, actions/popups, options and side panels. Extension-created Chrome windows are managed auxiliary windows; tab/window organization differs from Chrome |
| Modules | Three independently installed native workers, three bounded behavior programs, twelve declarative packages. Installed payloads are removed on uninstall. Required tab systems and exclusive providers have validated, transactional replacement |
| Catalogs | Official bundled packages, graphical local package/catalog import, bounded HTTPS community catalogs, payload integrity receipts, publisher and permission previews, dependency/version validation |
| Appearance | macOS, Material, Liquid Glass, Graphite; typography, text/spacing scales, icon packs, colors and contrast feedback, borders/shadows, density/corners, component overrides and accessibility preferences |
| Layout | Tabs on four edges, trees, split panes, multiple toolbar regions, draggable controls with keyboard placement/reorder, address/tab widths, sidebars on either side, responsive second panel, automatic sidebar hiding, menus and start widgets |
| Setups | Preview, undo, saved configurations and bounded import/export with module requirements. Dependencies and activation permissions are reviewed before atomic application; browsing data and permission grants are excluded |
| Privacy | Separate engine/profile stores; temporary private stores; no private browsing metadata/notes. Comprehensive profile deletion and website-data clearing have durable restart cleanup, scope checks and failure recovery |
| Recovery | Native settings/modules/recovery survive engine failure; original-preserving library/module backups, configuration restore, write retry, safe return to WebKit, interrupted-package rollback |
| Distribution | Universal WebKit app plus architecture-specific Chromium payloads in the same app. Graphical DMGs and signed update/offline-import flows stage a whole verified app, then activate with a READY-confirmed helper after explicit restart |

## Verification boundary

The current portable suite passes 64 tests, including database recovery, hostile imports, paired custom colors, profile deletion/rollback, compatibility bounds, module installation and interrupted transaction rollback, publisher/ABI/update policy, and downgrade rejection. All 18 factory packages validate. Native tests additionally exercise real WebKit storage, downloads, module workers and app installation staging. Current macOS results and artifacts will be recorded in AUDIT.md after their runs finish.

The Chromium workflow runs on ARM and Intel. It must pass actual embedded HTTP/HTTPS rendering, Reader/capture, profile/private isolation, popup/auxiliary lifetime, Chrome toolbar geometry/focus, MV3 lifecycle, genuine Web Store installation, and ordinary shutdown. Building the bridge or loading an unpacked fixture alone does not establish Web Store compatibility.

Developer ID and notarization credentials are not configured. Development artifacts are ad-hoc signed and unnotarized. The production workflow requires those credentials, signs nested code with hardened runtime, notarizes/staples the app and DMG, and fails closed if trust is unavailable. Development builds do not enable the trusted network installer by weakening publisher verification.

Interactive clean-Mac acceptance remains necessary for signing/distribution, VoiceOver, IME, multiple displays, media prompts and representative websites. No benchmark or universal extension-compatibility claim is made. Password, sync, translation, further engines and interchangeable engine internals are ecosystem expansion examples rather than shipped providers.

No weekly usage-limit reset was invoked by the agent.
