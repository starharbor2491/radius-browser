# Chromium integration

The optional development variant embeds a pinned Chromium Embedded Framework (CEF) runtime inside the same native Radius application. The standard build uses system WebKit without a Chromium download. Engine settings identify the installed build variant; tabs can explicitly reopen in the other available engine, and profiles can select the engine for future tabs.

This is not the consumer engine installer or Chrome-extension support specified in PRODUCT_PLAN.md. Native validation results must be assessed against a successful workflow and its source commit; compiling the upstream sample does not establish Radius integration.

## Build the optional variant

On macOS 14.5+ with Xcode 16+, CMake 3.21+, and Python 3.12+:

```sh
python3 scripts/chromium-runtime.py --arch arm64 --work-dir .build/chromium-runtime
RADIUS_CHROMIUM_PACKAGE="$PWD/.build/chromium-runtime/Chromium-arm64.radiusengine" ./scripts/build-app.sh
open dist/Radius.app
```

Use `x86_64` on Intel. The application executable and resource workers are universal; the optional Chromium runtime is specific to the selected architecture. The CI artifacts identify their runtime architecture. The script verifies pinned archive bytes before extraction, builds the bridge and sandbox helpers, and signs the development package before the app is signed. No CEF binaries are vendored in this repository.

CEF's helper sandbox allows framework reads under the actual outer application bundle. An App Support framework cannot be made executable by setting CEF resource lookup paths. The build therefore embeds the runtime under `Contents/Frameworks/Chromium.radiusengine` before final signing. Radius does not rewrite its running signed application to install code. A consumer install/update/removal flow requires a separately designed signed application updater.

The native package seal protects its ABI/architecture/CEF metadata and code. Ad-hoc signatures verify package integrity, not publisher identity or notarization. These builds do not disable the sandbox, TLS verification, or Gatekeeper.

## Supported development behavior

The adapter hosts Chromium in a native `NSView` within Radius tabs. It has navigation, find, zoom, reader extraction, PNG capture, controlled popup adoption, explicit error recovery, per-profile persistent contexts, and separate in-memory contexts for each private window. WebKit and Chromium stores remain separate. Changing engines preserves the tab's position and safe HTTP/HTTPS URL, warns before reloading a page, and does not replay POST bodies or transfer generated pages or unsaved state.

CEF initialization, Cocoa event dispatch, request-context readiness, and asynchronous browser close/quit are integrated with the native app. Pending pages cancelled before context initialization are discarded safely. Renderer failure leaves native settings and recovery available. Website-data clearing requires Chromium to be shut down first.

Chromium downloads and camera/microphone access are unavailable in this development adapter. Downloads show a nonfatal message; media permissions are denied. Use WebKit for those capabilities. These limitations are disclosed in engine settings.

## Native hosting and Chrome extensions

The pinned distribution is `154.0.34+g14c5a08+chromium-154.0.8037.98`, from [CEF commit 14c5a08](https://github.com/chromiumembedded/cef/commit/14c5a089e8452874cb1a556dc3fde26ed2d87723).

Its [macOS window definition](https://github.com/chromiumembedded/cef/blob/14c5a089e8452874cb1a556dc3fde26ed2d87723/include/internal/cef_types_mac.h) states:

> Alloy style will always be used if `windowless_rendering_enabled` is true or if `parent_view` is provided.

The [cefclient implementation](https://github.com/chromiumembedded/cef/blob/14c5a089e8452874cb1a556dc3fde26ed2d87723/tests/cefclient/browser/main_context_impl.cc) applies this rule to native-parent macOS windows. [Issue #3294](https://github.com/chromiumembedded/cef/issues/3294), concerning Chrome-style non-Views embedding, was open when inspected. [CEF's runtime-style definition](https://github.com/chromiumembedded/cef/blob/14c5a089e8452874cb1a556dc3fde26ed2d87723/include/internal/cef_types_runtime.h) distinguishes Chrome's browser services from Alloy's smaller feature set. The [architecture documentation](https://chromiumembedded.github.io/cef/architecture.html#cef3) explains that the old Alloy bootstrap was removed in M128; current Chrome bootstrap alone does not confer Chrome-style extension behavior.

Radius uses supported native-parent Alloy hosting. Chrome Web Store installation, Manifest V3 APIs, extension updates, action popups, side panels, and permission revocation are not implemented or advertised. Off-screen rendering, XPC, IOSurface, or an old `chrome_runtime` flag do not remove the runtime-style restriction. Meeting the plan's extension requirements needs a supported Chrome-style hosting architecture or maintained upstream support.

## Reproducible evidence

The interactive executor is Linux. macOS compilation and runtime checks run through GitHub Actions on native ARM and Intel hosts. The `Verify embedded Chromium runtime` workflow builds the pinned runtime, tests the shell and real resource workers, packages Radius, and checks actual embedded browsing, HTTPS, reader, PNG capture, profile/private isolation, popup openers, browser closure, and ordinary application shutdown. A timeout or forced cleanup is failure. Provenance only marks Radius validation true after all those checks pass.

The separate [`scripts/chromium-proof.py`](../scripts/chromium-proof.py) experiment builds upstream Chrome-style Views and native Alloy samples. [Native sample run 37944960439](https://github.com/starharbor2491/radius-browser/actions/runs/37944960439) passed all four renderer/normal-quit probes on matching ARM/Intel hosts. These sample results do not establish Radius hosting, extensions, Keychain protection, or consumer distribution.

| Architecture | Archive bytes | Pinned SHA-256 |
| --- | ---: | --- |
| arm64 | 307,056,359 | `2e4a60880addad09c85d9ea27f4df09cb803069e1709377576e9cf62169648fe` |
| x86_64 | 354,938,950 | `b11f8b0d190541f167d0f66265c5017f2faf9b9d08790172732eb09accf00e40` |

## Remaining consumer gates

- Developer ID signing, hardened-runtime configuration, notarization, stapling, clean-Mac installation, and a signed updater with interrupted-update recovery.
- Consumer engine package installation/removal and offline installer parity.
- Chrome Web Store installation, extension restart/update/removal, Manifest V3 API and isolation acceptance checks.
- Interactive IME, focus, shortcuts, VoiceOver, drag/drop, fullscreen, media, and multiple-display checks.
- Broader website compatibility, renderer/host crash recovery, and measured performance and battery behavior.

No performance, extension compatibility, publisher trust, or completed consumer release claim follows from development CI alone.
