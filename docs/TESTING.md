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
- Enable/disable/uninstall each package. Open Resources and replace Resource Monitor with Memory Breakdown; verify the old process exits and only the chosen provider runs. Close the panel, disable the provider, and uninstall it; confirm processes exit and installed worker files are removed from Application Support. Factory reinstall copies remain in the sealed app bundle. Retain notes on removal. Relaunch and update the app; intentionally disabled/removed modules must stay so.
- Preview and apply each design system, light/dark/system mode, accent, transparency, density, and corners. Test system Reduce Transparency, Increase Contrast, Reduce Motion, and keyboard-only/VoiceOver operation.
- Place tabs at every edge, move navigation to the bottom, open each sidebar on both sides, resize sidebar through Customize, hide it, and restore defaults through Recovery.
- Enable tree tabs; create children, collapse/expand, reparent, pin, drag, and move siblings. The selected tab must remain visible and pinned roots must remain first. Open side-by-side and stacked panes; navigate each independently, switch with mouse and keyboard, close either pane's tab, and restore sessions. Address/find/zoom/reader actions must follow the active pane.
- Preview a split layout from a one-tab window, cancel, and verify the original tab/session is unchanged. Return a window to one pane, apply appearance changes, and confirm it stays in one pane; explicitly select Split view to reopen it.
- Save/export/import setups and verify no private data enters the exported file. Cancel previews and use Undo.
- Simulate an invalid module manifest and an unreadable library database in a disposable test account. Native recovery must still open; backups must survive repair. Simulate a denied disk write; failed saving must be visible and quit must offer keeping the app open.
- Simulate web-content process termination. Native browser controls, settings, Modules, Customize, and Recovery must remain usable.

For the optional Chromium development build, reopen an HTTP/HTTPS tab explicitly in each engine, confirm the reload notice and separate sign-ins, and change the default for new tabs. Closing the last tab and opening the second split pane must honor that default; Duplicate must retain the source engine. Check per-profile and separate-private-window cookies/local storage, popup openers, reader, capture, errors, reload/back/forward, and close/quit while both engines are mounted. Downloads and media are disclosed as unavailable in Chromium. A missing runtime must show native recovery even on a blank tab. Clear website data after restarting to close Chromium. Consumer engine and extension acceptance is in CHROMIUM.md.
