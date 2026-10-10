// SPDX-License-Identifier: MPL-2.0
import AppKit
import Foundation
import Testing
@preconcurrency import WebKit
import RadiusCore
@testable import RadiusApp

extension NativeIntegrationTests {
@Suite(.serialized)
@MainActor
struct ReaderModuleTests {
    @Test func installedReaderExtractsWithoutMutatingOrPersistingPrivatePage() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("radius-reader-native-" + UUID().uuidString)
        let app = AppState(directory: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        // Previous builds allowed local descriptor imports for Reader. Their names
        // must not shadow the real worker after upgrading to the native package.
        let repository = try ModuleRepository(root: directory.appendingPathComponent("Modules"))
        try repository.install(ModuleManifest(id: "org.example.legacy-reader", name: "AAA Legacy Reader", summary: "Legacy descriptor", capability: .reader))
        await app.load()
        #expect(app.enabled(.reader))
        let model = BrowserModel(app: app, isPrivate: true)
        defer { model.closeWindow() }
        let tab = try #require(model.activeWebTab as? WebTab)
        tab.webView.loadHTMLString("<html><body><nav>Navigation</nav><article><h1>Private title</h1><p>Only reader text</p><p>One&nbsp;two</p></article><script>window.radiusMarker = 42; window.XMLSerializer = function() { window.radiusMarker = 0; throw new Error('Page override must not run'); };</script></body></html>", baseURL: nil)
        for _ in 0..<150 {
            if (try? await tab.webView.evaluateJavaScript("window.radiusMarker")) as? Int == 42 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let before = app.library
        let text = try await app.readerText(from: tab)
        #expect(text.contains("Private title"))
        #expect(text.contains("Only reader text"))
        #expect(text.contains("One\u{00a0}two"))
        #expect(!text.contains("Navigation"))
        #expect((try await tab.webView.evaluateJavaScript("window.radiusMarker")) as? Int == 42)
        #expect((try await tab.webView.evaluateJavaScript("document.querySelector('nav').textContent")) as? String == "Navigation")
        #expect(app.library == before)
        let reader = try #require(app.installedModules.first { $0.id == "org.radius.reader" })
        app.toggleModule(reader)
        #expect(!app.enabled(.reader))
        #expect(app.installedModules.contains { $0.id == "org.example.legacy-reader" && $0.enabled })
        await #expect(throws: (any Error).self) { try await app.readerText(from: tab) }
        try app.removeModule(reader.id)
        #expect(!app.enabled(.reader))
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("Modules/org.radius.reader/worker").path))
        #expect(await app.flush())
    }

    @Test func snapshotCancellationAndDeadlineIgnoreLateCallbacks() async throws {
        let request = WebPageSnapshotRequest()
        var completion: (@MainActor @Sendable (Result<Any, any Error>) -> Void)?
        let task = Task { try await request.capture { completion = $0 } }
        for _ in 0..<100 {
            if completion != nil { break }
            await Task.yield()
        }
        #expect(completion != nil)
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        completion?(.success("<p>Late response</p>"))
        await #expect(throws: ValidationError.self) { try await request.capture { _ in } }

        let timedOut = WebPageSnapshotRequest(timeout: .milliseconds(20))
        await #expect(throws: ValidationError.self) { try await timedOut.capture { _ in } }
        timedOut.cancel()
        let disposed = WebPageSnapshotRequest()
        disposed.cancel()
        await #expect(throws: CancellationError.self) { try await disposed.capture { _ in Issue.record("A disposed snapshot must not start.") } }
    }

    @Test func disablingAndRemovingReaderReapsAnUnresponsiveWorker() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("radius-reader-cancel-" + UUID().uuidString)
        let app = AppState(directory: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        await app.load()
        let fixture = directory.appendingPathComponent("blocked-reader")
        // Test-only fixture blocks without reading stdin. Production launches still require
        // exact bundled bytes; this checks cancellation while the transport writer is blocked.
        try Data("#!/bin/sh\nexec /bin/sleep 30\n".utf8).write(to: fixture)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.path)
        let staleSnapshot = SuspendedReaderTab()
        let staleCapture = Task { try await app.readerText(from: staleSnapshot) }
        for _ in 0..<100 {
            if staleSnapshot.completion != nil { break }
            await Task.yield()
        }
        #expect(staleSnapshot.completion != nil)
        staleSnapshot.didStartNavigation()
        staleSnapshot.completion?(.success("<html><body>Old page</body></html>"))
        await #expect(throws: CancellationError.self) { try await staleCapture.value }
        for removing in [false, true] {
            let worker = ReaderWorker()
            defer { worker.cancel() }
            let module = try #require(app.installedModules.first { $0.id == "org.radius.reader" })
            if !module.enabled { try app.setModuleEnabledApproved(module.id, enabled: true) }
            let snapshot = SuspendedReaderTab()
            let capture = Task { try await app.readerText(from: snapshot) }
            let task = Task { try await worker.extract(html: String(repeating: "x", count: 500_000), executable: fixture, moduleID: module.id) }
            for _ in 0..<100 {
                if worker.process?.isRunning == true && snapshot.capturing { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let process = try #require(worker.process)
            #expect(process.isRunning)
            await #expect(throws: ValidationError.self) {
                try await worker.extract(html: "<p>Concurrent request</p>", executable: fixture, moduleID: module.id)
            }
            if removing { try app.removeModule(module.id) }
            else { try app.setModuleEnabledApproved(module.id, enabled: false) }
            await #expect(throws: CancellationError.self) { try await task.value }
            await #expect(throws: CancellationError.self) { try await capture.value }
            #expect(!process.isRunning)
            await #expect(throws: ValidationError.self) {
                try await worker.extract(html: "<p>Reused request</p>", executable: fixture, moduleID: module.id)
            }
        }
        #expect(await app.flush())
    }
}

}

@MainActor
private final class SuspendedReaderTab: BrowserEngineTab {
    private let request = WebPageSnapshotRequest()
    private(set) var capturing = false
    private(set) var completion: (@MainActor @Sendable (Result<Any, any Error>) -> Void)?
    override func pageHTML() async throws -> String {
        capturing = true
        return try await request.capture { completion = $0 }
    }
}
