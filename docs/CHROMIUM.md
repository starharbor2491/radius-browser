# Chromium integration evidence

Radius currently has no embedded Chromium engine. Chromium installation, engine
switching, and Chrome extension compatibility must remain unavailable until a
real adapter and its distribution pass the gates below. An upstream CEF sample
running in a separate window does not make Chromium available inside Radius.

## Architectural finding

The stable CEF distribution inspected on 2026-10-09 is
`154.0.34+g14c5a08+chromium-154.0.8037.98`, from CEF commit
[`14c5a089e8452874cb1a556dc3fde26ed2d87723`](https://github.com/chromiumembedded/cef/commit/14c5a089e8452874cb1a556dc3fde26ed2d87723).

Its [macOS window definition](https://github.com/chromiumembedded/cef/blob/14c5a089e8452874cb1a556dc3fde26ed2d87723/include/internal/cef_types_mac.h)
states:

> Alloy style will always be used if `windowless_rendering_enabled` is true or if `parent_view` is provided.

This affects both obvious integration approaches: `CefWindowInfo.SetAsChild`
inside a Radius `NSView`, and off-screen presentation through a shared surface.
Neither is evidence that Chrome-style extension functionality survives in a
Radius tab. The upstream
[cefclient implementation](https://github.com/chromiumembedded/cef/blob/14c5a089e8452874cb1a556dc3fde26ed2d87723/tests/cefclient/browser/main_context_impl.cc)
explicitly changes native-parent macOS windows to Alloy style. Its referenced
[issue #3294](https://github.com/chromiumembedded/cef/issues/3294), "chrome: Add
support for embedded non-Views windows", was open when inspected.

[CEF's runtime-style header](https://github.com/chromiumembedded/cef/blob/14c5a089e8452874cb1a556dc3fde26ed2d87723/include/internal/cef_types_runtime.h)
distinguishes Chrome style, with Chrome UI and browser functionality, from Alloy
style, with fewer default browser services and off-screen rendering support.
The [architecture documentation](https://chromiumembedded.github.io/cef/architecture.html#cef3)
also explains that the old Alloy bootstrap was removed in M128. Consequently,
the fact that a current CEF process uses the Chrome bootstrap is insufficient
evidence of Chrome-style behavior. Old examples setting `chrome_runtime = true`
or passing `--enable-chrome-runtime` are not a solution to this macOS constraint.

There is no built-in `CEFWebView` that can be exchanged with `WKWebView`. CEF
requires a framework, helper application bundles, application event integration,
request-context ownership, asynchronous browser teardown, and sandbox setup.
The pinned upstream
[main application](https://github.com/chromiumembedded/cef/blob/14c5a089e8452874cb1a556dc3fde26ed2d87723/tests/cefsimple/cefsimple_mac.mm)
and [helper entry point](https://github.com/chromiumembedded/cef/blob/14c5a089e8452874cb1a556dc3fde26ed2d87723/tests/cefsimple/process_helper_mac.cc)
show these requirements. A speculative Swift wrapper around an undeclared CEF
module would add no functioning integration, so none is registered in Radius.

## Reproducible development proof

[`scripts/chromium-proof.py`](../scripts/chromium-proof.py) downloads a pinned
upstream standard distribution and verifies a checked-in SHA-256 digest. On a
Mac, it builds the upstream `cefclient.app` with its framework and helper apps,
requesting sandbox support. It can launch two distinct experiments with separate
persistent profile directories:

- `chrome`: a Chrome-style CEF Views window, the starting point for consumer
  extension investigation.
- `native-alloy`: an AppKit native-parent window with Alloy style, the starting
  point for native view-hosting investigation.

The script uses upstream's `OPTION_USE_ARC=OFF` for this pinned sample: its ARC
CMake block refers to `${target}` before defining the sample target. This selects
the sample's supported manual reference counting path; it does not change Radius's
Swift memory management.

This is developer tooling for stage 0. It is not Radius's consumer engine
installer and does not modify Radius or any existing browser profile.

The pinned CEF build instructions require Xcode 16+ on macOS 14.5+ and CMake
3.21+. Use Python with `tarfile.data_filter` support (Python 3.12+ is sufficient).
Run from the repository root on a Mac:

```sh
python3 scripts/chromium-proof.py build
python3 scripts/chromium-proof.py run --style chrome --url chrome://version
python3 scripts/chromium-proof.py run --style chrome --url https://chromewebstore.google.com/
python3 scripts/chromium-proof.py run --style native-alloy --url https://example.com/
```

The native CPU architecture is selected by default. Use `--arch arm64` or
`--arch x86_64` to select a distribution explicitly. Build and run commands fail
early on non-macOS hosts. Archive verification alone can run on Linux:

```sh
python3 scripts/chromium-proof.py fetch --arch arm64
python3 scripts/chromium-proof.py fetch --arch x86_64
```

Builds live under `.build/chromium-proof/`. A successful build writes
`build-<architecture>.json` with the artifact path and provenance. Its explicit
`false` fields record that compiling the upstream sample does not verify Radius
integration, extensions, or a signed distribution. Runtime diagnostics and
profile data remain under `profiles/<architecture>/<style>/` in that same
development directory. No command disables the sandbox, Gatekeeper, or TLS
verification. The script does not claim its development bundle is notarized.
Upstream `cefclient` also enables `use-mock-keychain` on macOS; its development
profile cannot establish that Radius credentials are protected by Keychain.

## Verification performed in this workspace

The available executor was Debian Linux x86_64. No macOS SDK, Xcode, macOS
execution endpoint, Developer ID identity, or notarization credentials were
configured. Installing the Linux Swift compiler can test portable Radius code;
it cannot compile or exercise AppKit, SwiftUI, or WebKit. Apple's
[Xcode requirements](https://developer.apple.com/support/xcode/) identify the
supported macOS build hosts. A macOS CI runner can compile the application after
the workflow is made available to it; that does not replace interactive tests
on a Mac or a signed clean-install proof.

Both macOS archives were downloaded over HTTPS from the
[CEF distribution service](https://cef-builds.spotifycdn.com/index.html), checked
against its published SHA-1 values, and independently hashed with SHA-256 for
the pinned script. The actual archives were inspected for the sample build
files and the macOS runtime-style restriction.

Both `fetch` commands passed against those archives. The `build` command on
Linux exited with a clear macOS requirement before downloading or creating a
build directory. The macOS compilation and launch paths have not been run here.

| Architecture | Archive bytes | Pinned SHA-256 |
| --- | ---: | --- |
| arm64 | 307,056,359 | `2e4a60880addad09c85d9ea27f4df09cb803069e1709377576e9cf62169648fe` |
| x86_64 | 354,938,950 | `b11f8b0d190541f167d0f66265c5017f2faf9b9d08790172732eb09accf00e40` |

SHA-256 pins fix the bytes used in this experiment. They are not a replacement
for publisher verification and signed package metadata in the future consumer
installer. The pinned release must also be reassessed for security updates
before distribution. No CEF binaries are vendored in this repository.

## What must be proved before registering Chromium

First choose a supported hosting arrangement. Candidates to investigate are a
CEF Views-owned Chrome-style window with an explicitly designed native shell
boundary, or a maintained CEF/Chromium change supporting the required native
parent. Neither candidate is implemented here. Cross-process control through
XPC and image transport through IOSurface do not themselves implement a usable
view-hosting bridge or lift the runtime-style restriction.

| Gate | Required evidence | Current result |
| --- | --- | --- |
| macOS build and lifecycle | Build both architectures; load framework/helpers; browse; close every browser; quit cleanly with sandbox enabled. | Not executed on macOS. |
| Native Radius hosting | Render inside the chosen Radius window architecture; verify IME, focus, shortcuts, VoiceOver, drag/drop, popups, fullscreen, media, and multiple displays. | Not implemented. Native-parent CEF limitation confirmed. |
| Consumer extension installation | Install from Chrome Web Store through its normal flow, without developer mode, unpacking, or command-line flags; restart; receive an extension update; remove it. | Not executed. |
| Manifest V3 behavior | Exercise service-worker restart, content scripts, permissions and revocation, action popup anchoring, side panels, storage, and the declared browser API matrix. | Not executed. |
| Context isolation | Keep each engine/profile/private context separate; confirm extensions cannot inspect unrelated WebKit or private tabs. | No Chromium adapter exists. |
| Controlled reopening | Preserve Radius tab placement and safe URL; warn and reload normally; never copy cookies, replay POSTs, or claim JavaScript-state transfer. | Blocked on a second working adapter. |
| Downloadable package | Signed publisher metadata, integrity checks, compatibility checks, Developer ID signing/notarization, clean-Mac install, update, removal, interrupted-update recovery. | Not implemented or verified. |
| Failure recovery | Kill renderer and host processes; preserve the native recovery interface; restore a working engine without silently downgrading to vulnerable code. | Not implemented for Chromium. |

Only passing gates justify changing the engine catalog from unavailable to
installable. A successful CEF window or a successful unpacked-extension test is
a useful intermediate result, but does not pass the consumer integration gates.
