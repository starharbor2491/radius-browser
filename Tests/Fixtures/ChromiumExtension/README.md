# Radius Chromium extension fixture

This unpacked Manifest V3 extension exercises selected APIs in the pinned
Chromium runtime using a local `http://127.0.0.1/` test page. Loading it unpacked
does not prove Chrome Web Store installation, install permission prompts,
extension update delivery, compatibility with other extensions, or a completed
consumer release. Those require separate evidence.

The fixed public manifest key gives this fixture the extension ID
`pomncmnnjempbbdlbamhjphmpidacofc`. No private signing key is stored. Use a fresh
persistent browser profile for a clean run; keep that profile for restart and
storage persistence checks. The host pattern matches any localhost port.

On a matching page, read the markers on `document.documentElement.dataset`:

| Marker | Meaning |
| --- | --- |
| `radiusFixtureContent` | `ready` after content-script initialization. |
| `radiusFixtureExtensionId` | The fixed extension ID above. |
| `radiusFixtureWorker` | `ready` after a service-worker response and storage read; `error` on failure. |
| `radiusFixtureManifestVersion` | `3`, obtained from the worker's manifest. |
| `radiusFixtureVersion` | `1.0.0`, obtained from the worker's manifest. |
| `radiusFixtureScripting` | `ready` after the worker calls `chrome.scripting.executeScript`. |
| `radiusFixtureCount` | Persisted `storage.local.pingCount`, incremented by each document's worker ping. |
| `radiusFixtureActionOpened` | Number of actual popup-document loads recorded by `popup.js`. |
| `radiusFixtureSidePanelOpened` | Number of actual side-panel-document loads recorded by `sidepanel.js`. |
| `radiusFixtureTheme` | Persisted theme preference, `light` or `dark`. |
| `radiusFixtureError` | API failure message, when present. |

Click `#radius-fixture-action` with a browser input event to request
`chrome.action.openPopup()`. Require its `radiusFixtureActionOpened` counter to
increase; a successful request alone is insufficient. The separate
`radiusFixtureActionState` marker reports `pending`, `opened`, or `error` for the
request.

Click `#radius-fixture-sidepanel` with a browser input event to request
`chrome.sidePanel.open({tabId: sender.tab.id})`. A new panel document increments
`radiusFixtureSidePanelOpened`; reopening an existing panel may reuse its
document. `radiusFixtureSidePanelState` reports the request result using the same
three states. Capture the native browser window to verify the popup and panel
are visibly hosted correctly. These storage markers demonstrate document
execution and do not by themselves prove visibility or correct positioning.

Open extension settings via the extension manager or
`chrome-extension://pomncmnnjempbbdlbamhjphmpidacofc/options.html`. Wait for
`radiusFixtureOptionsState === "ready"`, click the standard HTML checkbox
`#nativecheckbox`, and wait for `radiusFixtureOptionsState === "saved"`. The
preference is stored as `storage.local.theme`; the local test page observes its
change through `chrome.storage.onChanged`. Reload/restart to check persistence.

The declared permissions are `storage`, `activeTab`, `scripting`, and `sidePanel`.
The scripting test uses the explicit localhost host permission, so it does not
independently establish the `activeTab` grant/revocation lifecycle. No external
network endpoint or browser security override is used by the fixture. Action
and side-panel calls run immediately in the worker message listener to preserve
the input event's gesture context; failures remain visible in the markers.
