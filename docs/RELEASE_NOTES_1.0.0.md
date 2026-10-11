Radius 1.0.0 for macOS 14 or later. The Chromium installers include the complete native CEF runtime, five sandbox helper variants, framework resources, license notices, updater helpers, and all 18 default modules. WebKit is available in every installer through the macOS system framework. No Homebrew, Xcode, package manager, or additional engine download is required to use the installed app.

| Mac | Complete installer |
| --- | --- |
| Apple Silicon (M-series) | `Radius-1.0.0-Chromium-arm64-development.dmg` |
| Intel | `Radius-1.0.0-Chromium-x86_64-development.dmg` |
| Either CPU, WebKit only | `Radius-1.0.0-WebKit-universal-development.dmg` |

Open the matching DMG, drag Radius into Applications, eject the disk image, and open Radius. Select the default engine in **Settings → Browsing engines**. Existing profile data, layouts, and module choices remain outside the application bundle.

These builds are ad-hoc signed and **not notarized**. If macOS blocks Radius, review the source and checksum, then use **System Settings → Privacy & Security → Open Anyway** and confirm **Open**. The trusted in-app updater remains unavailable until Developer ID signing is configured. This release is marked prerelease to identify that distribution limitation.

The app includes profiles/private windows, normal Chrome tabs and extension management, WebKit browsing, downloads/bookmarks/history, split panes, resource monitoring, Reader, Notes/Capture/Focus, graphical module management, four appearance systems, and layout customization.

The DMGs are the exact accepted files from [WebKit/native CI](https://github.com/starharbor2491/radius-browser/actions/runs/38089121425) and [Chromium Apple Silicon/Intel CI](https://github.com/starharbor2491/radius-browser/actions/runs/38089121427). Their executable source is `f91a8c4c2779fd21795711438c4da0f2ea15c701`; the merged release source changes only documentation afterward. Installed acceptance verifies sealed copies, detached launch, ordinary quit, helper exit, app removal, and preserved external data. Both Chromium variants additionally pass genuine Chrome Web Store installation and full-process extension persistence/removal.

`SHA256SUMS` covers every attached payload. Package metadata and `Radius-1.0.0-installation-receipts.json` record the architectures, modules, hashes, tested source, workflows, and installed checks. [Installation details](https://github.com/starharbor2491/radius-browser/blob/main/docs/DISTRIBUTION.md) and [acceptance evidence](https://github.com/starharbor2491/radius-browser/blob/main/docs/AUDIT.md) are in the repository.
