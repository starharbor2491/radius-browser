// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
import RadiusCore
@testable import RadiusApp

@Suite(.serialized)
@MainActor
struct ResourceModuleTests {
    @Test func nativeWorkerReplacementDisableAndUninstallStopExecutionAndKeepData() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("radius-resource-native-" + UUID().uuidString)
        let app = AppState(directory: directory)
        let worker = ResourceWorker()
        defer { worker.stop(); try? FileManager.default.removeItem(at: directory) }
        await app.load()
        #expect(app.startupError == nil)
        #expect(app.notice == nil)
        let note = Note(profileID: app.library.profiles[0].id)
        app.library.notes.append(note)
        let original = try app.resourceWorkerPackage()
        try worker.start(executable: original.url, moduleID: original.id)
        let firstProcess = try #require(worker.process)
        try await waitForFrame(worker)
        #expect(worker.frame?.title == "Resource Monitor")
        #expect(worker.frame?.metrics.contains { $0.name == "System CPU" } == true)
        try app.installApprovedModule("org.radius.memory-monitor")
        #expect(app.installedModules.filter { $0.enabled && $0.manifest.capability == .resourceMonitor }.map(\.id) == [original.id])
        try app.replaceResourceProvider(with: "org.radius.memory-monitor")
        #expect(!firstProcess.isRunning)
        #expect(app.library.notes == [note])
        let replacement = try app.resourceWorkerPackage()
        try worker.start(executable: replacement.url, moduleID: replacement.id)
        let secondProcess = try #require(worker.process)
        try await waitForFrame(worker)
        #expect(worker.frame?.title == "Memory Breakdown")
        #expect(worker.frame?.metrics.count == 5)
        try app.removeModule(replacement.id)
        #expect(!secondProcess.isRunning)
        #expect(!FileManager.default.fileExists(atPath: replacement.url.path))
        #expect(!app.enabled(.resourceMonitor))
        #expect(app.library.notes == [note])
        let disabled = try #require(app.installedModules.first { $0.id == original.id })
        app.toggleModule(disabled)
        let resumed = try app.resourceWorkerPackage()
        try worker.start(executable: resumed.url, moduleID: resumed.id)
        let thirdProcess = try #require(worker.process)
        let enabled = try #require(app.installedModules.first { $0.id == original.id })
        app.toggleModule(enabled)
        #expect(!thirdProcess.isRunning)
        #expect(!app.enabled(.resourceMonitor))
        #expect(FileManager.default.fileExists(atPath: original.url.path))
        #expect(await app.flush())
    }

    @Test func installedNativeBytesMustMatchBundledWorkerAndClosingPanelStopsWorker() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("radius-resource-trust-" + UUID().uuidString)
        let app = AppState(directory: directory)
        let worker = ResourceWorker()
        defer { worker.stop(); try? FileManager.default.removeItem(at: directory) }
        await app.load()
        let package = try app.resourceWorkerPackage()
        try worker.start(executable: package.url, moduleID: package.id)
        let process = try #require(worker.process)
        try await waitForFrame(worker)
        worker.stop() // The panel's onDisappear lifecycle calls the same stop-and-reap path.
        #expect(!process.isRunning)
        var altered = try Data(contentsOf: package.url); altered.append(0)
        try altered.write(to: package.url)
        #expect(throws: (any Error).self) { try app.resourceWorkerPackage() }
        #expect(await app.flush())
    }

    private func waitForFrame(_ worker: ResourceWorker) async throws {
        for _ in 0..<150 {
            if worker.frame != nil { return }
            if let failure = worker.failure { throw ValidationError(failure) }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw ValidationError("The real native resource worker did not publish a sample.")
    }
}
