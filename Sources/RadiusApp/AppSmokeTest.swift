// SPDX-License-Identifier: MPL-2.0
import AppKit
import RadiusCore

/// CI-only launch verification using the actual app window and an isolated, disposable data folder.
@MainActor
enum AppSmokeTest {
    static func run() async {
        guard let outputPath = ProcessInfo.processInfo.environment["RADIUS_SMOKE_TEST_OUTPUT"],
              ProcessInfo.processInfo.environment["RADIUS_SMOKE_TEST_DATA"] != nil else {
            fail("Smoke test requires isolated data and output directories."); return
        }
        let output = URL(fileURLWithPath: outputPath, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            let deadline = Date().addingTimeInterval(20)
            while AppDelegate.state?.ready != true || NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }) == nil || AppDelegate.state?.windows.values.compactMap(\.model).isEmpty != false {
                if let error = AppDelegate.state?.startupError { throw ValidationError(error) }
                if Date() > deadline { throw ValidationError("The packaged app did not open a browser window.") }
                try await Task.sleep(for: .milliseconds(100))
            }
            guard let app = AppDelegate.state, let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
                  let browser = app.windows.values.compactMap(\.model).first else { throw ValidationError("Browser state is unavailable.") }
            app.library.preferences.completedOnboarding = true
            browser.panel = .resources
            for design in DesignSystem.allCases {
                var config = Configuration(); config.theme.design = design
                if design == .graphite { config.layout.tabs = .leading; config.layout.sidebar = .trailing }
                app.applyConfiguration(config)
                try await Task.sleep(for: .milliseconds(500))
                guard let view = window.contentView, let image = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw ValidationError("Cannot capture the browser window.") }
                view.cacheDisplay(in: view.bounds, to: image)
                guard let png = image.representation(using: .png, properties: [:]), png.count > 1000 else { throw ValidationError("The browser screenshot was empty.") }
                try png.write(to: output.appendingPathComponent("Radius-\(design.rawValue).png"))
            }
            // Verify native control surfaces render independently of a website engine.
            for sheet in [BrowserSheet.modules, .customize, .settings, .recovery] {
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
                browser.navigate(address)
                let pageDeadline = Date().addingTimeInterval(10)
                while browser.activeWebTab.webView.title != "Radius HTTP fixture" || browser.activeWebTab.loading {
                    if Date() > pageDeadline { throw ValidationError("The packaged app could not navigate to its HTTP test page.") }
                    try await Task.sleep(for: .milliseconds(100))
                }
                guard browser.activeWebTab.webView.url?.scheme == "http" else { throw ValidationError("HTTP navigation did not reach the fixture.") }
                let text = try await browser.activeWebTab.readerText()
                guard text.contains("Local browser check") else { throw ValidationError("Reader could not read the HTTP fixture.") }
            }
            guard await app.flush() else { throw ValidationError(app.notice ?? "App data could not be saved.") }
            print("Radius packaged-app smoke test passed.")
            NSApp.terminate(nil)
        } catch { fail(error.localizedDescription) }
    }
    private static func fail(_ message: String) {
        print("Radius smoke test failed: \(message)")
        exit(1)
    }
}
