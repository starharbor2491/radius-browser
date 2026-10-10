// SPDX-License-Identifier: MPL-2.0
import AppKit
import RadiusCore

/// Executed only by the packaged application's isolated native smoke test.
@MainActor
enum ChromiumAcceptance {
    static func verifyHostAndManagement(_ tab: ChromiumTab, app: AppState, ownerWindow: NSWindow) async throws {
        guard ProcessInfo.processInfo.environment["RADIUS_SMOKE_TEST_DATA"] != nil,
              ProcessInfo.processInfo.arguments.contains("--smoke-test") else {
            throw ValidationError("Chromium acceptance requires the isolated smoke-test launch.")
        }
        guard tab.chromeStyle, let child = tab.chromeWindow, child !== ownerWindow,
              child.parent === ownerWindow, child.isVisible else {
            throw ValidationError("Chromium is not an intact Chrome-style child window in Radius.")
        }
        let expected = ownerWindow.convertToScreen(tab.nativeView.convert(tab.nativeView.visibleRect, to: nil))
        guard abs(child.frame.minX - expected.minX) < 2, abs(child.frame.minY - expected.minY) < 2,
              abs(child.frame.width - expected.width) < 2, abs(child.frame.height - expected.height) < 2 else {
            throw ValidationError("The Chrome pane does not match its native layout anchor.")
        }
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
        if ProcessInfo.processInfo.environment["RADIUS_CHROMIUM_WEBSTORE_TEST"] == "1" {
            try await verifyWebStore(manager)
        }
        print("Radius Chromium acceptance: Chrome Views, native child geometry/focus, and extension manager passed")
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
            "expression": "(async () => { return \(expression); })()", "awaitPromise": true, "returnByValue": true
        ])
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["exceptionDetails"] == nil, let result = object["result"] as? [String: Any],
              let value = result["value"] as? String else {
            throw ValidationError("Chrome extension acceptance JavaScript failed.")
        }
        return value
    }
    private static func verifyWebStore(_ tab: ChromiumTab) async throws {
        // Fixed public MV3 extension, installed only into the fresh acceptance
        // profile above. Never run this probe in the user's browsing profile.
        let extensionID = "ddkjiahejlhfcafbddmgiahcphecmpfh"
        tab.load(URL(string: "https://chromewebstore.google.com/detail/ublock-origin-lite/\(extensionID)?hl=en")!)
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
        _ = try await tab.request("Input.dispatchMouseEvent", parameters: ["type":"mousePressed", "x":x, "y":y, "button":"left", "clickCount":1])
        _ = try await tab.request("Input.dispatchMouseEvent", parameters: ["type":"mouseReleased", "x":x, "y":y, "button":"left", "clickCount":1])
        // Inspect our own native accessibility tree and press only the enabled
        // Add extension button on this fixed fixture's real permission dialog.
        print("Radius Chromium acceptance: waiting for the native Web Store permission dialog")
        var approved = false
        let installDeadline = ContinuousClock.now.advanced(by: .seconds(45))
        while ContinuousClock.now < installDeadline {
            if !approved {
                let response = try await tab.request("Radius.acceptFixtureExtension", parameters: [:])
                approved = (try JSONSerialization.jsonObject(with: response) as? [String: Any])?["pressed"] as? Bool == true
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
        throw ValidationError("The native Chrome Web Store installation was not approved and completed before its deadline.")
    }
}
