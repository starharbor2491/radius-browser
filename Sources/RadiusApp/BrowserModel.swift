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
    private var webTabs: [UUID: BrowserEngineTab] = [:]
    private var privateDataStore: WKWebsiteDataStore?
    var selectedTab: BrowserTab { session.tabs.first(where: { $0.id == session.selectedTabID }) ?? session.tabs[0] }
    var profile: Profile { app.library.profiles.first(where: { $0.id == session.profileID }) ?? app.library.profiles[0] }
    var activeWebTab: BrowserEngineTab { webTab(session.selectedTabID) }
    var hasPage: Bool { selectedTab.url != nil }
    var bookmarks: [Bookmark] { app.library.bookmarks.filter { $0.profileID == session.profileID } }
    init(app: AppState, isPrivate: Bool) {
        self.app = app; self.isPrivate = isPrivate; session = app.claimSession(privateBrowsing: isPrivate)
        for i in session.tabs.indices where session.tabs[i].engineID == nil { session.tabs[i].engineID = .webkit }
        if isPrivate { privateDataStore = .nonPersistent() }
        address = selectedTab.url?.absoluteString ?? ""
        app.registerWindow(self)
    }
    func webTab(_ id: UUID) -> BrowserEngineTab {
        if let cached = webTabs[id] { return cached }
        let engine = session.tabs.first(where: { $0.id == id })?.engineID ?? .webkit
        let tab: BrowserEngineTab
        if engine == .chromium {
            do { tab = try ChromiumRuntime.shared.makeTab(profileID: session.profileID, privateSessionID: isPrivate ? session.id : nil, dataDirectory: app.dataDirectory) }
            catch { tab = UnavailableEngineTab(engine: engine, reason: error.localizedDescription) }
        } else {
            let dataStore = privateDataStore ?? WKWebsiteDataStore(forIdentifier: session.profileID)
            tab = WebTab(dataStore: dataStore, downloads: downloads)
        }
        attach(tab, id: id)
        if let url = session.tabs.first(where: { $0.id == id })?.url { tab.load(url) }
        return tab
    }
    private func attach(_ tab: BrowserEngineTab, id: UUID) {
        tab.onChange = { [weak self, weak tab] finished in
            guard let self, let tab, let index = self.session.tabs.firstIndex(where: { $0.id == id }) else { return }
            if let url = tab.url, AddressResolver.isWebURL(url) || url.scheme == "blob" || url.absoluteString == "about:blank" {
                self.session.tabs[index].url = url
                self.session.tabs[index].title = String((tab.title ?? url.host ?? "Website").prefix(512))
                if self.session.selectedTabID == id && !self.addressEditing { self.address = url.absoluteString }
                if finished && !self.isPrivate && AddressResolver.isWebURL(url) {
                    self.app.addHistory(url: url, title: self.session.tabs[index].title, profileID: self.session.profileID)
                }
            }
        }
        tab.onCreateWindow = { [weak self] child, url in
            guard let self, self.session.tabs.count < 200 else { return false }
            let descriptor = BrowserTab(url: url ?? URL(string: "about:blank"), engineID: child.engineID)
            self.attach(child, id: descriptor.id)
            self.session.tabs.append(descriptor); self.selectTab(descriptor.id)
            _ = self.session.setParent(descriptor.id, to: id)
            return true
        }
        tab.onClose = { [weak self] in self?.closeTab(id) }
        tab.onNotice = { [weak self] message in self?.app.notice = message }
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
    func newTab(url: URL? = nil, parentID: UUID? = nil, engine: BrowserEngineID? = nil) {
        if let url, !AddressResolver.isWebURL(url) { app.notice = "This page cannot be reopened in a separate browsing context."; return }
        if let parentID, !session.tabs.contains(where: { $0.id == parentID }) || session.ancestors(of: parentID).count >= 8 {
            app.notice = "Tab trees support up to eight levels. Open this page as a top-level tab instead."; return
        }
        guard session.tabs.count < 200 else { app.notice = "This window has 200 tabs. Close a tab or open another window."; return }
        let tab = BrowserTab(url: url, engineID: engine ?? profile.engineID ?? .webkit)
        session.tabs.append(tab)
        if let parentID { _ = session.setParent(tab.id, to: parentID) }
        selectTab(tab.id)
    }
    func selectTab(_ id: UUID) {
        guard session.tabs.contains(where: { $0.id == id }) else { return }
        session.selectTab(id); address = selectedTab.url?.absoluteString ?? ""
        // Both views remain mounted in a split. Keep native focus and toolbar context together.
        if session.split != nil, let view = webTabs[id]?.nativeView, let window = view.window {
            if let current = window.firstResponder as? NSView, current === view || current.isDescendant(of: view) { return }
            webTabs[id]?.focus()
        }
    }
    func closeTab(_ id: UUID) {
        guard let index = session.tabs.firstIndex(where: { $0.id == id }) else { return }
        let closing = session.tabs[index]
        if let url = closing.url, AddressResolver.isWebURL(url) { closedTabs.append(closing); if closedTabs.count > 20 { closedTabs.removeFirst() } }
        webTabs.removeValue(forKey: id)?.dispose()
        for i in session.tabs.indices where session.tabs[i].parentID == id { session.tabs[i].parentID = closing.parentID }
        let otherPane = session.split.map { $0.first == id ? $0.second : $0.first }
        if session.split?.contains(id) == true { session.split = nil; session.splitSuppressed = true }
        session.tabs.remove(at: index)
        if session.tabs.isEmpty { session.tabs = [BrowserTab(engineID: profile.engineID ?? .webkit)] }
        if session.selectedTabID == id { selectTab(otherPane ?? session.tabs[min(index, session.tabs.count - 1)].id) }
    }
    func reopenClosedTab() {
        guard session.tabs.count < 200, var tab = closedTabs.popLast() else { return }
        tab.id = UUID(); tab.parentID = nil; tab.collapsed = nil; session.tabs.append(tab); selectTab(tab.id)
    }
    func selectRelativeTab(_ offset: Int) {
        guard let index = session.tabs.firstIndex(where: { $0.id == session.selectedTabID }) else { return }
        selectTab(session.tabs[(index + offset + session.tabs.count) % session.tabs.count].id)
    }
    func moveTab(_ id: UUID, by offset: Int) {
        guard let index = session.tabs.firstIndex(where: { $0.id == id }) else { return }
        if app.configuration.layout.treeTabs == true {
            let siblings = session.tabs.filter { $0.parentID == session.tabs[index].parentID && $0.pinned == session.tabs[index].pinned }
            guard let sibling = siblings.firstIndex(where: { $0.id == id }), siblings.indices.contains(sibling + offset),
                  let target = session.tabs.firstIndex(where: { $0.id == siblings[sibling + offset].id }) else { return }
            session.tabs.swapAt(index, target)
        } else if session.tabs.indices.contains(index + offset), session.tabs[index].pinned == session.tabs[index + offset].pinned { session.tabs.swapAt(index, index + offset) }
    }
    @discardableResult func moveTab(_ id: UUID, before target: UUID) -> Bool {
        guard id != target, let from = session.tabs.firstIndex(where: { $0.id == id }), let to = session.tabs.firstIndex(where: { $0.id == target }) else { return false }
        guard session.tabs[from].pinned == session.tabs[to].pinned else { return false }
        if app.configuration.layout.treeTabs == true && session.tabs[from].parentID != session.tabs[to].parentID {
            guard session.setParent(id, to: session.tabs[to].parentID) else { return false }
        }
        let item = session.tabs.remove(at: from); session.tabs.insert(item, at: from < to ? to - 1 : to)
        return true
    }
    func pinTab(_ id: UUID) {
        guard let index = session.tabs.firstIndex(where: { $0.id == id }) else { return }
        session.tabs[index].pinned.toggle()
        if session.tabs[index].pinned { session.tabs[index].parentID = nil }
        session.tabs = session.tabs.filter(\.pinned) + session.tabs.filter { !$0.pinned }
    }
    func synchronizeSplit(force: Bool = false) {
        // A layout preview must not create or persist browsing tabs.
        guard app.previewConfiguration == nil else { return }
        if app.configuration.layout.split != nil {
            if force { session.splitSuppressed = nil }
            if session.splitSuppressed != true { session.enableSplit(defaultEngine: profile.engineID ?? .webkit) }
        } else { session.split = nil; session.splitSuppressed = nil }
    }
    func beginSplit(_ axis: SplitAxis) {
        app.library.preferences.configuration.layout.split = axis
        synchronizeSplit(force: true)
    }
    func endSplit() {
        session.split = nil; session.splitSuppressed = true
    }
    func selectOtherPane() {
        guard let pair = session.split else { return }
        selectTab(pair.first == session.selectedTabID ? pair.second : pair.first)
    }
    func updateFocusedTab(_ responder: NSResponder?) {
        guard let pair = session.split, let view = responder as? NSView else { return }
        for id in [pair.first, pair.second] where id != session.selectedTabID {
            if let tab = webTabs[id], view === tab.nativeView || view.isDescendant(of: tab.nativeView) {
                selectTab(id); return
            }
        }
    }
    func toggleBranch(_ id: UUID) {
        guard let index = session.tabs.firstIndex(where: { $0.id == id }) else { return }
        session.tabs[index].collapsed = session.tabs[index].collapsed != true
        if session.tabs[index].collapsed == true && session.ancestors(of: session.selectedTabID).contains(id) { selectTab(id) }
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
        for i in session.tabs.indices {
            if let url = session.tabs[i].url, !AddressResolver.isWebURL(url) {
                session.tabs[i].url = nil; session.tabs[i].title = "New tab"
            }
        }
        address = selectedTab.url?.absoluteString ?? ""
        if isPrivate { privateDataStore = .nonPersistent() }
    }
    func reopenTab(_ id: UUID, with engine: BrowserEngineID) {
        guard let descriptor = session.tabs.first(where: { $0.id == id }), descriptor.engineID != engine else { return }
        if let url = descriptor.url, !AddressResolver.isWebURL(url) {
            app.notice = "Generated pages cannot be reopened in another engine. Open the original website instead."; return
        }
        if engine == .chromium && !ChromiumRuntime.shared.isInstalled(in: app.dataDirectory) {
            app.notice = "Chromium requires the optional Radius development build with a runtime for this Mac's architecture. See Settings → Browsing engines."; return
        }
        if descriptor.url != nil {
            let alert = NSAlert(); alert.messageText = "Reopen this page in \(engine.label)?"
            alert.informativeText = "The page loads normally in a separate website context. Sign-ins, forms, and unsaved page work do not transfer."
            alert.addButton(withTitle: "Reopen page"); alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        changeEngine(id, to: engine)
    }
    func changeEngine(_ id: UUID, to engine: BrowserEngineID) {
        guard let index = session.tabs.firstIndex(where: { $0.id == id }) else { return }
        if let url = session.tabs[index].url, !AddressResolver.isWebURL(url) { return }
        webTabs.removeValue(forKey: id)?.dispose()
        session.tabs[index].engineID = engine
        _ = webTab(id)
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
        disposeEngineTabs()
        downloads.cancelAll()
        if !isPrivate { app.closeSession(session.id) }
        privateDataStore = nil; closedTabs.removeAll(); app.unregisterWindow(session.id)
    }
    func disposeEngineTabs() {
        webTabs.values.forEach { $0.dispose() }; webTabs.removeAll()
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
