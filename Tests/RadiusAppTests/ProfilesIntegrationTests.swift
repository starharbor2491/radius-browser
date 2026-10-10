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
    @Test func deletingAProfileCancelsItsTransfersAfterTheWindowSwitchesProfiles() async throws {
        let (app, directory) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let removed = Profile(name: "Download origin"), kept = Profile(name: "Current profile")
        app.library.profiles = [removed, kept]
        app.library.sessions = [WindowSession(profileID: removed.id)]
        let browser = BrowserModel(app: app, isPrivate: false)
        let center = browser.downloads
        var removedCancellations = 0, keptCancellations = 0
        let removedItem = DownloadItem(chromiumID: "removed-profile", profileID: removed.id, sourceURL: nil) { [weak center] in
            removedCancellations += 1
            center?.updateChromium(id: "removed-profile", fraction: 0, complete: false, cancelled: true, interrupted: false)
        }
        center.items.append(removedItem)
        browser.changeProfile(kept.id)
        let keptItem = DownloadItem(chromiumID: "kept-profile", profileID: kept.id, sourceURL: nil) { keptCancellations += 1 }
        center.items.append(keptItem)
        defer {
            center.updateChromium(id: "kept-profile", fraction: 0, complete: false, cancelled: true, interrupted: false)
            browser.closeWindow()
        }
        try await app.deleteProfile(removed.id, replacingWith: kept.id)
        #expect(browser.session.profileID == kept.id)
        #expect(removedCancellations == 1)
        #expect(!removedItem.active)
        #expect(keptCancellations == 0)
        #expect(keptItem.active)
        #expect(!DownloadAdmission.shared.acceptsDownloads(for: removed.id))
        #expect(DownloadAdmission.shared.acceptsDownloads(for: kept.id))
        #expect(app.library.profiles == [kept])
        try await removeStores([removed.id, kept.id], releasing: [app])
    }

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
        #expect(DownloadAdmission.shared.acceptsDownloads(for: removed.id))
        #expect(DownloadAdmission.shared.acceptsDownloads(for: kept.id))
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
        let webKitTab = BrowserTab(title: "Independent WebKit page", engineID: .webkit)
        app.library.sessions = [WindowSession(profileID: profileID, tabs: [website, generated, webKitTab])]
        let browser = BrowserModel(app: app, isPrivate: false)
        defer {
            app.saveWithoutChromiumOnQuit = false; app.terminating = false
            browser.closeWindow()
        }
        let originalAdapter = browser.activeWebTab
        let cachedWebKit = try #require(browser.webTab(webKitTab.id) as? WebTab)
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
        let duringQuit = browser.activeWebTab
        if originalAdapter is UnavailableEngineTab {
            #expect(duringQuit is UnavailableEngineTab)
            #expect(duringQuit.engineID == .chromium)
            #expect(duringQuit.errorMessage?.isEmpty == false)
            #expect(duringQuit !== originalAdapter, "Transient closing placeholders must not replace a cached browsing adapter.")
        } else { #expect(duringQuit === originalAdapter) }
        #expect(browser.webTab(webKitTab.id) === cachedWebKit, "Preparing the restart snapshot must preserve actual cached engine pages.")

        app.saveWithoutChromiumOnQuit = false; app.terminating = false
        try #require(await app.flush())
        let restored = try await database.load()
        var expectedDurableLibrary = originalLibrary
        expectedDurableLibrary.normalize()
        #expect(restored.profiles == expectedDurableLibrary.profiles)
        #expect(restored.sessions == expectedDurableLibrary.sessions)
        #expect(browser.session == originalSession)
        let afterRefusal = browser.activeWebTab
        if originalAdapter is UnavailableEngineTab {
            #expect(afterRefusal is UnavailableEngineTab)
            #expect(afterRefusal.engineID == .chromium)
            #expect(afterRefusal.errorMessage?.isEmpty == false)
            #expect(afterRefusal !== duringQuit && afterRefusal !== originalAdapter, "A refused quit must retry the engine factory instead of caching a temporary failure.")
        } else { #expect(afterRefusal === originalAdapter) }
        #expect(browser.webTab(webKitTab.id) === cachedWebKit)
    }

    @Test func refusingQuitSavesEditsMadeWhileTerminationSuspendedAutosave() async throws {
        let (app, directory) = try await fixture()
        defer {
            app.ready = false; app.terminating = false
            try? FileManager.default.removeItem(at: directory)
        }
        try #require(await app.flush())
        let database = try LibraryDatabase(url: directory.appendingPathComponent("library.sqlite"))
        let baseline = try await database.load()
        let bookmark = Bookmark(profileID: app.library.profiles[0].id, title: "Saved during quit", url: try #require(URL(string: "https://quit.fixture.invalid/saved")))

        app.terminating = true
        app.library.bookmarks.append(bookmark)
        app.library.preferences.configuration.theme.accent = .orange
        // Allow the usual debounce to pass. Termination owns persistence until
        // the quit is accepted or refused; this edit must stay in memory here.
        try await Task.sleep(for: .milliseconds(350))
        #expect(try await database.load() == baseline)

        app.terminating = false
        // No further library mutation or explicit flush may rescue this edit.
        let deadline = ContinuousClock().now.advanced(by: .seconds(5))
        var persisted = try await database.load()
        while !persisted.bookmarks.contains(where: { $0.id == bookmark.id }) && ContinuousClock().now < deadline {
            try await Task.sleep(for: .milliseconds(50))
            persisted = try await database.load()
        }
        #expect(persisted.bookmarks == baseline.bookmarks + [bookmark])
        #expect(persisted.preferences.configuration.theme.accent == .orange)
        #expect(persisted.profiles == baseline.profiles)
    }

    @Test func finalTerminationSnapshotSavesEditsMadeAfterTheInitialQuitFlush() async throws {
        let (app, directory) = try await fixture()
        defer {
            app.ready = false; app.terminating = false
            try? FileManager.default.removeItem(at: directory)
        }
        app.terminating = true
        try #require(await app.flush())
        let database = try LibraryDatabase(url: directory.appendingPathComponent("library.sqlite"))
        let baseline = try await database.load()
        let profileID = app.library.profiles[0].id
        let note = Note(profileID: profileID, title: "Latest edit", text: "Written while engine cleanup was finishing")
        let bookmark = Bookmark(profileID: profileID, title: "Latest bookmark", url: try #require(URL(string: "https://quit.fixture.invalid/latest")))
        app.library.notes.append(note)
        app.library.bookmarks.append(bookmark)
        #expect(try await database.load() == baseline)

        try #require(await app.flushForTermination())
        let persisted = try await database.load()
        #expect(persisted.notes == baseline.notes + [note])
        #expect(persisted.bookmarks == baseline.bookmarks + [bookmark])
        #expect(persisted.profiles == baseline.profiles)
        #expect(app.terminating)
    }

    @Test func finalQuitFreezeProtectsTheSnapshotAndCancellationResumesRealAutosave() async throws {
        let (app, directory) = try await fixture()
        let originalProfile = app.library.profiles[0]
        let otherProfile = Profile(name: "Other profile")
        app.library.profiles.append(otherProfile)
        let firstTab = BrowserTab(title: "First", pinned: true, engineID: .webkit)
        let secondTab = BrowserTab(title: "Second", engineID: .webkit)
        app.library.sessions = [WindowSession(profileID: originalProfile.id, tabs: [firstTab, secondTab])]
        let browser = BrowserModel(app: app, isPrivate: false)
        defer {
            app.ready = false; app.unfreezeQuitData(); app.terminating = false
            browser.closeWindow(); try? FileManager.default.removeItem(at: directory)
        }
        browser.closedTabs = [BrowserTab(title: "Closed", url: URL(string: "https://quit.fixture.invalid/closed"))]
        let deletedID = UUID()
        app.library.pendingProfileDeletions = [deletedID]
        app.library.pendingWebsiteDataClears = [originalProfile.id]
        try #require(await app.flush())
        let baseline = app.library, session = browser.session, closedTabs = browser.closedTabs
        let blocked = Note(profileID: originalProfile.id, title: "Blocked", text: "Never save this frozen edit")

        app.terminating = true; app.freezeQuitData()
        app.library.notes.append(blocked)
        app.library.preferences.configuration.theme.accent = .orange
        browser.session.tabs[0].title = "Blocked title"
        browser.newTab()
        browser.reopenClosedTab()
        browser.closeTab(firstTab.id)
        browser.pinTab(firstTab.id)
        browser.changeProfile(otherProfile.id)
        browser.changeEngine(firstTab.id, to: .chromium)
        browser.beginSplit(.sideBySide)
        browser.navigate("https://quit.fixture.invalid/blocked")
        #expect(app.finalQuitDataFrozen)
        #expect(app.library == baseline)
        #expect(browser.session == session)
        #expect(browser.closedTabs == closedTabs)

        // Accepted cleanup may clear its durable retry records synchronously;
        // returning from that closure must immediately restore the freeze.
        app.updateQuitCleanup { library in
            library.pendingProfileDeletions?.removeAll()
            library.pendingWebsiteDataClears?.removeAll()
        }
        app.library.notes.append(blocked)
        #expect(app.library.notes == baseline.notes)
        try #require(await app.flushForTermination())
        let database = try LibraryDatabase(url: directory.appendingPathComponent("library.sqlite"))
        let cleaned = try await database.load()
        #expect(cleaned.pendingProfileDeletions?.isEmpty != false)
        #expect(cleaned.pendingWebsiteDataClears?.isEmpty != false)
        #expect(cleaned.notes == baseline.notes)
        #expect(cleaned.sessions == baseline.sessions)
        #expect(cleaned.profiles == baseline.profiles)

        app.unfreezeQuitData(); app.terminating = false
        let resumed = Note(profileID: originalProfile.id, title: "After cancelled quit", text: "Autosave must resume")
        app.library.notes.append(resumed)
        browser.newTab()
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        var persisted = try await database.load()
        while (!persisted.notes.contains(where: { $0.id == resumed.id }) || persisted.sessions != app.library.sessions), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
            persisted = try await database.load()
        }
        #expect(persisted.notes == baseline.notes + [resumed])
        #expect(persisted.sessions == app.library.sessions)
        #expect(browser.session.tabs.count == session.tabs.count + 1)
        #expect(persisted.profiles == baseline.profiles)
    }

    @Test func simultaneousStartupRecoveryKeepsOneBackupAndWritesToTheNewDatabase() async throws {
        let directory = temporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let originalBytes = Data("A corrupt database that recovery must preserve".utf8)
        try originalBytes.write(to: directory.appendingPathComponent("library.sqlite"))
        let app = AppState(directory: directory)
        defer { app.ready = false; try? FileManager.default.removeItem(at: directory) }
        await app.load()
        try #require(!app.ready && app.startupError != nil)

        // Separate startup-error windows can request recovery at the same time.
        // The second request must never move the first request's open database.
        let first = Task { @MainActor in await app.resetLibrary() }
        let second = Task { @MainActor in await app.resetLibrary() }
        await first.value; await second.value
        try #require(app.ready && app.startupError == nil)
        let backups = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("Recovery-") }
        let backup = try #require(backups.count == 1 ? backups.first : nil)
        #expect(try Data(contentsOf: backup.appendingPathComponent("library.sqlite")) == originalBytes)
        let saved = Note(profileID: app.library.profiles[0].id, title: "Recovered", text: "Write to the active data directory")
        app.library.notes.append(saved)
        try #require(await app.flush())
        let reopened = try LibraryDatabase(url: directory.appendingPathComponent("library.sqlite"))
        #expect(try await reopened.load().notes == [saved])
        #expect(try Data(contentsOf: backup.appendingPathComponent("library.sqlite")) == originalBytes)
    }

    @Test func overlappingWebsiteClearRequestsRetryWithoutLosingExistingQueuesOrUnrelatedEdits() async throws {
        let (app, directory) = try await fixture()
        defer { app.ready = false; try? FileManager.default.removeItem(at: directory) }
        let existing = app.library.profiles[0]
        let firstProfile = Profile(name: "First request"), secondProfile = Profile(name: "Second request")
        app.library.profiles.append(contentsOf: [firstProfile, secondProfile])
        try await app.requestWebsiteDataClear(existing.id)
        var firstSave: ProfileCallbackWait<Bool>?
        let first = Task { @MainActor in
            try await app.requestWebsiteDataClear(firstProfile.id, persist: {
                (try? await ProfileCallbackWait<Bool>.wait("the first website-clear save") { request in firstSave = request }) ?? false
            })
        }
        defer { firstSave?.finish(.success(false)); first.cancel() }
        let deadline = ContinuousClock().now.advanced(by: .seconds(5))
        while firstSave == nil && ContinuousClock().now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let heldSave = try #require(firstSave)
        #expect(Set(app.library.pendingWebsiteDataClears ?? []) == [existing.id, firstProfile.id])
        for id in [secondProfile.id, firstProfile.id] {
            var rejected = false
            do { try await app.requestWebsiteDataClear(id) }
            catch { rejected = true }
            #expect(rejected, "Overlapping and duplicate requests must explicitly retry instead of reporting unsaved success.")
        }
        var deletionRejected = false
        do { try await app.deleteProfile(firstProfile.id, replacingWith: existing.id) }
        catch { deletionRejected = true }
        #expect(deletionRejected)
        let edit = Note(profileID: secondProfile.id, title: "Concurrent edit", text: "Keep this when the first save fails")
        app.library.notes.append(edit)
        heldSave.finish(.success(false))
        var firstFailed = false
        do { try await first.value }
        catch { firstFailed = true }
        #expect(firstFailed)
        #expect(!app.savingWebsiteDataClearRequest)
        #expect(app.library.pendingWebsiteDataClears == [existing.id])
        #expect(app.library.notes == [edit])
        #expect(app.library.profiles.contains { $0.id == firstProfile.id })

        // Retrying invokes the real database writer. Repeating a successful
        // profile request must preserve the other durable requests as well.
        try await app.requestWebsiteDataClear(secondProfile.id)
        try await app.requestWebsiteDataClear(firstProfile.id)
        try await app.requestWebsiteDataClear(secondProfile.id)
        let database = try LibraryDatabase(url: directory.appendingPathComponent("library.sqlite"))
        let persisted = try await database.load()
        #expect(Set(persisted.pendingWebsiteDataClears ?? []) == [existing.id, firstProfile.id, secondProfile.id])
        #expect(persisted.notes == [edit])
        #expect(persisted.profiles == app.library.profiles)
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
