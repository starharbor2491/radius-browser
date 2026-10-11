// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
@testable import RadiusCore

@Test func profileDeletionRejectsInvalidTargetsWithoutMutatingTheLibrary() throws {
    var state = LibraryState()
    let first = state.profiles[0].id
    let second = Profile(name: "Work")
    state.profiles.append(second)
    let original = state
    for (removed, replacement) in [(first, first), (UUID(), second.id), (first, UUID())] {
        #expect(throws: (any Error).self) { try state.removeProfile(removed, replacingWith: replacement) }
        #expect(state == original)
    }
    state.profiles = [original.profiles[0]]
    let singleProfile = state
    #expect(throws: (any Error).self) { try state.removeProfile(first, replacingWith: second.id) }
    #expect(state == singleProfile)
}

@Test func profileDeletionScopesDataAndReplacesAffectedWindowsWithBlankSessions() throws {
    var state = LibraryState()
    let deleted = state.profiles[0]
    var retained = Profile(name: "Work"); retained.engineID = .chromium
    state.profiles.append(retained)
    let url = try #require(URL(string: "https://example.com/private-page"))
    let deletedBookmark = Bookmark(profileID: deleted.id, title: "Removed bookmark", url: url)
    let keptBookmark = Bookmark(profileID: retained.id, title: "Kept bookmark", url: url)
    let deletedHistory = HistoryEntry(profileID: deleted.id, title: "Removed history", url: url)
    let keptHistory = HistoryEntry(profileID: retained.id, title: "Kept history", url: url)
    let deletedNote = Note(profileID: deleted.id, text: "Removed note")
    let keptNote = Note(profileID: retained.id, text: "Kept note")
    state.bookmarks = [deletedBookmark, keptBookmark]; state.history = [deletedHistory, keptHistory]
    state.notes = [deletedNote, keptNote]
    var affected = WindowSession(profileID: deleted.id, tabs: [BrowserTab(url: url, pinned: true), BrowserTab(url: url)])
    affected.enableSplit(); affected.selectTab(affected.tabs[1].id)
    let unaffected = WindowSession(profileID: retained.id, tabs: [BrowserTab(url: url)])
    state.sessions = [affected, unaffected]

    let removed = try state.removeProfile(deleted.id, replacingWith: retained.id)
    #expect(removed.profile == deleted)
    #expect(removed.bookmarks == [deletedBookmark]); #expect(removed.history == [deletedHistory])
    #expect(removed.notes == [deletedNote]); #expect(removed.sessions == [affected])
    #expect(state.profiles == [retained])
    #expect(state.bookmarks == [keptBookmark]); #expect(state.history == [keptHistory]); #expect(state.notes == [keptNote])
    let replacement = try #require(state.sessions.first(where: { $0.id == affected.id }))
    #expect(replacement.profileID == retained.id)
    #expect(replacement.tabs.count == 1)
    #expect(replacement.tabs[0].url == nil && !replacement.tabs[0].pinned && replacement.tabs[0].parentID == nil)
    #expect(replacement.tabs[0].engineID == .chromium)
    #expect(replacement.selectedTabID == replacement.tabs[0].id && replacement.split == nil)
    #expect(state.sessions.first(where: { $0.id == unaffected.id }) == unaffected)
    #expect(state.pendingProfileDeletions == [deleted.id])
}

@Test func failedProfileDeletionRestoresOnlyItsContentsAndPreservesOtherEdits() throws {
    var state = LibraryState()
    let deleted = state.profiles[0]
    let retained = Profile(name: "Work"); state.profiles.append(retained)
    let originalSession = WindowSession(profileID: deleted.id, tabs: [BrowserTab(title: "Restore this tab")])
    state.sessions = [originalSession, WindowSession(profileID: retained.id)]
    state.notes = [Note(profileID: deleted.id, text: "Restore this note")]
    let unrelatedTombstone = UUID(); state.pendingProfileDeletions = [unrelatedTombstone]
    let removed = try state.removeProfile(deleted.id, replacingWith: retained.id)
    state.profiles[0].name = "Renamed while saving"
    let addedProfile = Profile(name: "Added while saving"); state.profiles.append(addedProfile)
    let addedNote = Note(profileID: retained.id, text: "Keep the concurrent edit"); state.notes.append(addedNote)
    state.sessions[1].tabs[0].title = "Keep the concurrent tab edit"
    let concurrentSession = state.sessions[1]
    state.restoreProfile(removed)

    #expect(state.profiles.first(where: { $0.id == retained.id })?.name == "Renamed while saving")
    #expect(state.profiles.contains(addedProfile))
    #expect(state.profiles.contains(deleted))
    #expect(state.notes.contains(addedNote) && state.notes.contains(removed.notes[0]))
    #expect(state.sessions.first(where: { $0.id == originalSession.id }) == originalSession)
    #expect(state.sessions.first(where: { $0.id == concurrentSession.id }) == concurrentSession)
    #expect(state.pendingProfileDeletions == [unrelatedTombstone])
    let onceRestored = state; state.restoreProfile(removed)
    #expect(state == onceRestored)
}

@Test func deletedProfileTombstoneSurvivesDatabaseRestartWithoutReturningItsData() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("radius-deletion-test-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let databaseURL = directory.appendingPathComponent("library.sqlite")
    let database = try LibraryDatabase(url: databaseURL)
    var state = LibraryState()
    let deleted = state.profiles[0].id, retained = Profile(name: "Work")
    state.profiles.append(retained)
    state.sessions = [WindowSession(profileID: deleted)]
    state.notes = [Note(profileID: deleted, text: "Deleted data")]
    _ = try state.removeProfile(deleted, replacingWith: retained.id)
    try await database.save(state, revision: 1)
    try await database.checkpoint()
    let reopened = try LibraryDatabase(url: databaseURL)
    let restored = try await reopened.load()
    #expect(restored == state)
    #expect(restored.pendingProfileDeletions == [deleted])
    #expect(restored.notes.isEmpty && restored.sessions[0].profileID == retained.id)
}

@Test func legacyAppearanceAndLayoutDecodeWithOptionalCustomizationAbsent() throws {
    let data = Data(#"{"theme":{"design":"material","colorMode":"dark","accent":"teal","density":"compact","cornerRadius":8,"transparency":false,"reducedMotion":true},"layout":{"tabs":"trailing","navigation":"bottom","sidebar":"hidden","sidebarWidth":260,"bookmarksBar":true,"statusBar":false}}"#.utf8)
    let config = try JSONDecoder().decode(Configuration.self, from: data)
    #expect(config.theme.design == .material && config.theme.density == .compact && config.theme.cornerRadius == 8)
    #expect(config.theme.typography == nil && config.theme.fontScale == nil && config.theme.accentHex == nil)
    #expect(config.theme.tabsAppearance == nil && config.theme.navigationAppearance == nil && config.theme.sidebarAppearance == nil)
    #expect(config.layout.tabs == .trailing && config.layout.navigation == .bottom && config.layout.sidebarWidth == 260)
    #expect(config.layout.toolbarComponents == nil && config.layout.addressWidth == nil && config.layout.tabsWidth == nil)
    #expect(config.layout.hideTabStrip == nil && config.layout.sidebarAutoHide == nil && config.layout.secondaryPanel == nil)
    #expect(try JSONDecoder().decode(Configuration.self, from: JSONEncoder().encode(config)) == config)
}

@Test func importedCustomizationBoundsKeepTheInterfaceFiniteAndCommandsUnique() {
    var config = Configuration()
    config.theme.cornerRadius = .nan; config.theme.fontScale = .infinity; config.theme.spacingScale = -10
    config.theme.borderWidth = 100; config.theme.shadowStrength = -1
    config.theme.accentHex = "javascript:alert(1)"; config.theme.surfaceHex = "#12aBf0"; config.theme.textHex = "１２３４５６"
    var component = ComponentAppearance(); component.cornerRadius = .infinity; component.fontScale = 50
    config.theme.navigationAppearance = component
    config.layout.sidebarWidth = .infinity; config.layout.addressWidth = 0; config.layout.tabsWidth = 1000
    config.layout.treeTabs = true; config.layout.tabs = .bottom; config.layout.secondaryPanel = "unknown"
    let duplicate = UUID()
    config.layout.toolbarComponents = [ToolbarComponent(id: duplicate, command: .back, region: .beforeAddress),
        ToolbarComponent(id: duplicate, command: .forward, region: .beforeAddress),
        ToolbarComponent(command: .back, region: .afterAddress)] +
        (0..<40).map { _ in ToolbarComponent(command: .separator, region: .top) }
    config.normalize()
    #expect(config.theme.cornerRadius == 10 && config.theme.fontScale == 1 && config.theme.spacingScale == 0.75)
    #expect(config.theme.borderWidth == 2 && config.theme.shadowStrength == 0)
    #expect(config.theme.accentHex == nil && config.theme.textHex == nil && config.theme.surfaceHex == nil)
    #expect(config.theme.navigationAppearance?.cornerRadius == 10 && config.theme.navigationAppearance?.fontScale == 1.4)
    #expect(config.layout.sidebarWidth == 240 && config.layout.addressWidth == 0.4 && config.layout.tabsWidth == 320)
    #expect(config.layout.tabs == .leading && config.layout.secondaryPanel == nil)
    #expect(config.layout.toolbarComponents?.count == 32)
    #expect(config.layout.toolbarComponents?.filter { $0.command == .back }.count == 1)
    #expect(config.layout.toolbarComponents?.contains(where: { $0.command == .forward }) == false)
    let onceNormalized = config; config.normalize(); #expect(config == onceNormalized)
}

@Test func customRGBColorsUseStandardContrastAndRejectMalformedInputs() throws {
    let white = try #require(InterfaceColor(hex: "#FFFFFF")), black = try #require(InterfaceColor(hex: "000000"))
    let gray = try #require(InterfaceColor(hex: "777777"))
    #expect(abs(white.contrastRatio(against: black) - 21) < 0.000_001)
    #expect(white.contrastRatio(against: white) == 1)
    #expect(abs(gray.contrastRatio(against: white) - 4.478_089_453_577_214) < 0.000_001)
    #expect(gray.contrastRatio(against: white) == white.contrastRatio(against: gray))
    #expect(InterfaceColor(hex: "12abCD") == InterfaceColor(hex: "#12ABcd"))
    for input in ["FFF", "FFFFFFFF", "#GGGGGG", "#１２３４５６", " 123456", "123456 ", "##123456"] {
        #expect(InterfaceColor(hex: input) == nil)
    }
}

@Test func importedAndPersistedCustomColorsStayPairedAcrossSystemAppearances() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("radius-color-pair-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let cases: [(surface: String?, text: String?, mode: ColorMode)] = [
        (nil, "#FFFFFF", .light), ("#000000", nil, .dark),
        ("#FFFFFF", "invalid", .light), ("#17212B", "#F1F5F9", .dark)
    ]
    for (index, colors) in cases.enumerated() {
        var configuration = Configuration()
        configuration.theme.surfaceHex = colors.surface; configuration.theme.textHex = colors.text
        configuration.theme.colorMode = colors.mode; configuration.theme.accentHex = "#66D9CC"
        configuration.theme.typography = .rounded
        let imported = try SetupPack.decode(JSONEncoder().encode(SetupPack(name: "Color setup", configuration: configuration)))
        let expectedSurface = index == cases.count - 1 ? "#17212B" : nil
        let expectedText = index == cases.count - 1 ? "#F1F5F9" : nil
        #expect(imported.configuration.theme.surfaceHex == expectedSurface)
        #expect(imported.configuration.theme.textHex == expectedText)
        #expect(imported.configuration.theme.colorMode == colors.mode)
        #expect(imported.configuration.theme.accentHex == "#66D9CC" && imported.configuration.theme.typography == .rounded)

        // Save the original malformed values to exercise startup repair, including
        // named setups; an export/import round trip alone would miss this path.
        let databaseURL = directory.appendingPathComponent("library-\(index).sqlite")
        let database = try LibraryDatabase(url: databaseURL)
        var library = LibraryState()
        library.preferences.configuration = configuration
        library.preferences.savedConfigurations = [NamedConfiguration(name: "Saved colors", configuration: configuration)]
        try await database.save(library, revision: 1)
        try await database.checkpoint()
        let reopened = try LibraryDatabase(url: databaseURL)
        let restored = try await reopened.load()
        #expect(restored.preferences.configuration == imported.configuration)
        #expect(restored.preferences.savedConfigurations.first?.configuration == imported.configuration)
        #expect(restored.profiles == library.profiles)
    }
}

@Test func normalizationKeepsPinnedTabsFirstAndSelectedTreeChildrenReachable() {
    var root = BrowserTab(title: "Root"); root.collapsed = true
    let child = BrowserTab(title: "Selected child", parentID: root.id)
    let ordinary = BrowserTab(title: "Ordinary")
    let pinned = BrowserTab(title: "Pinned", pinned: true, parentID: child.id)
    var session = WindowSession(profileID: UUID(), tabs: [ordinary, root, pinned, child])
    session.selectedTabID = child.id; session.normalize()
    #expect(session.tabs.map(\.id) == [pinned.id, ordinary.id, root.id, child.id])
    #expect(session.tabs[0].parentID == nil)
    #expect(session.selectedTabID == child.id && session.visibleTreeTabs.contains(where: { $0.id == child.id }))
    #expect(session.tabs.first(where: { $0.id == root.id })?.collapsed == false)
}
