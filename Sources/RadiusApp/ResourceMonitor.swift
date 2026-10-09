// SPDX-License-Identifier: MPL-2.0
import Darwin
import SwiftUI
import RadiusCore

/// Only curated, byte-verified first-party executables reach start(). Native workers have
/// normal same-user OS access; the display protocol is not an OS sandbox or permission grant.
@MainActor
final class ResourceWorker: ObservableObject {
    @Published private(set) var frame: ResourceFrame?
    @Published private(set) var failure: String?
    private(set) var process: Process?
    private(set) var moduleID: String?
    private var input: Pipe?
    private var output: Pipe?
    private var buffer = Data()
    private var generation = UUID()
    private var watchdog: Task<Void, Never>?
    private static var workers: [WeakResourceWorker] = []
    deinit {
        watchdog?.cancel()
        try? input?.fileHandleForWriting.close()
        if let process, process.isRunning { process.terminate() }
    }

    func start(executable: URL, moduleID: String) throws {
        stop(); frame = nil; failure = nil
        let process = Process(), input = Pipe(), output = Pipe()
        let generation = UUID(); self.generation = generation
        process.executableURL = executable
        process.currentDirectoryURL = executable.deletingLastPathComponent()
        process.environment = ["PATH": "/usr/bin:/bin"]
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { @MainActor in self?.receive(data, generation: generation) }
        }
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                guard let self, self.generation == generation else { return }
                self.failure = "The resource provider stopped. Close and reopen the panel to retry."
                self.stop()
            }
        }
        self.process = process; self.input = input; self.output = output; self.moduleID = moduleID
        do { try process.run() } catch { stop(); throw error }
        Self.workers.removeAll { $0.value == nil || $0.value === self }
        Self.workers.append(WeakResourceWorker(self))
        resetWatchdog()
    }
    func showFailure(_ error: any Error) { stop(); failure = error.localizedDescription }
    private func receive(_ data: Data, generation: UUID) {
        guard self.generation == generation else { return }
        guard !data.isEmpty else { return }
        guard buffer.count + data.count <= 64 * 1024 else { fail("The resource provider exceeded its output limit."); return }
        buffer.append(data)
        while let end = buffer.firstIndex(of: 0x0a) {
            let line = Data(buffer[..<end]); buffer.removeSubrange(...end)
            do { frame = try ResourceFrame.decode(line); resetWatchdog() }
            catch { fail(error.localizedDescription); return }
        }
    }
    private func fail(_ message: String) { failure = message; stop() }
    private func resetWatchdog() {
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(8)) } catch { return }
            self?.fail("The resource provider stopped responding. Close and reopen the panel to retry.")
        }
    }
    /// Stop and reap before the caller removes/replaces the installed package. Normal workers
    /// exit immediately; a separate dispatch timer bounds a stuck worker's shutdown to 250 ms.
    func stop() {
        generation = UUID(); watchdog?.cancel(); watchdog = nil; frame = nil
        output?.fileHandleForReading.readabilityHandler = nil
        process?.terminationHandler = nil
        try? input?.fileHandleForWriting.close()
        if let process, process.isRunning {
            process.terminate()
            let deadline = DispatchWorkItem { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.25, execute: deadline)
            process.waitUntilExit()
            deadline.cancel()
        }
        try? output?.fileHandleForReading.close()
        process = nil; input = nil; output = nil; moduleID = nil; buffer.removeAll()
    }
    static func stopAll(moduleID: String? = nil) {
        for worker in workers.compactMap(\.value) where moduleID == nil || worker.moduleID == moduleID { worker.stop() }
        workers.removeAll { $0.value == nil }
    }
}
@MainActor
private final class WeakResourceWorker {
    weak var value: ResourceWorker?
    init(_ value: ResourceWorker) { self.value = value }
}

struct ResourcePanel: View {
    @EnvironmentObject private var app: AppState
    @StateObject private var worker = ResourceWorker()
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if let frame = worker.frame {
                    Text(frame.title).font(.headline)
                    ForEach(Array(frame.metrics.enumerated()), id: \.offset) { _, metric in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(metric.name).font(.caption).foregroundStyle(.secondary)
                            Text(metric.value).font(.system(size: 25, weight: .medium, design: .rounded)).monospacedDigit()
                            if !metric.samples.isEmpty {
                                Sparkline(values: metric.samples).stroke(Color.accentColor, lineWidth: 2).frame(height: 52)
                                    .accessibilityLabel("Recent " + metric.name + " samples")
                            }
                            if let fraction = metric.fraction { ProgressView(value: fraction) }
                            if !metric.detail.isEmpty { Text(metric.detail).font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                    Text(frame.detail).font(.caption).foregroundStyle(.secondary)
                } else if worker.failure == nil { ProgressView("Starting resource provider…") }
                if let failure = worker.failure { Text(failure).font(.callout).foregroundStyle(.orange) }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
        }
        .task(id: app.resourceWorkerGeneration) {
            do {
                let package = try app.resourceWorkerPackage()
                try worker.start(executable: package.url, moduleID: package.id)
            } catch { worker.showFailure(error) }
        }
        .onDisappear { worker.stop() }
    }
}
struct Sparkline: Shape {
    var values: [Double]
    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard values.count > 1 else { return path }
        for (index, value) in values.enumerated() {
            let point = CGPoint(x: rect.width * Double(index) / Double(values.count - 1), y: rect.height * (1 - value))
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        return path
    }
}
