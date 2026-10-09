// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
@testable import RadiusCore

@Test func addressesAreResolvedSafely() {
    #expect(AddressResolver.resolve("example.com")?.absoluteString == "https://example.com")
    #expect(AddressResolver.resolve("localhost:8080/a")?.absoluteString == "http://localhost:8080/a")
    #expect(AddressResolver.resolve(" https://example.com/a?x=1 ")?.host == "example.com")
    #expect(AddressResolver.resolve("javascript:alert(1)") == nil)
    #expect(AddressResolver.resolve("file:///etc/passwd") == nil)
    #expect(AddressResolver.resolve("https://user:pass@example.com") == nil)
    #expect(AddressResolver.resolve("https://") == nil)
    #expect(AddressResolver.resolve(" ") == nil)
    let search = AddressResolver.resolve("swift actor isolation")!
    #expect(URLComponents(url: search, resolvingAgainstBaseURL: false)?.queryItems?.first?.value == "swift actor isolation")
}
@Test func sessionRepairsMissingSelectionAndDuplicateTabs() {
    let tab = BrowserTab(url: URL(string: "file:///private/data"))
    var session = WindowSession(profileID: UUID(), tabs: [tab, tab])
    session.selectedTabID = UUID()
    session.normalize()
    #expect(session.tabs.count == 1)
    #expect(session.tabs[0].url == nil)
    #expect(session.selectedTabID == tab.id)
    session.tabs = []
    session.normalize()
    #expect(session.tabs.count == 1)
}
@Test func sharedSetupContainsNoPrivateDataAndClampsDimensions() throws {
    var config = Configuration()
    config.layout.sidebarWidth = 900
    config.theme.cornerRadius = -1
    let pack = SetupPack(name: "Reading", configuration: config)
    let data = try JSONEncoder().encode(pack)
    let roundTrip = try SetupPack.decode(data)
    #expect(roundTrip.configuration.layout.sidebarWidth == 360)
    #expect(roundTrip.configuration.theme.cornerRadius == 0)
    let keys = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(Set(keys.keys) == ["formatVersion", "name", "configuration"])
    #expect(throws: (any Error).self) { try SetupPack.decode(Data(repeating: 0, count: 65_537)) }
}
@Test func databaseRoundTripAndOutOfOrderSaves() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let database = try LibraryDatabase(url: directory.appendingPathComponent("library.sqlite"))
    var state = try await database.load()
    let profileID = state.profiles[0].id
    state.bookmarks = [Bookmark(profileID: profileID, title: "An apostrophe's & Unicode 你好", url: URL(string: "https://example.com")!)]
    try await database.save(state, revision: 4)
    var stale = state; stale.bookmarks = []
    try await database.save(stale, revision: 3)
    #expect(try await database.load() == state)
    try await database.checkpoint()
    let reopened = try LibraryDatabase(url: directory.appendingPathComponent("library.sqlite"))
    #expect(try await reopened.load() == state)
}
@Test func bookmarkHTMLRoundTripIsSafeAndDeduplicated() throws {
    let profileID = UUID()
    let original = [Bookmark(profileID: profileID, title: "<Docs> & \"Help\"", url: URL(string: "https://example.com/?a=1&b=2")!)]
    let restored = try BookmarkExchange.parse(BookmarkExchange.export(original), profileID: profileID)
    #expect(restored[0].title == original[0].title)
    #expect(restored[0].url == original[0].url)
    let hostile = Data(#"<a href="javascript:alert(1)">Bad</a><A HREF='https://a.test'>OK</A><a href="https://a.test">Duplicate</a>"#.utf8)
    #expect(try BookmarkExchange.parse(hostile, profileID: profileID).count == 1)
}
@Test func moduleLifecycleRemovesFilesAndDoesNotReseedRemovedModules() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = try ModuleRepository(root: directory)
    let manifest = module("org.radius.notes", .notes)
    try repository.seedDefaults([manifest])
    #expect(try repository.installed().first?.enabled == true)
    try repository.setEnabled(manifest.id, false)
    #expect(try repository.installed().first?.enabled == false)
    try repository.uninstall(manifest.id)
    #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent(manifest.id).path))
    try repository.seedDefaults([manifest])
    #expect(try repository.installed().isEmpty)
}
@Test func dependenciesResolveInOrderAndProtectRemoval() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = try ModuleRepository(root: directory)
    let base = module("org.radius.base", .notes)
    var dependent = module("org.radius.reader", .reader); dependent.dependencies = [base.id]
    let plan = try repository.installationPlan(for: dependent.id, catalog: [dependent, base])
    #expect(plan.map(\.id) == [base.id, dependent.id])
    for manifest in plan { try repository.install(manifest) }
    #expect(throws: (any Error).self) { try repository.uninstall(base.id) }
    #expect(throws: (any Error).self) { try repository.setEnabled(base.id, false) }
    try repository.setEnabled(dependent.id, false)
    try repository.setEnabled(base.id, false)
    #expect(throws: (any Error).self) { try repository.setEnabled(dependent.id, true) }
    try repository.uninstall(dependent.id)
    try repository.uninstall(base.id)
}
@Test func invalidModulesAndCyclesAreRejected() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = try ModuleRepository(root: directory)
    for id in ["../escape", "a/b", ".hidden", "a..b", "", "💣"] {
        #expect(throws: (any Error).self) { try repository.install(module(id, .notes)) }
    }
    var a = module("org.radius.a", .notes), b = module("org.radius.b", .reader)
    a.dependencies = [b.id]; b.dependencies = [a.id]
    #expect(throws: (any Error).self) { try repository.installationPlan(for: a.id, catalog: [a, b]) }
    #expect(throws: (any Error).self) { try repository.installationPlan(for: a.id, catalog: [a, a]) }
}
@Test func symlinkModuleCannotReadOutsideRepository() throws {
    let directory = temporaryDirectory(), other = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory); try? FileManager.default.removeItem(at: other) }
    try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
    let repository = try ModuleRepository(root: directory)
    try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("org.radius.notes", isDirectory: true), withDestinationURL: other)
    #expect(throws: (any Error).self) { try repository.installed() }
}
private func temporaryDirectory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("radius-test-" + UUID().uuidString, isDirectory: true) }
private func module(_ id: String, _ capability: ModuleCapability) -> ModuleManifest { ModuleManifest(id: id, name: "Test", summary: "Test module", capability: capability) }
