// SPDX-License-Identifier: MPL-2.0
import AppKit
import SwiftUI
@preconcurrency import WebKit
import RadiusCore

@MainActor
final class BrowserModel: ObservableObject {
    @Published var session: WindowSession {
        didSet {
            guard !restoringFrozenSession else { return }
            if app.finalQuitDataFrozen {
                restoringFrozenSession = true
                session = oldValue
                restoringFrozenSession = false
                return
            }
            if !isPrivate && !isClosed { app.updateSession(session) }
        }
    }
    private var restoringFrozenSession = false
    @Published private(set) var isClosed = false
    @Published var panel: BrowserPanel? = nil
    @Published var address = ""
    var addressEditing = false
    @Published var focusMode = false { didSet { if !focusMode { focusHiddenComponents = []; focusProviderID = nil } } }
    @Published var focusHiddenComponents = Set<String>()
    var focusProviderID: String?
    func closeSecondarySidebar() {
        if var preview = app.previewConfiguration {
            preview.layout.secondaryPanel = nil; app.previewConfiguration = preview
        } else {
            var configuration = app.library.preferences.configuration
            configuration.layout.secondaryPanel = nil; app.applyConfiguration(configuration)
        }
    }
    func enterFocus() {
        app.perform {
            let requested = try app.requestedFocusPresentation()
            focusHiddenComponents = requested.hiddenComponents; focusProviderID = requested.moduleID
            focusMode = !requested.hiddenComponents.isEmpty
        }
    }
    func exitFocus() {
        if focusMode, app.installedModules.contains(where: { $0.id == focusProviderID && $0.enabled }) {
            app.perform { _ = try app.behaviorResult(.focusMode, event: "exit") }
        }
        focusMode = false
    }
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
    var hasNativeTabs: Bool { webTabs[session.selectedTabID]?.hasNativeNavigationChrome == true }
    var bookmarks: [Bookmark] { app.library.bookmarks.filter { $0.profileID == session.profileID } }
    init(app: AppState, isPrivate: Bool) {
        self.app = app; self.isPrivate = isPrivate; session = app.claimSession(privateBrowsing: isPrivate)
        for i in session.tabs.indices where session.tabs[i].engineID == nil { session.tabs[i].engineID = .webkit }
        if isPrivate {
            privateDataStore = .nonPersistent()
            ChromiumRuntime.shared.beginPrivateSession(session.id)
        }
        address = selectedTab.url?.absoluteString ?? ""
        app.registerWindow(self)
    }
    func webTab(_ id: UUID) -> BrowserEngineTab {
        if app.deletingProfileIDs.contains(session.profileID) { return UnavailableEngineTab(engine: selectedTab.engineID ?? .webkit, reason: "This profile is being deleted.") }
        if app.profilesAwaitingWebsiteDataRemoval.contains(session.profileID) {
            return UnavailableEngineTab(engine: session.tabs.first(where: { $0.id == id })?.engineID ?? .webkit,
                reason: "Website data removal is pending for this profile. Quit and reopen Radius to retry before browsing.")
        }
        if let cached = webTabs[id] { return cached }
        let engine = session.tabs.first(where: { $0.id == id })?.engineID ?? .webkit
        // Quitting may be cancelled. Keep this placeholder out of the cache so
        // live tabs can be recreated normally after AppKit keeps the app open.
        if app.terminating { return UnavailableEngineTab(engine: engine, reason: "Radius is closing its browsing engines.") }
        guard !isClosed else {
            let tab = UnavailableEngineTab(engine: engine, reason: "This browser window is closed.")
            webTabs[id] = tab; return tab
        }
        let tab: BrowserEngineTab
        if engine == .chromium {
            do { tab = try ChromiumRuntime.shared.makeTab(profileID: session.profileID, privateSessionID: isPrivate ? session.id : nil, dataDirectory: app.dataDirectory, downloads: downloads) }
            catch { return UnavailableEngineTab(engine: engine, reason: error.localizedDescription) }
        } else {
            let dataStore = privateDataStore ?? app.webKitDataStore(profileID: session.profileID)
            tab = WebTab(dataStore: dataStore, downloads: downloads, profileID: session.profileID)
        }
        attach(tab, id: id)
        if engine == .chromium, let pages = session.tabs.first(where: { $0.id == id })?.chromiumPages, !pages.isEmpty {
            tab.restoreChromiumSessionPages(ChromiumSessionPage.normalized(pages))
        } else if let url = session.tabs.first(where: { $0.id == id })?.url { tab.load(url) }
        return tab
    }
    private func attach(_ tab: BrowserEngineTab, id: UUID) {
        tab.onChange = { [weak self, weak tab] finished in
            guard let self, !self.isClosed, !self.app.finalQuitDataFrozen, !self.app.deletingProfileIDs.contains(self.session.profileID), self.app.library.profiles.contains(where: { $0.id == self.session.profileID }), let tab, let index = self.session.tabs.firstIndex(where: { $0.id == id }) else { return }
            if let pages = tab.chromiumSessionPages {
                let saved: [ChromiumSessionPage]? = tab.isShowingStartPage && pages.count == 1 ? nil : ChromiumSessionPage.normalized(pages)
                if self.session.tabs[index].chromiumPages != saved { self.session.tabs[index].chromiumPages = saved }
            }
            if tab.isShowingStartPage {
                self.session.tabs[index].url = nil
                self.session.tabs[index].title = "New tab"
                if self.session.selectedTabID == id && !self.addressEditing { self.address = "" }
                return
            }
            if let url = tab.url, AddressResolver.isWebURL(url) || url.scheme == "blob" || url.absoluteString == "about:blank" ||
                (tab.engineID == .chromium && ["chrome", "chrome-extension"].contains(url.scheme ?? "")) {
                self.session.tabs[index].url = url
                self.session.tabs[index].title = boundedPageTitle(tab.title ?? url.host ?? "Website")
                if self.session.selectedTabID == id && !self.addressEditing { self.address = url.absoluteString }
                if finished && !self.isPrivate && AddressResolver.isWebURL(url) {
                    self.app.addHistory(url: url, title: self.session.tabs[index].title, profileID: self.session.profileID)
                }
            }
        }
        tab.onCreateWindow = { [weak self] child, url in
            guard let self, !self.isClosed, !self.app.terminating,
                  !self.app.deletingProfileIDs.contains(self.session.profileID),
                  !self.app.profilesAwaitingWebsiteDataRemoval.contains(self.session.profileID),
                  self.app.library.profiles.contains(where: { $0.id == self.session.profileID }),
                  self.session.tabs.count < 200 else { return false }
            let descriptor = BrowserTab(url: url ?? URL(string: "about:blank"), engineID: child.engineID)
            self.attach(child, id: descriptor.id)
            self.session.tabs.append(descriptor); self.selectTab(descriptor.id)
            _ = self.session.setParent(descriptor.id, to: id)
            return true
        }
        tab.onClose = { [weak self] in self?.closeTab(id) }
        tab.onNotice = { [weak self] message in self?.app.notice = message }
        tab.onActivate = { [weak self] in
            guard let self, !self.isClosed, self.session.selectedTabID != id else { return }
            self.selectTab(id)
        }
        tab.onBrowserCommand = { [weak self, weak tab] command in
            guard let self, !self.isClosed, !self.app.finalQuitDataFrozen, let tab else { return }
            if self.session.selectedTabID != id { self.selectTab(id) }
            switch command {
            case "closeTab": self.closeTab(id)
            case "closeWindow": tab.nativeView.window?.performClose(nil)
            case "newWindow": NotificationCenter.default.post(name: .radiusOpenBrowserWindow, object: self.session.id, userInfo: ["private": false])
            case "privateWindow": NotificationCenter.default.post(name: .radiusOpenBrowserWindow, object: self.session.id, userInfo: ["private": true])
            case "quit": NSApp.terminate(nil)
            case "downloads": self.togglePanel(.downloads)
            default: break
            }
        }
        tab.allowPopups = { [weak self] in self?.app.library.preferences.blockPopups == false }
        webTabs[id] = tab
    }
    func updatePopupPolicy() { webTabs.values.forEach { $0.updatePopupPolicy() } }
    func navigate(_ input: String) {
        guard !isClosed, !app.finalQuitDataFrozen else { return }
        guard let url = AddressResolver.resolve(input, search: app.library.preferences.search) else {
            app.notice = "Enter a website address or search. Only HTTP and HTTPS addresses are supported."; return
        }
        let tab = activeWebTab
        session.tabs[session.tabs.firstIndex(where: { $0.id == session.selectedTabID })!].url = url
        address = url.absoluteString
        tab.load(url)
    }
    func showStartPage() {
        guard !isClosed, !app.finalQuitDataFrozen, let index = session.tabs.firstIndex(where: { $0.id == session.selectedTabID }) else { return }
        // Stop the old document while retaining its engine, website store,
        // back history and any transfers already owned by the adapter.
        let tab = activeWebTab
        tab.showStartPage()
        // WebKit uses Radius's native start surface. A browsing Chromium pane
        // keeps Chrome's own new-tab surface and inner tab strip mounted.
        let startURL = tab.isShowingStartPage ? nil : tab.url
        session.tabs[index].url = startURL
        session.tabs[index].title = tab.isShowingStartPage ? "New tab" : boundedPageTitle(tab.title ?? "New tab")
        address = startURL?.absoluteString ?? ""; addressEditing = false
    }
    func performTabCommand(_ command: NativeTabCommand) {
        guard !isClosed, !app.finalQuitDataFrozen else { return }
        if activeWebTab.performNativeTabCommand(command) { return }
        switch command {
        case .new:
            newTab()
            NotificationCenter.default.post(name: .radiusFocusAddress, object: session.id)
        case .close: closeTab(session.selectedTabID)
        case .reopen: reopenClosedTab()
        case .previous: selectRelativeTab(-1)
        case .next: selectRelativeTab(1)
        }
    }
    func newTab(url: URL? = nil, parentID: UUID? = nil, engine: BrowserEngineID? = nil) {
        guard !isClosed, !app.finalQuitDataFrozen else { return }
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
        guard !app.finalQuitDataFrozen, session.tabs.contains(where: { $0.id == id }) else { return }
        session.selectTab(id); address = selectedTab.url?.absoluteString ?? ""
        // Both views remain mounted in a split. Keep native focus and toolbar context together.
        if session.split != nil, let view = webTabs[id]?.nativeView, let window = view.window {
            if let current = window.firstResponder as? NSView, current === view || current.isDescendant(of: view) { return }
            webTabs[id]?.focus()
        }
    }
    func closeTab(_ id: UUID) {
        guard !app.finalQuitDataFrozen, let index = session.tabs.firstIndex(where: { $0.id == id }) else { return }
        captureChromiumSessions()
        let closing = session.tabs[index]
        if closing.url.map(AddressResolver.isWebURL) == true || closing.chromiumPages?.contains(where: { $0.url != nil }) == true {
            closedTabs.append(closing); if closedTabs.count > 20 { closedTabs.removeFirst() }
        }
        webTabs.removeValue(forKey: id)?.dispose()
        for i in session.tabs.indices where session.tabs[i].parentID == id { session.tabs[i].parentID = closing.parentID }
        let otherPane = session.split.map { $0.first == id ? $0.second : $0.first }
        if session.split?.contains(id) == true { session.split = nil; session.splitSuppressed = true }
        session.tabs.remove(at: index)
        if session.tabs.isEmpty { session.tabs = [BrowserTab(engineID: profile.engineID ?? .webkit)] }
        if session.selectedTabID == id { selectTab(otherPane ?? session.tabs[min(index, session.tabs.count - 1)].id) }
    }
    func reopenClosedTab() {
        guard !app.finalQuitDataFrozen, session.tabs.count < 200, var tab = closedTabs.popLast() else { return }
        tab.id = UUID(); tab.parentID = nil; tab.collapsed = nil
        if tab.pinned {
            session.tabs.insert(tab, at: session.tabs.firstIndex(where: { !$0.pinned }) ?? session.tabs.endIndex)
        } else { session.tabs.append(tab) }
        selectTab(tab.id)
    }
    func selectRelativeTab(_ offset: Int) {
        guard let index = session.tabs.firstIndex(where: { $0.id == session.selectedTabID }) else { return }
        selectTab(session.tabs[(index + offset + session.tabs.count) % session.tabs.count].id)
    }
    func moveTab(_ id: UUID, by offset: Int) {
        guard !app.finalQuitDataFrozen, let index = session.tabs.firstIndex(where: { $0.id == id }) else { return }
        if app.configuration.layout.treeTabs == true {
            let siblings = session.tabs.filter { $0.parentID == session.tabs[index].parentID && $0.pinned == session.tabs[index].pinned }
            guard let sibling = siblings.firstIndex(where: { $0.id == id }), siblings.indices.contains(sibling + offset),
                  let target = session.tabs.firstIndex(where: { $0.id == siblings[sibling + offset].id }) else { return }
            session.tabs.swapAt(index, target)
        } else if session.tabs.indices.contains(index + offset), session.tabs[index].pinned == session.tabs[index + offset].pinned { session.tabs.swapAt(index, index + offset) }
    }
    @discardableResult func moveTab(_ id: UUID, before target: UUID) -> Bool {
        guard !app.finalQuitDataFrozen, id != target, let from = session.tabs.firstIndex(where: { $0.id == id }), let to = session.tabs.firstIndex(where: { $0.id == target }) else { return false }
        guard session.tabs[from].pinned == session.tabs[to].pinned else { return false }
        if app.configuration.layout.treeTabs == true && session.tabs[from].parentID != session.tabs[to].parentID {
            guard session.setParent(id, to: session.tabs[to].parentID) else { return false }
        }
        let item = session.tabs.remove(at: from); session.tabs.insert(item, at: from < to ? to - 1 : to)
        return true
    }
    func pinTab(_ id: UUID) {
        guard !app.finalQuitDataFrozen, let index = session.tabs.firstIndex(where: { $0.id == id }) else { return }
        session.tabs[index].pinned.toggle()
        if session.tabs[index].pinned { session.tabs[index].parentID = nil }
        session.tabs = session.tabs.filter(\.pinned) + session.tabs.filter { !$0.pinned }
    }
    func synchronizeSplit(force: Bool = false) {
        // A layout preview must not create or persist browsing tabs.
        guard !isClosed, !app.finalQuitDataFrozen, app.previewConfiguration == nil else { return }
        if app.configuration.layout.split != nil {
            if force { session.splitSuppressed = nil }
            if session.splitSuppressed != true { session.enableSplit(defaultEngine: profile.engineID ?? .webkit) }
        } else { session.split = nil; session.splitSuppressed = nil }
    }
    func beginSplit(_ axis: SplitAxis) {
        guard !app.finalQuitDataFrozen else { return }
        app.library.preferences.configuration.layout.split = axis
        synchronizeSplit(force: true)
    }
    func endSplit() {
        guard !app.finalQuitDataFrozen else { return }
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
        guard !app.finalQuitDataFrozen, let index = session.tabs.firstIndex(where: { $0.id == id }) else { return }
        session.tabs[index].collapsed = session.tabs[index].collapsed != true
        if session.tabs[index].collapsed == true && session.ancestors(of: session.selectedTabID).contains(id) { selectTab(id) }
    }
    func switchProfile(_ id: UUID) {
        guard id != session.profileID, app.library.profiles.contains(where: { $0.id == id }) else { return }
        guard app.deletingProfileIDs.isDisjoint(with: [id, session.profileID]) else { app.notice = "Wait for profile deletion to finish before switching profiles."; return }
        let alert = NSAlert(); alert.messageText = "Switch profile?"
        alert.informativeText = "Open pages will reload in the selected profile. Sign-ins stay separate. Unsaved page work may be lost."
        alert.addButton(withTitle: "Switch profile"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        changeProfile(id)
    }
    func changeProfile(_ id: UUID) {
        guard !isClosed, !app.finalQuitDataFrozen, app.library.profiles.contains(where: { $0.id == id }) else { return }
        guard app.deletingProfileIDs.isDisjoint(with: [id, session.profileID]) else { app.notice = "Wait for profile deletion to finish before switching profiles."; return }
        webTabs.values.forEach { $0.dispose() }; webTabs.removeAll(); closedTabs.removeAll()
        if isPrivate { ChromiumRuntime.shared.releasePrivateProfile(session.profileID, sessionID: session.id) }
        session.profileID = id; panel = nil
        for i in session.tabs.indices {
            if let url = session.tabs[i].url, !AddressResolver.isWebURL(url) {
                session.tabs[i].url = nil; session.tabs[i].title = "New tab"
            }
        }
        address = selectedTab.url?.absoluteString ?? ""
        if isPrivate { privateDataStore = .nonPersistent() }
    }
    func resetAfterProfileDeletion(replacementID: UUID) {
        guard !isClosed, let replacement = app.library.profiles.first(where: { $0.id == replacementID }) else { return }
        disposeEngineTabs(); closedTabs.removeAll(); panel = nil
        if isPrivate { ChromiumRuntime.shared.releasePrivateProfile(session.profileID, sessionID: session.id) }
        session = app.library.sessions.first(where: { $0.id == session.id }) ??
            WindowSession(id: session.id, profileID: replacementID, tabs: [BrowserTab(engineID: replacement.engineID ?? .webkit)])
        address = ""; addressEditing = false
        if isPrivate { privateDataStore = .nonPersistent() }
    }
    private func safeReopeningURL(_ descriptor: BrowserTab) -> URL? {
        if descriptor.engineID == .chromium, let selected = descriptor.chromiumPages?.first {
            return selected.url.flatMap { AddressResolver.isWebURL($0) ? $0 : nil }
        }
        return descriptor.url.flatMap { AddressResolver.isWebURL($0) ? $0 : nil }
    }
    func reopenTab(_ id: UUID, with engine: BrowserEngineID) {
        guard !isClosed, !app.finalQuitDataFrozen else { return }
        guard !app.deletingProfileIDs.contains(session.profileID) else { app.notice = "Wait for profile deletion to finish before switching engines."; return }
        let profileID = session.profileID
        webTabs[id]?.refreshActiveContent()
        captureChromiumSessions()
        if let chromium = webTabs[id] as? ChromiumTab, !chromium.isReadyForEngineSwitch {
            app.notice = "Wait for this Chrome pane to finish restoring its tabs and active page before switching engines."
            return
        }
        guard let descriptor = session.tabs.first(where: { $0.id == id }), descriptor.engineID != engine else { return }
        if descriptor.engineID != .chromium, let url = descriptor.url, !AddressResolver.isWebURL(url) {
            app.notice = "Generated pages cannot be reopened in another engine. Open the original website instead."; return
        }
        if engine == .chromium && !ChromiumRuntime.shared.isInstalled(in: app.dataDirectory) {
            app.notice = "Install Chromium in Settings → Browsing engines → Installation and updates, then reopen this tab."; return
        }
        let safeURL = safeReopeningURL(descriptor)
        let hasOtherChromeTabs = (descriptor.chromiumPages?.count ?? 0) > 1
        let hasGeneratedChromePage = descriptor.engineID == .chromium && descriptor.url.map {
            !AddressResolver.isWebURL($0) && !["about:blank", "chrome://newtab/", "chrome://new-tab-page/"].contains($0.absoluteString)
        } == true
        if safeURL != nil || hasOtherChromeTabs || hasGeneratedChromePage {
            let reviewedPage = webTabs[id]
            let reviewedRevision = reviewedPage?.navigationRevision
            let alert = NSAlert()
            alert.messageText = safeURL == nil ? "Switch this pane to \(engine.label)?" : "Reopen this page in \(engine.label)?"
            alert.informativeText = hasOtherChromeTabs
                ? "Only the active Chrome tab reopens in the other engine. Other Chrome tabs, sign-ins, forms and unsaved work do not transfer."
                : "The page loads normally in a separate website context. Sign-ins, forms, and unsaved page work do not transfer."
            if safeURL == nil {
                alert.informativeText = "The new engine opens a blank page. The Chrome tabs in this pane and their unsaved work will close."
            }
            alert.addButton(withTitle: safeURL == nil ? "Switch engine" : "Reopen page"); alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            // Chromium continues processing callbacks during the native modal.
            // Apply only to the profile and pages whose loss was just reviewed.
            webTabs[id]?.refreshActiveContent()
            captureChromiumSessions()
            if let chromium = webTabs[id] as? ChromiumTab, !chromium.isReadyForEngineSwitch {
                app.notice = "The active Chrome page is not ready. Review the pane and try switching engines again."
                return
            }
            guard session.profileID == profileID, !app.deletingProfileIDs.contains(profileID),
                  let current = session.tabs.first(where: { $0.id == id }),
                  current.engineID == descriptor.engineID, safeReopeningURL(current) == safeURL,
                  current.url == descriptor.url, current.chromiumPages == descriptor.chromiumPages,
                  webTabs[id] === reviewedPage, webTabs[id]?.navigationRevision == reviewedRevision else {
                app.notice = "The tabs changed while confirmation was open. Review the pane and try again."
                return
            }
        }
        changeEngine(id, to: engine)
    }
    func changeEngine(_ id: UUID, to engine: BrowserEngineID) {
        guard !isClosed, !app.finalQuitDataFrozen, !app.deletingProfileIDs.contains(session.profileID),
              app.library.profiles.contains(where: { $0.id == session.profileID }),
              let index = session.tabs.firstIndex(where: { $0.id == id }) else { return }
        if session.tabs[index].engineID != .chromium, let url = session.tabs[index].url, !AddressResolver.isWebURL(url) { return }
        let url = safeReopeningURL(session.tabs[index])
        webTabs.removeValue(forKey: id)?.dispose()
        session.tabs[index].engineID = engine
        session.tabs[index].chromiumPages = nil
        session.tabs[index].url = url
        if url == nil { session.tabs[index].title = "New tab" }
        if session.selectedTabID == id { address = url?.absoluteString ?? ""; addressEditing = false }
        _ = webTab(id)
    }
    func toggleBookmark() {
        guard !isPrivate else { return }
        let page = activeWebTab
        page.refreshActiveContent()
        guard let url = page.url, AddressResolver.isWebURL(url) else { return }
        app.toggleBookmark(url: url, title: boundedPageTitle(page.title ?? url.host ?? "Website"), profileID: session.profileID)
    }
    func togglePanel(_ next: BrowserPanel) {
        if panel == next { panel = nil }
        else {
            if app.configuration.layout.sidebar == .hidden { app.library.preferences.configuration.layout.sidebar = .leading }
            panel = next
        }
    }
    func closeWindow() {
        guard !isClosed else { return }
        isClosed = true
        disposeEngineTabs()
        if isPrivate { ChromiumRuntime.shared.closePrivateSession(session.id) }
        downloads.cancelAll()
        if !isPrivate { app.closeSession(session.id) }
        privateDataStore = nil; closedTabs.removeAll(); app.unregisterWindow(session.id)
    }
    func disposeEngineTabs() {
        webTabs.values.forEach { $0.dispose() }; webTabs.removeAll()
    }
    func captureChromiumSessions() {
        guard !isClosed, !app.finalQuitDataFrozen, !app.deletingProfileIDs.contains(session.profileID) else { return }
        for (id, tab) in webTabs {
            tab.refreshActiveContent()
            guard let index = session.tabs.firstIndex(where: { $0.id == id }),
                  let pages = tab.chromiumSessionPages else { continue }
            let saved: [ChromiumSessionPage]? = tab.isShowingStartPage && pages.count == 1 ? nil : ChromiumSessionPage.normalized(pages)
            if session.tabs[index].chromiumPages != saved { session.tabs[index].chromiumPages = saved }
        }
    }
    func resynchronizeCachedPages() {
        // Engine commits can arrive while the final snapshot is frozen. Replay
        // the existing adapters on refusal without recreating live documents.
        for tab in webTabs.values { tab.onChange?(false) }
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
enum BrowserSheet: String, Identifiable { case modules, customize, settings, engines, recovery, extensions; var id: Self { self } }
