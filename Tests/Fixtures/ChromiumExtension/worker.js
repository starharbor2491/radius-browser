// SPDX-License-Identifier: MPL-2.0
// Serialize ping counters without delaying gesture-sensitive open operations.
let pingQueue = Promise.resolve();

function ping(tabId) {
  const result = pingQueue.then(async () => {
    const manifest = chrome.runtime.getManifest();
    const state = await chrome.storage.local.get({pingCount: 0, theme: "light"});
    const pingCount = state.pingCount + 1;
    const results = await chrome.scripting.executeScript({
      target: {tabId},
      func: () => {
        document.documentElement.dataset.radiusFixtureScripting = "ready";
        return location.href;
      }
    });
    await chrome.storage.local.set({
      pingCount,
      theme: state.theme,
      manifestVersion: manifest.manifest_version,
      extensionVersion: manifest.version
    });
    return {
      ok: true,
      manifestVersion: manifest.manifest_version,
      extensionVersion: manifest.version,
      pingCount,
      scriptedURL: results[0].result
    };
  });
  pingQueue = result.catch(() => {});
  return result;
}

chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (sender.id !== chrome.runtime.id || message?.source !== "radius-fixture") {
    return false;
  }
  const tabId = sender.tab?.id;
  let source;
  try {
    source = new URL(sender.url);
  } catch {
    return false;
  }
  if (!Number.isInteger(tabId) || source.protocol !== "http:" ||
      source.hostname !== "127.0.0.1") {
    return false;
  }

  let operation;
  switch (message.command) {
    case "ping":
      operation = ping(tabId);
      break;
    case "openPopup":
      // Start immediately in the message event's user-gesture context.
      operation = chrome.action.openPopup({windowId: sender.tab.windowId})
          .then(() => ({ok: true}));
      break;
    case "openSidePanel":
      operation = chrome.sidePanel.open({tabId}).then(() => ({ok: true}));
      break;
    default:
      sendResponse({ok: false, error: "Unknown fixture command"});
      return false;
  }
  operation.then(sendResponse, error => sendResponse({
    ok: false,
    error: String(error.message || error)
  }));
  return true;
});
