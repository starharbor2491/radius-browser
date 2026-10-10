# Chromium integration

Radius embeds Chromium browser services through CEF Chrome-style Views. WebKit remains available without the optional engine. Settings, Modules, Customize and Recovery are native and remain usable independently of either engine.

## Supported architecture

Each Chromium pane contains a `CefBrowserView` in a frameless `CefWindow`. Its Cocoa window is attached as a child of the owning Radius window and tracks the native placeholder view's screen coordinates and visibility. Radius never sets `parent_view` or reparents Chrome's internal views: CEF forces native-parent hosting into Alloy, which lacks the required Chrome browser services.

The complete Chrome toolbar remains visible for site identity, navigation, extension actions and popups. Radius suppresses duplicate outer navigation controls and routes focus/shortcuts to the active Chromium pane. Each pane appears to Chrome extension APIs as a separate window. Pages opened by extension browser APIs retain their existing native Chrome WebContents/window rather than losing identity in a URL reload; Radius tracks those auxiliary windows through downloads, profile deletion and shutdown.

The bridge ABI and sealed engine manifest are version 2; `runtimeStyle` must be `chrome`. Older Alloy packages are rejected. The pinned CEF distribution is `154.0.34+g14c5a08+chromium-154.0.8037.98`, [commit 14c5a08](https://github.com/chromiumembedded/cef/commit/14c5a089e8452874cb1a556dc3fde26ed2d87723). Source, helpers, sandbox initialization and archive digests are reproducible in the build scripts.

## Extensions and privacy

The native extension sheet selects a normal Radius profile and opens Chromium's own manager or Chrome Web Store. Chromium controls extension installation, permission prompts, updates, disabling and removal. The supported MV3 target includes content scripts, background service workers, scripting, storage, declared permissions, action popups, options and side panels. Extensions that assume Chrome's tab/window organization may behave differently. This is a compatibility target, not a promise that every extension works.

Persistent Chromium contexts are separate for each Radius profile. Every private Radius window has a separate in-memory context; regular-profile extensions and cookies do not leak into it. WebKit stores are independent. Switching engines preserves tab organization and safe HTTP/HTTPS addresses, reloads explicitly, and does not transfer cookies, POST bodies, forms or JavaScript state.

Downloads use Radius's native destination/replace/cancel controls. Chromium extension installation retains Chromium's own CRX handling. Media uses the native permission path and platform usage descriptions. Cancellation waits for the writer to stop before deleting staging files; failures retain staging safely for recovery. Ordinary quit tracks both Radius tabs and auxiliary/manager pages and waits for asynchronous browser closure.

Reader captures in an isolated DevTools world and passes bounded HTML to the removable worker. Capture returns bounded viewport PNG bytes to a bounded behavior package's native save flow. There is no listening remote-debugging port.

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
