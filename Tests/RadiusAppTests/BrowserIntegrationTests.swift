// SPDX-License-Identifier: MPL-2.0
import AppKit
import Testing
@preconcurrency import WebKit
import RadiusCore
@testable import RadiusApp

@Suite(.serialized)
@MainActor
struct BrowserIntegrationTests {
    @Test func privateWindowDoesNotSaveTabsOrHistory() async throws {
        let (app, directory) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let browser = BrowserModel(app: app, isPrivate: true)
        browser.session.tabs[0].url = URL(string: "https://private.example")
        #expect(!app.library.sessions.contains { $0.id == browser.session.id })
        #expect(!browser.activeWebTab.webView.configuration.websiteDataStore.isPersistent)
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
        let oldView = browser.activeWebTab
        let profile = Profile(name: "Separate")
        app.library.profiles.append(profile)
        browser.changeProfile(profile.id)
        let newView = browser.activeWebTab
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
        let parent = browser.activeWebTab
        parent.webView.loadHTMLString("<html><head><title>Fixture</title></head><body>Popup test</body></html>", baseURL: URL(string: "https://fixture.invalid"))
        try await waitUntil { parent.webView.title == "Fixture" && !parent.webView.isLoading }
        _ = try await parent.webView.evaluateJavaScript("window.open('about:blank', '_blank'); 'opened'")
        try await waitUntil { browser.session.tabs.count == 2 }
        let child = browser.activeWebTab
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
        let parent = browser.activeWebTab
        parent.webView.loadHTMLString("<html><head><title>Source</title></head><body>Source</body></html>", baseURL: URL(string: "https://fixture.invalid"))
        try await waitUntil { parent.webView.title == "Source" && !parent.webView.isLoading }
        _ = try await parent.webView.evaluateJavaScript("const u = URL.createObjectURL(new Blob(['<html><head><title>Generated document</title></head><body>Generated</body></html>'], {type: 'text/html'})); window.open(u, '_blank'); 'opened'")
        try await waitUntil { browser.session.tabs.count == 2 && browser.activeWebTab.webView.title == "Generated document" }
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
