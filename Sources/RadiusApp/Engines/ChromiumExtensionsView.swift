// SPDX-License-Identifier: MPL-2.0
import AppKit
import SwiftUI
import RadiusCore

/// The native entry point selects a Radius profile. Chromium owns installation,
/// permission prompts, updates and extension configuration inside that profile.
struct ChromiumExtensionsView: View {
    var initialProfileID: UUID? = nil
    var onOpenSettings: (() -> Void)? = nil
    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var runtime = ChromiumRuntime.shared
    @StateObject private var downloads = DownloadCenter()
    @State private var profileID: UUID?
    @State private var tab: ChromiumTab?
    @State private var message: String?
    @State private var deferredProfileOpen = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Chromium extensions").font(.title2.bold())
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
                Picker("Profile", selection: $profileID) {
                    ForEach(app.library.profiles) { profile in
                        Text(profile.name).tag(Optional(profile.id))
                    }
                }.frame(maxWidth: 250)
            }
            Text("Extensions belong to the selected Chromium profile. WebKit and private windows use separate website stores and do not run these extensions.")
                .font(.callout).foregroundStyle(.secondary)
            if runtime.isInstalled(in: app.dataDirectory) {
                HStack {
                    Button("Installed extensions") { tab?.showExtensions() }
                    Button("Chrome Web Store") { tab?.load(URL(string: "https://chromewebstore.google.com/")!) }
                    Spacer()
                    Text("Actions and popups appear in each Chromium pane’s toolbar.").font(.caption).foregroundStyle(.secondary)
                }.disabled(tab == nil || tab?.profileID != profileID || app.terminating || app.finalQuitDataFrozen)
                if let tab, tab.profileID == profileID {
                    ChromiumExtensionContent(tab: tab).id(ObjectIdentifier(tab))
                } else if let message {
                    ContentUnavailableView {
                        Label("Extensions could not open", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(message)
                    } actions: {
                        Button("Retry", action: openProfile)
                    }
                } else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
            } else {
                ContentUnavailableView("Chromium is not installed", systemImage: "puzzlepiece.extension",
                                       description: Text("Install Chromium in Browsing engines, then return here to manage extensions."))
                if let onOpenSettings { Button("Open browsing engine settings", action: onOpenSettings) }
            }
            if let tab, tab.profileID == profileID, let message { Text(message).font(.callout).foregroundStyle(.secondary) }
            Text("Compatibility target: Manifest V3 content scripts, background service workers, scripting, storage, permissions, actions and popups, options and side panels. Each Chromium browsing pane has Chrome's own tabs and extension toolbar. Compatibility varies by extension.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(20).frame(minWidth: 760, minHeight: 560)
        .onAppear { if profileID == nil { profileID = app.library.profiles.first(where: { $0.id == initialProfileID })?.id ?? app.library.profiles.first?.id } }
        .onChange(of: profileID) { _, _ in openProfile() }
        .onChange(of: app.terminating || app.finalQuitDataFrozen) { _, busy in
            if !busy, deferredProfileOpen { openProfile() }
        }
        .onChange(of: app.library.profiles.map(\.id)) { _, ids in
            if let profileID, !ids.contains(profileID) { self.profileID = ids.first }
        }
        .onReceive(NotificationCenter.default.publisher(for: .radiusChromiumProfileClosed)) { notification in
            guard notification.object as? UUID == profileID else { return }
            tab?.dispose(); tab = nil
            profileID = app.library.profiles.first { $0.id != profileID }?.id
        }
        .onDisappear { deferredProfileOpen = false; tab?.dispose(); tab = nil }
        .onExitCommand { dismiss() }
    }
    private func openProfile() {
        if let tab, tab.profileID != profileID {
            tab.dispose(); self.tab = nil; message = nil
        }
        guard !app.terminating, !app.finalQuitDataFrozen else {
            deferredProfileOpen = true; return
        }
        deferredProfileOpen = false
        tab?.dispose(); tab = nil; message = nil
        guard let profileID, app.library.profiles.contains(where: { $0.id == profileID }) else {
            message = "Choose an available profile to manage its extensions."; return
        }
        guard !app.deletingProfileIDs.contains(profileID) else {
            message = "This profile is being deleted. Retry if deletion is cancelled."; return
        }
        guard runtime.isInstalled(in: app.dataDirectory) else { return }
        do {
            let page = try runtime.makeTab(profileID: profileID, privateSessionID: nil,
                                           dataDirectory: app.dataDirectory, downloads: downloads)
            page.onNotice = { message = $0 }
            page.onClose = { [weak page] in
                guard let page, tab === page else { return }
                tab = nil; dismiss()
            }
            page.onBrowserCommand = { [weak page] command in
                switch command {
                case "closeTab", "closeWindow": dismiss()
                case "extensions": page?.showExtensions()
                case "quit": NSApp.terminate(nil)
                default: break
                }
            }
            page.showExtensions()
            tab = page
        } catch { message = error.localizedDescription }
    }
}

private struct ChromiumExtensionContent: View {
    @ObservedObject var tab: ChromiumTab
    var body: some View {
        ZStack {
            WebViewHost(tab: tab)
            if let error = tab.errorMessage {
                ContentUnavailableView("Extensions could not open", systemImage: "exclamationmark.triangle",
                                       description: Text(error))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityLabel("Chromium extension management")
    }
}
