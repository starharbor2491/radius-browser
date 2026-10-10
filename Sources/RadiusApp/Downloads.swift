// SPDX-License-Identifier: MPL-2.0
import AppKit
import CoreServices
import RadiusCore
import SwiftUI
@preconcurrency import WebKit

@MainActor
final class DownloadItem: ObservableObject, Identifiable {
    let id = UUID()
    @Published var name = "Preparing download…"
    @Published var status = "Waiting for a destination"
    @Published var destination: URL?
    var staging: URL?
    var approvedReplacement = false
    @Published var active = true
    @Published var fraction = 0.0
    let download: WKDownload?
    let chromiumID: String?
    var sourceURL: URL?
    var cancelChromium: (@MainActor @Sendable () -> Void)?
    var destinationPanel: NSSavePanel?
    var cancellationRequested = false
    var transferEnded = false
    // Browser destruction stops CEF download callbacks without stopping its
    // writer. This is distinct from receiving an actual terminal update.
    var acknowledgementUnavailable = false
    var awaitsTerminalUpdate: Bool { !transferEnded && !acknowledgementUnavailable }
    var progressObservation: NSKeyValueObservation?
    init(_ download: WKDownload) { self.download = download; chromiumID = nil }
    init(chromiumID: String, sourceURL: URL?, cancel: @escaping @MainActor @Sendable () -> Void) {
        download = nil; self.chromiumID = chromiumID; self.sourceURL = sourceURL; cancelChromium = cancel
    }
}
@MainActor
final class DownloadCenter: NSObject, ObservableObject, WKDownloadDelegate {
    @Published var items: [DownloadItem] = []
    private var standaloneWindow: DownloadWindowController?
    func showWindow() {
        if standaloneWindow == nil {
            standaloneWindow = DownloadWindowController(center: self) { [weak self] in self?.standaloneWindow = nil }
        }
        standaloneWindow?.showWindow(nil)
        standaloneWindow?.window?.makeKeyAndOrderFront(nil)
    }
    func track(_ download: WKDownload) {
        let item = DownloadItem(download); items.insert(item, at: 0); download.delegate = self
        item.progressObservation = download.progress.observe(\.fractionCompleted, options: [.new]) { [weak item] _, change in
            let fraction = change.newValue ?? 0
            Task { @MainActor [weak item] in
                guard let item, item.active else { return }
                item.fraction = fraction
            }
        }
    }
    private func item(_ download: WKDownload) -> DownloadItem? { items.first { $0.download === download } }
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String, completionHandler: @escaping @MainActor @Sendable (URL?) -> Void) {
        guard let item = item(download) else { completionHandler(nil); return }
        item.sourceURL = response.url
        chooseDestination(for: item, suggestedName: suggestedFilename, completion: completionHandler)
    }
    /// IDs must be unique across the runtime, including downloads from different tabs.
    func beginChromium(id: String, suggestedName: String, sourceURL: URL?, cancel: @escaping @MainActor @Sendable () -> Void,
                       completion: @escaping @MainActor @Sendable (URL?) -> Void) {
        guard !items.contains(where: { $0.chromiumID == id }) else { completion(nil); return }
        let item = DownloadItem(chromiumID: id, sourceURL: sourceURL, cancel: cancel)
        items.insert(item, at: 0)
        chooseDestination(for: item, suggestedName: suggestedName, completion: completion)
    }
    /// A terminal update acknowledges that Chromium has closed the staging file.
    /// Keep these updates connected after cancellation so shutdown can await cleanup.
    func updateChromium(id: String, fraction: Double, complete: Bool, cancelled: Bool, interrupted: Bool) {
        guard let item = items.first(where: { $0.chromiumID == id }), !item.transferEnded else { return }
        if complete || cancelled || interrupted {
            item.destinationPanel?.cancel(nil)
            if item.cancellationRequested || cancelled { finishCancellation(item) }
            else if interrupted { fail(item, message: "Download interrupted") }
            else { finish(item) }
        } else if item.active, fraction.isFinite {
            item.fraction = min(1, max(0, fraction))
        }
    }
    /// Call before clearing the closed browser's command target. Mandatory CEF
    /// closes can leave downloads running without any further status callbacks.
    /// Preserve their files and let runtime shutdown stop the remaining writers.
    func chromiumOwnerClosed(ids: Set<String>) {
        for item in items where item.awaitsTerminalUpdate && item.chromiumID.map({ ids.contains($0) }) == true {
            item.acknowledgementUnavailable = true
            item.cancellationRequested = true
            item.active = false
            item.status = item.staging == nil
                ? "Source tab closed before cancellation was confirmed."
                : "Source tab closed before cancellation was confirmed. The incomplete temporary file is retained."
            item.destinationPanel?.cancel(nil)
            // Request cancellation even if an earlier request timed out. Set
            // state first because a callback can deliver a real terminal update
            // synchronously; that update may safely perform the usual cleanup.
            let cancel = item.cancelChromium
            item.cancelChromium = nil
            cancel?()
        }
    }
    private func chooseDestination(for item: DownloadItem, suggestedName: String, completion: @MainActor @Sendable (URL?) -> Void) {
        guard item.active else { completion(nil); return }
        let cleanName = URL(fileURLWithPath: suggestedName).lastPathComponent
        item.name = cleanName.isEmpty ? "Download" : cleanName
        let panel = NSSavePanel(); panel.nameFieldStringValue = item.name
        panel.message = "Save this download. Files are never opened automatically."
        item.destinationPanel = panel
        let choice = panel.runModal()
        item.destinationPanel = nil
        guard item.active, choice == .OK, let url = panel.url else {
            if item.active { cancel(item) }
            completion(nil)
            return
        }
        let staging = url.deletingLastPathComponent().appendingPathComponent(".radius-download-" + UUID().uuidString + ".part")
        item.approvedReplacement = FileManager.default.fileExists(atPath: url.path)
        item.destination = url; item.staging = staging; item.status = "Downloading"; completion(staging)
    }
    func downloadDidFinish(_ download: WKDownload) {
        guard let item = item(download) else { return }
        if item.cancellationRequested { finishCancellation(item) }
        else { finish(item) }
    }
    private func finish(_ item: DownloadItem) {
        guard !item.transferEnded else { return }
        // Mark the writer finished before presenting a replacement alert, whose
        // nested run loop can deliver additional Chromium terminal updates.
        item.transferEnded = true
        item.active = false; item.progressObservation = nil
        defer { endTransfer(item) }
        guard let staging = item.staging, let destination = item.destination else { item.status = "Failed: missing destination"; return }
        do {
            // Apply quarantine before moving or replacing anything. A failed save
            // retains the completed staging file for the user's Finder action.
            var quarantine: [String: Any] = [
                kLSQuarantineTypeKey as String: kLSQuarantineTypeWebDownload,
                kLSQuarantineAgentNameKey as String: "Radius",
                kLSQuarantineTimeStampKey as String: Date()
            ]
            if let sourceURL = item.sourceURL { quarantine[kLSQuarantineDataURLKey as String] = sourceURL }
            try (staging as NSURL).setResourceValue(quarantine, forKey: .quarantinePropertiesKey)
            if FileManager.default.fileExists(atPath: destination.path) {
                if !item.approvedReplacement {
                    let alert = NSAlert(); alert.messageText = "Replace a file that appeared during this download?"
                    alert.informativeText = "A file now exists at \(destination.lastPathComponent). Your completed download is kept separately until you choose."
                    alert.addButton(withTitle: "Keep existing file"); alert.addButton(withTitle: "Replace file")
                    guard alert.runModal() == .alertSecondButtonReturn else {
                        item.status = "Download complete. Existing file kept; downloaded copy is available in Finder."; item.fraction = 1; return
                    }
                }
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: staging,
                                                         backupItemName: nil, options: .usingNewMetadataOnly)
            } else { try FileManager.default.moveItem(at: staging, to: destination) }
            item.staging = nil; item.fraction = 1; item.status = "Finished"
        } catch { item.status = "Failed to save: \(error.localizedDescription). Temporary file kept at \(staging.path)." }
    }
    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        guard let item = item(download) else { return }
        if item.cancellationRequested { finishCancellation(item) }
        else { fail(item, message: error.localizedDescription) }
    }
    private func fail(_ item: DownloadItem, message: String) {
        guard !item.transferEnded else { return }
        item.active = false; item.status = "Failed: \(message)"
        removeStaging(item); endTransfer(item)
    }
    private func finishCancellation(_ item: DownloadItem) {
        guard !item.transferEnded else { return }
        item.active = false; item.status = "Cancelled"
        removeStaging(item); endTransfer(item)
    }
    private func removeStaging(_ item: DownloadItem) {
        if let staging = item.staging {
            do { try FileManager.default.removeItem(at: staging); item.staging = nil }
            catch {
                if !FileManager.default.fileExists(atPath: staging.path) { item.staging = nil }
                else { item.status += ". Temporary file could not be removed: \(error.localizedDescription)" }
            }
        }
    }
    private func endTransfer(_ item: DownloadItem) {
        item.transferEnded = true; item.progressObservation = nil; item.cancelChromium = nil
        item.acknowledgementUnavailable = false
    }
    func cancel(_ item: DownloadItem) {
        guard item.active else { return }
        item.cancellationRequested = true
        item.active = false; item.status = "Cancelling…"; item.progressObservation = nil
        item.destinationPanel?.cancel(nil)
        if let download = item.download {
            download.cancel { [self, item] _ in
                Task { @MainActor in
                    self.finishCancellation(item)
                }
            }
        } else {
            // Chromium's terminal update performs cleanup after its writer closes.
            item.cancelChromium?()
        }
    }
    func cancelAll() { items.filter(\.active).forEach(cancel) }
    /// Owner-closed downloads cannot acknowledge cancellation. Keep their files
    /// and allow the caller to proceed to Chromium shutdown instead of waiting.
    func cancelAllAndWait(timeout: Duration = .seconds(10)) async throws {
        try await cancelAndWait(items.filter(\.awaitsTerminalUpdate), timeout: timeout)
    }
    func cancelChromiumAndWait(ids: Set<String>, timeout: Duration = .seconds(10)) async throws {
        try await cancelAndWait(items.filter { item in
            item.awaitsTerminalUpdate && item.chromiumID.map { ids.contains($0) } == true
        }, timeout: timeout)
    }
    private func cancelAndWait(_ pending: [DownloadItem], timeout: Duration) async throws {
        pending.forEach(cancel)
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while pending.contains(where: \.awaitsTerminalUpdate) {
            try Task.checkCancellation()
            if clock.now >= deadline {
                // An engine failure may prevent the final callback. Keep both the
                // item and staging file intact so a late update can still clean
                // up safely, and allow the user to retry cancellation.
                for item in pending where item.awaitsTerminalUpdate {
                    item.active = true
                    item.status = item.staging == nil
                        ? "Cancellation not confirmed. Try cancelling again."
                        : "Cancellation not confirmed. Temporary file kept; try cancelling again."
                }
                throw ValidationError("The browser engine has not confirmed that all downloads stopped. Any temporary files have been kept. Try cancelling again before closing Radius.")
            }
            try await clock.sleep(until: min(deadline, clock.now.advanced(by: .milliseconds(50))))
        }
    }
    var hasActive: Bool { items.contains(where: \.awaitsTerminalUpdate) }
}

/// Auxiliary Chrome windows can outlive their original Radius tab. Their
/// native download list therefore has its own presentation and lifetime.
@MainActor
private final class DownloadWindowController: NSWindowController, NSWindowDelegate {
    private let onClose: @MainActor () -> Void
    init(center: DownloadCenter, onClose: @escaping @MainActor () -> Void) {
        self.onClose = onClose
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 460, height: 500),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Downloads — Radius"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.contentView = NSHostingView(rootView: DownloadsPanel(center: center))
        window.delegate = self
        window.center()
    }
    required init?(coder: NSCoder) { nil }
    func windowWillClose(_ notification: Notification) { onClose() }
}
