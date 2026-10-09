// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
import CSQLite
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
@Test func legacySessionsAndSetupsLoadWithoutTreeOrSplitFields() throws {
    let original = WindowSession(profileID: UUID())
    var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
    object.removeValue(forKey: "split")
    var tabs = try #require(object["tabs"] as? [[String: Any]])
    tabs[0].removeValue(forKey: "parentID"); tabs[0].removeValue(forKey: "collapsed"); object["tabs"] = tabs
    let decoded = try JSONDecoder().decode(WindowSession.self, from: JSONSerialization.data(withJSONObject: object))
    #expect(decoded == original)
    let legacy = Data(#"{"formatVersion":1,"name":"Old setup","configuration":{"theme":{"design":"native","colorMode":"system","accent":"blue","density":"comfortable","cornerRadius":10,"transparency":true,"reducedMotion":false},"layout":{"tabs":"top","navigation":"top","sidebar":"leading","sidebarWidth":240,"bookmarksBar":false,"statusBar":true}}}"#.utf8)
    #expect(try SetupPack.decode(legacy).configuration.layout.split == nil)
    #expect(try SetupPack.decode(legacy).configuration.layout.treeTabs == nil)
}
@Test func tabTreesRejectCyclesAndExposeSelectedChildren() {
    let root = BrowserTab(), child = BrowserTab(), grandchild = BrowserTab()
    var session = WindowSession(profileID: UUID(), tabs: [root, child, grandchild])
    let childMoved = session.setParent(child.id, to: root.id); #expect(childMoved)
    let grandchildMoved = session.setParent(grandchild.id, to: child.id); #expect(grandchildMoved)
    let cycle = session.setParent(root.id, to: grandchild.id); #expect(!cycle)
    let selfParent = session.setParent(root.id, to: root.id); #expect(!selfParent)
    let missingParent = session.setParent(root.id, to: UUID()); #expect(!missingParent)
    session.tabs[0].collapsed = true
    #expect(session.visibleTreeTabs.map(\.id) == [root.id])
    session.selectTab(grandchild.id)
    #expect(session.visibleTreeTabs.map(\.id) == [root.id, child.id, grandchild.id])
    #expect(session.ancestors(of: grandchild.id) == [child.id, root.id])
    session.tabs[0].parentID = grandchild.id
    session.normalize()
    #expect(session.visibleTreeTabs.count == 3)
    #expect(session.tabs[0].parentID == nil)
}
@Test func tabTreesBoundDepthIncludingMovedSubtrees() {
    var session = WindowSession(profileID: UUID(), tabs: (0..<11).map { _ in BrowserTab() })
    for i in 1...8 { let moved = session.setParent(session.tabs[i].id, to: session.tabs[i - 1].id); #expect(moved) }
    let tooDeep = session.setParent(session.tabs[9].id, to: session.tabs[8].id); #expect(!tooDeep)
    let childMoved = session.setParent(session.tabs[10].id, to: session.tabs[9].id); #expect(childMoved)
    let subtreeTooDeep = session.setParent(session.tabs[9].id, to: session.tabs[7].id); #expect(!subtreeTooDeep)
    session.tabs[9].parentID = session.tabs[8].id
    session.normalize()
    #expect(session.tabs[9].parentID == nil)
}
@Test func splitSelectionReplacesOnlyActivePaneAndRepairsMissingTabs() throws {
    let a = BrowserTab(), b = BrowserTab(), c = BrowserTab()
    var session = WindowSession(profileID: UUID(), tabs: [a, b, c])
    session.enableSplit()
    #expect(session.split == TabSplit(first: a.id, second: b.id))
    session.selectTab(b.id); session.selectTab(c.id)
    #expect(session.split == TabSplit(first: a.id, second: c.id))
    let restored = try JSONDecoder().decode(WindowSession.self, from: JSONEncoder().encode(session))
    #expect(restored == session)
    session.tabs.removeAll { $0.id == a.id }; session.normalize()
    #expect(session.split == nil)
    session.split = TabSplit(first: c.id, second: c.id); session.normalize()
    #expect(session.split == nil)
    var empty = WindowSession(profileID: UUID()); empty.enableSplit()
    #expect(empty.tabs.count == 2)
    #expect(empty.selectedTabID == empty.split?.first)
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
@Test func bookmarkEntitiesDecodeOnceWithoutCorruptingURLs() throws {
    let data = Data(#"<a href='https://example.test/?a=1&#38;b=2'>A&#39;s &#x1F4D6; &amp;lt;</a>"#.utf8)
    let bookmarks = try BookmarkExchange.parse(data, profileID: UUID())
    #expect(bookmarks[0].url.absoluteString == "https://example.test/?a=1&b=2")
    #expect(bookmarks[0].title == "A's 📖 &lt;")
}
@Test func malformedBookmarkAnchorsHaveBoundedParsingTime() {
    let malformed = Data(String(repeating: #"<a href="https://example.test">"#, count: 10_000).utf8)
    let clock = ContinuousClock(), start = clock.now
    #expect(throws: (any Error).self) { try BookmarkExchange.parse(malformed, profileID: UUID()) }
    #expect(start.duration(to: clock.now) < .seconds(5))
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
    for id in ["../escape", "a/b", ".hidden", "a..b", "", "💣", "ORG.RADIUS.NOTES"] {
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

@Test func searchesWithColonsAndIPv6LoopbackWork() {
    for text in ["site:example.com Swift", "C++: vector", "swift: actor"] {
        let url = AddressResolver.resolve(text)
        #expect(url?.host == "duckduckgo.com")
        #expect(url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems?.first?.value } == text)
    }
    #expect(AddressResolver.resolve("[::1]:8080/test")?.scheme == "http")
    #expect(AddressResolver.resolve("ftp://example.com") == nil)
}
@Test func updatesKeepDisabledModulesDisabled() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = try ModuleRepository(root: directory)
    var manifest = module("org.radius.notes", .notes)
    try repository.install(manifest); try repository.setEnabled(manifest.id, false)
    manifest.version = 2
    try repository.install(manifest)
    #expect(try repository.installed().first?.manifest.version == 2)
    #expect(try repository.installed().first?.enabled == false)
}

@Test func newerDatabaseIsRejectedWithoutMutation() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("library.sqlite")
    var handle: OpaquePointer?
    #expect(sqlite3_open(url.path, &handle) == SQLITE_OK)
    #expect(sqlite3_exec(handle, "PRAGMA user_version=2; CREATE TABLE future(data TEXT);", nil, nil, nil) == SQLITE_OK)
    sqlite3_close(handle)
    let before = try Data(contentsOf: url)
    #expect(throws: (any Error).self) { try LibraryDatabase(url: url) }
    #expect(try Data(contentsOf: url) == before)
}

@Test func interruptedModuleUpdateRestoresPreviousPackage() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = try ModuleRepository(root: directory)
    let manifest = module("org.radius.notes", .notes)
    try repository.install(manifest); try repository.setEnabled(manifest.id, false)
    let backup = ".backup-" + UUID().uuidString
    let stage = ".stage-" + UUID().uuidString
    try FileManager.default.moveItem(at: directory.appendingPathComponent(manifest.id), to: directory.appendingPathComponent(backup))
    let journal = try JSONSerialization.data(withJSONObject: ["id": manifest.id, "stage": stage, "backup": backup])
    try journal.write(to: directory.appendingPathComponent(".transaction.json"))
    let repaired = try ModuleRepository(root: directory)
    #expect(try repaired.installed().first?.manifest == manifest)
    #expect(try repaired.installed().first?.enabled == false)
    #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent(".transaction.json").path))
}
