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
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        guard let item = item(download) else { completionHandler(nil); return }
        let cleanName = URL(fileURLWithPath: suggestedFilename).lastPathComponent
        item.name = cleanName.isEmpty ? "Download" : cleanName
        let panel = NSSavePanel(); panel.nameFieldStringValue = item.name
        panel.message = "Save this download. Files are never opened automatically."
        guard panel.runModal() == .OK, let url = panel.url else {
            item.status = "Cancelled"; item.active = false; item.progressObservation = nil; completionHandler(nil); return
        }
        item.destination = url; item.status = "Downloading"; completionHandler(url)
    }
    func downloadDidFinish(_ download: WKDownload) {
        guard let item = item(download) else { return }
        item.active = false; item.fraction = 1; item.status = "Finished"; item.progressObservation = nil
    }
    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        guard let item = item(download) else { return }
        item.active = false; item.status = "Failed: \(error.localizedDescription)"; item.progressObservation = nil
    }
    func cancel(_ item: DownloadItem) {
        guard item.active else { return }
        item.download.cancel { _ in }
        item.active = false; item.status = "Cancelled"; item.progressObservation = nil
    }
    func cancelAll() { items.filter(\.active).forEach(cancel) }
    var hasActive: Bool { items.contains(where: \.active) }
}
