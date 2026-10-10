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
                HStack { Text("Chromium").font(.headline); Spacer(); Text(installed ? "Engine included" : "Optional engine").font(.caption).foregroundStyle(.secondary) }
                Text("Chromium uses Chrome browser services with Radius's native controls. Extensions remain within Chromium contexts; WebKit tabs use separate website data.").font(.callout).foregroundStyle(.secondary)
                Text(installed
                    ? "Chromium is part of this sealed application. Use Installation and updates to stage a verified WebKit-only installer and remove the engine after restarting; your website data is kept."
                    : "WebKit is available immediately. Use Installation and updates to add Chromium from an official release or a verified offline installer.")
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
        alert.informativeText = "All profile defaults and Chromium tabs will switch to WebKit. Website addresses reload in separate sign-in contexts; forms and unsaved work do not transfer. Generated pages become New tab. Tab organization and saved browser data are kept. You can then install the WebKit-only Radius package without reopening unavailable Chromium tabs."
        alert.addButton(withTitle: "Switch to WebKit"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        busy = true
        Task {
            defer { busy = false }
            app.prepareForChromiumRemoval()
            guard await app.flush() else { message = app.notice ?? "Could not save the engine change. Retry before restarting."; return }
            message = "All tabs now use WebKit. Use Installation and updates to stage a WebKit-only Radius installer."
        }
    }
}
