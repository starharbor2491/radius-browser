// SPDX-License-Identifier: MPL-2.0
import AppKit
import SwiftUI

struct RadiusApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var state = AppState()
    var body: some Scene {
        WindowGroup("Radius", id: "browser") { BrowserWindowRoot(isPrivate: false).environmentObject(state) }
            .defaultSize(width: 1240, height: 820)
            .commands { BrowserCommands(app: state) }
        WindowGroup("Radius — Private", id: "private") { BrowserWindowRoot(isPrivate: true).environmentObject(state) }
            .defaultSize(width: 1240, height: 820)
    }
}
struct BrowserCommands: Commands {
    @ObservedObject var app: AppState
    @FocusedObject private var focusedBrowser: BrowserModel?
    @Environment(\.openWindow) private var openWindow
    private var nativeTab: ChromiumTab? { ChromiumRuntime.shared.focusedNativeTab }
    private var browser: BrowserModel? {
        if nativeTab?.isAuxiliary == true { return nil }
        var window = NSApp.keyWindow
        while let parent = window?.parent { window = parent }
        if let model = (window?.delegate as? WindowDelegateProxy)?.model, !model.isClosed { return model }
        if nativeTab != nil { return nil }
        return focusedBrowser
    }
    private var canHandleTabCommands: Bool { nativeTab != nil || browser != nil }
    private var bookmarkTitle: String {
        browser?.bookmarks.contains(where: { $0.url == browser?.selectedTab.url }) == true
            ? "Remove Radius bookmark" : "Save in Radius bookmarks"
    }
    private func performTabCommand(_ command: NativeTabCommand) {
        guard !app.finalQuitDataFrozen else { return }
        if let nativeTab { _ = nativeTab.performNativeTabCommand(command); return }
        browser?.performTabCommand(command)
    }
    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Group {
                Button("New window") { openWindow(id: "browser") }.keyboardShortcut("n")
                Button("New private window") { openWindow(id: "private") }.keyboardShortcut("n", modifiers: [.command, .shift])
                Button("New tab") { performTabCommand(.new) }.keyboardShortcut("t").disabled(!canHandleTabCommands)
                Button("Reopen closed tab") { performTabCommand(.reopen) }.keyboardShortcut("t", modifiers: [.command, .shift]).disabled(!canHandleTabCommands || (nativeTab == nil && browser?.hasNativeTabs != true && browser?.closedTabs.isEmpty != false))
                if browser?.hasNativeTabs == true {
                    Button("New browsing pane") { browser?.newTab(engine: .chromium) }
                    Button("Reopen closed browsing pane") { browser?.reopenClosedTab() }.disabled(browser?.closedTabs.isEmpty != false)
                }
            }.disabled(app.finalQuitDataFrozen)
        }
        CommandGroup(replacing: .appSettings) {
            Group {
                Button("Settings…") { browser?.sheet = .settings }.keyboardShortcut(",").disabled(browser == nil)
            }.disabled(app.finalQuitDataFrozen)
        }
        CommandGroup(replacing: .saveItem) {
            Group {
                if nativeTab != nil || browser?.hasNativeTabs == true {
                    Button(bookmarkTitle) { browser?.toggleBookmark() }.disabled(browser?.hasPage != true || browser?.isPrivate == true)
                } else {
                    Button(bookmarkTitle) { browser?.toggleBookmark() }.keyboardShortcut("d").disabled(browser?.hasPage != true || browser?.isPrivate == true)
                }
            }.disabled(app.finalQuitDataFrozen)
        }
        CommandGroup(after: .newItem) {
            Group {
                Button("Close tab") { performTabCommand(.close) }.keyboardShortcut("w").disabled(!canHandleTabCommands)
                if browser?.hasNativeTabs == true {
                    Button("Close browsing pane") { if let browser { browser.closeTab(browser.session.selectedTabID) } }
                }
                Button("Close window") {
                    var window = NSApp.keyWindow
                    while let parent = window?.parent { window = parent }
                    window?.performClose(nil)
                }.keyboardShortcut("w", modifiers: [.command, .shift])
            }.disabled(app.finalQuitDataFrozen)
        }
        CommandMenu("Browse") {
            Group {
                Button("Open location…") { NotificationCenter.default.post(name: .radiusFocusAddress, object: browser?.session.id) }.keyboardShortcut("l").disabled(browser == nil)
                Button("Reload page") { browser?.activeWebTab.reload() }.keyboardShortcut("r").disabled(browser?.hasPage != true)
                Button("Find in page…") { NotificationCenter.default.post(name: .radiusFind, object: browser?.session.id) }.keyboardShortcut("f").disabled(browser?.hasPage != true)
                Divider()
                Button("Previous tab") { performTabCommand(.previous) }.keyboardShortcut("[", modifiers: [.command, .shift]).disabled(!canHandleTabCommands)
                Button("Next tab") { performTabCommand(.next) }.keyboardShortcut("]", modifiers: [.command, .shift]).disabled(!canHandleTabCommands)
                Button("Switch browsing pane") { browser?.selectOtherPane() }
                    .keyboardShortcut("`", modifiers: [.command, .option]).disabled(browser?.session.split == nil)
                Button(browser?.session.split == nil ? "Split side by side" : "Return to one pane") {
                    guard let browser else { return }
                    if browser.session.split != nil { browser.endSplit() }
                    else { browser.beginSplit(.sideBySide) }
                }.disabled(browser == nil)
                Divider()
                Button("Modules…") { browser?.sheet = .modules }.disabled(browser == nil)
                Button("Customize…") { browser?.sheet = .customize }.disabled(browser == nil)
                Button("Recovery…") { browser?.sheet = .recovery }.disabled(browser == nil)
            }.disabled(app.finalQuitDataFrozen)
        }
    }
}
