// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
@testable import RadiusCore

@Test func chromiumPaneRestorationKeepsSafePagesAndRepairsInternalAndOversizedData() throws {
    let selected = ChromiumSessionPage(url: URL(string: "https://example.com/active"), title: String(repeating: "A", count: 600))
    let duplicate = ChromiumSessionPage(url: URL(string: "https://example.com/background"), title: "Background")
    let internalPage = ChromiumSessionPage(url: URL(string: "chrome://extensions/"), title: "Extensions")
    let credentialPage = ChromiumSessionPage(url: URL(string: "https://user:secret@example.com/"), title: "Secret")
    let oversized = ChromiumSessionPage(url: URL(string: "https://example.com/" + String(repeating: "x", count: 9000)), title: "Too long")
    let pages = [selected, duplicate, duplicate, internalPage, credentialPage, oversized]
        + Array(repeating: ChromiumSessionPage(), count: 210)
    var session = WindowSession(profileID: UUID(), tabs: [
        BrowserTab(title: "Stale outer title", url: URL(string: "https://example.com/stale"), engineID: .chromium, chromiumPages: pages)
    ])
    session.normalize()
    let saved = try #require(session.tabs[0].chromiumPages)
    #expect(saved.count == 200)
    #expect(saved[0].url == selected.url && saved[0].title.count == 512)
    #expect(saved[1] == saved[2])
    #expect(saved[3...5].allSatisfy { $0.url == nil && $0.title == "New tab" })
    #expect(session.tabs[0].url == selected.url && session.tabs[0].title == saved[0].title)
    let decoded = try JSONDecoder().decode(WindowSession.self, from: JSONEncoder().encode(session))
    #expect(decoded == session)
    let normalized = session
    session.normalize()
    #expect(session == normalized)
}

@Test func legacyTabsDecodeAndOtherEnginesDiscardChromeSessionRecords() throws {
    let original = BrowserTab(url: URL(string: "https://example.com/"), engineID: .chromium)
    var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
    object.removeValue(forKey: "chromiumPages")
    let legacy = try JSONDecoder().decode(BrowserTab.self, from: JSONSerialization.data(withJSONObject: object))
    #expect(legacy == original && legacy.chromiumPages == nil)
    var changed = original
    changed.engineID = .webkit
    changed.chromiumPages = [ChromiumSessionPage(url: URL(string: "https://other.example/"), title: "Other")]
    var session = WindowSession(profileID: UUID(), tabs: [changed])
    session.normalize()
    #expect(session.tabs[0].chromiumPages == nil)
    #expect(session.tabs[0].url == original.url)
}

@Test func websiteTitlesBoundCombiningCharactersWithoutDiscardingOrdinaryText() {
    let title = "e" + String(repeating: "\u{0301}", count: 10_000)
    #expect(title.count == 1)
    let bounded = boundedPageTitle(title)
    #expect(bounded.unicodeScalars.count == 512 && bounded.utf8.count <= 2048)
    #expect(boundedPageTitle(String(repeating: "A", count: 600)).count == 512)
    #expect(boundedPageTitle("Résumé – 日本語") == "Résumé – 日本語")
    let page = ChromiumSessionPage(url: URL(string: "https://example.com/"), title: title)
    #expect(ChromiumSessionPage.normalized([page])[0].title == bounded)
    var library = LibraryState()
    let profile = library.profiles[0].id
    library.bookmarks = [Bookmark(profileID: profile, title: title, url: page.url!)]
    library.history = [HistoryEntry(profileID: profile, title: title, url: page.url!)]
    library.sessions = [WindowSession(profileID: profile, tabs: [BrowserTab(title: title, url: page.url)])]
    library.normalize()
    #expect(library.bookmarks[0].title == bounded && library.history[0].title == bounded)
    #expect(library.sessions[0].tabs[0].title == bounded)
}
