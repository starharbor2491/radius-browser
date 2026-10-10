// SPDX-License-Identifier: MPL-2.0
import AppKit
import Darwin
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
            if ProcessInfo.processInfo.environment["RADIUS_CHROMIUM_EXTENSION_RESTART"] == "1" {
                try await ChromiumAcceptance.verifyStoreRestart(app: app)
                guard await app.flush() else { throw ValidationError(app.notice ?? "Could not save restart acceptance data.") }
                trace("Chromium real-process restart acceptance passed")
                NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0)
                return
            }
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
                guard let view = window.contentView else { throw ValidationError("The browser window has no content.") }
                try capture(view, to: output.appendingPathComponent("Radius-\(design.rawValue).png"))
            }
            let baseline = app.configuration
            for design in DesignSystem.allCases {
                trace("Capturing \(design.rawValue) dark appearance")
                var config = baseline; config.theme.design = design; config.theme.colorMode = .dark
                app.applyConfiguration(config)
                try await Task.sleep(for: .milliseconds(400))
                guard let view = window.contentView else { throw ValidationError("The browser window has no content.") }
                try capture(view, to: output.appendingPathComponent("Radius-\(design.rawValue)-dark.png"))
            }
            app.applyConfiguration(baseline)
            // Verify native control surfaces render independently of a website engine.
            for sheet in [BrowserSheet.modules, .customize, .settings, .recovery] {
                trace("Opening \(sheet.rawValue) screen")
                browser.sheet = sheet
                try await Task.sleep(for: .milliseconds(400))
                guard let view = window.attachedSheet?.contentView else { throw ValidationError("The \(sheet.rawValue) screen did not open.") }
                try capture(view, to: output.appendingPathComponent("Radius-\(sheet.rawValue).png"))
                browser.sheet = nil
                try await Task.sleep(for: .milliseconds(300))
            }
            for mode in [ColorMode.light, .dark] {
                var config = baseline; config.theme.colorMode = mode; config.theme.accent = mode == .dark ? .teal : .orange
                app.applyConfiguration(config)
                for sheet in mode == .dark ? [BrowserSheet.customize, .recovery] : [.customize] {
                    trace("Capturing \(sheet.rawValue) \(mode.rawValue) contrast")
                    browser.sheet = sheet
                    try await Task.sleep(for: .milliseconds(400))
                    guard let view = window.attachedSheet?.contentView else { throw ValidationError("The \(sheet.rawValue) contrast screen did not open.") }
                    try capture(view, to: output.appendingPathComponent("Radius-\(sheet.rawValue)-\(mode.rawValue).png"))
                    browser.sheet = nil
                    try await Task.sleep(for: .milliseconds(300))
                }
            }
            app.applyConfiguration(baseline)
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
                let text = try await app.readerText(from: browser.activeWebTab)
                guard text.contains("Local browser check") else { throw ValidationError("Reader could not read the HTTP fixture.") }
                trace("Capturing customized controls at wide and narrow window sizes")
                let originalFrame = window.frame
                let originalConfiguration = app.configuration
                var customized = originalConfiguration
                customized.theme.typography = .rounded; customized.theme.fontScale = 1.2
                customized.theme.spacingScale = 1.15; customized.theme.iconStyle = .filled
                customized.theme.surfaceHex = "#17212B"; customized.theme.textHex = "#F1F5F9"
                customized.theme.accentHex = "#66D9CC"; customized.theme.colorMode = .dark
                customized.theme.borderWidth = 1; customized.theme.shadowStrength = 0.2
                var tabAppearance = ComponentAppearance(); tabAppearance.density = .compact; tabAppearance.cornerRadius = 6
                customized.theme.tabsAppearance = tabAppearance
                customized.layout.tabs = .leading; customized.layout.tabsWidth = 300
                customized.layout.sidebar = .trailing; customized.layout.sidebarWidth = 360
                customized.layout.secondaryPanel = "bookmarks"
                customized.layout.toolbarComponents = ToolbarComponent.browserDefaults + [
                    .init(command: .newTab, region: .top), .init(command: .reader, region: .top),
                    .init(command: .screenshot, region: .bottom), .init(command: .downloads, region: .bottom),
                    .init(command: .customize, region: .overflow)
                ]
                app.applyConfiguration(customized)
                for width in [1240.0, 800.0] {
                    window.setContentSize(NSSize(width: width, height: 720))
                    try await Task.sleep(for: .milliseconds(450))
                    guard let view = window.contentView else { throw ValidationError("Customized browser content is unavailable.") }
                    try capture(view, to: output.appendingPathComponent("Radius-customized-\(Int(width)).png"))
                }
                window.setFrame(originalFrame, display: true)
                app.applyConfiguration(originalConfiguration)
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
                guard let view = window.contentView else { throw ValidationError("Cannot capture split panes.") }
                try capture(view, to: output.appendingPathComponent("Radius-split.png"))
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
                    guard let chromium = browser.webTab(id) as? ChromiumTab else { throw ValidationError("Chromium adapter is unavailable.") }
                    trace("Verifying Reader captures in an isolated Chromium world")
                    _ = try await evaluate(chromium, "(() => { window.radiusOriginalSerializer = window.XMLSerializer; window.radiusSnapshotTouched = false; window.XMLSerializer = class { constructor() { window.radiusSnapshotTouched = true; } serializeToString() { return '<html><body>Wrong page-world snapshot</body></html>'; } }; return 'ready'; })()")
                    guard try await app.readerText(from: chromium).contains("Local browser check"),
                          try await evaluate(chromium, "String(window.radiusSnapshotTouched)") == "false" else { throw ValidationError("Chromium Reader invoked the page's overridden serializer.") }
                    _ = try await evaluate(chromium, "(() => { window.XMLSerializer = window.radiusOriginalSerializer; delete window.radiusOriginalSerializer; delete window.radiusSnapshotTouched; return 'restored'; })()")
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
                        if index == 0 {
                            _ = try await evaluate(tab, "document.cookie = '\(privateToken)=1; path=/'; localStorage.setItem('\(privateToken)', '1'); document.cookie")
                            trace("Checking private Chromium popup policy and opener")
                            try await verifyPopups(in: probe.0, app: app)
                        }
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
                    trace("Checking normal Chromium popup policy and opener")
                    try await verifyPopups(in: browser, app: app)
                    let captureResponse = try await chromium.request("Page.captureScreenshot", parameters: ["format": "png", "captureBeyondViewport": false])
                    guard let captureObject = try JSONSerialization.jsonObject(with: captureResponse) as? [String: Any],
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
                    let httpsPage = try await evaluate(chromium, "JSON.stringify({href: location.href, title: document.title, body: document.body ? document.body.innerText.slice(0, 300) : null})")
                    trace("HTTPS probe: reported address \(chromium.url?.absoluteString ?? "nil"); document \(httpsPage)")
                    guard chromium.url?.scheme == "https" else { throw ValidationError("Chromium HTTPS address was not reported: \(chromium.url?.absoluteString ?? "nil").") }
                    let httpsReader = try await app.readerText(from: chromium)
                    guard try await evaluate(chromium, "String(location.protocol)") == "https:", httpsReader.trimmingCharacters(in: .whitespacesAndNewlines).count >= 40 else {
                        throw ValidationError("Chromium HTTPS reader did not return the loaded page's body (\(httpsReader.count) characters).")
                    }
                    try await Task.sleep(for: .milliseconds(500))
                    guard let view = window.contentView else { throw ValidationError("Cannot capture embedded Chromium.") }
                    try capture(view, to: output.appendingPathComponent("Radius-chromium.png"))
                    // WindowServer capture includes GPU-backed layers omitted by Cocoa bitmap caching.
                    await captureWindow(window, to: output.appendingPathComponent("Radius-chromium-window.png"))
                    if let chromeWindow = chromium.chromeWindow { await captureWindow(chromeWindow, to: output.appendingPathComponent("Radius-chromium-toolbar-window.png")) }
                    try await ChromiumAcceptance.verifyHostAndManagement(chromium, app: app, ownerWindow: window)
                    trace("Closing Chromium while WebKit and Radius remain open")
                    browser.closeTab(id)
                    let closeDeadline = Date().addingTimeInterval(10)
                    while ChromiumRuntime.shared.api?.live_pages() != 0 {
                        if Date() > closeDeadline { throw ValidationError("The Chromium page did not close.") }
                        try await Task.sleep(for: .milliseconds(100))
                    }
                    guard window.isVisible, browser.activeWebTab.engineID == .webkit else { throw ValidationError("Closing Chromium also closed the native window or WebKit pane.") }
                    trace("Leaving the native extension manager open to verify quit ownership")
                    browser.sheet = .extensions
                    let managerDeadline = ContinuousClock.now.advanced(by: .seconds(15))
                    while ChromiumRuntime.shared.api?.live_pages() == 0 {
                        guard ContinuousClock.now < managerDeadline else { throw ValidationError("The native extension sheet did not create its managed page.") }
                        try await Task.sleep(for: .milliseconds(100))
                    }
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
    private static func capture(_ view: NSView, to url: URL) throws {
        guard let image = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw ValidationError("Cannot capture \(url.lastPathComponent).") }
        view.cacheDisplay(in: view.bounds, to: image)
        guard let png = image.representation(using: .png, properties: [:]), png.count > 1000 else { throw ValidationError("The \(url.lastPathComponent) screenshot was empty.") }
        try png.write(to: url)
    }
    private static func captureWindow(_ window: NSWindow, to url: URL) async {
        window.makeKeyAndOrderFront(nil)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-o", "-l", String(window.windowNumber), url.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        do {
            try await Task.sleep(for: .milliseconds(300))
            try Task.checkCancellation()
            try process.run()
            let deadline = ContinuousClock.now.advanced(by: .seconds(8))
            while process.isRunning && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(50)) }
            if process.isRunning { throw ValidationError("Window capture timed out.") }
            process.waitUntilExit()
            let file = try FileHandle(forReadingFrom: url)
            defer { try? file.close() }
            let png = try file.read(upToCount: 8 * 1024 * 1024 + 1) ?? Data()
            guard process.terminationStatus == 0, png.count > 1000, png.count <= 8 * 1024 * 1024,
                  png.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) else { throw ValidationError("Window capture was unavailable.") }
            trace("Chromium own-window OS capture saved")
        } catch {
            if process.isRunning {
                process.terminate()
                try? await Task.sleep(for: .milliseconds(250))
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                process.waitUntilExit()
            }
            // Recording permission depends on the runner. Keep the renderer assertions;
            // never grant recording access or alter the runner's privacy settings here.
            trace("Chromium own-window OS capture unavailable: \(error.localizedDescription)")
            try? FileManager.default.removeItem(at: url)
        }
    }
    private static func evaluate(_ tab: ChromiumTab, _ source: String) async throws -> String {
        let data = try await tab.request("Runtime.evaluate", parameters: ["expression": source, "returnByValue": true])
        guard let response = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = response["result"] as? [String: Any], let value = result["value"] as? String else {
            throw ValidationError("The Chromium script did not return its expected result.")
        }
        return value
    }
    private static func verifyPopups(in browser: BrowserModel, app: AppState) async throws {
        let parentID = browser.session.selectedTabID
        guard let parent = browser.activeWebTab as? ChromiumTab, let expectedWindow = parent.nativeView.window else { throw ValidationError("The popup probe requires a hosted Chromium tab.") }
        let originalPolicy = app.library.preferences.blockPopups
        defer {
            app.library.preferences.blockPopups = originalPolicy
            browser.updatePopupPolicy()
        }
        app.library.preferences.blockPopups = true; browser.updatePopupPolicy()
        let blocked = try await evaluate(parent, "(() => { const w = window.open('about:blank'); if (w) { w.close(); return 'opened'; } return 'blocked'; })()")
        guard blocked == "blocked" else { throw ValidationError("Chromium opened an unsolicited popup while Radius blocks popups.") }
        app.library.preferences.blockPopups = false; browser.updatePopupPolicy()
        let opened = try await evaluate(parent, "(() => { const w = window.open('about:blank'); if (!w) return 'blocked'; w.document.write('<html><title>Radius Chromium popup</title><body>Popup</body></html>'); w.document.close(); return 'opened'; })()")
        guard opened == "opened" else { throw ValidationError("Chromium rejected its allowed popup request: \(opened).") }
        let deadline = Date().addingTimeInterval(10)
        while browser.activeWebTab.title != "Radius Chromium popup" {
            if Date() > deadline {
                var documentTitle = "unavailable"
                if let popup = browser.activeWebTab as? ChromiumTab { documentTitle = (try? await evaluate(popup, "String(document.title)")) ?? "unavailable" }
                throw ValidationError("Chromium popup did not open inside Radius. Engine: \(browser.activeWebTab.engineID.label); title: \(browser.activeWebTab.title ?? "nil"); document title: \(documentTitle); error: \(browser.activeWebTab.errorMessage ?? "none").")
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard browser.session.selectedTabID != parentID,
              let popup = browser.activeWebTab as? ChromiumTab,
              popup.nativeView.window === expectedWindow,
              try await evaluate(popup, "String(window.opener !== null)") == "true" else { throw ValidationError("Chromium popup lost its opener or native window.") }
        browser.closeTab(browser.session.selectedTabID); browser.selectTab(parentID)
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
