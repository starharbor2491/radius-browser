// SPDX-License-Identifier: MPL-2.0
(async () => {
  const state = await chrome.storage.local.get({actionOpened: 0});
  const count = state.actionOpened + 1;
  await chrome.storage.local.set({actionOpened: count});
  document.documentElement.dataset.radiusFixtureActionOpened = String(count);
  document.getElementById("status").textContent = `Action popup opened ${count} time(s).`;
})().catch(error => {
  document.documentElement.dataset.radiusFixtureError = String(error.message || error);
  document.getElementById("status").textContent = `Fixture error: ${error.message || error}`;
});
