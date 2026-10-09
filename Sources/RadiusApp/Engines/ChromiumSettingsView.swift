// SPDX-License-Identifier: MPL-2.0
import AppKit
import SwiftUI
import RadiusCore

struct ChromiumSettingsView: View {
    let dataDirectory: URL
    @EnvironmentObject private var app: AppState
    @ObservedObject private var runtime = ChromiumRuntime.shared
    @State private var busy = false
    private var installed: Bool { runtime.isInstalled(in: dataDirectory) }
    @State private var message: String?
    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack { Text("Chromium Alloy").font(.headline); Spacer(); Text(installed ? "Development runtime installed" : "Optional development runtime").font(.caption).foregroundStyle(.secondary) }
                Text("An embedded Chromium engine for Radius's native controls. Chrome extensions, downloads, and camera/microphone capture are not supported by this development adapter.").font(.callout).foregroundStyle(.secondary)
                Text(installed
                    ? "This development app includes Chromium. To remove its runtime, use the standard Radius app build; your website data is kept."
                    : "This is the standard WebKit build. Chromium requires the optional development app built with its runtime inside the signed app bundle.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if referencesChromium {
                    Button("Use WebKit for all tabs…") { prepareForRemoval() }.disabled(busy)
                }
                if busy { ProgressView().controlSize(.small) }
                if let message { Text(message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }.padding(8)
        }
    }
    private var referencesChromium: Bool {
        app.library.profiles.contains { $0.engineID == .chromium } ||
        app.library.sessions.contains { $0.tabs.contains { $0.engineID == .chromium } } ||
        app.windows.values.compactMap(\.model).contains { model in
            model.session.tabs.contains { $0.engineID == .chromium } || model.closedTabs.contains { $0.engineID == .chromium }
        }
    }
    private func prepareForRemoval() {
        let alert = NSAlert(); alert.messageText = "Switch all Chromium tabs to WebKit?"
        alert.informativeText = "All profile defaults and Chromium tabs will switch to WebKit. Website addresses reload in separate sign-in contexts; forms and unsaved work do not transfer. Generated pages become New tab. Tab organization and saved browser data are kept. You can then use the standard Radius app build without reopening unavailable Chromium tabs."
        alert.addButton(withTitle: "Switch to WebKit"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        busy = true
        Task {
            defer { busy = false }
            for index in app.library.profiles.indices { app.library.profiles[index].engineID = .webkit }
            for sessionIndex in app.library.sessions.indices {
                for tabIndex in app.library.sessions[sessionIndex].tabs.indices {
                    let tab = app.library.sessions[sessionIndex].tabs[tabIndex]
                    guard tab.engineID == .chromium else { continue }
                    app.library.sessions[sessionIndex].tabs[tabIndex].engineID = .webkit
                    if let url = tab.url, !AddressResolver.isWebURL(url) {
                        app.library.sessions[sessionIndex].tabs[tabIndex].url = nil
                        app.library.sessions[sessionIndex].tabs[tabIndex].title = "New tab"
                    }
                }
            }
            for model in app.windows.values.compactMap(\.model) {
                for descriptor in model.session.tabs where descriptor.engineID == .chromium {
                    if let url = descriptor.url, !AddressResolver.isWebURL(url),
                       let index = model.session.tabs.firstIndex(where: { $0.id == descriptor.id }) {
                        model.session.tabs[index].url = nil; model.session.tabs[index].title = "New tab"
                    }
                    model.changeEngine(descriptor.id, to: .webkit)
                }
                for index in model.closedTabs.indices { model.closedTabs[index].engineID = .webkit }
                model.address = model.selectedTab.url?.absoluteString ?? ""
            }
            guard await app.flush() else { message = app.notice ?? "Could not save the engine change. Retry before restarting."; return }
            message = "All tabs now use WebKit. Quit this app before opening the standard Radius build."
        }
    }
}
