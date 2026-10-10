// SPDX-License-Identifier: MPL-2.0
(async () => {
  const state = await chrome.storage.local.get({sidePanelOpened: 0});
  const count = state.sidePanelOpened + 1;
  await chrome.storage.local.set({sidePanelOpened: count});
  document.documentElement.dataset.radiusFixtureSidePanelOpened = String(count);
  document.getElementById("status").textContent = `Side panel loaded ${count} time(s).`;
})().catch(error => {
  document.documentElement.dataset.radiusFixtureError = String(error.message || error);
  document.getElementById("status").textContent = `Fixture error: ${error.message || error}`;
});
