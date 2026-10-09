// SPDX-License-Identifier: MPL-2.0
import AppKit
import SwiftUI
@preconcurrency import WebKit
import RadiusCore

@MainActor
final class BrowserModel: ObservableObject {
    @Published var session: WindowSession { didSet { if !isPrivate { app.updateSession(session) } } }
    @Published var panel: BrowserPanel? = nil
    @Published var address = ""
    var addressEditing = false
    @Published var focusMode = false
    @Published var sheet: BrowserSheet?
    @Published var closedTabs: [BrowserTab] = []
    let isPrivate: Bool
    let app: AppState
    let downloads = DownloadCenter()
    private var webTabs: [UUID: WebTab] = [:]
    private var privateDataStore: WKWebsiteDataStore?
    var selectedTab: BrowserTab { session.tabs.first(where: { $0.id == session.selectedTabID }) ?? session.tabs[0] }
    var profile: Profile { app.library.profiles.first(where: { $0.id == session.profileID }) ?? app.library.profiles[0] }
    var activeWebTab: WebTab { webTab(session.selectedTabID) }
    var hasPage: Bool { selectedTab.url != nil }
    var bookmarks: [Bookmark] { app.library.bookmarks.filter { $0.profileID == session.profileID } }
    init(app: AppState, isPrivate: Bool) {
        self.app = app; self.isPrivate = isPrivate; session = app.claimSession(privateBrowsing: isPrivate)
        if isPrivate { privateDataStore = .nonPersistent() }
        address = selectedTab.url?.absoluteString ?? ""
        app.registerWindow(self)
    }
    func webTab(_ id: UUID) -> WebTab {
        if let cached = webTabs[id] { return cached }
        let dataStore = privateDataStore ?? WKWebsiteDataStore(forIdentifier: session.profileID)
        let tab = WebTab(dataStore: dataStore, downloads: downloads)
        attach(tab, id: id)
        if let url = session.tabs.first(where: { $0.id == id })?.url { tab.load(url) }
        return tab
    }
    private func attach(_ tab: WebTab, id: UUID) {
        tab.onChange = { [weak self, weak tab] finished in
            guard let self, let tab, let index = self.session.tabs.firstIndex(where: { $0.id == id }) else { return }
            if let url = tab.webView.url, AddressResolver.isWebURL(url) || url.scheme == "blob" || url.absoluteString == "about:blank" {
                self.session.tabs[index].url = url
                self.session.tabs[index].title = String((tab.webView.title ?? url.host ?? "Website").prefix(512))
                if self.session.selectedTabID == id && !self.addressEditing { self.address = url.absoluteString }
                if finished && !self.isPrivate && AddressResolver.isWebURL(url) {
                    self.app.addHistory(url: url, title: self.session.tabs[index].title, profileID: self.session.profileID)
                }
            }
        }
        tab.onCreateWindow = { [weak self] configuration, url in
            guard let self, self.session.tabs.count < 200 else { return nil }
            let descriptor = BrowserTab(url: url ?? URL(string: "about:blank"))
            let child = WebTab(dataStore: configuration.websiteDataStore, downloads: self.downloads, configuration: configuration)
            self.attach(child, id: descriptor.id)
            self.session.tabs.append(descriptor); self.selectTab(descriptor.id)
            return child.webView
        }
        tab.onClose = { [weak self] in self?.closeTab(id) }
        tab.allowPopups = { [weak self] in self?.app.library.preferences.blockPopups == false }
        webTabs[id] = tab
    }
    func updatePopupPolicy() { webTabs.values.forEach { $0.updatePopupPolicy() } }
    func navigate(_ input: String) {
        guard let url = AddressResolver.resolve(input, search: app.library.preferences.search) else {
            app.notice = "Enter a website address or search. Only HTTP and HTTPS addresses are supported."; return
        }
        let tab = activeWebTab
        session.tabs[session.tabs.firstIndex(where: { $0.id == session.selectedTabID })!].url = url
        address = url.absoluteString
        tab.load(url)
    }
    func newTab(url: URL? = nil) {
        if let url, !AddressResolver.isWebURL(url) { app.notice = "This page cannot be reopened in a separate browsing context."; return }
        guard session.tabs.count < 200 else { app.notice = "This window has 200 tabs. Close a tab or open another window."; return }
        let tab = BrowserTab(url: url)
        session.tabs.append(tab); selectTab(tab.id)
    }
    func selectTab(_ id: UUID) {
        guard session.tabs.contains(where: { $0.id == id }) else { return }
        session.selectedTabID = id; address = selectedTab.url?.absoluteString ?? ""
    }
    func closeTab(_ id: UUID) {
        guard let index = session.tabs.firstIndex(where: { $0.id == id }) else { return }
        let closing = session.tabs[index]
        if let url = closing.url, AddressResolver.isWebURL(url) { closedTabs.append(closing); if closedTabs.count > 20 { closedTabs.removeFirst() } }
        webTabs.removeValue(forKey: id)?.dispose()
        session.tabs.remove(at: index)
        if session.tabs.isEmpty { session.tabs = [BrowserTab()] }
        if session.selectedTabID == id { selectTab(session.tabs[min(index, session.tabs.count - 1)].id) }
    }
    func reopenClosedTab() {
        guard session.tabs.count < 200, var tab = closedTabs.popLast() else { return }
        tab.id = UUID(); session.tabs.append(tab); selectTab(tab.id)
    }
    func selectRelativeTab(_ offset: Int) {
        guard let index = session.tabs.firstIndex(where: { $0.id == session.selectedTabID }) else { return }
        selectTab(session.tabs[(index + offset + session.tabs.count) % session.tabs.count].id)
    }
    func moveTab(_ id: UUID, by offset: Int) {
        guard let index = session.tabs.firstIndex(where: { $0.id == id }), session.tabs.indices.contains(index + offset) else { return }
        session.tabs.swapAt(index, index + offset)
    }
    func moveTab(_ id: UUID, before target: UUID) {
        guard id != target, let from = session.tabs.firstIndex(where: { $0.id == id }), let to = session.tabs.firstIndex(where: { $0.id == target }) else { return }
        let item = session.tabs.remove(at: from); session.tabs.insert(item, at: from < to ? to - 1 : to)
    }
    func pinTab(_ id: UUID) {
        guard let index = session.tabs.firstIndex(where: { $0.id == id }) else { return }
        session.tabs[index].pinned.toggle()
        session.tabs = session.tabs.filter(\.pinned) + session.tabs.filter { !$0.pinned }
    }
    func switchProfile(_ id: UUID) {
        guard id != session.profileID, app.library.profiles.contains(where: { $0.id == id }) else { return }
        let alert = NSAlert(); alert.messageText = "Switch profile?"
        alert.informativeText = "Open pages will reload in the selected profile. Sign-ins stay separate. Unsaved page work may be lost."
        alert.addButton(withTitle: "Switch profile"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        changeProfile(id)
    }
    func changeProfile(_ id: UUID) {
        guard app.library.profiles.contains(where: { $0.id == id }) else { return }
        webTabs.values.forEach { $0.dispose() }; webTabs.removeAll(); closedTabs.removeAll()
        session.profileID = id; panel = nil
        if isPrivate { privateDataStore = .nonPersistent() }
    }
    func toggleBookmark() {
        guard !isPrivate, let url = selectedTab.url, AddressResolver.isWebURL(url) else { return }
        app.toggleBookmark(url: url, title: selectedTab.title, profileID: session.profileID)
    }
    func togglePanel(_ next: BrowserPanel) {
        if panel == next { panel = nil }
        else {
            if app.configuration.layout.sidebar == .hidden { app.library.preferences.configuration.layout.sidebar = .leading }
            panel = next
        }
    }
    func closeWindow() {
        webTabs.values.forEach { $0.dispose() }; webTabs.removeAll()
        downloads.cancelAll()
        if !isPrivate { app.closeSession(session.id) }
        privateDataStore = nil; closedTabs.removeAll(); app.unregisterWindow(session.id)
    }
}
enum BrowserPanel: String, CaseIterable, Identifiable {
    case bookmarks, history, downloads, notes, resources
    var id: Self { self }
    var label: String { switch self { case .resources: "Resources"; default: rawValue.capitalized } }
    var icon: String {
        switch self { case .bookmarks: "bookmark"; case .history: "clock"; case .downloads: "arrow.down.circle"; case .notes: "note.text"; case .resources: "gauge.with.dots.needle.33percent" }
    }
}
enum BrowserSheet: String, Identifiable { case modules, customize, settings, recovery; var id: Self { self } }
