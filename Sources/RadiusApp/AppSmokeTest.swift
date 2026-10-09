// SPDX-License-Identifier: MPL-2.0
import AppKit
import SwiftUI
import RadiusCore

/// CI-only launch verification using the actual app window and an isolated, disposable data folder.
@MainActor
enum AppSmokeTest {
    static func run() async {
        trace("Starting packaged-app smoke test")
        guard let outputPath = ProcessInfo.processInfo.environment["RADIUS_SMOKE_TEST_OUTPUT"],
              ProcessInfo.processInfo.environment["RADIUS_SMOKE_TEST_DATA"] != nil else {
            fail("Smoke test requires isolated data and output directories."); return
        }
        let output = URL(fileURLWithPath: outputPath, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            trace("Waiting for browser window")
            let deadline = Date().addingTimeInterval(20)
            while AppDelegate.state?.ready != true || NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }) == nil || AppDelegate.state?.windows.values.compactMap(\.model).isEmpty != false {
                if let error = AppDelegate.state?.startupError { throw ValidationError(error) }
                if Date() > deadline { throw ValidationError("The packaged app did not open a browser window.") }
                try await Task.sleep(for: .milliseconds(100))
            }
            guard let app = AppDelegate.state, let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
                  let browser = app.windows.values.compactMap(\.model).first else { throw ValidationError("Browser state is unavailable.") }
            trace("Browser window opened")
            app.library.preferences.completedOnboarding = true
            browser.panel = .resources
            for design in DesignSystem.allCases {
                trace("Capturing \(design.rawValue) appearance")
                var config = Configuration(); config.theme.design = design
                if design == .graphite { config.layout.tabs = .leading; config.layout.sidebar = .trailing }
                app.applyConfiguration(config)
                // Allow the monitor's second sample and native progress animation to settle.
                try await Task.sleep(for: .milliseconds(2200))
                guard let view = window.contentView, let image = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw ValidationError("Cannot capture the browser window.") }
                view.cacheDisplay(in: view.bounds, to: image)
                guard let png = image.representation(using: .png, properties: [:]), png.count > 1000 else { throw ValidationError("The browser screenshot was empty.") }
                try png.write(to: output.appendingPathComponent("Radius-\(design.rawValue).png"))
            }
            // Verify native control surfaces render independently of a website engine.
            for sheet in [BrowserSheet.modules, .customize, .settings, .recovery] {
                trace("Opening \(sheet.rawValue) screen")
                browser.sheet = sheet
                try await Task.sleep(for: .milliseconds(400))
                guard let panel = window.attachedSheet, let view = panel.contentView,
                      let image = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw ValidationError("The \(sheet.rawValue) screen did not open.") }
                view.cacheDisplay(in: view.bounds, to: image)
                guard let png = image.representation(using: .png, properties: [:]) else { throw ValidationError("Cannot capture \(sheet.rawValue).") }
                try png.write(to: output.appendingPathComponent("Radius-\(sheet.rawValue).png"))
                browser.sheet = nil
                try await Task.sleep(for: .milliseconds(300))
            }
            if let address = ProcessInfo.processInfo.environment["RADIUS_SMOKE_TEST_URL"] {
                trace("Navigating to loopback HTTP fixture")
                browser.navigate(address)
                let pageDeadline = Date().addingTimeInterval(10)
                while browser.activeWebTab.title != "Radius HTTP fixture" || browser.activeWebTab.loading {
                    if Date() > pageDeadline { throw ValidationError("The packaged app could not navigate to its HTTP test page.") }
                    try await Task.sleep(for: .milliseconds(100))
                }
                guard browser.activeWebTab.url?.scheme == "http" else { throw ValidationError("HTTP navigation did not reach the fixture.") }
                trace("Extracting reader text")
                let text = try await browser.activeWebTab.readerText()
                guard text.contains("Local browser check") else { throw ValidationError("Reader could not read the HTTP fixture.") }
                trace("Verifying split panes and tree tabs")
                browser.panel = nil
                var config = app.library.preferences.configuration
                config.layout.tabs = .leading; config.layout.treeTabs = true; config.layout.split = .sideBySide
                app.applyConfiguration(config); browser.synchronizeSplit()
                guard let pair = browser.session.split else { throw ValidationError("Split panes did not open.") }
                browser.selectTab(pair.second); browser.navigate(address)
                let splitDeadline = Date().addingTimeInterval(10)
                while browser.webTab(pair.second).title != "Radius HTTP fixture" || browser.webTab(pair.second).loading {
                    if Date() > splitDeadline { throw ValidationError("The second browsing pane could not navigate.") }
                    try await Task.sleep(for: .milliseconds(100))
                }
                guard browser.webTab(pair.first) !== browser.webTab(pair.second), browser.session.split?.first == pair.first else { throw ValidationError("Browsing panes were not independent.") }
                _ = browser.session.setParent(pair.second, to: pair.first)
                try await Task.sleep(for: .milliseconds(500))
                guard let view = window.contentView, let image = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw ValidationError("Cannot capture split panes.") }
                view.cacheDisplay(in: view.bounds, to: image)
                guard let png = image.representation(using: .png, properties: [:]) else { throw ValidationError("Cannot encode split panes.") }
                try png.write(to: output.appendingPathComponent("Radius-split.png"))
                browser.selectOtherPane()
                guard browser.session.selectedTabID == pair.first else { throw ValidationError("Switching panes did not update the address context.") }
                if ProcessInfo.processInfo.environment["RADIUS_CHROMIUM_PACKAGE"] != nil {
                    trace("Verifying bundled optional Chromium runtime")
                    guard ChromiumRuntime.shared.isInstalled(in: app.dataDirectory) else { throw ValidationError("The Chromium development variant has no bundled runtime.") }
                    let id = browser.session.selectedTabID
                    trace("Reopening an embedded tab in Chromium")
                    browser.changeEngine(id, to: .chromium)
                    let chromiumDeadline = Date().addingTimeInterval(30)
                    while browser.webTab(id).title != "Radius HTTP fixture" || browser.webTab(id).loading {
                        if let error = browser.webTab(id).errorMessage { throw ValidationError(error) }
                        if Date() > chromiumDeadline { throw ValidationError("Embedded Chromium did not render the HTTP fixture.") }
                        try await Task.sleep(for: .milliseconds(100))
                    }
                    guard browser.webTab(id).nativeView.window === window, browser.webTab(id).engineID == .chromium else {
                        throw ValidationError("Chromium was not hosted inside the actual Radius window.")
                    }
                    guard try await browser.webTab(id).readerText().contains("Local browser check") else { throw ValidationError("Embedded Chromium did not execute the reader request.") }
                    guard let chromium = browser.webTab(id) as? ChromiumTab else { throw ValidationError("Chromium adapter is unavailable.") }
                    trace("Cancelling a Chromium page before its new context is ready")
                    let liveBeforeCancellation = ChromiumRuntime.shared.api?.live_pages()
                    let pending = try ChromiumRuntime.shared.makeTab(profileID: UUID(), privateSessionID: UUID(), dataDirectory: app.dataDirectory)
                    pending.dispose()
                    guard ChromiumRuntime.shared.api?.live_pages() == liveBeforeCancellation else { throw ValidationError("An uninitialized Chromium page survived cancellation.") }
                    try await Task.sleep(for: .milliseconds(250))
                    guard ChromiumRuntime.shared.api?.live_pages() == liveBeforeCancellation else { throw ValidationError("A cancelled Chromium page was created later.") }
                    trace("Checking Chromium profile and private-window isolation")
                    let normalToken = "radiusNormal" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
                    _ = try await evaluate(chromium, "document.cookie = '\(normalToken)=1; path=/; max-age=60'; localStorage.setItem('\(normalToken)', '1'); document.cookie")
                    guard try await evaluate(chromium, "document.cookie").contains(normalToken) else { throw ValidationError("The normal Chromium profile could not set its test cookie.") }
                    var probes: [(BrowserModel, NSWindow)] = []
                    defer { for (model, window) in probes { model.closeWindow(); window.close() } }
                    let privateToken = "radiusPrivate" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
                    for index in 0..<2 {
                        let probe = try await openProbe(app: app, privateBrowsing: true, profileID: nil, address: address + "?private-probe=\(index)")
                        probes.append(probe)
                        guard let tab = probe.0.activeWebTab as? ChromiumTab else { throw ValidationError("A private probe used the wrong engine.") }
                        let cookies = try await evaluate(tab, "document.cookie")
                        guard !cookies.contains(normalToken), !cookies.contains(privateToken) else { throw ValidationError("Chromium cookies leaked into another private window.") }
                        guard try await evaluate(tab, "String(localStorage.getItem('\(normalToken)'))") == "null",
                              try await evaluate(tab, "String(localStorage.getItem('\(privateToken)'))") == "null" else { throw ValidationError("Chromium local storage leaked into a private window.") }
                        if index == 0 { _ = try await evaluate(tab, "document.cookie = '\(privateToken)=1; path=/'; localStorage.setItem('\(privateToken)', '1'); document.cookie") }
                    }
                    let separateProfile = Profile(name: "Isolation probe"); app.library.profiles.append(separateProfile)
                    let separate = try await openProbe(app: app, privateBrowsing: false, profileID: separateProfile.id, address: address)
                    probes.append(separate)
                    guard let separateTab = separate.0.activeWebTab as? ChromiumTab else { throw ValidationError("The separate profile used the wrong engine.") }
                    let separateCookies = try await evaluate(separateTab, "document.cookie")
                    guard !separateCookies.contains(normalToken) else { throw ValidationError("Chromium profile cookies were not separated.") }
                    guard try await evaluate(separateTab, "String(localStorage.getItem('\(normalToken)'))") == "null" else { throw ValidationError("Chromium profile local storage was not separated.") }
                    guard !app.library.history.contains(where: { $0.url.query?.contains("private-probe") == true }),
                          !app.library.sessions.flatMap(\.tabs).contains(where: { $0.url?.query?.contains("private-probe") == true }) else { throw ValidationError("Private Chromium browsing entered saved history or sessions.") }
                    for (model, window) in probes { model.closeWindow(); window.close() }; probes.removeAll()
                    trace("Checking Chromium popup opener and tab context")
                    app.library.preferences.blockPopups = false; browser.updatePopupPolicy()
                    _ = try await evaluate(chromium, "(() => { const w = window.open('about:blank'); if (!w) return 'blocked'; w.document.write('<html><title>Radius Chromium popup</title><body>Popup</body></html>'); return 'opened'; })()")
                    let popupDeadline = Date().addingTimeInterval(10)
                    while browser.activeWebTab.title != "Radius Chromium popup" {
                        if Date() > popupDeadline { throw ValidationError("Chromium popup did not open inside Radius.") }
                        try await Task.sleep(for: .milliseconds(100))
                    }
                    guard let popup = browser.activeWebTab as? ChromiumTab,
                          try await evaluate(popup, "String(window.opener !== null)") == "true" else { throw ValidationError("Chromium popup lost its opener.") }
                    browser.closeTab(browser.session.selectedTabID); browser.selectTab(id)
                    let capture = try await chromium.request("Page.captureScreenshot", parameters: ["format": "png", "captureBeyondViewport": false])
                    guard let captureObject = try JSONSerialization.jsonObject(with: capture) as? [String: Any],
                          let encoded = captureObject["data"] as? String, let contentPNG = Data(base64Encoded: encoded),
                          contentPNG.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]), contentPNG.count > 1000 else {
                        throw ValidationError("Chromium could not capture its rendered page.")
                    }
                    try contentPNG.write(to: output.appendingPathComponent("Radius-chromium-content.png"))
                    trace("Checking ordinary HTTPS browsing in Chromium")
                    browser.navigate("https://example.com/")
                    let httpsDeadline = Date().addingTimeInterval(20)
                    while chromium.title != "Example Domain" || chromium.loading {
                        if let error = chromium.errorMessage { throw ValidationError(error) }
                        if Date() > httpsDeadline { throw ValidationError("Chromium did not load its HTTPS check page.") }
                        try await Task.sleep(for: .milliseconds(100))
                    }
                    guard chromium.url?.scheme == "https", try await chromium.readerText().contains("Example Domain") else { throw ValidationError("Chromium HTTPS browsing failed.") }
                    try await Task.sleep(for: .milliseconds(500))
                    guard let view = window.contentView, let image = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw ValidationError("Cannot capture embedded Chromium.") }
                    view.cacheDisplay(in: view.bounds, to: image)
                    guard let png = image.representation(using: .png, properties: [:]) else { throw ValidationError("Cannot encode embedded Chromium.") }
                    try png.write(to: output.appendingPathComponent("Radius-chromium.png"))
                    trace("Closing Chromium while WebKit and Radius remain open")
                    browser.closeTab(id)
                    let closeDeadline = Date().addingTimeInterval(10)
                    while ChromiumRuntime.shared.api?.live_pages() != 0 {
                        if Date() > closeDeadline { throw ValidationError("The Chromium page did not close.") }
                        try await Task.sleep(for: .milliseconds(100))
                    }
                    guard window.isVisible, browser.activeWebTab.engineID == .webkit else { throw ValidationError("Closing Chromium also closed the native window or WebKit pane.") }
                    trace("Embedded Chromium runtime check passed")
                }
            }
            trace("Saving browser data")
            guard await app.flush() else { throw ValidationError(app.notice ?? "App data could not be saved.") }
            trace("Radius packaged-app smoke test passed.")
            // Let this actor job return before AppKit enters its deferred-termination loop.
            NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0)
        } catch { fail(error.localizedDescription) }
    }
    private static func evaluate(_ tab: ChromiumTab, _ source: String) async throws -> String {
        let data = try await tab.request("Runtime.evaluate", parameters: ["expression": source, "returnByValue": true])
        guard let response = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = response["result"] as? [String: Any], let value = result["value"] as? String else {
            throw ValidationError("The Chromium script did not return its expected result.")
        }
        return value
    }
    private static func openProbe(app: AppState, privateBrowsing: Bool, profileID: UUID?, address: String) async throws -> (BrowserModel, NSWindow) {
        let model = BrowserModel(app: app, isPrivate: privateBrowsing)
        if let profileID { model.changeProfile(profileID) }
        model.changeEngine(model.session.selectedTabID, to: .chromium)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: BrowserWindow(model: model).environmentObject(app))
        window.orderFront(nil); model.navigate(address)
        do {
            let deadline = Date().addingTimeInterval(15)
            while model.activeWebTab.title != "Radius HTTP fixture" || model.activeWebTab.loading {
                if let error = model.activeWebTab.errorMessage { throw ValidationError(error) }
                if Date() > deadline { throw ValidationError("A Chromium isolation page did not load.") }
                try await Task.sleep(for: .milliseconds(100))
            }
            return (model, window)
        } catch { model.closeWindow(); window.close(); throw error }
    }
    private static func trace(_ message: String) {
        FileHandle.standardOutput.write(Data((message + "\n").utf8))
    }
    private static func fail(_ message: String) {
        trace("Radius smoke test failed: \(message)")
        exit(1)
    }
}
