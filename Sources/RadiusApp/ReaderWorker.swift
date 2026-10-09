// SPDX-License-Identifier: MPL-2.0
import Darwin
import Foundation
import RadiusCore

/// A single user-requested extraction. Only the HTML snapshot crosses the pipes;
/// the trusted worker has ordinary same-user OS access, not an OS permission sandbox.
@MainActor
final class ReaderWorker {
    private(set) var process: Process?
    private(set) var moduleID: String?
    private var input: Pipe?
    private var output: Pipe?
    private var completion: CheckedContinuation<String, any Error>?
    private var watchdog: Task<Void, Never>?
    private var hasStarted = false
    private static var active: [WeakReaderWorker] = []

    func extract(html: String, executable: URL, moduleID: String) async throws -> String {
        // Each instance owns exactly one extraction, including its queued pipe callbacks.
        // Reuse could let a callback from a cancelled process complete a later request.
        guard !hasStarted else { throw ValidationError("A Reader worker can only extract one page.") }
        hasStarted = true
        try Task.checkCancellation()
        let request = try JSONEncoder().encode(ReaderRequest(html: html))
        guard request.count <= ReaderRequest.maximumMessageBytes else { throw ValidationError("Reader's page snapshot is too large.") }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                self.completion = continuation
                let process = Process(), input = Pipe(), output = Pipe()
                self.process = process; self.input = input; self.output = output; self.moduleID = moduleID
                process.executableURL = executable; process.currentDirectoryURL = executable.deletingLastPathComponent()
                process.environment = ["PATH": "/usr/bin:/bin"]
                process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
                // Cancellation can close the child's read end during a write. Prevent SIGPIPE
                // from terminating Radius; FileHandle reports the failed write as an error.
                _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
                do { try process.run() } catch { finish(.failure(error)); return }
                Self.active.removeAll { $0.value == nil }; Self.active.append(WeakReaderWorker(self))
                watchdog = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(8)) } catch { return }
                    self?.finish(.failure(ValidationError("Reader did not finish in time. Try a smaller page.")))
                }
                DispatchQueue.global().async { [weak self] in
                    do { try input.fileHandleForWriting.write(contentsOf: request); try input.fileHandleForWriting.close() }
                    catch { Task { @MainActor in self?.finish(.failure(error)) } }
                }
                DispatchQueue.global().async { [weak self] in
                    let result: Result<String, any Error>
                    do {
                        var data = Data()
                        while let chunk = try output.fileHandleForReading.read(upToCount: min(16 * 1024, ReaderResponse.maximumBytes + 1 - data.count)), !chunk.isEmpty {
                            data.append(chunk)
                            guard data.count <= ReaderResponse.maximumBytes else { throw ValidationError("Reader returned too much data.") }
                        }
                        process.waitUntilExit()
                        guard process.terminationStatus == 0 else { throw ValidationError("Reader stopped before completing the page.") }
                        result = .success(try JSONDecoder().decode(ReaderResponse.self, from: data).validatedText())
                    } catch { result = .failure(error) }
                    Task { @MainActor in self?.finish(result) }
                }
            }
        } onCancel: { Task { @MainActor in self.cancel() } }
    }
    func cancel() { finish(.failure(CancellationError())) }
    private func finish(_ result: Result<String, any Error>) {
        guard let continuation = completion else { return }
        completion = nil; watchdog?.cancel(); watchdog = nil
        if let process, process.isRunning {
            process.terminate()
            let deadline = DispatchWorkItem { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.25, execute: deadline)
            process.waitUntilExit(); deadline.cancel()
        }
        try? input?.fileHandleForWriting.close(); try? output?.fileHandleForReading.close()
        process = nil; input = nil; output = nil; moduleID = nil
        continuation.resume(with: result)
    }
    static func stopAll(moduleID: String? = nil) {
        for worker in active.compactMap(\.value) where moduleID == nil || worker.moduleID == moduleID { worker.cancel() }
        active.removeAll { $0.value == nil }
    }
}
@MainActor private final class WeakReaderWorker {
    weak var value: ReaderWorker?
    init(_ value: ReaderWorker) { self.value = value }
}
