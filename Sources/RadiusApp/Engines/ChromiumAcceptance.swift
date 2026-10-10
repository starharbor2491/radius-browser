// SPDX-License-Identifier: MPL-2.0
import AppKit
import RadiusCore

/// Executed only by the packaged application's isolated native smoke test.
@MainActor
enum ChromiumAcceptance {
    static func verifyExtensionSheet(browser: BrowserModel, ownerWindow: NSWindow) async throws {
        guard ProcessInfo.processInfo.environment["RADIUS_SMOKE_TEST_DATA"] != nil,
              CommandLine.arguments.contains("--smoke-test"), !browser.app.terminating,
              !browser.app.finalQuitDataFrozen else {
            throw ValidationError("Extension sheet acceptance requires the isolated smoke-test launch.")
        }
        let original = try await waitForExtensionSheet(ownerWindow: ownerWindow, profileID: browser.session.profileID)
        let profile = Profile(name: "Extension profile acceptance")
        browser.app.library.profiles.append(profile)
        defer { browser.app.library.profiles.removeAll { $0.id == profile.id } }
        func picker(in view: NSView) -> NSPopUpButton? {
            if let control = view as? NSPopUpButton, control.itemTitles.contains(profile.name) { return control }
            for child in view.subviews { if let control = picker(in: child) { return control } }
            return nil
        }
        let pickerDeadline = ContinuousClock.now.advanced(by: .seconds(5))
        var profilePicker: NSPopUpButton?
        while profilePicker == nil {
            if let root = ownerWindow.attachedSheet?.contentView { profilePicker = picker(in: root) }
            guard ContinuousClock.now < pickerDeadline else { throw ValidationError("The extension sheet's native profile selector was not available.") }
            if profilePicker == nil { try await Task.sleep(for: .milliseconds(100)) }
        }
        guard let profilePicker, let action = profilePicker.action else { throw ValidationError("The extension profile selector has no native action.") }
        // A profile selection can arrive while an asynchronous Quit is still
        // awaiting its save decision. It must hide the old profile immediately
        // and create the selected manager only after cancellation resumes work.
        browser.app.terminating = true
        defer { browser.app.terminating = false }
        profilePicker.selectItem(withTitle: profile.name)
        guard NSApp.sendAction(action, to: profilePicker.target, from: profilePicker) else {
            throw ValidationError("The extension profile selector did not handle its native selection action.")
        }
        try await Task.sleep(for: .milliseconds(300))
        guard original.nativeView.window == nil,
              !ChromiumRuntime.shared.extensionManagementTabs.contains(where: { $0.profileID == profile.id }) else {
            throw ValidationError("A deferred extension profile selection exposed the old profile or created a browser during Quit.")
        }
        browser.app.terminating = false
        let replacement = try await waitForExtensionSheet(ownerWindow: ownerWindow, profileID: profile.id)
        guard replacement !== original, original.nativeView.window == nil else {
            throw ValidationError("Switching extension profiles reused the disposed manager's native host.")
        }
        try await waitForManager(replacement)
        browser.app.terminating = true
        try await Task.sleep(for: .milliseconds(100))
        browser.app.terminating = false
        try await Task.sleep(for: .milliseconds(200))
        guard try await waitForExtensionSheet(ownerWindow: ownerWindow, profileID: profile.id) === replacement else {
            throw ValidationError("Refusing Quit needlessly replaced the unchanged extension manager.")
        }
        _ = try? await replacement.request("Page.close", parameters: [:], timeout: .seconds(5))
        let closeDeadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ownerWindow.attachedSheet != nil || browser.sheet != nil {
            guard ContinuousClock.now < closeDeadline else { throw ValidationError("Closing the extension manager from Chrome left an empty native sheet open.") }
            try await Task.sleep(for: .milliseconds(100))
        }
        // Keep the final manager alive so normal app Quit still proves that
        // runtime-owned sheet pages are included in shutdown ownership.
        browser.sheet = .extensions
        _ = try await waitForExtensionSheet(ownerWindow: ownerWindow, profileID: browser.session.profileID)
        print("Radius Chromium acceptance: native extension profile switching, engine close dismissal, and reopened sheet geometry passed")
    }
    private static func waitForExtensionSheet(ownerWindow: NSWindow, profileID: UUID) async throws -> ChromiumTab {
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while ContinuousClock.now < deadline {
            if let tab = ChromiumRuntime.shared.extensionManagementTabs.first(where: {
                $0.profileID == profileID && $0.nativeView.window?.sheetParent === ownerWindow
            }), !tab.loading, tab.chromeStyle,
               let sheet = tab.nativeView.window, let chrome = tab.chromeWindow,
               chrome.parent === sheet, chrome.isVisible {
                let expected = sheet.convertToScreen(tab.nativeView.convert(tab.nativeView.bounds.intersection(tab.nativeView.visibleRect), to: nil))
                guard abs(chrome.frame.minX - expected.minX) < 2, abs(chrome.frame.minY - expected.minY) < 2,
                      abs(chrome.frame.width - expected.width) < 2, abs(chrome.frame.height - expected.height) < 2 else {
                    throw ValidationError("The extension manager's Chrome child is misaligned inside its native sheet.")
                }
                return tab
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw ValidationError("The extension manager did not become visible inside its native Radius sheet.")
    }
    static func verifyKeyboardRouting(browser: BrowserModel, ownerWindow: NSWindow) async throws {
        guard ProcessInfo.processInfo.environment["RADIUS_SMOKE_TEST_DATA"] != nil,
              ProcessInfo.processInfo.arguments.contains("--smoke-test"),
              let address = ProcessInfo.processInfo.environment["RADIUS_SMOKE_TEST_URL"],
              var components = URLComponents(string: address), components.host == "127.0.0.1" else {
            throw ValidationError("Keyboard acceptance requires the isolated loopback smoke test.")
        }
        let originalIDs = Set(browser.session.tabs.map(\.id))
        let selected = browser.session.selectedTabID
        let split = browser.session.split
        let splitSuppressed = browser.session.splitSuppressed
        defer {
            for id in browser.session.tabs.map(\.id) where !originalIDs.contains(id) { browser.closeTab(id) }
            browser.session.split = split
            browser.session.splitSuppressed = splitSuppressed
            browser.selectTab(selected)
        }
        browser.newTab(url: components.url, engine: .chromium)
        let probeID = browser.session.selectedTabID
        guard let tab = browser.activeWebTab as? ChromiumTab else { throw ValidationError("The shortcut probe did not create a Chromium tab.") }
        try await waitForLoad(tab, host: "127.0.0.1")
        let showDeadline = ContinuousClock.now.advanced(by: .seconds(10))
        while tab.chromeWindow?.isVisible != true {
            guard ContinuousClock.now < showDeadline else { throw ValidationError("The shortcut probe's Chrome child did not become visible.") }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard let chrome = tab.chromeWindow else { throw ValidationError("The shortcut probe has no native Chrome window.") }
        try await verifyChromeGeometry(tab, ownerWindow: ownerWindow)
        if let pair = browser.session.split {
            browser.selectTab(pair.first == probeID ? pair.second : pair.first)
            ownerWindow.makeKeyAndOrderFront(nil)
        }
        chrome.makeKeyAndOrderFront(nil); tab.focus()
        try await Task.sleep(for: .milliseconds(200))
        guard chrome.isKeyWindow, browser.session.selectedTabID == probeID else {
            throw ValidationError("Focusing the Chrome pane did not select its native Radius tab (active=\(NSApp.isActive), key=\(chrome.isKeyWindow), eligible=\(chrome.canBecomeKey), visible=\(chrome.isVisible), child=\(chrome.windowNumber), actualKey=\(NSApp.keyWindow?.windowNumber ?? -1), parent=\(ownerWindow.windowNumber), selectedProbe=\(browser.session.selectedTabID == probeID)).")
        }
        // Send ordinary AppKit events to our own key window. Do not invoke the
        // browser command callback or grant system accessibility permission.
        try key("l", code: 37, modifiers: .command, window: chrome)
        try await Task.sleep(for: .milliseconds(150))
        let focusedState = try await tab.request("Radius.chromeHostState", parameters: [:])
        print("Radius Chromium shortcut state after Cmd-L: \(String(decoding: focusedState, as: UTF8.self)), responder=\(String(describing: chrome.firstResponder))")
        components.fragment = "radius-native-shortcut"
        guard let target = components.url else { throw ValidationError("The shortcut probe address is invalid.") }
        for character in target.absoluteString { try key(String(character), code: 0, window: chrome) }
        try key("\r", code: 36, window: chrome)
        let locationDeadline = ContinuousClock.now.advanced(by: .seconds(10))
        while tab.url != target || tab.loading {
            guard ContinuousClock.now < locationDeadline else {
                throw ValidationError("Native Cmd-L did not route typed navigation to Chrome's address bar (URL=\(tab.url?.absoluteString ?? "nil"), responder=\(String(describing: chrome.firstResponder)), key=\(chrome.isKeyWindow)).")
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        browser.showStartPage()
        try await waitForStartPage(tab)
        guard browser.activeWebTab === tab, !browser.hasPage, tab.url == nil, tab.canGoBack else {
            throw ValidationError("Chromium Home did not retain its native state (sameBrowser=\(browser.activeWebTab === tab), hasPage=\(browser.hasPage), URL=\(tab.url?.absoluteString ?? "nil"), canGoBack=\(tab.canGoBack)).")
        }
        tab.goBack()
        let backDeadline = ContinuousClock.now.advanced(by: .seconds(10))
        while tab.url != target || tab.loading || !tab.hasNativeNavigationChrome {
            guard ContinuousClock.now < backDeadline else { throw ValidationError("Chromium Back did not restore the page after Home.") }
            try await Task.sleep(for: .milliseconds(100))
        }
        tab.goForward()
        let forwardDeadline = ContinuousClock.now.advanced(by: .seconds(10))
        while browser.hasPage || tab.loading || !tab.isShowingStartPage {
            guard ContinuousClock.now < forwardDeadline else { throw ValidationError("Chromium Forward did not return to Radius's native start page.") }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard browser.activeWebTab === tab, tab.url == nil else { throw ValidationError("Chromium Forward replaced the Home browser or exposed its internal address.") }
        tab.goBack()
        let restoreDeadline = ContinuousClock.now.advanced(by: .seconds(10))
        while tab.url != target || tab.loading || !tab.hasNativeNavigationChrome {
            guard ContinuousClock.now < restoreDeadline else { throw ValidationError("Chromium Back failed after traversing its Home history entry.") }
            try await Task.sleep(for: .milliseconds(100))
        }
        print("Radius Chromium acceptance: Home preserved its browser and Back/Forward restored the previous document and native start page")
        browser.showStartPage()
        try await waitForStartPage(tab)
        // Exercise the engine's navigation path, as extension tabs.update does,
        // without clearing the adapter's pending Home state through load().
        _ = try await tab.request("Page.navigate", parameters: ["url": target.absoluteString])
        let externalDeadline = ContinuousClock.now.advanced(by: .seconds(10))
        while tab.url != target || tab.loading || !tab.hasNativeNavigationChrome || !browser.hasPage {
            guard ContinuousClock.now < externalDeadline else { throw ValidationError("An engine-originated Chromium navigation remained hidden behind Radius's start page.") }
            try await Task.sleep(for: .milliseconds(100))
        }
        print("Radius Chromium acceptance: engine-originated navigation replaced the native Home state")
        try await verifyNavigationRetry(browser: browser, tab: tab, fixtureURL: target)
        chrome.makeKeyAndOrderFront(nil); tab.focus()
        let beforeNew = Set(browser.session.tabs.map(\.id))
        guard let profileIndex = browser.app.library.profiles.firstIndex(where: { $0.id == browser.session.profileID }) else {
            throw ValidationError("The shortcut probe's profile is unavailable.")
        }
        let originalEngine = browser.app.library.profiles[profileIndex].engineID
        browser.app.library.profiles[profileIndex].engineID = .chromium
        defer { browser.app.library.profiles[profileIndex].engineID = originalEngine }
        try key("t", code: 17, modifiers: .command, window: chrome)
        try await Task.sleep(for: .milliseconds(300))
        let created = Set(browser.session.tabs.map(\.id)).subtracting(beforeNew)
        guard created.count == 1, created.contains(browser.session.selectedTabID) else {
            throw ValidationError("Native Cmd-T from Chrome did not create and select one Radius tab.")
        }
        guard let blank = browser.activeWebTab as? ChromiumTab, !browser.hasPage,
              blank.nativeView.window == nil, !blank.hasNativeNavigationChrome, !blank.focusAddressBar() else {
            throw ValidationError("A blank Chromium tab hid Radius's address field or claimed an unmounted Chrome toolbar.")
        }
        ownerWindow.makeKeyAndOrderFront(nil)
        try key("l", code: 37, modifiers: .command, window: ownerWindow)
        try await Task.sleep(for: .milliseconds(100))
        guard ownerWindow.firstResponder is NSTextView else {
            throw ValidationError("Cmd-L on the Chromium start page did not focus Radius's native address field.")
        }
        components.fragment = "radius-native-blank-tab"
        guard let blankTarget = components.url else { throw ValidationError("The blank tab probe address is invalid.") }
        for character in blankTarget.absoluteString { try key(String(character), code: 0, window: ownerWindow) }
        try key("\r", code: 36, window: ownerWindow)
        let blankDeadline = ContinuousClock.now.advanced(by: .seconds(15))
        while blank.url != blankTarget || blank.loading || !blank.hasNativeNavigationChrome {
            guard ContinuousClock.now < blankDeadline else { throw ValidationError("A blank default-Chromium tab could not navigate from Radius's native address field.") }
            try await Task.sleep(for: .milliseconds(100))
        }
        print("Radius Chromium acceptance: default Chromium start page accepted native address input and mounted Chrome navigation")
        for id in created { browser.closeTab(id) }
        browser.selectTab(probeID)
        chrome.makeKeyAndOrderFront(nil); tab.focus()
        try await Task.sleep(for: .milliseconds(100))
        try key("w", code: 13, modifiers: .command, window: chrome)
        try await Task.sleep(for: .milliseconds(300))
        guard !browser.session.tabs.contains(where: { $0.id == probeID }),
              Set(browser.session.tabs.map(\.id)) == originalIDs, ownerWindow.isVisible else {
            throw ValidationError("Native Cmd-W from Chrome did not close only its Radius tab.")
        }
        browser.session.split = split
        browser.session.splitSuppressed = splitSuppressed
        browser.selectTab(selected)
        try await Task.sleep(for: .milliseconds(300))
        print("Radius Chromium acceptance: focused Chrome pane and native Cmd-L/T/W routing passed")
    }
    private static func verifyNavigationRetry(browser: BrowserModel, tab: ChromiumTab, fixtureURL: URL) async throws {
        browser.showStartPage()
        try await waitForStartPage(tab)
        let target = fixtureURL.deletingLastPathComponent().appendingPathComponent("navigation-retry")
        // Bypass the adapter's load method, as an extension can. The fixture
        // closes the connection without a response until recovery is enabled.
        _ = try await tab.request("Page.navigate", parameters: ["url": target.absoluteString])
        let failureDeadline = ContinuousClock.now.advanced(by: .seconds(15))
        while tab.errorMessage == nil || tab.loading {
            guard ContinuousClock.now < failureDeadline else { throw ValidationError("Chromium did not report the fixture's failed HTTP navigation.") }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard !tab.isShowingStartPage, tab.url == target, browser.hasPage, browser.activeWebTab === tab,
              browser.selectedTab.url == target, browser.address == target.absoluteString else {
            throw ValidationError("A failed Chromium navigation lost its requested address behind the native start page.")
        }
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let (_, response) = try await session.data(for: URLRequest(url: target.appendingPathComponent("enable"), timeoutInterval: 5))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw ValidationError("The navigation recovery fixture could not be enabled.") }
        tab.reload()
        try await waitForLoad(tab, host: "127.0.0.1")
        guard tab.url == target, tab.errorMessage == nil, !tab.isShowingStartPage,
              try await evaluate(tab, "location.href") == target.absoluteString else {
            throw ValidationError("Chromium Retry did not load the failed web address after its server recovered.")
        }
        print("Radius Chromium acceptance: Home failure retained its address and native Retry loaded the recovered HTTP page")
    }
    private static func waitForStartPage(_ tab: ChromiumTab) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        var document = ""
        while ContinuousClock.now < deadline {
            // StopLoad can synchronously report loading=false before the Home
            // load commits. Require the actual replacement document as well.
            if !tab.loading {
                document = (try? await evaluate(tab, "location.href")) ?? ""
                if document.hasPrefix("about:blank#radius-start-"), tab.isShowingStartPage,
                   tab.nativeView.window == nil, !tab.loading { return }
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw ValidationError("Chromium Home did not commit its empty document (document=\(document), loading=\(tab.loading), mounted=\(tab.nativeView.window != nil), startPage=\(tab.isShowingStartPage)).")
    }
    private static func key(_ characters: String, code: UInt16, modifiers: NSEvent.ModifierFlags = [], window: NSWindow) throws {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code) else {
                throw ValidationError("AppKit could not create the owned-window keyboard event.")
            }
            // Enter AppKit's own event queue so local monitors and key
            // equivalents run through the same dispatch path as user input.
            NSApp.postEvent(event, atStart: false)
        }
    }
    private static func verifyChromeGeometry(_ tab: ChromiumTab, ownerWindow: NSWindow) async throws {
        guard let chrome = tab.chromeWindow else { throw ValidationError("Chrome has no native window.") }
        let expected = ownerWindow.convertToScreen(tab.nativeView.convert(tab.nativeView.bounds.intersection(tab.nativeView.visibleRect), to: nil))
        func region(_ identifier: String, in view: NSView) -> NSView? {
            guard !view.isHidden else { return nil }
            if view.identifier?.rawValue == identifier, !view.bounds.isEmpty { return view }
            for child in view.subviews { if let found = region(identifier, in: child) { return found } }
            return nil
        }
        guard let root = ownerWindow.contentView, let page = region("radius.page", in: root) else {
            throw ValidationError("Radius's independent native page layout region is unavailable.")
        }
        let pageRect = ownerWindow.convertToScreen(page.convert(page.bounds, to: nil))
        guard pageRect.insetBy(dx: -2, dy: -2).contains(chrome.frame) else {
            throw ValidationError("Chrome covers controls outside Radius's page region (page=\(pageRect), child=\(chrome.frame)).")
        }
        if let tabs = region("radius.verticalTabs", in: root) {
            let tabRect = ownerWindow.convertToScreen(tabs.convert(tabs.bounds, to: nil))
            let overlap = chrome.frame.intersection(tabRect)
            guard overlap.isNull || overlap.width < 2 || overlap.height < 2 else {
                throw ValidationError("Chrome overlaps Radius's visible native tab strip.")
            }
        }
        let nativeState = try await tab.request("Radius.chromeHostState", parameters: [:])
        let state = try JSONSerialization.jsonObject(with: nativeState) as? [String: Any] ?? [:]
        print("Radius Chromium geometry: owner=\(ownerWindow.windowNumber) \(ownerWindow.frame), child=\(chrome.windowNumber) \(chrome.frame), parent=\(chrome.parent?.windowNumber ?? -1), hostBounds=\(tab.nativeView.bounds), hostFrame=\(tab.nativeView.frame), superBounds=\(String(describing: tab.nativeView.superview?.bounds)), anchor=\(expected), chrome=\(String(decoding: nativeState, as: UTF8.self))")
        guard chrome !== ownerWindow, chrome.parent === ownerWindow,
              abs(chrome.frame.minX - expected.minX) < 2, abs(chrome.frame.minY - expected.minY) < 2,
              abs(chrome.frame.width - expected.width) < 2, abs(chrome.frame.height - expected.height) < 2 else {
            throw ValidationError("The Chrome window does not fit its native page anchor; see the recorded window frames.")
        }
        guard tab.hasNativeNavigationChrome, state["toolbarDrawn"] as? Bool == true,
              (state["toolbarWidth"] as? Int ?? 0) > 20, (state["toolbarHeight"] as? Int ?? 0) > 20 else {
            throw ValidationError("The Chrome navigation toolbar is not visibly laid out inside its native child window.")
        }
    }
    static func verifyHostAndManagement(_ tab: ChromiumTab, app: AppState, ownerWindow: NSWindow) async throws {
        guard ProcessInfo.processInfo.environment["RADIUS_SMOKE_TEST_DATA"] != nil,
              ProcessInfo.processInfo.arguments.contains("--smoke-test") else {
            throw ValidationError("Chromium acceptance requires the isolated smoke-test launch.")
        }
        // The preceding independent keyboard probe restores the selected tab.
        // SwiftUI must remount that tab before inspecting its attached child.
        let mountDeadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !tab.hasNativeNavigationChrome || tab.chromeWindow?.parent !== ownerWindow {
            guard ContinuousClock.now < mountDeadline else { throw ValidationError("The restored Chromium tab did not remount inside its Radius window.") }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard tab.chromeStyle, tab.hasNativeNavigationChrome, let child = tab.chromeWindow, child !== ownerWindow,
              child.parent === ownerWindow, child.isVisible else {
            throw ValidationError("Chromium is not an intact Chrome-style child window in Radius.")
        }
        try await verifyChromeGeometry(tab, ownerWindow: ownerWindow)
        guard tab.focusAddressBar() else { throw ValidationError("Chrome's address control is unavailable.") }
        try await Task.sleep(for: .milliseconds(100))
        guard child.isKeyWindow else { throw ValidationError("The Chrome toolbar cannot receive keyboard focus.") }
        let manager = try ChromiumRuntime.shared.makeTab(profileID: UUID(), privateSessionID: nil, dataDirectory: app.dataDirectory)
        let managerWindow = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 900, height: 680),
                                     styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        managerWindow.isReleasedWhenClosed = false
        managerWindow.title = "Radius extension acceptance"
        managerWindow.contentView = manager.nativeView
        managerWindow.makeKeyAndOrderFront(nil)
        defer { manager.dispose(); managerWindow.close() }
        manager.showExtensions()
        try await waitForManager(manager)
        let installed = try await evaluate(manager, "JSON.stringify(await chrome.developerPrivate.getExtensionsInfo({includeDisabled:true, includeTerminated:true}))")
        guard let data = installed.data(using: .utf8), (try JSONSerialization.jsonObject(with: data)) is [[String: Any]] else {
            throw ValidationError("The Chrome extension management service did not return installed extensions.")
        }
        guard manager.chromeStyle, manager.chromeWindow?.parent === managerWindow else {
            throw ValidationError("Extension management escaped its native Radius window.")
        }
        var failures: [String] = []
        do { try await verifyFixture(manager, app: app) }
        catch { failures.append("Local MV3 fixture: " + error.localizedDescription) }
        manager.dispose(); managerWindow.close()
        let closeDeadline = ContinuousClock.now.advanced(by: .seconds(10))
        while manager.chromeWindow != nil, ContinuousClock.now < closeDeadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        if ProcessInfo.processInfo.environment["RADIUS_CHROMIUM_WEBSTORE_TEST"] == "1" {
            do {
                // Use a separate profile/window so a local fixture or its own
                // file chooser cannot obscure independent Store evidence.
                let store = try ChromiumRuntime.shared.makeTab(profileID: UUID(), privateSessionID: nil, dataDirectory: app.dataDirectory)
                let storeWindow = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1000, height: 740),
                                           styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
                storeWindow.isReleasedWhenClosed = false; storeWindow.title = "Radius Web Store acceptance"
                storeWindow.contentView = store.nativeView; storeWindow.makeKeyAndOrderFront(nil)
                defer { store.dispose(); storeWindow.close() }
                store.showExtensions(); try await waitForManager(store)
                try await verifyWebStore(store)
                let version = try await evaluate(store, "String((await chrome.developerPrivate.getExtensionsInfo({includeDisabled:true,includeTerminated:true})).find(e => e.id === 'ddkjiahejlhfcafbddmgiahcphecmpfh')?.version)")
                let receipt: [String: Any] = ["profileID": store.profileID.uuidString, "version": version,
                                              "processID": ProcessInfo.processInfo.processIdentifier]
                try JSONSerialization.data(withJSONObject: receipt).write(
                    to: app.dataDirectory.appendingPathComponent("Chromium/ExtensionAcceptance/webstore-restart.json"), options: .atomic)
            } catch { failures.append("Chrome Web Store: " + error.localizedDescription) }
        }
        if !failures.isEmpty { throw ValidationError(failures.joined(separator: "\n")) }
        print("Radius Chromium acceptance: Chrome Views, native child geometry/focus, and extension manager passed")
    }
    static func verifySessionCookieAfterLastBrowserCloses(app: AppState) async throws {
        var failures: [String] = []
        for isPrivate in [false, true] {
            do { try await verifySessionCookieAfterLastBrowserCloses(app: app, isPrivate: isPrivate) }
            catch { failures.append((isPrivate ? "Private window: " : "Regular profile: ") + error.localizedDescription) }
        }
        if !failures.isEmpty { throw ValidationError(failures.joined(separator: "\n")) }
    }
    private static func verifySessionCookieAfterLastBrowserCloses(app: AppState, isPrivate: Bool) async throws {
        guard ProcessInfo.processInfo.environment["RADIUS_SMOKE_TEST_DATA"] != nil,
              CommandLine.arguments.contains("--smoke-test"),
              let address = ProcessInfo.processInfo.environment["RADIUS_SMOKE_TEST_URL"],
              let url = URL(string: address), url.host == "127.0.0.1" else {
            throw ValidationError("The Chromium session-cookie probe requires the loopback fixture.")
        }
        let profile = UUID()
        let privateSessionID = isPrivate ? UUID() : nil
        if let privateSessionID { ChromiumRuntime.shared.beginPrivateSession(privateSessionID) }
        defer { if let privateSessionID { ChromiumRuntime.shared.closePrivateSession(privateSessionID) } }
        let first = try ChromiumRuntime.shared.makeTab(profileID: profile, privateSessionID: privateSessionID, dataDirectory: app.dataDirectory)
        let window = NSWindow(contentRect: NSRect(x: 120, y: 100, width: 900, height: 680),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Radius session-cookie acceptance"
        window.contentView = first.nativeView; window.makeKeyAndOrderFront(nil)
        defer { first.dispose(); window.close() }
        first.load(url); try await waitForLoad(first, host: "127.0.0.1")
        let cookie = "radiusSession" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        guard try await evaluate(first, "(document.cookie = '\(cookie)=present; path=/', document.cookie)")
            .contains(cookie + "=present") else {
            throw ValidationError("Chromium did not seed an expiry-free session cookie.")
        }
        var closed = false
        first.onClose = { closed = true }
        // Page.close follows Chrome's actual close lifecycle. Disposing the
        // Swift adapter alone only starts asynchronous CEF destruction.
        _ = try? await first.request("Page.close", parameters: [:], timeout: .seconds(5))
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !closed {
            guard ContinuousClock.now < deadline else { throw ValidationError("The last Chromium profile browser did not acknowledge closing.") }
            try await Task.sleep(for: .milliseconds(50))
        }
        guard window.isVisible else { throw ValidationError("Closing a Chromium browser also closed its native Radius window.") }
        let reopened = try ChromiumRuntime.shared.makeTab(profileID: profile, privateSessionID: privateSessionID, dataDirectory: app.dataDirectory)
        defer { reopened.dispose() }
        window.contentView = reopened.nativeView
        reopened.load(url); try await waitForLoad(reopened, host: "127.0.0.1")
        guard try await evaluate(reopened, "document.cookie").contains(cookie + "=present") else {
            throw ValidationError("Closing the last Chromium browser signed out its website context while its Radius window remained open.")
        }
        print("Radius Chromium acceptance: expiry-free \(isPrivate ? "private-window" : "regular-profile") cookie survived its last browser closing")
        if let privateSessionID {
            ChromiumRuntime.shared.closePrivateSession(privateSessionID)
            window.close()
            let releaseDeadline = ContinuousClock.now.advanced(by: .seconds(10))
            while reopened.chromeWindow != nil {
                guard ContinuousClock.now < releaseDeadline else { throw ValidationError("Closing the private window did not finish closing its Chromium browsers.") }
                try await Task.sleep(for: .milliseconds(50))
            }
            // Deliberately reuse the diagnostic identity to prove the released
            // context itself is gone, rather than only testing a different key.
            ChromiumRuntime.shared.beginPrivateSession(privateSessionID)
            let fresh = try ChromiumRuntime.shared.makeTab(profileID: profile, privateSessionID: privateSessionID, dataDirectory: app.dataDirectory)
            let freshWindow = NSWindow(contentRect: NSRect(x: 120, y: 100, width: 900, height: 680),
                                       styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            freshWindow.isReleasedWhenClosed = false
            freshWindow.contentView = fresh.nativeView; freshWindow.makeKeyAndOrderFront(nil)
            defer { fresh.dispose(); freshWindow.close() }
            fresh.load(url); try await waitForLoad(fresh, host: "127.0.0.1")
            guard try await evaluate(fresh, "document.cookie").contains(cookie + "=present") == false else {
                throw ValidationError("A private context kept its sign-in after its native window lifetime ended.")
            }
            print("Radius Chromium acceptance: private-window lifetime release erased its session cookie")
        }
    }
    static func verifyStoreRestart(app: AppState) async throws {
        guard ProcessInfo.processInfo.environment["RADIUS_SMOKE_TEST_DATA"] != nil,
              ProcessInfo.processInfo.environment["RADIUS_CHROMIUM_EXTENSION_RESTART"] == "1",
              ProcessInfo.processInfo.arguments.contains("--smoke-test") else {
            throw ValidationError("Extension restart acceptance requires the isolated second smoke-test launch.")
        }
        let receiptURL = app.dataDirectory.appendingPathComponent("Chromium/ExtensionAcceptance/webstore-restart.json")
        let size = try receiptURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= 4096,
              let receipt = try JSONSerialization.jsonObject(with: Data(contentsOf: receiptURL)) as? [String: Any],
              let profile = receipt["profileID"] as? String, let profileID = UUID(uuidString: profile),
              let version = receipt["version"] as? String,
              let processID = receipt["processID"] as? Int, processID != Int(ProcessInfo.processInfo.processIdentifier) else {
            throw ValidationError("The Web Store restart receipt is missing or was created in this same process.")
        }
        let manager = try ChromiumRuntime.shared.makeTab(profileID: profileID, privateSessionID: nil, dataDirectory: app.dataDirectory)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 900, height: 680),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.title = "Radius extension restart acceptance"
        window.contentView = manager.nativeView; window.makeKeyAndOrderFront(nil)
        defer { manager.dispose(); window.close() }
        manager.showExtensions(); try await waitForManager(manager)
        let text = try await evaluate(manager, "JSON.stringify((await chrome.developerPrivate.getExtensionsInfo({includeDisabled:true,includeTerminated:true})).find(e => e.id === 'ddkjiahejlhfcafbddmgiahcphecmpfh') || null)")
        guard let data = text.data(using: .utf8), let installed = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? [String: Any],
              installed["state"] as? String == "ENABLED", installed["version"] as? String == version else {
            throw ValidationError("The Chrome Web Store extension did not persist enabled across the full process restart.")
        }
        _ = try await evaluate(manager, "String(await chrome.management.uninstall('ddkjiahejlhfcafbddmgiahcphecmpfh',{showConfirmDialog:false}))")
        let remains = try await evaluate(manager, "String((await chrome.developerPrivate.getExtensionsInfo({includeDisabled:true,includeTerminated:true})).some(e => e.id === 'ddkjiahejlhfcafbddmgiahcphecmpfh'))")
        guard remains == "false" else { throw ValidationError("The Web Store extension could not be removed after restart.") }
        try FileManager.default.removeItem(at: receiptURL)
        print("Radius Chromium acceptance: Web Store extension persisted across a full process restart and was removed")
    }
    private static func waitForManager(_ tab: ChromiumTab) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        while tab.url?.scheme != "chrome" || tab.url?.host != "extensions" || tab.loading {
            if let error = tab.errorMessage { throw ValidationError(error) }
            guard ContinuousClock.now < deadline else { throw ValidationError("Chrome extension management did not load.") }
            try await Task.sleep(for: .milliseconds(100))
        }
    }
    private static func evaluate(_ tab: ChromiumTab, _ expression: String) async throws -> String {
        let data = try await tab.request("Runtime.evaluate", parameters: [
            "expression": "(async () => { return \(expression); })()", "awaitPromise": true, "returnByValue": true,
            "userGesture": true
        ])
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ValidationError("Chrome extension acceptance returned invalid JavaScript results.")
        }
        if let exception = object["exceptionDetails"] as? [String: Any] {
            let detail = (exception["exception"] as? [String: Any])?["description"] as? String ?? exception["text"] as? String ?? "Unknown exception"
            throw ValidationError("Chrome extension acceptance JavaScript: \(String(detail.prefix(1200)))")
        }
        guard let result = object["result"] as? [String: Any],
              let value = result["value"] as? String else {
            throw ValidationError("Chrome extension acceptance JavaScript failed.")
        }
        return value
    }
    private static func verifyFixture(_ manager: ChromiumTab, app: AppState) async throws {
        guard let sourcePath = ProcessInfo.processInfo.environment["RADIUS_SMOKE_TEST_EXTENSION_FIXTURE"],
              let address = ProcessInfo.processInfo.environment["RADIUS_SMOKE_TEST_URL"],
              let fixtureURL = URL(string: address), fixtureURL.scheme == "http", fixtureURL.host == "127.0.0.1" else {
            throw ValidationError("The isolated extension API fixture is not configured.")
        }
        let id = "pomncmnnjempbbdlbamhjphmpidacofc"
        print("Radius Chromium acceptance: loading the isolated native MV3 API fixture")
        let folder = app.dataDirectory.appendingPathComponent("Chromium/ExtensionAcceptance", isDirectory: true)
        let installedFolder = folder.appendingPathComponent("current", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: installedFolder.path) { try FileManager.default.removeItem(at: installedFolder) }
        try FileManager.default.copyItem(at: URL(fileURLWithPath: sourcePath, isDirectory: true), to: installedFolder)
        _ = try await evaluate(manager, "String(await chrome.developerPrivate.updateProfileConfiguration({inDeveloperMode:true}))")
        try await ChromiumFixtureLoader.load(manager: manager, dataDirectory: app.dataDirectory)
        let enabled = try await evaluate(manager, "String((await chrome.developerPrivate.getExtensionsInfo({includeDisabled:true,includeTerminated:true})).find(e => e.id === '\(id)')?.state)")
        guard enabled == "ENABLED" else { throw ValidationError("The native manager did not load the MV3 fixture.") }
        _ = try await evaluate(manager, "String(await chrome.developerPrivate.updateExtensionConfiguration({extensionId:'\(id)',pinnedToToolbar:true}))")
        let page = try ChromiumRuntime.shared.makeTab(profileID: manager.profileID, privateSessionID: nil, dataDirectory: app.dataDirectory)
        let window = NSWindow(contentRect: NSRect(x: 140, y: 100, width: 1000, height: 720),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.title = "Radius MV3 API acceptance"
        window.contentView = page.nativeView; window.makeKeyAndOrderFront(nil)
        defer {
            for auxiliary in ChromiumRuntime.shared.auxiliaryTabs where auxiliary.profileID == manager.profileID { auxiliary.dispose() }
            page.dispose(); window.close()
        }
        page.load(fixtureURL)
        var state = try await waitForFixture(page, key: "radiusFixtureWorker", value: "ready")
        guard state["radiusFixtureManifestVersion"] == "3", state["radiusFixtureScripting"] == "ready",
              state["radiusFixtureExtensionId"] == id, let count = Int(state["radiusFixtureCount"] ?? "") else {
            throw ValidationError("The MV3 worker, content script, scripting or storage API did not execute.")
        }
        print("Radius Chromium acceptance: opening the native extension action and side panel")
        try await click(page, selector: "#radius-fixture-action")
        state = try await waitForFixture(page, key: "radiusFixtureActionOpened", value: "1")
        guard state["radiusFixtureActionState"] != "error" else { throw ValidationError("The extension action did not open.") }
        // Close the action through an ordinary outside click before opening the panel.
        _ = try await page.request("Input.dispatchMouseEvent", parameters: ["type":"mousePressed", "x":20, "y":20, "button":"left", "clickCount":1])
        _ = try await page.request("Input.dispatchMouseEvent", parameters: ["type":"mouseReleased", "x":20, "y":20, "button":"left", "clickCount":1])
        try await click(page, selector: "#radius-fixture-sidepanel")
        _ = try await waitForFixture(page, key: "radiusFixtureSidePanelOpened", value: "1")
        print("Radius Chromium acceptance: MV3 content/worker/scripting/storage/action/side-panel documents executed")

        // Exercise the real management command. CEF opens a native auxiliary
        // Chrome window; its original browser/tab identity must be preserved.
        _ = try await evaluate(manager, "String(await chrome.developerPrivate.showOptions('\(id)'))")
        let optionsDeadline = ContinuousClock.now.advanced(by: .seconds(15))
        var options: ChromiumTab?
        while ContinuousClock.now < optionsDeadline {
            options = ChromiumRuntime.shared.auxiliaryTabs.first { $0.profileID == manager.profileID && $0.url?.host == id && $0.chromeWindow?.isVisible == true }
            if options != nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard let options else { throw ValidationError("Extension settings did not open in a managed auxiliary Chrome window.") }
        _ = try await waitForFixture(options, key: "radiusFixtureOptionsState", value: "ready")
        guard options.chromeWindow?.isVisible == true else { throw ValidationError("The native extension settings window is not visible.") }
        let permissions = try await evaluate(options, "JSON.stringify(await chrome.permissions.getAll())")
        guard let permissionData = permissions.data(using: .utf8),
              let grants = try JSONSerialization.jsonObject(with: permissionData) as? [String: Any],
              Set(grants["permissions"] as? [String] ?? []).isSuperset(of: ["storage", "activeTab", "scripting", "sidePanel"]),
              (grants["origins"] as? [String] ?? []).contains("http://127.0.0.1/*") else {
            throw ValidationError("The fixture's granted extension permissions differ from its requested scope.")
        }
        try await click(options, selector: "#nativecheckbox")
        _ = try await waitForFixture(options, key: "radiusFixtureTheme", value: "dark")
        _ = try await waitForFixture(page, key: "radiusFixtureTheme", value: "dark")
        let createdTabID = try await evaluate(options, "String((await chrome.tabs.create({url:chrome.runtime.getURL('options.html?api=tab')})).id)")
        let createdTab = try await waitForAuxiliary(profileID: manager.profileID, query: "api=tab")
        guard try await evaluate(createdTab, "String((await chrome.tabs.getCurrent()).id)") == createdTabID else {
            throw ValidationError("The extension-created tab lost its Chromium tab identity.")
        }
        let createdWindowID = try await evaluate(options, "String((await chrome.windows.create({url:chrome.runtime.getURL('options.html?api=window'),type:'normal'})).id)")
        let createdWindow = try await waitForAuxiliary(profileID: manager.profileID, query: "api=window")
        guard try await evaluate(createdWindow, "String((await chrome.windows.getCurrent()).id)") == createdWindowID else {
            throw ValidationError("The extension-created window lost its Chromium window identity.")
        }
        _ = try await evaluate(options, "String(!!window.open(chrome.runtime.getURL('options.html?api=popup'),'_blank'))")
        let descendant = try await waitForAuxiliary(profileID: manager.profileID, query: "api=popup")
        guard try await evaluate(descendant, "String(!!window.opener)") == "true" else {
            throw ValidationError("An auxiliary popup lost its original opener relationship.")
        }
        options.dispose()
        guard try await evaluate(createdTab, "String((await chrome.tabs.getCurrent()).id)") == createdTabID,
              try await evaluate(createdWindow, "String((await chrome.windows.getCurrent()).id)") == createdWindowID else {
            throw ValidationError("An auxiliary window stopped working when its origin tab closed.")
        }
        createdTab.dispose(); createdWindow.dispose(); descendant.dispose()
        print("Radius Chromium acceptance: tabs.create/windows.create identities and auxiliary popup opener/lifetime passed")
        page.reload()
        state = try await waitForFixture(page, key: "radiusFixtureWorker", value: "ready")
        // Wait for the next document's worker ping, not an old DOM state during reload.
        let storageDeadline = ContinuousClock.now.advanced(by: .seconds(10))
        while (Int(state["radiusFixtureCount"] ?? "") ?? 0) <= count, ContinuousClock.now < storageDeadline {
            try await Task.sleep(for: .milliseconds(100)); state = try await fixtureState(page)
        }
        guard state["radiusFixtureTheme"] == "dark", (Int(state["radiusFixtureCount"] ?? "") ?? 0) > count else {
            throw ValidationError("Extension settings/storage did not survive document reload.")
        }
        // Private Radius contexts start without regular-profile extensions.
        let fixturePrivateSession = UUID()
        ChromiumRuntime.shared.beginPrivateSession(fixturePrivateSession)
        defer { ChromiumRuntime.shared.closePrivateSession(fixturePrivateSession) }
        let privatePage = try ChromiumRuntime.shared.makeTab(profileID: manager.profileID, privateSessionID: fixturePrivateSession, dataDirectory: app.dataDirectory)
        defer { privatePage.dispose() }
        privatePage.load(fixtureURL)
        try await waitForLoad(privatePage, host: "127.0.0.1")
        try await Task.sleep(for: .milliseconds(500))
        guard try await evaluate(privatePage, "String(document.documentElement.dataset.radiusFixtureContent)") == "undefined" else {
            throw ValidationError("A regular-profile extension ran in an isolated private context.")
        }
        let manifestURL = installedFolder.appendingPathComponent("manifest.json")
        guard var manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any] else {
            throw ValidationError("The fixture manifest is invalid.")
        }
        manifest["version"] = "1.0.1"
        try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys]).write(to: manifestURL, options: .atomic)
        _ = try await evaluate(manager, "String(await chrome.developerPrivate.reload('\(id)',{failQuietly:true}))")
        page.reload()
        _ = try await waitForFixture(page, key: "radiusFixtureVersion", value: "1.0.1")
        _ = try await waitForFixture(page, key: "radiusFixtureTheme", value: "dark")
        let beforeDisable = try await fixtureState(page)
        let beforeDisableCount = Int(beforeDisable["radiusFixtureCount"] ?? "") ?? 0
        _ = try await evaluate(manager, "String(await chrome.management.setEnabled('\(id)',false))")
        guard try await evaluate(manager, "String((await chrome.developerPrivate.getExtensionsInfo({includeDisabled:true,includeTerminated:true})).find(e => e.id === '\(id)')?.state)") == "DISABLED" else {
            throw ValidationError("The extension manager did not disable the fixture.")
        }
        page.reload(); try await waitForLoad(page, host: "127.0.0.1")
        try await Task.sleep(for: .milliseconds(300))
        guard try await evaluate(page, "String(document.documentElement.dataset.radiusFixtureContent)") == "undefined" else {
            throw ValidationError("A disabled extension still injected into a new document.")
        }
        _ = try await evaluate(manager, "String(await chrome.management.setEnabled('\(id)',true))")
        page.reload()
        let restored = try await waitForFixture(page, key: "radiusFixtureWorker", value: "ready")
        guard restored["radiusFixtureTheme"] == "dark", restored["radiusFixtureVersion"] == "1.0.1",
              (Int(restored["radiusFixtureCount"] ?? "") ?? 0) > beforeDisableCount else {
            throw ValidationError("Re-enabling the fixture did not restore its worker/content or retained settings/storage.")
        }
        print("Radius Chromium acceptance: disabling stopped injection and re-enabling restored worker/content with retained storage")
        // This validates reload/update behavior for a local fixture. Signed Web
        // Store update delivery and whole-process restart are separate checks.
        _ = try await evaluate(manager, "String(await chrome.management.uninstall('\(id)',{showConfirmDialog:false}))")
        let removed = try await evaluate(manager, "String((await chrome.developerPrivate.getExtensionsInfo({includeDisabled:true,includeTerminated:true})).some(e => e.id === '\(id)'))")
        guard removed == "false" else { throw ValidationError("The extension manager did not remove the fixture.") }
        page.reload(); try await waitForLoad(page, host: "127.0.0.1")
        try await Task.sleep(for: .milliseconds(300))
        guard try await evaluate(page, "String(document.documentElement.dataset.radiusFixtureContent)") == "undefined" else {
            throw ValidationError("The removed extension still injected into a new document.")
        }
        print("Radius Chromium acceptance: native options window, grants, settings, storage, private isolation, local update and removal passed")
    }
    private static func fixtureState(_ tab: ChromiumTab) async throws -> [String: String] {
        if tab.loading { return [:] }
        let text = try await evaluate(tab, "JSON.stringify(document.documentElement ? document.documentElement.dataset : {})")
        guard let data = text.data(using: .utf8), let result = try JSONSerialization.jsonObject(with: data) as? [String: String] else {
            throw ValidationError("The fixture returned invalid state.")
        }
        if let error = result["radiusFixtureError"] { throw ValidationError("Extension API fixture: \(error)") }
        return result
    }
    private static func waitForAuxiliary(profileID: UUID, query: String) async throws -> ChromiumTab {
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while ContinuousClock.now < deadline {
            if let tab = ChromiumRuntime.shared.auxiliaryTabs.first(where: { $0.profileID == profileID && $0.url?.query == query }) {
                _ = try await waitForFixture(tab, key: "radiusFixtureOptionsState", value: "ready")
                if tab.chromeWindow?.isVisible == true { return tab }
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw ValidationError("The extension-created auxiliary browser did not load: \(query)")
    }
    private static func waitForFixture(_ tab: ChromiumTab, key: String, value: String) async throws -> [String: String] {
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while ContinuousClock.now < deadline {
            if let error = tab.errorMessage { throw ValidationError(error) }
            let state = try await fixtureState(tab)
            if state[key] == value { return state }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw ValidationError("Extension API fixture did not reach \(key)=\(value).")
    }
    private static func click(_ tab: ChromiumTab, selector: String) async throws {
        try await focusPage(tab)
        let encoded = String(decoding: try JSONSerialization.data(withJSONObject: selector, options: [.fragmentsAllowed]), as: UTF8.self)
        let point = try await evaluate(tab, "JSON.stringify((() => { const e=document.querySelector(\(encoded)); if (!e) return null; const r=e.getBoundingClientRect(); return {x:r.x+r.width/2,y:r.y+r.height/2}; })())")
        guard let data = point.data(using: .utf8), let position = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? [String: Double],
              let x = position["x"], let y = position["y"] else { throw ValidationError("The extension fixture control is unavailable: \(selector)") }
        _ = try await tab.request("Input.dispatchMouseEvent", parameters: ["type":"mousePressed", "x":x, "y":y, "button":"left", "clickCount":1])
        _ = try await tab.request("Input.dispatchMouseEvent", parameters: ["type":"mouseReleased", "x":x, "y":y, "button":"left", "clickCount":1])
    }
    private static func focusPage(_ tab: ChromiumTab) async throws {
        tab.chromeWindow?.makeKeyAndOrderFront(nil)
        tab.focus()
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            if tab.chromeWindow?.isKeyWindow == true {
                if tab.isAuxiliary { return }
                let data = try await tab.request("Radius.chromeHostState", parameters: [:])
                if (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["windowActive"] as? Bool == true { return }
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw ValidationError("The native Chromium acceptance window did not become key and active before input.")
    }
    private static func waitForLoad(_ tab: ChromiumTab, host: String) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(25))
        while tab.url?.host != host || tab.loading {
            if let error = tab.errorMessage { throw ValidationError(error) }
            guard ContinuousClock.now < deadline else { throw ValidationError("The extension acceptance page did not load.") }
            try await Task.sleep(for: .milliseconds(100))
        }
    }
    private static func verifyWebStore(_ tab: ChromiumTab) async throws {
        // Fixed public MV3 extension, installed only into the fresh acceptance
        // profile above. Never run this probe in the user's browsing profile.
        let extensionID = "ddkjiahejlhfcafbddmgiahcphecmpfh"
        tab.load(URL(string: "https://chromewebstore.google.com/detail/ublock-origin-lite/\(extensionID)?hl=en")!)
        try await waitForLoad(tab, host: "chromewebstore.google.com")
        let deadline = ContinuousClock.now.advanced(by: .seconds(45))
        var target: [String: Double]?
        while ContinuousClock.now < deadline {
            if let error = tab.errorMessage { throw ValidationError(error) }
            let value = try await evaluate(tab, """
            (() => {
                const visit = root => {
                    for (const element of root.querySelectorAll('*')) {
                        if (element.shadowRoot) { const found = visit(element.shadowRoot); if (found) return found; }
                        if ((element.tagName === 'BUTTON' || element.getAttribute('role') === 'button') &&
                            element.textContent.trim() === 'Add to Chrome' && !element.disabled) {
                            const r = element.getBoundingClientRect();
                            if (r.width && r.height) return {x:r.x+r.width/2,y:r.y+r.height/2};
                        }
                    }
                    return null;
                };
                return JSON.stringify(visit(document));
            })()
            """)
            if let bytes = value.data(using: .utf8), let point = try JSONSerialization.jsonObject(with: bytes, options: [.fragmentsAllowed]) as? [String: Double] {
                target = point; break
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        guard let target, let x = target["x"], let y = target["y"] else {
            throw ValidationError("The live Chrome Web Store did not offer Add to Chrome for the MV3 acceptance extension.")
        }
        try await focusPage(tab)
        _ = try await tab.request("Input.dispatchMouseEvent", parameters: ["type":"mousePressed", "x":x, "y":y, "button":"left", "clickCount":1])
        _ = try await tab.request("Input.dispatchMouseEvent", parameters: ["type":"mouseReleased", "x":x, "y":y, "button":"left", "clickCount":1])
        // Inspect our own native accessibility tree and press only the enabled
        // Add extension button on this fixed fixture's real permission dialog.
        print("Radius Chromium acceptance: waiting for the native Web Store permission dialog")
        var approved = false
        var lastPromptState = ""
        let installDeadline = ContinuousClock.now.advanced(by: .seconds(45))
        while ContinuousClock.now < installDeadline {
            if !approved {
                let response = try await tab.request("Radius.acceptFixtureExtension", parameters: [:])
                approved = (try JSONSerialization.jsonObject(with: response) as? [String: Any])?["pressed"] as? Bool == true
                let promptState = String(decoding: response, as: UTF8.self)
                if promptState != lastPromptState {
                    print("Radius Chromium native extension prompt: \(promptState)")
                    lastPromptState = promptState
                }
                if approved { print("Radius Chromium acceptance: pressed the fixture's native Add extension button") }
            }
            let value = try await evaluate(tab, "String(document.body.innerText.includes('Remove from Chrome'))")
            if value == "true", approved {
                tab.showExtensions(); try await waitForManager(tab)
                let state = try await evaluate(tab, "String((await chrome.developerPrivate.getExtensionsInfo({includeDisabled:true,includeTerminated:true})).find(e => e.id === '\(extensionID)')?.state)")
                guard state == "ENABLED" else { throw ValidationError("The Web Store extension was not enabled after installation.") }
                print("Radius Chromium acceptance: live Chrome Web Store install passed for \(extensionID)")
                return
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        if let output = ProcessInfo.processInfo.environment["RADIUS_SMOKE_TEST_OUTPUT"], let chrome = tab.chromeWindow {
            await AppSmokeTest.captureWindow(chrome, to: URL(fileURLWithPath: output).appendingPathComponent("Radius-webstore-permission-timeout.png"))
        }
        throw ValidationError("The native Chrome Web Store installation was not approved and completed before its deadline.")
    }
}
