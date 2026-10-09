# Validation

Run `./scripts/test.sh` on macOS or Linux with Swift 6 and SQLite development headers. Run `./scripts/build-app.sh` on macOS. CI builds a universal application zip for local testing and runs `./scripts/smoke-app.sh` against the packaged binary. The smoke test uses a disposable data directory and a dynamically allocated loopback HTTP fixture; it captures native screens and checks browsing, reader extraction, saving, and normal shutdown.

## Clean-Mac checklist

- Install/open the app from the artifact with ordinary macOS behavior. Never disable Gatekeeper to make the test pass; a distributable release needs signing and notarization.
- Navigate to an HTTPS page, use back/forward, redirect, reload/stop, search, find, zoom, and standard text editing shortcuts. Validate main-frame errors without replacing a working page for a subframe failure.
- Open two regular windows and two private windows. Confirm navigation and command shortcuts act in the focused window. Close/reopen tabs, pin/unpin and reorder tabs. Quit/relaunch and check session recovery.
- Create profiles A and B. Sign in to a test site in A. Reopen it in B and in a private window; confirm it is signed out. Close private windows and check history/session/database contain no private URLs.
- Export/import Safari, Chrome, and Firefox bookmarks HTML. Verify Unicode, entities, duplicates, invalid schemes and malformed files.
- Download a new file, cancel a download, replace an existing file through the destination picker, reject an invalid destination, and close a window with an active download. Do not auto-open downloaded files.
- Trigger a JavaScript alert/confirm/prompt and a user-clicked new window. Check site origin labeling, permission denial and allowed camera/microphone behavior.
- Enable/disable/uninstall each package. Confirm files are removed from Application Support, samplers stop, and notes can be retained. Relaunch and update the app; intentionally removed modules must stay removed.
- Preview and apply each design system, light/dark/system mode, accent, transparency, density, and corners. Test system Reduce Transparency, Increase Contrast, Reduce Motion, and keyboard-only/VoiceOver operation.
- Place tabs at every edge, move navigation to the bottom, open each sidebar on both sides, resize sidebar through Customize, hide it, and restore defaults through Recovery.
- Save/export/import setups and verify no private data enters the exported file. Cancel previews and use Undo.
- Simulate an invalid module manifest and an unreadable library database in a disposable test account. Native recovery must still open; backups must survive repair. Simulate a denied disk write; failed saving must be visible and quit must offer keeping the app open.
- Simulate web-content process termination. Native browser controls, settings, Modules, Customize, and Recovery must remain usable.

Chromium acceptance is in CHROMIUM.md. The presence of a CEF download or a compiling experiment is not evidence of extension compatibility.
