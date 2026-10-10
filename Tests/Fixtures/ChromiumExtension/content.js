// SPDX-License-Identifier: MPL-2.0
(() => {
  const root = document.documentElement;
  if (root.dataset.radiusFixtureContent === "ready") return;
  root.dataset.radiusFixtureContent = "ready";
  root.dataset.radiusFixtureExtensionId = chrome.runtime.id;
  root.dataset.radiusFixtureWorker = "pending";

  function reportError(error) {
    root.dataset.radiusFixtureError = String(error.message || error);
  }

  function reflectStorage(state) {
    root.dataset.radiusFixtureCount = String(state.pingCount ?? 0);
    root.dataset.radiusFixtureActionOpened = String(state.actionOpened ?? 0);
    root.dataset.radiusFixtureSidePanelOpened = String(state.sidePanelOpened ?? 0);
    root.dataset.radiusFixtureTheme = state.theme ?? "light";
  }

  async function refreshStorage() {
    reflectStorage(await chrome.storage.local.get([
      "pingCount", "actionOpened", "sidePanelOpened", "theme"
    ]));
  }

  async function command(name) {
    const response = await chrome.runtime.sendMessage({
      source: "radius-fixture", command: name
    });
    if (!response?.ok) throw new Error(response?.error || "No worker response");
    return response;
  }

  const controls = document.createElement("section");
  controls.id = "radius-fixture-controls";
  controls.setAttribute("aria-label", "Radius extension test controls");
  controls.style.cssText = "position:fixed;bottom:12px;right:12px;z-index:2147483647;" +
      "display:flex;gap:8px;padding:12px;background:white;color:black;" +
      "border:1px solid #777;border-radius:6px;font:14px system-ui";

  function addButton(id, label, name, marker) {
    const button = document.createElement("button");
    button.id = id;
    button.type = "button";
    button.textContent = label;
    button.addEventListener("click", () => {
      root.dataset[marker] = "pending";
      // Do not await storage or any other work before forwarding the gesture.
      command(name).then(() => {
        root.dataset[marker] = "opened";
      }, error => {
        root.dataset[marker] = "error";
        reportError(error);
      });
    });
    controls.append(button);
  }

  addButton("radius-fixture-action", "Open fixture action", "openPopup",
      "radiusFixtureActionState");
  addButton("radius-fixture-sidepanel", "Open fixture side panel", "openSidePanel",
      "radiusFixtureSidePanelState");
  document.body.append(controls);

  chrome.storage.onChanged.addListener((_changes, areaName) => {
    if (areaName === "local") refreshStorage().catch(reportError);
  });

  refreshStorage().catch(reportError);
  command("ping").then(async response => {
    root.dataset.radiusFixtureManifestVersion = String(response.manifestVersion);
    root.dataset.radiusFixtureVersion = response.extensionVersion;
    await refreshStorage();
    root.dataset.radiusFixtureWorker = "ready";
  }, error => {
    root.dataset.radiusFixtureWorker = "error";
    reportError(error);
  }).catch(error => {
    root.dataset.radiusFixtureWorker = "error";
    reportError(error);
  });
})();
