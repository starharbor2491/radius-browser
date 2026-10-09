// SPDX-License-Identifier: MPL-2.0
import AppKit
import Testing
@preconcurrency import WebKit
import RadiusCore
@testable import RadiusApp

@Suite(.serialized)
@MainActor
struct BrowserIntegrationTests {
    @Test func generatedSubframesLoadWithoutBecomingSavedTopLevelPages() async throws {
        let (app, directory) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let browser = BrowserModel(app: app, isPrivate: false)
        let tab = try #require(browser.activeWebTab as? WebTab)
        let embedded = Data("<script>parent.postMessage('data-loaded','*')</script>".utf8).base64EncodedString()
        tab.webView.loadHTMLString("""
            <html><title>Generated frames</title><body>
            <script>window.loadedFrames = []; addEventListener('message', e => loadedFrames.push(e.data));</script>
            <iframe srcdoc="<script>parent.postMessage('srcdoc-loaded','*')</script>"></iframe>
            <iframe src="data:text/html;base64,\(embedded)"></iframe>
            </body></html>
            """, baseURL: URL(string: "https://fixture.invalid"))
        try await waitUntil { tab.webView.title == "Generated frames" && !tab.webView.isLoading }
        var frames: [String] = []
        for _ in 0..<100 {
            frames = try await tab.webView.evaluateJavaScript("window.loadedFrames") as? [String] ?? []
            if frames.contains("srcdoc-loaded") && frames.contains("data-loaded") { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(frames.contains("srcdoc-loaded"))
        #expect(frames.contains("data-loaded"))
        #expect(browser.selectedTab.url?.scheme == "https")
        #expect(!app.library.history.contains { ["data", "about"].contains($0.url.scheme ?? "") })
        browser.closeWindow()
        #expect(await app.flush())
    }
    @Test func implicitNewTabsUseTheProfileDefaultEngine() async throws {
        let (app, directory) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        app.library.profiles[0].engineID = .chromium
        let browser = BrowserModel(app: app, isPrivate: true)
        #expect(browser.selectedTab.engineID == .chromium)
        browser.closeTab(browser.session.selectedTabID)
        #expect(browser.selectedTab.engineID == .chromium)
        browser.beginSplit(.sideBySide)
        #expect(browser.session.tabs.count == 2)
        #expect(browser.session.tabs.allSatisfy { $0.engineID == .chromium })
        browser.newTab(engine: .webkit)
        let source = browser.selectedTab
        browser.newTab(url: source.url, engine: source.engineID)
        #expect(browser.selectedTab.engineID == .webkit)
        let pinned = browser.session.tabs[0].id
        browser.pinTab(pinned)
        let unpinned = browser.session.selectedTabID
        #expect(!browser.moveTab(unpinned, before: pinned))
        browser.moveTab(pinned, by: 1)
        #expect(browser.session.tabs[0].id == pinned)
        browser.closeWindow(); #expect(await app.flush())
    }
    @Test func splitPreviewAndAppearanceChangesPreserveBrowsingState() async throws {
        let (app, directory) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let browser = BrowserModel(app: app, isPrivate: false)
        let originalTabs = browser.session.tabs
        var preview = app.configuration; preview.layout.split = .sideBySide
        app.previewConfiguration = preview; browser.synchronizeSplit()
        #expect(browser.session.tabs == originalTabs)
        #expect(browser.session.split == nil)
        app.previewConfiguration = nil; browser.synchronizeSplit()
        #expect(browser.session.tabs == originalTabs)
        browser.beginSplit(.sideBySide); browser.endSplit()
        let tabsBeforeAppearance = browser.session.tabs
        var appearance = app.configuration; appearance.theme.accent = .orange
        app.applyConfiguration(appearance)
        #expect(browser.session.split == nil)
        #expect(browser.session.tabs == tabsBeforeAppearance)
        browser.beginSplit(.sideBySide)
        #expect(browser.session.split != nil)
        #expect(browser.session.tabs == tabsBeforeAppearance)
        browser.closeWindow(); #expect(await app.flush())
    }
    @Test func profileReplacementResetsGeneratedPagesAndAddress() async throws {
        let (app, directory) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let browser = BrowserModel(app: app, isPrivate: true)
        browser.session.tabs[0].url = URL(string: "blob:https://fixture.invalid/unique")
        browser.session.tabs[0].title = "Generated page"
        let profile = Profile(name: "Separate"); app.library.profiles.append(profile)
        browser.changeProfile(profile.id)
        #expect(browser.selectedTab.url == nil)
        #expect(browser.selectedTab.title == "New tab")
        #expect(browser.address.isEmpty)
        browser.closeWindow(); #expect(await app.flush())
    }
    @Test func missingEnginePreservesTabPlacementAndOffersExplicitReplacement() async throws {
        let (app, directory) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let browser = BrowserModel(app: app, isPrivate: true)
        let id = browser.session.selectedTabID
        let oldTab = browser.activeWebTab
        browser.changeEngine(id, to: .chromium)
        #expect(browser.session.selectedTabID == id)
        #expect(browser.selectedTab.engineID == .chromium)
        #expect(browser.activeWebTab is UnavailableEngineTab)
        #expect(browser.activeWebTab.errorMessage != nil)
        browser.changeEngine(id, to: .webkit)
        #expect(browser.activeWebTab.engineID == .webkit)
        #expect(browser.activeWebTab !== oldTab)
        #expect(browser.session.tabs.count == 1)
        browser.closeWindow(); #expect(await app.flush())
    }
    @Test func splitPanesNavigateIndependentlyAndClosingPromotesChildren() async throws {
        let (app, directory) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        app.library.preferences.configuration.layout.split = .sideBySide
        let browser = BrowserModel(app: app, isPrivate: true)
        browser.synchronizeSplit()
        let pair = try #require(browser.session.split)
        let first = try #require(browser.webTab(pair.first) as? WebTab), second = try #require(browser.webTab(pair.second) as? WebTab)
        #expect(first !== second)
        first.webView.loadHTMLString("<html><title>Left pane</title><body>Left</body></html>", baseURL: URL(string: "https://left.invalid"))
        second.webView.loadHTMLString("<html><title>Right pane</title><body>Right</body></html>", baseURL: URL(string: "https://right.invalid"))
        try await waitUntil { first.webView.title == "Left pane" && second.webView.title == "Right pane" }
        browser.updateFocusedTab(second.webView)
        #expect(browser.session.selectedTabID == pair.second)
        #expect(URL(string: browser.address)?.host == "right.invalid")
        #expect(first.webView.url?.host == "left.invalid")
        browser.newTab(parentID: pair.second)
        let child = browser.session.selectedTabID
        #expect(browser.session.split?.first == pair.first)
        #expect(browser.session.split?.second == child)
        browser.closeTab(pair.second)
        #expect(browser.session.tabs.first(where: { $0.id == child })?.parentID == nil)
        browser.closeTab(pair.first)
        #expect(browser.session.split == nil)
        #expect(first.webView.navigationDelegate == nil)
        browser.closeWindow()
        #expect(await app.flush())
        #expect(app.library.sessions.isEmpty)
    }
    @Test func privateWindowDoesNotSaveTabsOrHistory() async throws {
        let (app, directory) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let browser = BrowserModel(app: app, isPrivate: true)
        browser.session.tabs[0].url = URL(string: "https://private.example")
        #expect(!app.library.sessions.contains { $0.id == browser.session.id })
        #expect(!(try #require(browser.activeWebTab as? WebTab)).webView.configuration.websiteDataStore.isPersistent)
        browser.closeWindow()
        #expect(await app.flush())
        let database = try LibraryDatabase(url: directory.appendingPathComponent("library.sqlite"))
        let persisted = try await database.load()
        #expect(persisted.history.isEmpty)
        #expect(!persisted.sessions.flatMap(\.tabs).contains { $0.url?.host == "private.example" })
    }
    @Test func switchingProfileCreatesANewWebsiteContext() async throws {
        let (app, directory) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let browser = BrowserModel(app: app, isPrivate: false)
        let oldView = try #require(browser.activeWebTab as? WebTab)
        let profile = Profile(name: "Separate")
        app.library.profiles.append(profile)
        browser.changeProfile(profile.id)
        let newView = try #require(browser.activeWebTab as? WebTab)
        #expect(newView !== oldView)
        #expect(oldView.webView.navigationDelegate == nil)
        #expect(newView.webView.configuration.websiteDataStore.identifier == profile.id)
        browser.closeWindow()
        #expect(await app.flush())
    }
    @Test func popupKeepsOpenerAndPrivateWebsiteStore() async throws {
        let (app, directory) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        app.library.preferences.blockPopups = false
        let browser = BrowserModel(app: app, isPrivate: true)
        let parent = try #require(browser.activeWebTab as? WebTab)
        parent.webView.loadHTMLString("<html><head><title>Fixture</title></head><body>Popup test</body></html>", baseURL: URL(string: "https://fixture.invalid"))
        try await waitUntil { parent.webView.title == "Fixture" && !parent.webView.isLoading }
        _ = try await parent.webView.evaluateJavaScript("window.open('about:blank', '_blank'); 'opened'")
        try await waitUntil { browser.session.tabs.count == 2 }
        let child = try #require(browser.activeWebTab as? WebTab)
        #expect(child !== parent)
        #expect(!child.webView.configuration.websiteDataStore.isPersistent)
        let hasOpener = try await child.webView.evaluateJavaScript("window.opener !== null") as? Bool
        #expect(hasOpener == true)
        browser.closeWindow()
        #expect(await app.flush())
    }
    @Test func reopenClosedTabRespectsLimit() async throws {
        let (app, directory) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let browser = BrowserModel(app: app, isPrivate: true)
        browser.closedTabs = [BrowserTab(url: URL(string: "https://example.com"))]
        browser.session.tabs = (0..<200).map { _ in BrowserTab() }
        browser.reopenClosedTab()
        #expect(browser.session.tabs.count == 200)
        #expect(browser.closedTabs.count == 1)
        browser.closeWindow()
        #expect(await app.flush())
    }
    @Test func generatedDocumentCanOpenWithoutPersistingItsURL() async throws {
        let (app, directory) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        app.library.preferences.blockPopups = false
        let browser = BrowserModel(app: app, isPrivate: false)
        let parent = try #require(browser.activeWebTab as? WebTab)
        parent.webView.loadHTMLString("<html><head><title>Source</title></head><body>Source</body></html>", baseURL: URL(string: "https://fixture.invalid"))
        try await waitUntil { parent.webView.title == "Source" && !parent.webView.isLoading }
        _ = try await parent.webView.evaluateJavaScript("const u = URL.createObjectURL(new Blob(['<html><head><title>Generated document</title></head><body>Generated</body></html>'], {type: 'text/html'})); window.open(u, '_blank'); 'opened'")
        try await waitUntil { browser.session.tabs.count == 2 && browser.activeWebTab.title == "Generated document" }
        #expect(browser.selectedTab.url?.scheme == "blob")
        browser.toggleBookmark()
        #expect(app.library.bookmarks.isEmpty)
        #expect(await app.flush())
        let database = try LibraryDatabase(url: directory.appendingPathComponent("library.sqlite"))
        let saved = try await database.load()
        #expect(!saved.sessions.flatMap(\.tabs).contains { $0.url?.scheme == "blob" })
        #expect(!saved.history.contains { $0.url.scheme == "blob" })
        browser.closeWindow()
        #expect(await app.flush())
    }
    @Test func javaScriptConfirmationUsesNativeDelegateAndReturnsBothChoices() async throws {
        _ = NSApplication.shared
        let tab = WebTab(dataStore: .nonPersistent(), downloads: DownloadCenter())
        defer { tab.dispose() }
        #expect(tab.responds(to: NSSelectorFromString("webView:runJavaScriptConfirmPanelWithMessage:initiatedByFrame:completionHandler:")))
        tab.webView.loadHTMLString("<html><head><title>Confirmation fixture</title></head><body>Confirmation test</body></html>", baseURL: URL(string: "https://fixture.invalid"))
        try await waitUntil { tab.webView.title == "Confirmation fixture" && !tab.webView.isLoading }
        for expected in [true, false] {
            let responder = ConfirmationResponder(accept: expected)
            let timer = Timer(timeInterval: 0.02, repeats: true) { _ in
                MainActor.assumeIsolated { responder.dismissModalIfPresent() }
            }
            // A run-loop timer can dismiss the real alert while runModal is active.
            RunLoop.main.add(timer, forMode: .common)
            RunLoop.main.add(timer, forMode: .modalPanel)
            defer { timer.invalidate() }
            let result = try await tab.webView.evaluateJavaScript("confirm('Radius confirmation integration test')") as? Bool
            timer.invalidate()
            #expect(responder.presented)
            #expect(result == expected)
        }
    }
    private func fixture() async throws -> (AppState, URL) {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("radius-native-test-" + UUID().uuidString, isDirectory: true)
        let app = AppState(directory: directory)
        await app.load()
        #expect(app.ready, Comment(rawValue: app.startupError ?? "App failed to load"))
        return (app, directory)
    }
    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !condition() {
            if Date() > deadline { throw ValidationError("WebKit integration test timed out.") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

@MainActor
private final class ConfirmationResponder {
    let accept: Bool
    private(set) var presented = false
    init(accept: Bool) { self.accept = accept }
    func dismissModalIfPresent() {
        guard !presented, NSApp.modalWindow != nil else { return }
        presented = true
        NSApp.stopModal(withCode: accept ? .alertFirstButtonReturn : .alertSecondButtonReturn)
    }
}
