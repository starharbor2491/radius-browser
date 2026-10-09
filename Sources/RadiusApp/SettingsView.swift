// SPDX-License-Identifier: MPL-2.0
import AppKit
import SwiftUI
@preconcurrency import WebKit
import RadiusCore

struct SettingsView: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: BrowserModel
    @State private var section = SettingsSection.general
    @State private var profileName = ""
    @State private var clearing = false
    @ObservedObject private var chromiumRuntime = ChromiumRuntime.shared
    enum SettingsSection: String, CaseIterable, Identifiable {
        case general = "General", profiles = "Profiles", privacy = "Privacy", engines = "Browsing engines"
        var id: Self { self }
        var icon: String { switch self { case .general: "gearshape"; case .profiles: "person.crop.circle"; case .privacy: "hand.raised"; case .engines: "globe" } }
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                List(SettingsSection.allCases, selection: $section) { item in Label(item.rawValue, systemImage: item.icon).tag(item) }
                    .listStyle(.sidebar).frame(width: 180)
                Divider()
                VStack(alignment: .leading, spacing: 16) {
                    Text(section.rawValue).font(.title2.weight(.semibold))
                    switch section { case .general: general; case .profiles: profiles; case .privacy: privacy; case .engines: engines }
                }.padding(24).frame(maxWidth: .infinity)
            }
            Divider()
            HStack { if let notice = app.notice { Text(notice).font(.caption).foregroundStyle(.secondary).lineLimit(3) }; Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }.padding(16)
        }.frame(width: 780, height: 590)
    }
    private var general: some View {
        Form {
            Section {
                Picker("Search engine", selection: preference(\.search)) { ForEach(SearchProvider.allCases, id: \.self) { Text($0.label).tag($0) } }
                Toggle("Restore tabs when Radius opens", isOn: preference(\.restoreSession))
                Toggle("Block unsolicited pop-ups", isOn: preference(\.blockPopups))
            }
            Section {
                Text("⌘L  Address     ⌘T  New tab     ⌘W  Close tab\n⌘R  Reload       ⌘F  Find          ⌘D  Bookmark\n⌘⇧T  Reopen closed tab     ⌘⇧N  Private window")
                    .font(.callout).foregroundStyle(.secondary).lineSpacing(8)
            } header: { Text("Keyboard shortcuts") }
        }.formStyle(.grouped)
    }
    private var profiles: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Each profile has separate bookmarks, history, notes, and website storage. Private windows use temporary website storage.").foregroundStyle(.secondary)
            List(app.library.profiles) { profile in
                HStack {
                    TextField("Profile name", text: profileBinding(profile.id)).textFieldStyle(.plain)
                    if profile.id == model.session.profileID { Text("Current").font(.caption).foregroundStyle(.secondary) }
                    else { Button("Switch") { model.switchProfile(profile.id) } }
                }.padding(.vertical, 5)
            }.listStyle(.inset)
            HStack {
                TextField("New profile name", text: $profileName).textFieldStyle(.roundedBorder)
                Button("Add profile") {
                    let name = profileName.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !name.isEmpty, app.library.profiles.count < 20 else { return }
                    app.library.profiles.append(Profile(name: String(name.prefix(80)))); profileName = ""
                }.disabled(profileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || app.library.profiles.count >= 20)
            }
            Text("Switching profiles reloads open pages and keeps sign-ins separate.").font(.caption).foregroundStyle(.secondary)
        }
    }
    private var privacy: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Data for \(model.profile.name)").font(.headline)
            Text("Browser data stays on this Mac. Radius has no analytics or cloud sync. Websites make their own network requests.").foregroundStyle(.secondary)
            GroupBox {
                VStack(alignment: .leading, spacing: 14) {
                    HStack { VStack(alignment: .leading) { Text("Browsing history"); Text("\(app.library.history.filter { $0.profileID == model.session.profileID }.count) saved visits").font(.caption).foregroundStyle(.secondary) }; Spacer(); Button("Clear…") { clearHistory() } }
                    Divider()
                    HStack { VStack(alignment: .leading) { Text("Cookies and website data"); Text("Signs you out of websites in this profile").font(.caption).foregroundStyle(.secondary) }; Spacer(); Button(clearing ? "Clearing…" : "Clear…") { clearWebsiteData() }.disabled(clearing) }
                }.padding(8)
            }
            Text("Private browsing avoids saving history and tabs. Saved downloads remain on disk. It does not hide activity from websites, employers, or network providers.").font(.callout).foregroundStyle(.secondary)
            Text("Radius metadata uses SQLite and is protected by your Mac's file permissions and disk encryption settings. This build does not store passwords or claim database-level encryption.").font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
    }
    private var engines: some View {
        ScrollView { VStack(alignment: .leading, spacing: 20) {
            Text("Choose the engine that displays websites. Your browser controls and recovery stay available independently.").foregroundStyle(.secondary)
            GroupBox {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: "globe").font(.title2)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("System WebKit").font(.headline)
                        Text("Available with macOS · No additional download").font(.caption).foregroundStyle(.secondary)
                        Text("Safari's platform web engine. Security updates arrive through macOS updates. Chrome extensions are not supported by this Radius build.").font(.callout).foregroundStyle(.secondary)
                    }
                }.padding(8)
            }
            ChromiumSettingsView(dataDirectory: app.dataDirectory)
            Picker("Default for new tabs in \(model.profile.name)", selection: Binding(get: { model.profile.engineID ?? .webkit }, set: { engine in
                guard let index = app.library.profiles.firstIndex(where: { $0.id == model.session.profileID }) else { return }
                app.library.profiles[index].engineID = engine
            })) {
                Text("WebKit").tag(BrowserEngineID.webkit)
                Text(chromiumRuntime.isInstalled(in: app.dataDirectory) ? "Chromium Alloy" : "Chromium Alloy (unavailable)").tag(BrowserEngineID.chromium).disabled(!chromiumRuntime.isInstalled(in: app.dataDirectory))
            }
            Text("Existing tabs keep their engine. Use a tab's context menu to reopen it in another engine.").font(.caption).foregroundStyle(.secondary)
            Link("Engine compatibility and release status", destination: URL(string: "https://github.com/starharbor2491/radius-browser/blob/codex/radius-v1/docs/CHROMIUM.md")!)
            Text("A required engine can be removed only after a compatible replacement is installed. Apple's system WebKit framework is part of macOS.").font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading) }
    }
    private func preference<T>(_ path: WritableKeyPath<Preferences, T>) -> Binding<T> {
        Binding(get: { app.library.preferences[keyPath: path] }, set: { app.library.preferences[keyPath: path] = $0 })
    }
    private func profileBinding(_ id: UUID) -> Binding<String> {
        Binding(get: { app.library.profiles.first { $0.id == id }?.name ?? "" }, set: { value in
            guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let index = app.library.profiles.firstIndex(where: { $0.id == id }) else { return }
            app.library.profiles[index].name = String(value.prefix(80))
        })
    }
    private func clearHistory() {
        let alert = NSAlert(); alert.messageText = "Clear history for \(model.profile.name)?"; alert.informativeText = "Bookmarks, notes, and other profiles are kept. This cannot be undone."
        alert.addButton(withTitle: "Clear history"); alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { app.library.history.removeAll { $0.profileID == model.session.profileID } }
    }
    private func clearWebsiteData() {
        guard !model.isPrivate else { app.notice = "Close this private window to discard its temporary website storage."; return }
        let alert = NSAlert(); alert.messageText = "Clear website data for \(model.profile.name)?"
        alert.informativeText = "Cookies, caches, and local databases in both WebKit and Chromium will be cleared for this profile. You will be signed out. Close other windows using this profile first. Unsaved page work may be lost."
        alert.addButton(withTitle: "Clear website data"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        clearing = true
        let profileID = model.session.profileID
        let profileName = model.profile.name
        Task {
            defer { clearing = false }
            do {
                try await ChromiumRuntime.shared.clearWebsiteData(profileID: profileID, dataDirectory: app.dataDirectory)
                let store = WKWebsiteDataStore(forIdentifier: profileID)
                await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
                if model.session.profileID == profileID { model.activeWebTab.reload() }
                app.notice = "Website data for \(profileName) was cleared."
            } catch { app.notice = error.localizedDescription }
        }
    }
}
