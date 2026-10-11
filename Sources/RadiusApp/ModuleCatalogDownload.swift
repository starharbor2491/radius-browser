// SPDX-License-Identifier: MPL-2.0
import AppKit
import Foundation
import RadiusCore

private final class ModuleCatalogRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, url.scheme == "https", url.host != nil, url.user == nil, url.password == nil else { completionHandler(nil); return }
        completionHandler(request)
    }
}
@MainActor extension AppState {
    func addCatalogFromURL() {
        let alert = NSAlert(); alert.messageText = "Add a community catalog"
        alert.informativeText = "Enter an HTTPS URL for a Radius JSON catalog. Publishers remain unverified. Adding the catalog does not install or enable modules."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 400, height: 28)); field.placeholderString = "https://example.com/radius-catalog.json"
        alert.accessoryView = field; alert.addButton(withTitle: "Fetch catalog"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn, let url = URL(string: field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) else { return }
        Task {
            do { try addCatalog(try await fetchModuleCatalog(url)) }
            catch { notice = error.localizedDescription }
        }
    }
    func refreshCommunityCatalog(named name: String) {
        Task {
            do {
                guard let repository, let current = try repository.communityCatalogs().first(where: { $0.name == name }), let url = current.sourceURL else {
                    throw ValidationError("This local catalog has no remote source. Import its updated JSON catalog instead.")
                }
                let updated = try await fetchModuleCatalog(url)
                guard updated.name == name else { throw ValidationError("The remote catalog changed its identity. Add it separately and inspect the publisher information.") }
                try addCatalog(updated, replaceExisting: true)
            } catch { notice = error.localizedDescription }
        }
    }
    private func fetchModuleCatalog(_ url: URL) async throws -> DeclarativeModuleCatalog {
        guard url.scheme == "https", url.host != nil, url.user == nil, url.password == nil else { throw ValidationError("Catalogs require an HTTPS URL without credentials.") }
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.urlCredentialStorage = nil; config.urlCache = nil
        config.timeoutIntervalForRequest = 20; config.timeoutIntervalForResource = 30
        let session = URLSession(configuration: config, delegate: ModuleCatalogRedirectPolicy(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(from: url)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200, response.url?.scheme == "https",
              response.expectedContentLength <= 2 * 1024 * 1024 else { throw ValidationError("The server did not return a catalog within the 2 MB limit.") }
        var data = Data(); data.reserveCapacity(16 * 1024)
        for try await byte in bytes {
            try Task.checkCancellation(); data.append(byte)
            guard data.count <= 2 * 1024 * 1024 else { throw ValidationError("The community catalog exceeds 2 MB.") }
        }
        var catalog = try DeclarativeModuleCatalog.decode(data)
        // Persist the user-requested source, never a self-reported redirect target.
        catalog.sourceURL = url
        return catalog
    }
}
