// SPDX-License-Identifier: MPL-2.0
import AppKit
import Testing
@preconcurrency import WebKit
import RadiusCore
@testable import RadiusApp

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
        try await setCookie(profileID: removed.id, value: "remove")
        try await setCookie(profileID: kept.id, value: "keep")
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
        #expect(await cookieValues(profileID: removed.id).isEmpty)
        #expect(await cookieValues(profileID: kept.id) == ["keep"])
        let database = try LibraryDatabase(url: directory.appendingPathComponent("library.sqlite"))
        let saved = try await database.load()
        #expect(saved.profiles == [kept])
        #expect(saved.sessions.first(where: { $0.id == regular.session.id }) == regular.session)
        #expect(!saved.sessions.contains { $0.id == privateWindow.session.id })
        #expect(!saved.sessions.flatMap(\.tabs).contains { $0.url?.host == "removed.invalid" })
        await removeStores([removed.id, kept.id])
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
        try await setCookie(profileID: cleared.id, value: "clear")
        try await setCookie(profileID: kept.id, value: "keep")

        try await app.requestWebsiteDataClear(cleared.id)
        try await app.requestWebsiteDataClear(cleared.id)
        #expect(app.library.pendingWebsiteDataClears == [cleared.id])
        #expect(FileManager.default.fileExists(atPath: clearedPath.path))
        #expect(await cookieValues(profileID: cleared.id) == ["clear"])
        let database = try LibraryDatabase(url: directory.appendingPathComponent("library.sqlite"))
        #expect(try await database.load().pendingWebsiteDataClears == [cleared.id])

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
        #expect(await cookieValues(profileID: cleared.id).isEmpty)
        #expect(await cookieValues(profileID: kept.id) == ["keep"])
        #expect((try await database.load().pendingWebsiteDataClears ?? []).isEmpty)
        await removeStores([cleared.id, kept.id])
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
        #expect(oldPage?.webView.configuration.websiteDataStore.identifier == profileID)
        try await setCookie(profileID: profileID, value: "pending")
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
        let deadline = ContinuousClock().now.advanced(by: .seconds(10))
        repeat {
            await restarted.finishPendingProfileDeletions()
            if (restarted.library.pendingWebsiteDataClears ?? []).isEmpty { break }
            try await Task.sleep(for: .milliseconds(100))
        } while ContinuousClock().now < deadline
        #expect((restarted.library.pendingWebsiteDataClears ?? []).isEmpty)
        #expect(restored.activeWebTab is WebTab)
        #expect(await cookieValues(profileID: profileID).isEmpty)
        restored.disposeEngineTabs()
        await removeStores([profileID])
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
    private func setCookie(profileID: UUID, value: String) async throws {
        let cookie = try #require(HTTPCookie(properties: [.domain: "profiles.fixture.invalid", .path: "/", .name: "radius-profile-test", .value: value]))
        await WKWebsiteDataStore(forIdentifier: profileID).httpCookieStore.setCookie(cookie)
        #expect(await cookieValues(profileID: profileID) == [value])
    }
    private func cookieValues(profileID: UUID) async -> [String] {
        await withCheckedContinuation { continuation in
            WKWebsiteDataStore(forIdentifier: profileID).httpCookieStore.getAllCookies { cookies in
                continuation.resume(returning: cookies.filter { $0.name == "radius-profile-test" }.map(\.value).sorted())
            }
        }
    }
    private func removeStores(_ ids: [UUID]) async {
        for id in ids {
            await withCheckedContinuation { continuation in
                WKWebsiteDataStore.remove(forIdentifier: id) { _ in continuation.resume() }
            }
        }
    }
}
