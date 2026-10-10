// SPDX-License-Identifier: MPL-2.0
import AppKit
import SwiftUI
@preconcurrency import WebKit
import RadiusCore

/// Engine objects stay inside this adapter. The native shell and recovery do not require a web view.
@MainActor
final class WebTab: BrowserEngineTab, WKNavigationDelegate, WKUIDelegate {
    let webView: WKWebView
    override var nativeView: NSView { webView }
    override var url: URL? { webView.url }
    override var title: String? { webView.title }
    override var engineID: BrowserEngineID { .webkit }
    private let downloads: DownloadCenter
    private var observations: [NSKeyValueObservation] = []
    private var imageSnapshots: [UUID: WebImageSnapshotRequest] = [:]
    private var pageSnapshots: [UUID: WebPageSnapshotRequest] = [:]
    init(dataStore: WKWebsiteDataStore, downloads: DownloadCenter, configuration: WKWebViewConfiguration? = nil) {
        let config = configuration ?? WKWebViewConfiguration()
        if configuration == nil { config.websiteDataStore = dataStore }
        webView = WKWebView(frame: .zero, configuration: config)
        self.downloads = downloads
        super.init()
        webView.navigationDelegate = self; webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        observations = [
            webView.observe(\.estimatedProgress, options: [.new]) { [weak self] _, change in
                let value = change.newValue ?? 0
                Task { @MainActor [weak self] in self?.progress = value }
            },
            webView.observe(\.title, options: [.new]) { [weak self] _, _ in Task { @MainActor [weak self] in self?.refresh(false) } },
            webView.observe(\.url, options: [.new]) { [weak self] _, _ in Task { @MainActor [weak self] in self?.refresh(false) } }
        ]
    }
    override func load(_ url: URL) {
        guard AddressResolver.isWebURL(url) else { errorMessage = "This address is not supported."; return }
        errorMessage = nil; updatePopupPolicy(); webView.load(URLRequest(url: url))
    }
    override func updatePopupPolicy() { webView.configuration.preferences.javaScriptCanOpenWindowsAutomatically = allowPopups?() == true }
    override func reload() { errorMessage = nil; webView.reload() }
    override func stop() { webView.stopLoading() }
    override func goBack() { webView.goBack() }
    override func goForward() { webView.goForward() }
    override func setZoom(_ value: Double) { super.setZoom(value); webView.pageZoom = zoom }
    override func dispose() {
        imageSnapshots.values.forEach { $0.cancel() }; imageSnapshots.removeAll()
        pageSnapshots.values.forEach { $0.cancel() }; pageSnapshots.removeAll()
        webView.stopLoading(); webView.navigationDelegate = nil; webView.uiDelegate = nil
        observations.removeAll(); super.dispose()
    }
    private func refresh(_ finished: Bool) {
        loading = webView.isLoading; canGoBack = webView.canGoBack; canGoForward = webView.canGoForward
        onChange?(finished)
    }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        didStartNavigation()
        imageSnapshots.values.forEach { $0.cancel() }; imageSnapshots.removeAll()
        pageSnapshots.values.forEach { $0.cancel() }; pageSnapshots.removeAll()
        errorMessage = nil; loading = true; refresh(false)
    }
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) { refresh(false) }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loading = false; refresh(true) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failed(error) }
    private func failed(_ error: Error) {
        loading = false
        if (error as NSError).code != NSURLErrorCancelled { errorMessage = error.localizedDescription }
        refresh(false)
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        imageSnapshots.values.forEach { $0.cancel() }; imageSnapshots.removeAll()
        pageSnapshots.values.forEach { $0.cancel() }; pageSnapshots.removeAll()
        loading = false; errorMessage = "The website's process stopped. Reload the page to continue."; refresh(false)
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        if url.absoluteString == "about:blank" { decisionHandler(.allow); return }
        // Websites can generate embedded documents without changing the browser's
        // top-level address or gaining access to local files.
        if navigationAction.targetFrame?.isMainFrame == false,
           url.scheme?.lowercased() == "data" || url.absoluteString.components(separatedBy: "#").first == "about:srcdoc" {
            decisionHandler(.allow); return
        }
        if url.scheme?.lowercased() == "blob" {
            decisionHandler(navigationAction.shouldPerformDownload ? .download : .allow); return
        }
        guard AddressResolver.isWebURL(url) else {
            // Only a deliberate click may hand off common non-web protocols.
            if navigationAction.navigationType == .linkActivated, ["mailto", "tel"].contains(url.scheme?.lowercased() ?? "") {
                let alert = NSAlert(); alert.messageText = "Open an external app?"
                alert.informativeText = "This website wants to open \(url.scheme ?? "another app")."
                alert.addButton(withTitle: "Open app"); alert.addButton(withTitle: "Cancel")
                if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(url) }
            }
            decisionHandler(.cancel); return
        }
        if navigationAction.shouldPerformDownload { decisionHandler(.download) }
        else { decisionHandler(.allow) }
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void) {
        decisionHandler(navigationResponse.canShowMIMEType ? .allow : .download)
    }
    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) { downloads.track(download) }
    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) { downloads.track(download) }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        let url = navigationAction.request.url
        guard url == nil || url?.absoluteString == "about:blank" || url?.scheme == "blob" || url.map(AddressResolver.isWebURL) == true else { return nil }
        // WebKit's javaScriptCanOpenWindowsAutomatically setting blocks unsolicited popups.
        // Return a view using the supplied configuration; WebKit preserves the request and opener.
        let child = WebTab(dataStore: configuration.websiteDataStore, downloads: downloads, configuration: configuration)
        guard onCreateWindow?(child, url) == true else { child.dispose(); return nil }
        return child.webView
    }
    func webViewDidClose(_ webView: WKWebView) { onClose?() }
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.message = "Choose files to share with \(frame.securityOrigin.host)."
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories; panel.canChooseFiles = true
        completionHandler(panel.runModal() == .OK ? panel.urls : nil)
    }
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable () -> Void) {
        let alert = siteAlert(frame, message); alert.addButton(withTitle: "OK"); alert.runModal(); completionHandler()
    }
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async -> Bool {
        let alert = siteAlert(frame, message); alert.addButton(withTitle: "OK"); alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable (String?) -> Void) {
        let alert = siteAlert(frame, prompt); let input = NSTextField(string: defaultText ?? "")
        input.frame = NSRect(x: 0, y: 0, width: 320, height: 24); alert.accessoryView = input
        alert.addButton(withTitle: "OK"); alert.addButton(withTitle: "Cancel")
        completionHandler(alert.runModal() == .alertFirstButtonReturn ? input.stringValue : nil)
    }
    private func siteAlert(_ frame: WKFrameInfo, _ message: String) -> NSAlert {
        let alert = NSAlert(); alert.messageText = "\(frame.securityOrigin.host) says"
        alert.informativeText = String(message.prefix(4000)); return alert
    }
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType, decisionHandler: @escaping @MainActor @Sendable (WKPermissionDecision) -> Void) {
        guard origin.protocol == "https" else { decisionHandler(.deny); return }
        let alert = NSAlert(); alert.messageText = "Allow \(origin.host) to use your camera or microphone?"
        alert.informativeText = "This permission applies to this website. macOS may also ask for permission."
        alert.addButton(withTitle: "Don't allow"); alert.addButton(withTitle: "Allow")
        decisionHandler(alert.runModal() == .alertSecondButtonReturn ? .grant : .deny)
    }
    override func capturePNG() async throws -> Data {
        let id = UUID(), request = WebImageSnapshotRequest()
        imageSnapshots[id] = request
        defer { imageSnapshots.removeValue(forKey: id) }
        return try await request.capture(webView)
    }
    override func pageHTML() async throws -> String {
        let script = "(() => { const html = document.documentElement ? new XMLSerializer().serializeToString(document.documentElement) : ''; if (html.length > 1048576) throw new Error('Page snapshot exceeds 1 MB.'); return html; })()"
        let id = UUID(), request = WebPageSnapshotRequest()
        pageSnapshots[id] = request
        defer { pageSnapshots.removeValue(forKey: id) }
        return try await request.capture { completion in
            // The isolated client world uses native DOM primitives even if a page
            // replaces XMLSerializer in its own JavaScript world.
            webView.evaluateJavaScript(script, in: nil, in: .defaultClient, completionHandler: completion)
        }
    }
    override func find(_ text: String, backwards: Bool = false) {
        guard !text.isEmpty else { return }
        let config = WKFindConfiguration(); config.backwards = backwards; config.wraps = true
        webView.find(text, configuration: config) { _ in }
    }
}

/// WebKit cannot cancel an individual JavaScript evaluation. Release the host's
/// wait on cancellation/deadline, and let late callbacks address only this request.
@MainActor
final class WebPageSnapshotRequest {
    private let timeout: Duration
    private var continuation: CheckedContinuation<String, any Error>?
    private var watchdog: Task<Void, Never>?
    private var hasStarted = false
    private var cancelled = false
    init(timeout: Duration = .seconds(8)) { self.timeout = timeout }

    func capture(using evaluate: (@escaping @MainActor @Sendable (Result<Any, any Error>) -> Void) -> Void) async throws -> String {
        guard !hasStarted else { throw ValidationError("A page snapshot request can only be used once.") }
        hasStarted = true
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            guard !cancelled else { throw CancellationError() }
            return try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                watchdog = Task { [weak self, timeout] in
                    do { try await Task.sleep(for: timeout) } catch { return }
                    self?.finish(.failure(ValidationError("The page did not respond to Reader in time. Try reloading it.")))
                }
                evaluate { [weak self] result in self?.finish(result) }
            }
        } onCancel: { Task { @MainActor [weak self] in self?.cancel() } }
    }
    func cancel() { cancelled = true; finish(.failure(CancellationError())) }
    private func finish(_ result: Result<Any, any Error>) {
        guard let continuation else { return }
        self.continuation = nil; watchdog?.cancel(); watchdog = nil
        switch result {
        case .failure(let error): continuation.resume(throwing: error)
        case .success(let value):
            guard let html = value as? String, html.utf8.count <= ReaderRequest.maximumHTMLBytes else {
                continuation.resume(throwing: ValidationError("The page snapshot exceeds 1 MB.")); return
            }
            continuation.resume(returning: html)
        }
    }
}
struct WebViewHost: NSViewRepresentable {
    let tab: BrowserEngineTab
    func makeNSView(context: Context) -> NSView { tab.nativeView }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

@MainActor
private final class WebImageSnapshotRequest {
    private var continuation: CheckedContinuation<Data, any Error>?
    private var watchdog: Task<Void, Never>?
    private var cancelled = false
    func capture(_ view: WKWebView) async throws -> Data {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            guard !cancelled else { throw CancellationError() }
            return try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                watchdog = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(8)) } catch { return }
                    self?.finish(nil, ValidationError("The page could not be captured in time."))
                }
                view.takeSnapshot(with: nil) { [weak self] image, error in
                    Task { @MainActor in self?.finish(image, error) }
                }
            }
        } onCancel: { Task { @MainActor [weak self] in self?.cancel() } }
    }
    func cancel() { cancelled = true; finish(nil, CancellationError()) }
    private func finish(_ image: NSImage?, _ error: (any Error)?) {
        guard let continuation else { return }
        self.continuation = nil; watchdog?.cancel(); watchdog = nil
        if let error { continuation.resume(throwing: error); return }
        guard let image, let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]), png.count <= 32 * 1024 * 1024 else {
            continuation.resume(throwing: ValidationError("The page could not be captured within the 32 MB limit.")); return
        }
        continuation.resume(returning: png)
    }
}
