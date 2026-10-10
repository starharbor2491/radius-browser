// SPDX-License-Identifier: MPL-2.0
import AppKit
import Testing
import CSQLite
@preconcurrency import WebKit
@preconcurrency import Network
import RadiusCore
@testable import RadiusApp

extension NativeIntegrationTests {
@Suite(.serialized)
@MainActor
struct BrowserIntegrationTests {
    @Test func startPageReplacesOnlyTheCurrentPageAndPreservesItsWorkspaceAndWebsiteStore() async throws {
        let (app, directory) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let browser = BrowserModel(app: app, isPrivate: false)
        defer { browser.closeWindow() }
        let pinned = BrowserTab(title: "Pinned", url: URL(string: "https://pinned.invalid/"), pinned: true, engineID: .chromium)
        let child = BrowserTab(parentID: pinned.id, engineID: .webkit)
        browser.session.tabs = [pinned, child]
        browser.session.selectedTabID = child.id
        browser.session.split = TabSplit(first: pinned.id, second: child.id)
        let source = try #require(browser.activeWebTab as? WebTab)
        let server = try BrowserHistoryPageServer()
        defer { server.stop() }
        let pageURL = try await server.start()
        browser.navigate(pageURL.absoluteString)
        try await waitUntil { source.webView.title == "Current page" && !source.webView.isLoading && browser.hasPage }
        let websiteStore = source.webView.configuration.websiteDataStore
        var expected = browser.session
        expected.tabs[1].url = nil; expected.tabs[1].title = "New tab"
        browser.addressEditing = true
        browser.showStartPage()
        #expect(browser.session == expected)
        #expect(!browser.hasPage && browser.address.isEmpty && !browser.addressEditing)
        try await waitUntil { source.isShowingStartPage && source.webView.url?.scheme == "about" && !source.webView.isLoading }
        let homeURL = try #require(source.webView.url)
        #expect(source.webView.navigationDelegate === source && source.onChange != nil)
        #expect(browser.activeWebTab === source && source.url == nil)
        #expect(source.webView.configuration.websiteDataStore === websiteStore)
        #expect((try await source.webView.evaluateJavaScript("typeof window.radiusPreviousDocument")) as? String == "undefined")
        #expect(source.canGoBack)
        #expect(app.library.sessions.first(where: { $0.id == expected.id }) == expected)
        // WebKit's own history gestures bypass the adapter commands.
        source.webView.goBack()
        try await waitUntil { source.webView.title == "Current page" && !source.webView.isLoading && browser.hasPage }
        #expect(!source.isShowingStartPage)
        #expect(browser.session.selectedTabID == child.id && browser.selectedTab.url == pageURL)
        #expect(browser.session.tabs.count == 2)

        source.webView.goForward()
        try await waitUntil { source.webView.url == homeURL && !source.webView.isLoading && !browser.hasPage }
        #expect(source.isShowingStartPage && source.url == nil && source.title == nil)
        #expect(browser.activeWebTab === source && browser.address.isEmpty)
        #expect(browser.session == expected)
        #expect(app.library.sessions.first(where: { $0.id == expected.id }) == expected)
        source.goBack()
        try await waitUntil { source.webView.title == "Current page" && !source.webView.isLoading && browser.hasPage }
        #expect(!source.isShowingStartPage && browser.selectedTab.url == pageURL)
        source.goForward()
        try await waitUntil { source.webView.url == homeURL && !source.webView.isLoading && !browser.hasPage }
        #expect(browser.session == expected && source.isShowingStartPage)
        source.goBack()
        try await waitUntil { source.webView.title == "Current page" && !source.webView.isLoading && browser.hasPage }

        // A pinned tab using a different engine keeps that engine and its place.
        browser.selectTab(pinned.id)
        expected = browser.session
        expected.tabs[0].url = nil; expected.tabs[0].title = "New tab"
        browser.showStartPage()
        #expect(browser.session == expected)
        #expect(browser.selectedTab.engineID == .chromium && browser.selectedTab.pinned)
        #expect(browser.session.tabs.count == 2)
        #expect(!browser.hasPage && browser.address.isEmpty)
        browser.closeWindow(); #expect(await app.flush())
    }
    @Test func failedNavigationFromHomeKeepsTheRequestedAddressAndReloadRetriesTheWebsite() async throws {
        let (app, directory) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let browser = BrowserModel(app: app, isPrivate: false)
        defer { browser.closeWindow() }
        let source = try #require(browser.activeWebTab as? WebTab)
        let websiteStore = source.webView.configuration.websiteDataStore, history = source.webView.backForwardList
        let server = try BrowserHistoryPageServer()
        defer { server.stop() }
        let pageURL = try await server.start()
        browser.navigate(pageURL.absoluteString)
        try await waitUntil { source.webView.title == "Current page" && !source.webView.isLoading }
        browser.showStartPage()
        try await waitUntil { source.webView.url?.scheme == "about" && !source.webView.isLoading && !browser.hasPage }
        let homeURL = try #require(history.currentItem?.url)
        server.stop()

        // An uncached path makes this a real failed provisional navigation.
        let target = pageURL.appendingPathComponent("unavailable-" + UUID().uuidString)
        browser.navigate(target.absoluteString)
        try await waitUntil { source.errorMessage != nil && !source.webView.isLoading }
        print("HOME_FAILED_NAVIGATION native=\(source.webView.url?.absoluteString ?? "nil") adapter=\(source.url?.absoluteString ?? "nil") requested=\(target.absoluteString) descriptor=\(browser.selectedTab.url?.absoluteString ?? "nil") address=\(browser.address) home=\(source.isShowingStartPage)")
        #expect(browser.selectedTab.url == target)
        #expect(browser.address == target.absoluteString)
        #expect(source.url == target && !source.isShowingStartPage)
        #expect(browser.activeWebTab === source)
        #expect(source.webView.configuration.websiteDataStore === websiteStore)
        #expect(source.webView.backForwardList === history && history.currentItem?.url == homeURL)

        let retryServer = try BrowserHistoryPageServer(port: UInt16(try #require(pageURL.port)))
        defer { retryServer.stop() }
        _ = try await retryServer.start()
        source.reload()
        try await waitUntil { retryServer.servedRequests > 0 && source.webView.url == target && !source.webView.isLoading && source.errorMessage == nil }
        #expect(source.webView.title == "Current page" && browser.selectedTab.url == target)
        #expect(browser.activeWebTab === source)
        #expect(source.webView.configuration.websiteDataStore === websiteStore)
        #expect(source.webView.backForwardList === history && history.backList.contains { $0.url == homeURL })
        browser.closeWindow(); #expect(await app.flush())
    }
    @Test func refusedFinalSaveKeepsTheLiveDocumentAndResynchronizesFrozenEngineCommits() async throws {
        let (app, directory) = try await fixture()
        let browser = BrowserModel(app: app, isPrivate: false)
        defer {
            app.ready = false; app.unfreezeQuitData(); app.terminating = false
            browser.closeWindow(); try? FileManager.default.removeItem(at: directory)
        }
        let source = try #require(browser.activeWebTab as? WebTab)
        let server = try BrowserHistoryPageServer()
        defer { server.stop() }
        let pageURL = try await server.start()
        browser.navigate(pageURL.absoluteString)
        try await waitUntil { source.webView.title == "Current page" && !source.webView.isLoading && browser.hasPage }
        _ = try await source.webView.evaluateJavaScript("""
            document.body.insertAdjacentHTML('beforeend', '<input id="radius-unsaved-form" value="kept">');
            window.radiusUnsavedValue = 'kept';
            """)
        let view = source.webView, store = view.configuration.websiteDataStore
        let history = view.backForwardList
        let originalHistoryURL = try #require(history.currentItem?.url)
        let originalSession = browser.session
        try #require(await app.flush())

        // Reject an actual SQLite UPDATE after the first quit save, rather than
        // disposing the document or stubbing the final persistence result.
        var connection: OpaquePointer?
        try #require(sqlite3_open_v2(directory.appendingPathComponent("library.sqlite").path, &connection,
                                   SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK)
        let databaseHandle = try #require(connection)
        defer {
            sqlite3_exec(databaseHandle, "DROP TRIGGER IF EXISTS radius_reject_final_save", nil, nil, nil)
            sqlite3_close(databaseHandle)
        }
        try #require(sqlite3_exec(databaseHandle, "CREATE TRIGGER radius_reject_final_save BEFORE UPDATE ON library BEGIN SELECT RAISE(ABORT, 'fixture rejected the final save'); END", nil, nil, nil) == SQLITE_OK)
        app.terminating = true
        let pendingNote = Note(profileID: browser.session.profileID, title: "Latest unsaved change", text: "Keep after refusing quit")
        app.library.notes.append(pendingNote)
        app.freezeQuitData()

        let committedURL = pageURL.appending(queryItems: [URLQueryItem(name: "during", value: "frozen")])
        let originalChange = source.onChange
        var receivedFrozenCommit = false
        source.onChange = { [weak source] finished in
            if app.finalQuitDataFrozen && source?.url == committedURL { receivedFrozenCommit = true }
            originalChange?(finished)
        }
        // A same-document website commit changes the live engine while Radius's
        // durable snapshot is frozen; its unsaved form must remain untouched.
        _ = try await view.evaluateJavaScript("history.pushState(null, '', '?during=frozen'); document.title = 'Changed while frozen';")
        try await waitUntil { receivedFrozenCommit && source.title == "Changed while frozen" }
        #expect(browser.session == originalSession)
        #expect(!(await app.flushForTermination()))
        #expect(browser.activeWebTab === source && source.webView.navigationDelegate === source)
        #expect(try await view.evaluateJavaScript("window.radiusUnsavedValue + ':' + document.getElementById('radius-unsaved-form').value") as? String == "kept:kept")

        try #require(sqlite3_exec(databaseHandle, "DROP TRIGGER radius_reject_final_save", nil, nil, nil) == SQLITE_OK)
        app.unfreezeQuitData()
        browser.resynchronizeCachedPages()
        app.terminating = false
        #expect(browser.activeWebTab === source && source.webView === view)
        #expect(view.configuration.websiteDataStore === store)
        #expect(view.backForwardList === history)
        #expect(history.backList.contains { $0.url == originalHistoryURL })
        #expect(view.backForwardList.currentItem?.url == committedURL && source.canGoBack)
        #expect(browser.selectedTab.url == committedURL && browser.selectedTab.title == "Changed while frozen")
        #expect(try await view.evaluateJavaScript("window.radiusUnsavedValue + ':' + document.getElementById('radius-unsaved-form').value") as? String == "kept:kept")

        let database = try LibraryDatabase(url: directory.appendingPathComponent("library.sqlite"))
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        var persisted = try await database.load()
        while (persisted.sessions != app.library.sessions || persisted.notes != [pendingNote]), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
            persisted = try await database.load()
        }
        #expect(persisted.sessions == app.library.sessions)
        #expect(persisted.notes == [pendingNote])
    }
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
    @Test func lateActivationOfReplacedPanePreservesSelectionWhileVisiblePaneCanStillActivate() async throws {
        let (app, directory) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let browser = BrowserModel(app: app, isPrivate: false)
        defer { browser.closeWindow() }
        let originalID = browser.session.selectedTabID
        let activateOriginal = try #require(browser.activeWebTab.onActivate)
        browser.beginSplit(.sideBySide)
        let siblingID = try #require(browser.session.split?.second)
        let activateSibling = try #require(browser.webTab(siblingID).onActivate)
        browser.newTab(engine: .webkit)
        let replacementID = browser.session.selectedTabID
        let replacementSession = browser.session

        // A delayed native focus event from the outgoing pane must not
        // replace the new pane or change the workspace's saved selection.
        activateOriginal()
        #expect(browser.session == replacementSession)
        #expect(app.library.sessions.first(where: { $0.id == browser.session.id }) == replacementSession)

        activateSibling()
        #expect(browser.session.selectedTabID == siblingID)
        #expect(browser.session.split == replacementSession.split)
        browser.endSplit()
        activateOriginal()
        #expect(browser.session.selectedTabID == siblingID && browser.session.split == nil)

        // Sidebar selection remains an explicit request to show a cached pane.
        browser.selectTab(originalID)
        #expect(browser.session.selectedTabID == originalID)
        #expect(browser.session.tabs.contains { $0.id == replacementID })
        browser.closeWindow(); #expect(await app.flush())
    }
    @Test func aNewSplitPaneReleasesStaleParentPageFocusWithoutBlockingRealPaneFocus() async throws {
        let (app, directory) = try await fixture()
        let browser = BrowserModel(app: app, isPrivate: false)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer {
            window.contentView = nil; window.close(); browser.closeWindow()
            try? FileManager.default.removeItem(at: directory)
        }
        let retainedID = browser.session.selectedTabID
        let retained = browser.activeWebTab
        browser.beginSplit(.sideBySide)
        let outgoingID = try #require(browser.session.split?.second)
        try #require(outgoingID != retainedID)
        browser.selectTab(outgoingID)
        let outgoing = browser.activeWebTab
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        window.contentView = content
        retained.nativeView.frame = NSRect(x: 0, y: 0, width: 300, height: 400)
        outgoing.nativeView.frame = NSRect(x: 300, y: 0, width: 300, height: 400)
        content.addSubview(retained.nativeView); content.addSubview(outgoing.nativeView)
        window.orderFront(nil)
        try #require(window.makeFirstResponder(retained.nativeView))
        let responder = try #require(window.firstResponder as? NSView)
        try #require(responder === retained.nativeView || responder.isDescendant(of: retained.nativeView))

        // A Chrome child can be key while its parent remembers the other
        // pane's WebKit responder. The new blank pane has no mounted view.
        browser.newTab(engine: .webkit)
        let blankID = browser.session.selectedTabID
        #expect(browser.activeWebTab.nativeView.window == nil)
        #expect(window.firstResponder !== responder)
        browser.updateFocusedTab(window.firstResponder)
        #expect(browser.session.selectedTabID == blankID)

        try #require(window.makeFirstResponder(retained.nativeView))
        browser.updateFocusedTab(window.firstResponder)
        #expect(browser.session.selectedTabID == retainedID)
        let focused = try #require(window.firstResponder as? NSView)
        #expect(focused === retained.nativeView || focused.isDescendant(of: retained.nativeView))
        #expect(await app.flush())
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
        app.terminating = true; browser.disposeEngineTabs()
        #expect(browser.activeWebTab is UnavailableEngineTab)
        app.terminating = false
        #expect(browser.activeWebTab is WebTab)
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
        #expect(browser.isClosed)
        #expect(browser.activeWebTab is UnavailableEngineTab)
        let closedTabs = browser.session.tabs
        browser.newTab(url: URL(string: "https://closed.example"))
        browser.navigate("https://closed.example")
        #expect(browser.session.tabs == closedTabs)
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
        #expect(!child.isShowingStartPage)
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
    @Test func reopeningPinnedTabPreservesPinnedSectionAndFreshIdentity() async throws {
        let (app, directory) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let browser = BrowserModel(app: app, isPrivate: true)
        let firstPinned = BrowserTab(title: "First pinned", url: URL(string: "https://first.invalid"), pinned: true)
        let reopening = BrowserTab(title: "Reopening", url: URL(string: "https://example.com"), pinned: true)
        let ordinary = BrowserTab(title: "Ordinary")
        browser.session.tabs = [firstPinned, reopening, ordinary]
        browser.session.selectedTabID = ordinary.id
        browser.closeTab(reopening.id)
        browser.reopenClosedTab()
        #expect(browser.session.tabs.map(\.title) == ["First pinned", "Reopening", "Ordinary"])
        #expect(browser.session.tabs.map(\.pinned) == [true, true, false])
        #expect(browser.selectedTab.id != reopening.id)
        #expect(browser.selectedTab.pinned)
        #expect(browser.selectedTab.parentID == nil)
        browser.closeTab(browser.selectedTab.id)
        browser.closeTab(firstPinned.id)
        browser.reopenClosedTab()
        #expect(browser.session.tabs.first?.title == "First pinned")
        #expect(browser.session.tabs.last?.id == ordinary.id)
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
        let tab = WebTab(dataStore: .nonPersistent(), downloads: DownloadCenter(), profileID: UUID())
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

}

@MainActor
private final class BrowserHistoryPageServer {
    private let listener: NWListener
    private(set) var servedRequests = 0
    private var connections: [UUID: NWConnection] = [:]
    private var stopped = false
    private var startup: CheckedContinuation<URL, any Error>?
    private var watchdog: Task<Void, Never>?
    init(port: UInt16 = 0) throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        listener = try NWListener(using: parameters)
        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in self?.changed(state) }
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in self?.serve(connection) }
        }
    }
    func start() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            startup = continuation
            watchdog = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(8)) } catch { return }
                self?.finish(.failure(ValidationError("The history test's local server did not start.")))
            }
            listener.start(queue: .main)
        }
    }
    func stop() {
        stopped = true
        listener.cancel(); connections.values.forEach { $0.cancel() }; connections.removeAll()
        finish(.failure(CancellationError()))
    }
    private func changed(_ state: NWListener.State) {
        if case .ready = state, let port = listener.port {
            finish(.success(URL(string: "http://127.0.0.1:\(port.rawValue)/history")!))
        } else if case .failed(let error) = state { finish(.failure(error)) }
    }
    private func finish(_ result: Result<URL, any Error>) {
        guard let startup else { return }
        self.startup = nil; watchdog?.cancel(); watchdog = nil
        startup.resume(with: result)
    }
    private func serve(_ connection: NWConnection) {
        guard !stopped, connections.count < 8 else { connection.cancel(); return }
        let id = UUID(); connections[id] = connection
        let body = Data("<html><title>Current page</title><body>Current page<script>window.radiusPreviousDocument = true</script></body></html>".utf8)
        let response = Data("HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8) + body
        connection.start(queue: .main)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, _, error in
            guard data != nil, error == nil else { connection.cancel(); return }
            Task { @MainActor in self?.servedRequests += 1 }
            connection.send(content: response, completion: .contentProcessed { [weak self] _ in
                connection.cancel()
                Task { @MainActor in self?.connections.removeValue(forKey: id) }
            })
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
