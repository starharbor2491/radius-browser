// SPDX-License-Identifier: MPL-2.0
import AppKit
import SwiftUI
@preconcurrency import WebKit

@MainActor
final class DownloadItem: ObservableObject, Identifiable {
    let id = UUID()
    @Published var name = "Preparing download…"
    @Published var status = "Waiting for a destination"
    @Published var destination: URL?
    var staging: URL?
    @Published var active = true
    @Published var fraction = 0.0
    let download: WKDownload
    var progressObservation: NSKeyValueObservation?
    init(_ download: WKDownload) { self.download = download }
}
@MainActor
final class DownloadCenter: NSObject, ObservableObject, WKDownloadDelegate {
    @Published var items: [DownloadItem] = []
    func track(_ download: WKDownload) {
        let item = DownloadItem(download); items.insert(item, at: 0); download.delegate = self
        item.progressObservation = download.progress.observe(\.fractionCompleted, options: [.new]) { [weak item] _, change in
            let fraction = change.newValue ?? 0
            Task { @MainActor [weak item] in item?.fraction = fraction }
        }
    }
    private func item(_ download: WKDownload) -> DownloadItem? { items.first { $0.download === download } }
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String, completionHandler: @escaping @MainActor @Sendable (URL?) -> Void) {
        guard let item = item(download) else { completionHandler(nil); return }
        let cleanName = URL(fileURLWithPath: suggestedFilename).lastPathComponent
        item.name = cleanName.isEmpty ? "Download" : cleanName
        let panel = NSSavePanel(); panel.nameFieldStringValue = item.name
        panel.message = "Save this download. Files are never opened automatically."
        guard panel.runModal() == .OK, let url = panel.url else {
            item.status = "Cancelled"; item.active = false; item.progressObservation = nil; completionHandler(nil); return
        }
        let staging = url.deletingLastPathComponent().appendingPathComponent(".radius-download-" + UUID().uuidString + ".part")
        item.destination = url; item.staging = staging; item.status = "Downloading"; completionHandler(staging)
    }
    func downloadDidFinish(_ download: WKDownload) {
        guard let item = item(download) else { return }
        item.active = false; item.progressObservation = nil
        guard let staging = item.staging, let destination = item.destination else { item.status = "Failed: missing destination"; return }
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: staging)
            } else { try FileManager.default.moveItem(at: staging, to: destination) }
            item.staging = nil; item.fraction = 1; item.status = "Finished"
        } catch { item.status = "Failed to save: \(error.localizedDescription). Temporary file kept at \(staging.path)." }
    }
    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        guard let item = item(download) else { return }
        item.active = false; item.status = "Failed: \(error.localizedDescription)"; item.progressObservation = nil
        if let staging = item.staging { try? FileManager.default.removeItem(at: staging); item.staging = nil }
    }
    func cancel(_ item: DownloadItem) {
        guard item.active else { return }
        let staging = item.staging
        item.download.cancel { _ in if let staging { try? FileManager.default.removeItem(at: staging) } }
        item.staging = nil
        item.active = false; item.status = "Cancelled"; item.progressObservation = nil
    }
    func cancelAll() { items.filter(\.active).forEach(cancel) }
    var hasActive: Bool { items.contains(where: \.active) }
}
