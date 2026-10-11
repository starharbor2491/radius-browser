# Chromium integration

Radius embeds Chromium browser services through CEF's supported normal Chrome window factory. WebKit remains available without the optional engine. Settings, Modules, Customize and Recovery are native and remain usable independently of either engine.

## Supported architecture

Each Chromium browsing pane owns one normal Chrome window, created without a `CefBrowserView` or native parent. Its intact Cocoa window attaches as a child of the owning Radius window and tracks the native placeholder view's screen coordinates and visibility. Radius never reparents Chrome's internal views. CEF forces native-parent hosting into Alloy; its Chrome-style Views factory creates a popup window, which lacks the normal window's toolbar features required by extension action popups.

Chrome owns the pane's native tab strip, address/navigation toolbar, extension actions and popups. Inner tabs preserve their WebContents, tab IDs, window IDs and background selection semantics. Radius displays the outer containers as browsing panes, with a tab count and explicit close-all scope. Menu actions and shortcuts target the focused native Chrome window; separate pane actions retain Radius's split/layout controls. Extension-created independent Chrome windows remain managed auxiliary windows through downloads, profile deletion and shutdown.

Active-page actions query Chrome through its public command callback, which receives the actual selected WebContents; they do not infer selection from renderer visibility. Safe session records restore selected/background HTTP(S) addresses without saving privileged URLs, cookies, forms or execution state. Home inside a browsing Chrome pane opens Chrome's own new-tab page and retains its inner tab strip and history. A pristine Radius pane retains the native start surface and its module widgets.

Chrome's native bookmark star, bookmark manager and history remain engine-local. The explicitly labeled Radius bookmark action and native sidebars use Radius's profile data across engines. Chrome retains its own Cmd-D shortcut; Radius reports additions/removals to its separate bookmark collection.

The bridge ABI is version 4 and the sealed engine manifest format is version 2; `runtimeStyle` must be `chrome`. ABI 4 requires normal Chrome windows, grouped native tabs, explicit private-context ownership, native tab commands and final-save input gating. Older bridges are rejected by the current loader. The pinned CEF distribution is `154.0.34+g14c5a08+chromium-154.0.8037.98`, [commit 14c5a08](https://github.com/chromiumembedded/cef/commit/14c5a089e8452874cb1a556dc3fde26ed2d87723). Source, helpers, sandbox initialization and archive digests are reproducible in the build scripts.

## Extensions and privacy

The native extension sheet selects a normal Radius profile and opens Chromium's own manager or Chrome Web Store. Chromium controls extension installation, permission prompts, updates, disabling and removal. The MV3 acceptance target includes content scripts, background service workers, scripting, storage, declared permissions, action popups, options, side panels and native tab/window identity. This is a compatibility target, not a promise that every extension works.

Persistent Chromium contexts are separate for each Radius profile. Every private Radius window has a separate in-memory context; regular-profile extensions and cookies do not leak into it. Enabling a regular-profile extension in private windows is outside the v1 acceptance target. WebKit stores are independent. Switching engines retains Radius's outer pane organization and the active safe HTTP/HTTPS address, reloads explicitly, and does not transfer cookies, POST bodies, forms or JavaScript state.

Switching a Chrome pane to WebKit retains only its active safe website address and closes the other inner tabs after explicit confirmation. Removing Chromium applies this conversion to every pane. The Privacy reset clears WebKit site data and resets the entire Chromium engine profile, including its extensions, native bookmarks, native history and settings; its confirmation states that scope. Radius's own bookmarks, history, notes and saved configuration remain separate. Clearing Radius history alone does not clear Chrome's native history.

Page-associated downloads use Radius's native destination/replace/cancel controls. Downloads started by an extension service worker through `chrome.downloads` may use Chromium's own download manager; that API is outside the tested MV3 target. Chromium's download history can retain the staging path for a file subsequently moved by Radius. Extension installation retains Chromium's own CRX handling. Media uses the native permission path and platform usage descriptions. Cancellation waits for the writer to stop before deleting staging files. When a native source tab closes and CEF can no longer deliver completion callbacks, Radius requests cancellation and retains its incomplete file until successful engine shutdown proves the writer stopped. Ordinary quit tracks browsing panes and auxiliary/manager pages and waits for asynchronous browser closure. User input is gated during the final save, and resumes if quitting is refused.

Reader captures in an isolated DevTools world and passes bounded HTML to the removable worker. Capture returns bounded viewport PNG bytes to a bounded behavior package's native save flow. Normal app startup opens no remote-debugging port. Isolated packaged-app acceptance opens an ephemeral loopback-only endpoint to install its fixed local extension fixture through Chromium’s browser-level protocol; this diagnostic path requires both the smoke-test switch and an isolated fixture/data directory. It is absent from normal browsing.

## Installation and security

CEF's macOS sandbox requires framework/helper placement under the sealed application bundle. Radius therefore stages and verifies a complete replacement application to add, update or remove Chromium. It does not modify its running signed app. Settings offers signed network releases and verified offline DMGs; explicit Restart and install activates the staged app through the signed waiting helper. See [distribution](DISTRIBUTION.md).

Development signatures establish integrity only. Production requires matching Developer ID publisher identity, nested/all-architecture signature verification, notarization, architecture/metadata compatibility and a monotonic security floor. TLS, Gatekeeper, CEF sandboxing and library validation are preserved.

## Developer build

On a supported Mac with Xcode 16+, Swift 6, CMake and Python:

```sh
python3 scripts/chromium-runtime.py --arch arm64 --work-dir .build/chromium-runtime
RADIUS_CHROMIUM_PACKAGE="$PWD/.build/chromium-runtime/Chromium-arm64.radiusengine" ./scripts/build-app.sh
open dist/Radius.app
```

Use `x86_64` on Intel. The native shell/workers are universal; Chromium is architecture-specific. End users install the graphical complete-app package and do not use these commands.

| Architecture | Archive bytes | Pinned SHA-256 |
| --- | ---: | --- |
| arm64 | 307,056,359 | `2e4a60880addad09c85d9ea27f4df09cb803069e1709377576e9cf62169648fe` |
| x86_64 | 354,938,950 | `b11f8b0d190541f167d0f66265c5017f2faf9b9d08790172732eb09accf00e40` |

## Acceptance evidence

The macOS workflow tests both CPU architectures with isolated data. HTTP/HTTPS rendering, Reader, captures, profile/private contexts, popups, Chrome child-window geometry/focus and normal quit must all pass. A local MV3 fixture separately exercises content/background execution, storage, scripting, permissions, action/panel/options documents, version update, disable and removal. A genuine Chrome Web Store install with its native approval is a distinct required check. Timeouts and forced cleanup fail acceptance.

AUDIT.md records exact successful source/run evidence. Earlier Alloy runs and upstream sample experiments do not certify the current implementation. Interactive clean-Mac input/accessibility, media and website acceptance complement automated tests; Developer ID credentials are an external release prerequisite.
