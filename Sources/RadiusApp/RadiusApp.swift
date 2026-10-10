// SPDX-License-Identifier: MPL-2.0
import AppKit
import SwiftUI

struct RadiusApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var state = AppState()
    var body: some Scene {
        WindowGroup("Radius", id: "browser") { BrowserWindowRoot(isPrivate: false).environmentObject(state) }
            .defaultSize(width: 1240, height: 820)
            .commands { BrowserCommands() }
        WindowGroup("Radius — Private", id: "private") { BrowserWindowRoot(isPrivate: true).environmentObject(state) }
            .defaultSize(width: 1240, height: 820)
    }
}
struct BrowserCommands: Commands {
    @FocusedObject private var browser: BrowserModel?
    @Environment(\.openWindow) private var openWindow
    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New window") { openWindow(id: "browser") }.keyboardShortcut("n")
            Button("New private window") { openWindow(id: "private") }.keyboardShortcut("n", modifiers: [.command, .shift])
            Button("New tab") { browser?.newTab(); NotificationCenter.default.post(name: .radiusFocusAddress, object: browser?.session.id) }.keyboardShortcut("t").disabled(browser == nil)
            Button("Reopen closed tab") { browser?.reopenClosedTab() }.keyboardShortcut("t", modifiers: [.command, .shift]).disabled(browser?.closedTabs.isEmpty != false)
        }
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { browser?.sheet = .settings }.keyboardShortcut(",").disabled(browser == nil)
        }
        CommandGroup(replacing: .saveItem) {
            Button("Bookmark this page") { browser?.toggleBookmark() }.keyboardShortcut("d").disabled(browser?.hasPage != true || browser?.isPrivate == true)
        }
        CommandGroup(after: .newItem) {
            Button("Close tab") { if let browser { browser.closeTab(browser.session.selectedTabID) } }.keyboardShortcut("w").disabled(browser == nil)
            Button("Close window") {
                var window = NSApp.keyWindow
                while let parent = window?.parent { window = parent }
                window?.performClose(nil)
            }.keyboardShortcut("w", modifiers: [.command, .shift])
        }
        CommandMenu("Browse") {
            Button("Open location…") { NotificationCenter.default.post(name: .radiusFocusAddress, object: browser?.session.id) }.keyboardShortcut("l").disabled(browser == nil)
            Button("Reload page") { browser?.activeWebTab.reload() }.keyboardShortcut("r").disabled(browser?.hasPage != true)
            Button("Find in page…") { NotificationCenter.default.post(name: .radiusFind, object: browser?.session.id) }.keyboardShortcut("f").disabled(browser?.hasPage != true)
            Divider()
            Button("Previous tab") { browser?.selectRelativeTab(-1) }.keyboardShortcut("[", modifiers: [.command, .shift]).disabled(browser == nil)
            Button("Next tab") { browser?.selectRelativeTab(1) }.keyboardShortcut("]", modifiers: [.command, .shift]).disabled(browser == nil)
            Button("Switch browsing pane") { browser?.selectOtherPane() }
                .keyboardShortcut("`", modifiers: [.command, .option]).disabled(browser?.session.split == nil)
            Button(browser?.session.split == nil ? "Split side by side" : "Return to one pane") {
                guard let browser else { return }
                if browser.session.split != nil { browser.endSplit() }
                else { browser.beginSplit(.sideBySide) }
            }.disabled(browser == nil)
            Divider()
            Button("Modules…") { browser?.sheet = .modules }
            Button("Customize…") { browser?.sheet = .customize }
            Button("Recovery…") { browser?.sheet = .recovery }
        }
    }
}
