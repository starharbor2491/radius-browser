// SPDX-License-Identifier: MPL-2.0
import AppKit

/// Chrome auxiliary windows have no SwiftUI scene. Keep their tab commands
/// owned by the application and resolve the real key window on every use.
@MainActor
final class NativeTabCommands: NSObject, NSMenuItemValidation {
    private var items: [NSMenuItem] = []
    private var installing = false

    override init() {
        super.init()
        let definitions: [(String, String, String, NSEvent.ModifierFlags)] = [
            ("new", "New tab", "t", .command),
            ("reopen", "Reopen closed tab", "t", [.command, .shift]),
            ("close", "Close tab", "w", .command),
            ("previous", "Previous tab", "[", [.command, .shift]),
            ("next", "Next tab", "]", [.command, .shift])
        ]
        items = definitions.map { id, title, key, modifiers in
            let item = NSMenuItem(title: title, action: #selector(performTabCommand(_:)), keyEquivalent: key)
            item.identifier = NSUserInterfaceItemIdentifier("radius.tab." + id)
            item.keyEquivalentModifierMask = modifiers
            item.target = self
            return item
        }
    }

    func install(in mainMenu: NSMenu?) {
        guard let mainMenu, !installing else { return }
        installing = true
        defer { installing = false }
        // These unique shortcuts belong to Radius's remaining SwiftUI commands.
        // They locate the standard groups without depending on localized titles
        // or changing any SwiftUI-owned item's action, target or enabled state.
        let menus = mainMenu.items.compactMap(\.submenu)
        if let file = menus.first(where: { shortcut("n", [.command, .shift], in: $0) != nil }),
           let newWindow = shortcut("n", [.command, .shift], in: file) {
            place(items[0], in: file, after: newWindow)
            place(items[1], in: file, after: items[0])
            if let closeWindow = shortcut("w", [.command, .shift], in: file) {
                place(items[2], in: file, before: closeWindow)
                // Radius assigns Command-W to the current tab. Remove only
                // Cocoa's competing window-close alias; keep Close All.
                for item in file.items where item.action == #selector(NSWindow.performClose(_:)) &&
                    item.keyEquivalent.lowercased() == "w" &&
                    item.keyEquivalentModifierMask.intersection([.command, .shift, .option, .control]) == .command {
                    file.removeItem(item)
                }
            }
            file.autoenablesItems = true
        }
        if let browse = menus.first(where: { shortcut("l", .command, in: $0) != nil }),
           let switchPane = shortcut("`", [.command, .option], in: browse) {
            place(items[4], in: browse, before: switchPane)
            place(items[3], in: browse, before: items[4])
            browse.autoenablesItems = true
        }
        // SwiftUI and Cocoa can both supply these standard Edit actions.
        // Preserve the first original responder item and its position.
        for edit in menus where edit.items.contains(where: { $0.action == #selector(NSText.copy(_:)) }) {
            for action in [NSSelectorFromString("startDictation:"), #selector(NSApplication.orderFrontCharacterPalette(_:))] {
                var found = false
                for item in edit.items where item.action == action {
                    if found { edit.removeItem(item) }
                    else { found = true }
                }
            }
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let command = command(for: menuItem), let app = AppDelegate.state,
              !app.finalQuitDataFrozen, !ChromiumRuntime.shared.finalQuitFrozen else { return false }
        if ChromiumRuntime.shared.focusedNativeTab != nil { return true }
        guard let browser = focusedBrowser, browser.app === app else { return false }
        if case .reopen = command { return browser.hasNativeTabs || !browser.closedTabs.isEmpty }
        return true
    }

    @objc private func performTabCommand(_ sender: NSMenuItem) {
        guard validateMenuItem(sender), let command = command(for: sender) else { return }
        if let tab = ChromiumRuntime.shared.focusedNativeTab {
            _ = tab.performNativeTabCommand(command)
        } else {
            focusedBrowser?.performTabCommand(command)
        }
    }

    private var focusedBrowser: BrowserModel? {
        var window = NSApp.keyWindow
        while let owner = window?.parent ?? window?.sheetParent { window = owner }
        guard let model = (window?.delegate as? WindowDelegateProxy)?.model, !model.isClosed,
              model.app.windows[model.session.id]?.model === model else { return nil }
        return model
    }

    private func command(for item: NSMenuItem) -> NativeTabCommand? {
        switch item.identifier?.rawValue {
        case "radius.tab.new": return .new
        case "radius.tab.reopen": return .reopen
        case "radius.tab.close": return .close
        case "radius.tab.previous": return .previous
        case "radius.tab.next": return .next
        default: return nil
        }
    }

    private func shortcut(_ key: String, _ modifiers: NSEvent.ModifierFlags, in menu: NSMenu) -> NSMenuItem? {
        menu.items.first {
            $0.keyEquivalent.lowercased() == key &&
            $0.keyEquivalentModifierMask.intersection([.command, .shift, .option, .control]) == modifiers
        }
    }

    private func place(_ item: NSMenuItem, in menu: NSMenu, after anchor: NSMenuItem) {
        if item.menu === menu, menu.index(of: item) == menu.index(of: anchor) + 1 { return }
        item.menu?.removeItem(item)
        menu.insertItem(item, at: menu.index(of: anchor) + 1)
    }

    private func place(_ item: NSMenuItem, in menu: NSMenu, before anchor: NSMenuItem) {
        if item.menu === menu, menu.index(of: item) + 1 == menu.index(of: anchor) { return }
        item.menu?.removeItem(item)
        menu.insertItem(item, at: menu.index(of: anchor))
    }
}
