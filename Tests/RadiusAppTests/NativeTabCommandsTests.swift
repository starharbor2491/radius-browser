// SPDX-License-Identifier: MPL-2.0
import AppKit
import Testing
@testable import RadiusApp

extension NativeIntegrationTests.BrowserIntegrationTests {
    @Test func nativeTabMenuTargetsTheCurrentOwnedWindowAndRejectsFrozenOrClosedModels() throws {
        _ = NSApplication.shared
        let previousState = AppDelegate.state
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("radius-menu-test-" + UUID().uuidString)
        let app = AppState(directory: directory)
        let first = BrowserModel(app: app, isPrivate: true)
        let second = BrowserModel(app: app, isPrivate: true)
        let firstWindow = commandWindow(), secondWindow = commandWindow(), otherWindow = commandWindow()
        let firstProxy = WindowDelegateProxy(original: nil, model: first)
        let secondProxy = WindowDelegateProxy(original: nil, model: second)
        firstWindow.delegate = firstProxy; secondWindow.delegate = secondProxy
        defer {
            app.unfreezeQuitData()
            firstWindow.delegate = nil; secondWindow.delegate = nil
            firstWindow.close(); secondWindow.close(); otherWindow.close()
            first.closeWindow(); second.closeWindow()
            withExtendedLifetime((firstProxy, secondProxy)) {}
            AppDelegate.state = previousState
            try? FileManager.default.removeItem(at: directory)
        }
        let commands = NativeTabCommands()
        let menu = commandMenu()
        commands.install(in: menu)
        let file = try #require(menu.items[0].submenu)
        let browse = try #require(menu.items[1].submenu)
        func item(_ id: String) throws -> NSMenuItem {
            try #require((file.items + browse.items).first { $0.identifier?.rawValue == "radius.tab." + id })
        }
        func perform(_ id: String) throws {
            let entry = try item(id), owner = try #require(entry.menu)
            owner.performActionForItem(at: owner.index(of: entry))
        }
        let new = try item("new"), reopen = try item("reopen")
        let original = first.session.selectedTabID
        firstWindow.makeKeyAndOrderFront(nil)
        try #require(NSApp.keyWindow === firstWindow)
        file.update(); browse.update()
        #expect(new.isEnabled && !reopen.isEnabled)
        try perform("new")
        #expect(first.session.tabs.count == 2 && second.session.tabs.count == 1)
        let added = first.session.selectedTabID
        try perform("previous"); #expect(first.session.selectedTabID == original)
        try perform("next"); #expect(first.session.selectedTabID == added)
        let closedURL = URL(string: "https://menu-fixture.invalid/closed")!
        first.session.tabs[1].url = closedURL
        try perform("close")
        file.update()
        #expect(first.session.tabs.count == 1 && reopen.isEnabled)
        try perform("reopen")
        #expect(first.session.tabs.count == 2 && first.selectedTab.url == closedURL)

        // Validation may have run before focus changes. Invocation must resolve
        // the new actual key window instead of retaining the previous model.
        file.update()
        secondWindow.makeKeyAndOrderFront(nil)
        try #require(NSApp.keyWindow === secondWindow)
        try perform("new")
        #expect(second.session.tabs.count == 2 && first.session.tabs.count == 2)
        let firstSnapshot = first.session, secondSnapshot = second.session
        app.freezeQuitData()
        file.update(); browse.update()
        for entry in (file.items + browse.items) where entry.target === commands {
            #expect(!entry.isEnabled)
            #expect(NSApp.sendAction(try #require(entry.action), to: entry.target, from: entry))
        }
        #expect(first.session == firstSnapshot && second.session == secondSnapshot)
        app.unfreezeQuitData()
        file.update()
        #expect(new.isEnabled)

        otherWindow.makeKeyAndOrderFront(nil)
        try #require(NSApp.keyWindow === otherWindow)
        file.update()
        #expect(!new.isEnabled)
        #expect(NSApp.sendAction(try #require(new.action), to: new.target, from: new))
        #expect(first.session == firstSnapshot && second.session == secondSnapshot)
        secondWindow.makeKeyAndOrderFront(nil)
        try #require(NSApp.keyWindow === secondWindow)
        second.closeWindow()
        file.update()
        #expect(!new.isEnabled)
        #expect(NSApp.sendAction(try #require(new.action), to: new.target, from: new))
        #expect(second.session == secondSnapshot)
    }

    @Test func nativeTabMenuSurvivesMenuReplacementWithoutDuplicatingCommandsOrCocoaEditingItems() throws {
        _ = NSApplication.shared
        let commands = NativeTabCommands(), menu = commandMenu()
        let file = try #require(menu.items[0].submenu)
        let standardClose = NSMenuItem(title: "System close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        standardClose.keyEquivalentModifierMask = .command
        let otherClose = NSMenuItem(title: "Other close", action: standardClose.action, keyEquivalent: "w")
        otherClose.keyEquivalentModifierMask = [.command, .option]
        let closeAll = NSMenuItem(title: "Close all", action: NSSelectorFromString("closeAll:"), keyEquivalent: "")
        file.addItem(standardClose); file.addItem(otherClose); file.addItem(closeAll)
        let edit = NSMenu(title: "Localized editing menu")
        let top = NSMenuItem(); top.submenu = edit; menu.addItem(top)
        let copy = NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        let dictation = NSMenuItem(title: "First dictation", action: NSSelectorFromString("startDictation:"), keyEquivalent: "")
        dictation.target = NSApp
        let emoji = NSMenuItem(title: "First emoji", action: #selector(NSApplication.orderFrontCharacterPalette(_:)), keyEquivalent: "")
        let separator = NSMenuItem.separator()
        let unrelated = NSMenuItem(title: "Emoji & Symbols", action: #selector(NSText.paste(_:)), keyEquivalent: "")
        edit.addItem(copy); edit.addItem(dictation); edit.addItem(separator)
        edit.addItem(NSMenuItem(title: "Other dictation", action: dictation.action, keyEquivalent: ""))
        edit.addItem(emoji)
        for _ in 0..<2 { edit.addItem(NSMenuItem(title: "Other emoji", action: emoji.action, keyEquivalent: "")) }
        edit.addItem(unrelated)
        commands.install(in: menu)
        #expect(!file.items.contains(standardClose) && file.items.contains(otherClose) && file.items.contains(closeAll))
        #expect(edit.items == [copy, dictation, separator, emoji, unrelated])
        #expect(dictation.target === NSApp && emoji.target == nil)
        let originals = menu.items.prefix(2).flatMap { $0.submenu?.items ?? [] }
        let owned = originals.filter { $0.target === commands }
        #expect(owned.count == 5)
        #expect(Set(owned.compactMap { $0.identifier?.rawValue }).count == 5)
        #expect(owned.allSatisfy { $0.action != nil })
        commands.install(in: menu)
        #expect(menu.items.prefix(2).flatMap { $0.submenu?.items ?? [] } == originals)
        #expect(edit.items == [copy, dictation, separator, emoji, unrelated])

        let replacement = commandMenu()
        commands.install(in: replacement)
        let restored = replacement.items.flatMap { $0.submenu?.items ?? [] }.filter { $0.target === commands }
        #expect(restored == owned)
        #expect(menu.items.prefix(2).flatMap { $0.submenu?.items ?? [] }.allSatisfy { $0.target !== commands })
        #expect(restored.map(\.keyEquivalent) == ["t", "t", "w", "[", "]"])
        #expect(restored.map(\.keyEquivalentModifierMask) == [.command, [.command, .shift], .command, [.command, .shift], [.command, .shift]])
    }

    private func commandWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }

    private func commandMenu() -> NSMenu {
        let menu = NSMenu()
        // Deliberately unrelated titles ensure placement depends on the
        // application's declared shortcuts, not an English menu label.
        let groups: [(String, [(String, NSEvent.ModifierFlags)])] = [
            ("First", [("n", NSEvent.ModifierFlags.command.union(.shift)), ("w", [.command, .shift])]),
            ("Second", [("l", NSEvent.ModifierFlags.command), ("`", [.command, .option])])
        ]
        for (title, definitions) in groups {
            let submenu = NSMenu(title: title), top = NSMenuItem()
            top.submenu = submenu; menu.addItem(top)
            for (key, modifiers) in definitions {
                let item = NSMenuItem(title: UUID().uuidString, action: nil, keyEquivalent: key)
                item.keyEquivalentModifierMask = modifiers; submenu.addItem(item)
            }
        }
        return menu
    }
}
