// SPDX-License-Identifier: MPL-2.0
import Foundation
import CoreFoundation
import AppKit
import Darwin
import Testing
import RadiusCore
@testable import RadiusApp

extension NativeIntegrationTests {
@Suite(.serialized)
@MainActor
struct ResourceModuleTests {

    @Test func realWorkerReapingRejectsNestedApprovedUpdatesAndPreservesUnrelatedLayoutEdits() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("radius-worker-reentry-" + UUID().uuidString)
        let previous = AppDelegate.state
        let app = AppState(directory: directory), worker = ResourceWorker()
        defer { worker.stop(); app.ready = false; AppDelegate.state = previous; try? FileManager.default.removeItem(at: directory) }
        await app.load()
        try #require(app.ready, Comment(rawValue: app.startupError ?? "Native worker fixture did not load"))
        let repository = try #require(app.repository)
        var widget = ModuleManifest(id: "org.test.reentry-widget", name: "Reentry widget", summary: "Reviewed update", capability: .startWidget, runtime: .declarative)
        let originalBytes = Data(#"{"formatVersion":1,"widgetTitle":"Original","widgetBody":"Before the reviewed update"}"#.utf8)
        let updatedBytes = Data(#"{"formatVersion":1,"widgetTitle":"Updated","widgetBody":"After the reviewed update"}"#.utf8)
        try repository.install(widget, payload: originalBytes)
        app.installedModules = try repository.installed()
        widget.version = 2; app.catalog.append(widget); app.modulePayloads[widget.id] = updatedBytes
        let package = try app.resourceWorkerPackage()
        let trustedBytes = try Data(contentsOf: package.url)

        for rollback in [false, true] {
            let requirements = try app.validateModuleRequirements(for: [widget.id])
            let approval = try app.captureModuleApproval(requirements, rootIDs: [widget.id])
            let inventory = try repository.installed()
            try worker.start(executable: package.url, moduleID: package.id)
            try await waitForFrame(worker)
            let process = try #require(worker.process)
            // Pause only this owned real worker. Its existing bounded SIGKILL
            // deadline makes the native wait service the run loop for 250 ms.
            try #require(kill(process.processIdentifier, SIGSTOP) == 0)
            var edited = app.library.preferences.configuration
            edited.layout.navigation = rollback ? .top : .bottom
            let probe = WorkerReentryProbe(app: app, id: widget.id, approval: approval, configuration: edited)
            // Run at the nested wait's entry instead of depending on a timer
            // firing before the real worker's bounded shutdown deadline.
            let observer = try #require(CFRunLoopObserverCreateWithHandler(
                kCFAllocatorDefault, CFRunLoopActivity.entry.rawValue, true, 0
            ) { observer, _ in
                MainActor.assumeIsolated {
                    guard probe.app.stoppingModuleWorkers else { return }
                    CFRunLoopObserverInvalidate(observer)
                    probe.attemptUpdate()
                }
            })
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .defaultMode)
            defer { CFRunLoopObserverInvalidate(observer) }

            if rollback {
                #expect(throws: (any Error).self) {
                    try app.withAtomicModuleChanges(for: [package.id]) {
                        try app.reinstallApprovedWorker(package.id)
                        throw ValidationError("Reject this fixture transaction after its real repair.")
                    }
                }
            } else { try app.reinstallApprovedWorker(package.id) }
            CFRunLoopObserverInvalidate(observer)
            #expect(probe.fired && probe.duringWorkerStop)
            #expect(probe.rejection != nil)
            #expect(probe.launchRejection != nil && !probe.launchPackageReturned && probe.newWorker.process == nil)
            #expect(probe.terminationReply == .terminateCancel)
            #expect(!app.terminating && !app.finalQuitDataFrozen && app.ready)
            #expect(!process.isRunning)
            #expect(try repository.installed() == inventory)
            #expect(try repository.dataPayload(for: widget.id, runtime: .declarative) == originalBytes)
            #expect(try Data(contentsOf: package.url) == trustedBytes)
            #expect(app.library.preferences.configuration == edited)
        }

        // The same reviewed update remains usable after the wait has finished.
        let requirements = try app.validateModuleRequirements(for: [widget.id])
        let approval = try app.captureModuleApproval(requirements, rootIDs: [widget.id])
        try app.installApprovedModule(widget.id, approval: approval)
        #expect(try repository.dataPayload(for: widget.id, runtime: .declarative) == updatedBytes)
        #expect(app.startWidgets.contains { $0.widgetTitle == "Updated" })
        #expect(await app.flush())
    }

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
        try app.setModuleEnabledApproved(disabled.id, enabled: true)
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
        #expect(worker.frame == nil)
        var altered = try Data(contentsOf: package.url); altered.append(0)
        try altered.write(to: package.url)
        #expect(throws: (any Error).self) { try app.resourceWorkerPackage() }
        let oldGeneration = app.resourceWorkerGeneration
        try app.reinstallApprovedWorker(package.id)
        #expect(app.resourceWorkerGeneration != oldGeneration)
        let repaired = try app.resourceWorkerPackage()
        try worker.start(executable: repaired.url, moduleID: repaired.id)
        try await waitForFrame(worker)
        #expect(worker.frame?.title == "Resource Monitor")
        #expect(await app.flush())
    }

    @Test func missingAndOversizedWorkersCanBeRepairedAfterRelaunch() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("radius-resource-repair-" + UUID().uuidString)
        let initial = AppState(directory: directory)
        let worker = ResourceWorker()
        defer { worker.stop(); try? FileManager.default.removeItem(at: directory) }
        await initial.load()
        let package = try initial.resourceWorkerPackage()
        #expect(await initial.flush())
        for damage in ["missing", "empty", "oversized"] {
            try FileManager.default.removeItem(at: package.url)
            if damage != "missing" {
                try Data(repeating: 0, count: damage == "empty" ? 0 : 8 * 1024 * 1024 + 1).write(to: package.url)
            }
            let reopened = AppState(directory: directory)
            await reopened.load()
            #expect(reopened.ready)
            #expect(reopened.startupError == nil)
            #expect(reopened.installedModules.contains { $0.id == package.id && $0.enabled })
            // A signed application update/startup repairs existing official worker
            // payloads from its sealed factory copy without restoring removals.
            #expect(try reopened.resourceWorkerPackage().id == package.id)
            try reopened.reinstallApprovedWorker(package.id)
            let repaired = try reopened.resourceWorkerPackage()
            try worker.start(executable: repaired.url, moduleID: repaired.id)
            try await waitForFrame(worker)
            #expect(worker.frame?.title == "Resource Monitor")
            worker.stop()
            #expect(await reopened.flush())
        }
    }

    @Test func damagedReplacementDoesNotStopTheWorkingProvider() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("radius-resource-preflight-" + UUID().uuidString)
        let app = AppState(directory: directory), worker = ResourceWorker()
        defer { worker.stop(); try? FileManager.default.removeItem(at: directory) }
        await app.load()
        let original = try app.resourceWorkerPackage()
        try worker.start(executable: original.url, moduleID: original.id)
        let process = try #require(worker.process)
        try await waitForFrame(worker)
        try app.installApprovedModule("org.radius.memory-monitor")
        let replacement = directory.appendingPathComponent("Modules/org.radius.memory-monitor/worker")
        try FileManager.default.removeItem(at: replacement)
        let generation = app.resourceWorkerGeneration
        #expect(throws: (any Error).self) { try app.replaceResourceProvider(with: "org.radius.memory-monitor") }
        #expect(app.resourceWorkerGeneration == generation)
        #expect(process.isRunning)
        #expect(try app.resourceWorkerPackage().id == original.id)
        try app.reinstallApprovedWorker("org.radius.memory-monitor")
        try app.replaceResourceProvider(with: "org.radius.memory-monitor")
        #expect(!process.isRunning)
        #expect(try app.resourceWorkerPackage().id == "org.radius.memory-monitor")
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

}

@MainActor
private final class WorkerReentryProbe {
    let app: AppState
    let id: String
    let approval: ModuleApprovalSnapshot
    let configuration: Configuration
    var fired = false
    var duringWorkerStop = false
    var rejection: String?
    let newWorker = ResourceWorker()
    var launchRejection: String?
    var launchPackageReturned = false
    var terminationReply: NSApplication.TerminateReply?
    init(app: AppState, id: String, approval: ModuleApprovalSnapshot, configuration: Configuration) {
        self.app = app; self.id = id; self.approval = approval; self.configuration = configuration
    }
    func attemptUpdate() {
        fired = true; duringWorkerStop = app.stoppingModuleWorkers
        do { try app.installApprovedModule(id, approval: approval) }
        catch { rejection = error.localizedDescription }
        do {
            let package = try app.resourceWorkerPackage()
            launchPackageReturned = true
            try newWorker.start(executable: package.url, moduleID: package.id)
        } catch { launchRejection = error.localizedDescription }
        terminationReply = AppDelegate().applicationShouldTerminate(NSApplication.shared)
        newWorker.stop()
        // A separate editor's interface change remains valid during reaping.
        app.applyConfiguration(configuration)
    }
}
