// SPDX-License-Identifier: MPL-2.0
import AppKit
import SwiftUI
import RadiusCore

struct ChromiumSettingsView: View {
    let dataDirectory: URL
    @EnvironmentObject private var app: AppState
    @ObservedObject private var runtime = ChromiumRuntime.shared
    @State private var busy = false
    @State private var installed = false
    @State private var message: String?
    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack { Text("Chromium Alloy").font(.headline); Spacer(); Text(installed ? "Development runtime installed" : "Optional development runtime").font(.caption).foregroundStyle(.secondary) }
                Text("An embedded Chromium engine for Radius's native controls. Chrome extensions, downloads, and camera/microphone capture are not supported by this development adapter.").font(.callout).foregroundStyle(.secondary)
                HStack {
                    Button(installed ? "Replace runtime…" : "Install runtime…") { choosePackage() }.disabled(busy || runtime.isLoaded)
                    if installed {
                        Button(runtime.isLoaded ? "Prepare to remove…" : "Remove runtime…") {
                            if runtime.isLoaded || referencesChromium { prepareForRemoval() } else { remove() }
                        }.disabled(busy)
                    }
                    if busy { ProgressView().controlSize(.small) }
                }
                if runtime.isLoaded { Text("Restart Radius with WebKit selected before changing the runtime.").font(.caption).foregroundStyle(.secondary) }
                if let message { Text(message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }.padding(8)
        }.onAppear { installed = runtime.isInstalled(in: dataDirectory) }
    }
    private func choosePackage() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.treatsFilePackagesAsDirectories = false; panel.allowsMultipleSelection = false
        panel.message = "Choose a Chromium.radiusengine development package built with Radius's runtime build script."
        guard panel.runModal() == .OK, let source = panel.url else { return }
        let alert = NSAlert(); alert.messageText = "Install this development runtime?"
        alert.informativeText = "This package contains native code that will run inside Radius. Install only a package you built yourself or obtained from a trusted developer. File checks verify integrity, not publisher identity."
        alert.addButton(withTitle: "Install trusted runtime"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        busy = true
        Task {
            defer { busy = false; installed = runtime.isInstalled(in: dataDirectory) }
            do { try await runtime.install(from: source, dataDirectory: dataDirectory); message = runtime.status }
            catch { message = error.localizedDescription }
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
        let alert = NSAlert(); alert.messageText = "Switch Chromium tabs to WebKit before removal?"
        alert.informativeText = "All profile defaults and Chromium tabs will switch to WebKit. Website addresses reload in separate sign-in contexts; forms and unsaved work do not transfer. Generated pages become New tab. Tab organization and saved browser data are kept. If Chromium is loaded, restart Radius afterward, then remove its runtime here."
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
            if runtime.isLoaded { message = "All tabs now use WebKit. Restart Radius, then return here to remove the Chromium runtime." }
            else { remove() }
        }
    }
    private func remove() {
        let alert = NSAlert(); alert.messageText = "Remove the Chromium runtime?"
        alert.informativeText = "Tabs configured for Chromium will be unavailable until you reinstall it or reopen them in WebKit. Chromium profile website data is kept."
        alert.addButton(withTitle: "Remove runtime"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do { try runtime.uninstall(dataDirectory: dataDirectory); installed = false; message = runtime.status }
        catch { message = error.localizedDescription }
    }
}
