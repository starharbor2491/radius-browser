// SPDX-License-Identifier: MPL-2.0
import AppKit
import Testing
@preconcurrency import WebKit
import RadiusCore
@testable import RadiusApp

extension NativeIntegrationTests {
@Suite(.serialized)
@MainActor
struct ProfilesIntegrationTests {
    @Test func deletingAProfileResetsItsWindowsAndErasesOnlyItsWebsiteData() async throws {
        let (app, directory) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let removed = Profile(name: "Remove")
        let kept = Profile(name: "Keep")
        app.library.profiles = [removed, kept]
        let first = BrowserTab(title: "Pinned", url: URL(string: "https://removed.invalid"), pinned: true, engineID: .webkit)
        let child = BrowserTab(title: "Child", url: URL(string: "https://child.invalid"), parentID: first.id, engineID: .webkit)
        var removedSession = WindowSession(profileID: removed.id, tabs: [first, child])
        removedSession.split = TabSplit(first: first.id, second: child.id)
        let keptSession = WindowSession(profileID: kept.id, tabs: [BrowserTab(title: "Keep page", url: URL(string: "https://kept.invalid"), engineID: .webkit)])
        app.library.sessions = [removedSession, keptSession]
        let regular = BrowserModel(app: app, isPrivate: false)
        let unaffected = BrowserModel(app: app, isPrivate: false)
        let privateWindow = BrowserModel(app: app, isPrivate: true)
        defer { regular.closeWindow(); unaffected.closeWindow(); privateWindow.closeWindow() }
        #expect(privateWindow.session.profileID == removed.id)
        let privatePage = try #require(privateWindow.activeWebTab as? WebTab)
        #expect(!privatePage.webView.configuration.websiteDataStore.isPersistent)
        privateWindow.closedTabs = [BrowserTab(url: URL(string: "https://private.invalid"))]
        regular.closedTabs = [first]
        regular.panel = .history; regular.addressEditing = true
        seedLibraryContents(app, profiles: [removed, kept])
        let keptBookmarks = app.library.bookmarks.filter { $0.profileID == kept.id }
        let keptNotes = app.library.notes.filter { $0.profileID == kept.id }
        let keptHistory = app.library.history.filter { $0.profileID == kept.id }
        let removedPath = try seedChromiumStorage(directory, profileID: removed.id, contents: "remove")
        let keptPath = try seedChromiumStorage(directory, profileID: kept.id, contents: "keep")
        try await setCookie(app: app, profileID: removed.id, value: "remove")
        try await setCookie(app: app, profileID: kept.id, value: "keep")
        #expect(await app.flush())

        try await app.deleteProfile(removed.id, replacingWith: kept.id)

        #expect(app.library.profiles == [kept])
        #expect(app.library.bookmarks == keptBookmarks)
        #expect(app.library.notes == keptNotes)
        #expect(app.library.history == keptHistory)
        #expect(unaffected.session == keptSession)
        for window in [regular, privateWindow] {
            #expect(window.session.profileID == kept.id)
            #expect(window.session.tabs.count == 1)
            #expect(window.selectedTab.url == nil)
            #expect(window.selectedTab.engineID == .webkit)
            #expect(!window.selectedTab.pinned)
            #expect(window.session.split == nil)
            #expect(window.closedTabs.isEmpty)
            #expect(window.address.isEmpty)
            #expect(!window.addressEditing)
        }
        #expect(regular.panel == nil)
        #expect(privatePage.webView.navigationDelegate == nil)
        #expect(!(try #require(privateWindow.activeWebTab as? WebTab)).webView.configuration.websiteDataStore.isPersistent)
        #expect(app.deletingProfileIDs.isEmpty)
        #expect((app.library.pendingProfileDeletions ?? []).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: removedPath.path))
        #expect(try Data(contentsOf: keptPath) == Data("keep".utf8))
        #expect(try await cookieValues(profileID: removed.id).isEmpty)
        #expect(try await cookieValues(store: app.webKitDataStore(profileID: kept.id)) == ["keep"])
        let database = try LibraryDatabase(url: directory.appendingPathComponent("library.sqlite"))
        let saved = try await database.load()
        #expect(saved.profiles == [kept])
        #expect(saved.sessions.first(where: { $0.id == regular.session.id }) == regular.session)
        #expect(!saved.sessions.contains { $0.id == privateWindow.session.id })
        #expect(!saved.sessions.flatMap(\.tabs).contains { $0.url?.host == "removed.invalid" })
        try await removeStores([removed.id, kept.id], releasing: [app])
    }

    @Test func failedMetadataCommitRestoresTheProfileWithoutErasingItsFilesOrLeavingTabsBlocked() async throws {
        _ = NSApplication.shared
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // A state with no loaded database makes the commit fail deterministically.
        let app = AppState(directory: directory)
        let removed = Profile(name: "Remove"), kept = Profile(name: "Keep")
        app.library.profiles = [removed, kept]
        app.ready = true
        let browser = BrowserModel(app: app, isPrivate: false)
        defer { browser.closeWindow() }
        seedLibraryContents(app, profiles: [removed, kept])
        let originalSession = browser.session
        let originalBookmarks = app.library.bookmarks, originalNotes = app.library.notes, originalHistory = app.library.history
        let oldPage = try #require(browser.activeWebTab as? WebTab)
        let sentinel = try seedChromiumStorage(directory, profileID: removed.id, contents: "keep after failed save")
        var failure: (any Error)?
        do { try await app.deleteProfile(removed.id, replacingWith: kept.id) }
        catch { failure = error }

        #expect(failure != nil)
        #expect(Set(app.library.profiles.map(\.id)) == Set([removed.id, kept.id]))
        #expect(Set(app.library.bookmarks.map(\.id)) == Set(originalBookmarks.map(\.id)))
        #expect(Set(app.library.notes.map(\.id)) == Set(originalNotes.map(\.id)))
        #expect(Set(app.library.history.map(\.id)) == Set(originalHistory.map(\.id)))
        #expect(browser.session == originalSession)
        #expect(app.deletingProfileIDs.isEmpty)
        #expect((app.library.pendingProfileDeletions ?? []).isEmpty)
        #expect(try Data(contentsOf: sentinel) == Data("keep after failed save".utf8))
        #expect(oldPage.webView.navigationDelegate == nil)
        #expect(browser.activeWebTab is WebTab)
        #expect(browser.activeWebTab !== oldPage)
        #expect((browser.activeWebTab as? WebTab)?.webView.configuration.websiteDataStore.identifier == removed.id)
    }

    @Test func queuedWebsiteClearSurvivesRestartAndKeepsLibraryDataAndOtherProfileStorage() async throws {
        let (app, directory) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cleared = Profile(name: "Clear"), kept = Profile(name: "Keep")
        app.library.profiles = [cleared, kept]
        app.library.sessions = [WindowSession(profileID: cleared.id, tabs: [BrowserTab(url: URL(string: "https://restore.invalid"), engineID: .webkit)])]
        seedLibraryContents(app, profiles: [cleared, kept])
        let expectedProfiles = app.library.profiles, expectedSessions = app.library.sessions
        let expectedBookmarks = app.library.bookmarks, expectedNotes = app.library.notes, expectedHistory = app.library.history
        let clearedPath = try seedChromiumStorage(directory, profileID: cleared.id, contents: "clear")
        let keptPath = try seedChromiumStorage(directory, profileID: kept.id, contents: "keep")
        try await setCookie(app: app, profileID: cleared.id, value: "clear")
        try await setCookie(app: app, profileID: kept.id, value: "keep")

        try await app.requestWebsiteDataClear(cleared.id)
        try await app.requestWebsiteDataClear(cleared.id)
        #expect(app.library.pendingWebsiteDataClears == [cleared.id])
        #expect(FileManager.default.fileExists(atPath: clearedPath.path))
        #expect(try await cookieValues(store: app.webKitDataStore(profileID: cleared.id)) == ["clear"])
        let database = try LibraryDatabase(url: directory.appendingPathComponent("library.sqlite"))
        #expect(try await database.load().pendingWebsiteDataClears == [cleared.id])

        // The queued profile's old owner must release its context before the
        // simulated launch retries removal; the other profile stays untouched.
        app.releaseWebKitDataStore(profileID: cleared.id)
        let restarted = AppState(directory: directory)
        await restarted.load()
        #expect(restarted.ready, Comment(rawValue: restarted.startupError ?? "Restart failed"))
        #expect((restarted.library.pendingWebsiteDataClears ?? []).isEmpty)
        #expect(restarted.library.profiles == expectedProfiles)
        #expect(restarted.library.sessions == expectedSessions)
        #expect(restarted.library.bookmarks == expectedBookmarks)
        #expect(restarted.library.notes == expectedNotes)
        #expect(restarted.library.history == expectedHistory)
        #expect(!FileManager.default.fileExists(atPath: clearedPath.path))
        #expect(try Data(contentsOf: keptPath) == Data("keep".utf8))
        #expect(try await cookieValues(profileID: cleared.id).isEmpty)
        #expect(try await cookieValues(store: app.webKitDataStore(profileID: kept.id)) == ["keep"])
        #expect((try await database.load().pendingWebsiteDataClears ?? []).isEmpty)
        try await removeStores([cleared.id, kept.id], releasing: [app, restarted])
    }

    @Test func callbacksCannotReinsertDataWhileTheirProfileIsBeingDeleted() async throws {
        let (app, directory) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let profileID = app.library.profiles[0].id
        let browser = BrowserModel(app: app, isPrivate: false)
        defer { browser.closeWindow() }
        let original = browser.session
        app.deletingProfileIDs.insert(profileID)
        defer { app.deletingProfileIDs.remove(profileID) }
        var changed = original
        changed.tabs[0].url = URL(string: "https://late.invalid")
        app.updateSession(changed)
        app.addHistory(url: URL(string: "https://late.invalid")!, title: "Late callback", profileID: profileID)
        app.toggleBookmark(url: URL(string: "https://late.invalid")!, title: "Late command", profileID: profileID)
        #expect(app.library.sessions.first(where: { $0.id == original.id }) == original)
        #expect(app.library.history.isEmpty)
        #expect(app.library.bookmarks.isEmpty)
        #expect(browser.activeWebTab is UnavailableEngineTab)
    }

    @Test func websiteClearFailureBlocksRestoredWebKitUntilItsStoreCanBeRemoved() async throws {
        let (app, directory) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let profileID = app.library.profiles[0].id
        let original = BrowserModel(app: app, isPrivate: false)
        defer { original.closeWindow() }
        var oldPage: WebTab? = try #require(original.activeWebTab as? WebTab)
        weak var originalView = oldPage?.webView
        #expect(oldPage?.webView.configuration.websiteDataStore.identifier == profileID)
        try await setCookie(app: app, profileID: profileID, value: "pending")
        try await app.requestWebsiteDataClear(profileID)

        // A live store cannot be removed. This models another running Radius
        // copy retaining the website context while the new launch retries.
        let restarted = AppState(directory: directory)
        await restarted.load()
        try #require(restarted.ready)
        #expect(restarted.library.pendingWebsiteDataClears == [profileID])
        let restored = BrowserModel(app: restarted, isPrivate: false)
        defer { restored.closeWindow() }
        #expect(restored.activeWebTab is UnavailableEngineTab)
        #expect(restored.activeWebTab.errorMessage != nil)

        original.disposeEngineTabs(); oldPage = nil
        app.releaseWebKitDataStore(profileID: profileID)
        let deadline = ContinuousClock().now.advanced(by: .seconds(10))
        while originalView != nil && ContinuousClock().now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        try #require(originalView == nil, "Retry must release the old copy's actual web view first.")
        repeat {
            await restarted.finishPendingProfileDeletions()
            if (restarted.library.pendingWebsiteDataClears ?? []).isEmpty { break }
            try await Task.sleep(for: .milliseconds(100))
        } while ContinuousClock().now < deadline
        #expect((restarted.library.pendingWebsiteDataClears ?? []).isEmpty)
        #expect(restored.activeWebTab is WebTab)
        #expect(try await cookieValues(profileID: profileID).isEmpty)
        restored.disposeEngineTabs()
        try await removeStores([profileID], releasing: [app, restarted])
    }

    @Test func switchingProfilesDuringDeletionKeepsBothSourceAndDestinationContextsIntact() async throws {
        let (app, directory) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let deleting = app.library.profiles[0], kept = Profile(name: "Keep")
        app.library.profiles.append(kept)
        let source = BrowserModel(app: app, isPrivate: true)
        let destination = BrowserModel(app: app, isPrivate: true)
        defer { source.closeWindow(); destination.closeWindow() }
        destination.changeProfile(kept.id)
        source.session.tabs[0].url = URL(string: "https://source.invalid")
        destination.session.tabs[0].url = URL(string: "https://destination.invalid")
        let sourceSession = source.session, destinationSession = destination.session
        let retainedPage = destination.activeWebTab

        app.deletingProfileIDs.insert(deleting.id)
        source.changeProfile(kept.id)
        destination.changeProfile(deleting.id)
        #expect(source.session == sourceSession)
        #expect(destination.session == destinationSession)
        #expect(destination.activeWebTab === retainedPage)
        #expect(source.activeWebTab is UnavailableEngineTab)

        app.deletingProfileIDs.remove(deleting.id)
        source.changeProfile(kept.id)
        #expect(source.session.profileID == kept.id)
    }

    @Test func closingTheLastWebKitTabKeepsSessionCookiesWhileRadiusIsRunning() async throws {
        let (app, directory) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let profileID = app.library.profiles[0].id
        let browser = BrowserModel(app: app, isPrivate: false)
        defer { browser.closeWindow() }
        let closedTabID = browser.session.selectedTabID
        // Seed through an actual tab's store, then retain no page or store in
        // the fixture. A persistent-cookie fixture would hide this sign-out.
        weak var originalView = try await seedSessionCookieOnActivePage(browser, value: "signed-in")

        browser.closeTab(closedTabID)
        let releaseDeadline = ContinuousClock().now.advanced(by: .seconds(10))
        while originalView != nil && ContinuousClock().now < releaseDeadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        try #require(originalView == nil, "The closed tab must release its real WKWebView before checking a new tab's session.")
        #expect(browser.session.tabs.count == 1)
        #expect(browser.session.selectedTabID != closedTabID)

        weak var replacementView = try #require(browser.activeWebTab as? WebTab).webView
        #expect(replacementView?.configuration.websiteDataStore.identifier == profileID)
        let replacementCookies = try await cookieValues(store: try #require(replacementView).configuration.websiteDataStore)
        #expect(replacementCookies == ["signed-in"], "Closing the last tab must not sign this profile out while Radius remains running.")

        browser.disposeEngineTabs()
        let cleanupDeadline = ContinuousClock().now.advanced(by: .seconds(10))
        while replacementView != nil && ContinuousClock().now < cleanupDeadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        try #require(replacementView == nil, "The cookie fixture must release its replacement view before removing website storage.")
        try await removeStores([profileID], releasing: [app])
    }

    @Test func stagedChromiumRemovalChangesOnlyTheRestartSnapshotAndARefusedQuitRestoresIt() async throws {
        let (app, directory) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let profileID = app.library.profiles[0].id
        app.library.profiles[0].engineID = .chromium
        let website = BrowserTab(title: "Signed-in website", url: URL(string: "https://fixture.invalid/account"), pinned: true, engineID: .chromium)
        let generated = BrowserTab(title: "Extension options", url: URL(string: "chrome-extension://fixture/options.html"), parentID: website.id, engineID: .chromium)
        app.library.sessions = [WindowSession(profileID: profileID, tabs: [website, generated])]
        let browser = BrowserModel(app: app, isPrivate: false)
        defer {
            app.saveWithoutChromiumOnQuit = false; app.terminating = false
            browser.closeWindow()
        }
        let cached = try #require(browser.activeWebTab as? UnavailableEngineTab, "This metadata regression must not require a real CEF runtime.")
        browser.closedTabs = [generated]
        let originalLibrary = app.library, originalSession = browser.session
        app.terminating = true
        app.saveWithoutChromiumOnQuit = true
        try #require(await app.flush())

        let database = try LibraryDatabase(url: directory.appendingPathComponent("library.sqlite"))
        let prepared = try await database.load()
        #expect(prepared.profiles.first { $0.id == profileID }?.engineID == .webkit)
        let preparedSession = try #require(prepared.sessions.first { $0.id == originalSession.id })
        #expect(preparedSession.tabs.allSatisfy { $0.engineID == .webkit })
        #expect(preparedSession.tabs.first { $0.id == website.id }?.url == website.url)
        #expect(preparedSession.tabs.first { $0.id == website.id }?.pinned == true)
        #expect(preparedSession.tabs.first { $0.id == generated.id }?.url == nil)
        #expect(preparedSession.tabs.first { $0.id == generated.id }?.title == "New tab")
        #expect(app.library == originalLibrary)
        #expect(browser.session == originalSession)
        #expect(browser.closedTabs == [generated])
        #expect(browser.activeWebTab === cached)

        app.saveWithoutChromiumOnQuit = false; app.terminating = false
        try #require(await app.flush())
        let restored = try await database.load()
        var expectedDurableLibrary = originalLibrary
        expectedDurableLibrary.normalize()
        #expect(restored.profiles == expectedDurableLibrary.profiles)
        #expect(restored.sessions == expectedDurableLibrary.sessions)
        #expect(browser.session == originalSession)
        #expect(browser.activeWebTab === cached)
    }

    private func fixture() async throws -> (AppState, URL) {
        _ = NSApplication.shared
        let directory = temporaryDirectory(), app = AppState(directory: directory)
        await app.load()
        try #require(app.ready, Comment(rawValue: app.startupError ?? "App failed to load"))
        return (app, directory)
    }
    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("RadiusProfilesIntegration-\(UUID().uuidString)", isDirectory: true)
    }
    private func seedLibraryContents(_ app: AppState, profiles: [Profile]) {
        for profile in profiles {
            let url = URL(string: "https://\(profile.id.uuidString.lowercased()).invalid")!
            app.library.bookmarks.append(Bookmark(profileID: profile.id, title: profile.name, url: url))
            app.library.history.append(HistoryEntry(profileID: profile.id, title: profile.name, url: url))
            app.library.notes.append(Note(profileID: profile.id, title: profile.name, text: "Scoped content"))
        }
    }
    private func seedChromiumStorage(_ directory: URL, profileID: UUID, contents: String) throws -> URL {
        let folder = directory.appendingPathComponent("Chromium/Profiles/\(profileID.uuidString)/Local Storage", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("fixture")
        try Data(contents.utf8).write(to: file)
        return file
    }
    private func setCookie(app: AppState, profileID: UUID, value: String) async throws {
        let cookie = try #require(HTTPCookie(properties: [.domain: "profiles.fixture.invalid", .path: "/", .name: "radius-profile-test", .value: value,
                                                        .expires: Date().addingTimeInterval(3600)]))
        try #require(!cookie.isSessionOnly && cookie.expiresDate != nil, "The deletion fixture must use a persistent cookie.")
        let store = app.webKitDataStore(profileID: profileID)
        try await ProfileCallbackWait<Void>.wait("setting profile cookie") { request in
            store.httpCookieStore.setCookie(cookie) {
                Task { @MainActor in request.finish(.success(())) }
            }
        }
        try #require(try await cookieValues(store: store) == [value], "The persistent cookie fixture must be populated before testing deletion.")
    }
    private func seedSessionCookieOnActivePage(_ browser: BrowserModel, value: String) async throws -> WKWebView {
        let page = try #require(browser.activeWebTab as? WebTab)
        let store = page.webView.configuration.websiteDataStore
        let cookie = try #require(HTTPCookie(properties: [.domain: "profiles.fixture.invalid", .path: "/", .name: "radius-profile-test", .value: value]))
        try #require(cookie.isSessionOnly, "This regression must use a session cookie without an expiration date.")
        try await ProfileCallbackWait<Void>.wait("setting an active tab's session cookie") { request in
            store.httpCookieStore.setCookie(cookie) {
                Task { @MainActor in request.finish(.success(())) }
            }
        }
        try #require(try await cookieValues(store: store) == [value], "The original live tab must be signed in before closing it.")
        return page.webView
    }
    private func cookieValues(profileID: UUID) async throws -> [String] {
        try await cookieValues(store: WKWebsiteDataStore(forIdentifier: profileID))
    }
    private func cookieValues(store: WKWebsiteDataStore) async throws -> [String] {
        defer { withExtendedLifetime(store) {} }
        return try await ProfileCallbackWait<[String]>.wait("reading profile cookies") { request in
            store.httpCookieStore.getAllCookies { cookies in
                let values = cookies.filter { $0.name == "radius-profile-test" }.map(\.value).sorted()
                Task { @MainActor in request.finish(.success(values)) }
            }
        }
    }
    private func removeStores(_ ids: [UUID], releasing apps: [AppState] = []) async throws {
        for app in apps { for id in ids { app.releaseWebKitDataStore(profileID: id) } }
        for id in ids {
            let deadline = ContinuousClock().now.advanced(by: .seconds(10))
            while true {
                do {
                    try await ProfileCallbackWait<Void>.wait("removing test website storage") { request in
                        WKWebsiteDataStore.remove(forIdentifier: id) { error in
                            Task { @MainActor in
                                if let error { request.finish(.failure(error)) }
                                else { request.finish(.success(())) }
                            }
                        }
                    }
                    break
                } catch let error as NSError where error.domain == "WKWebSiteDataStore" && error.code == 1 && ContinuousClock().now < deadline {
                    // The fixture has released its owned views and store cache;
                    // allow WebKit's asynchronous context teardown to finish.
                    try await Task.sleep(for: .milliseconds(50))
                }
            }
        }
    }
}

}

/// SDK callbacks must fail within a deadline, including cleanup after a test.
/// One-shot completion also makes a late WebKit response harmless.
@MainActor
private final class ProfileCallbackWait<Value: Sendable> {
    private var continuation: CheckedContinuation<Value, any Error>?
    private var deadline: Task<Void, Never>?
    static func wait(_ operationName: String, operation: (ProfileCallbackWait<Value>) -> Void) async throws -> Value {
        let request = ProfileCallbackWait<Value>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                request.continuation = continuation
                request.deadline = Task {
                    do { try await Task.sleep(for: .seconds(10)) }
                    catch { return }
                    request.finish(.failure(ValidationError("WebKit timed out while \(operationName).")))
                }
                operation(request)
                if Task.isCancelled { request.finish(.failure(CancellationError())) }
            }
        } onCancel: { Task { @MainActor in request.finish(.failure(CancellationError())) } }
    }
    func finish(_ result: Result<Value, any Error>) {
        guard let continuation else { return }
        self.continuation = nil; deadline?.cancel(); deadline = nil
        continuation.resume(with: result)
    }
}
