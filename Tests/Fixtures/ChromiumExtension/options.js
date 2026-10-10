// SPDX-License-Identifier: MPL-2.0
const checkbox = document.getElementById("nativecheckbox");
const status = document.getElementById("status");
const root = document.documentElement;

function showTheme(theme) {
  checkbox.checked = theme === "dark";
  root.dataset.radiusFixtureTheme = theme;
  status.textContent = `Saved theme: ${theme}.`;
}

function showError(error) {
  root.dataset.radiusFixtureError = String(error.message || error);
  status.textContent = `Fixture error: ${error.message || error}`;
}

chrome.storage.local.get({theme: "light"}).then(state => {
  showTheme(state.theme);
  checkbox.disabled = false;
  root.dataset.radiusFixtureOptionsState = "ready";
}, showError);

checkbox.addEventListener("change", () => {
  const theme = checkbox.checked ? "dark" : "light";
  root.dataset.radiusFixtureOptionsState = "saving";
  chrome.storage.local.set({theme}).then(() => {
    showTheme(theme);
    root.dataset.radiusFixtureOptionsState = "saved";
  }, showError);
});

chrome.storage.onChanged.addListener((changes, areaName) => {
  if (areaName === "local" && changes.theme) {
    showTheme(changes.theme.newValue ?? "light");
  }
});
