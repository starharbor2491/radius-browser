// SPDX-License-Identifier: MPL-2.0
import AppKit
import SwiftUI
@preconcurrency import WebKit
import RadiusCore

/// Engine objects stay inside this adapter. The native shell and recovery do not require a web view.
@MainActor
final class WebTab: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    let webView: WKWebView
    @Published var loading = false
    @Published var progress = 0.0
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var errorMessage: String?
    @Published var zoom = 1.0
    var onChange: ((Bool) -> Void)?
    var onCreateWindow: ((WKWebViewConfiguration, URL?) -> WKWebView?)?
    var onClose: (() -> Void)?
    var allowPopups: (() -> Bool)? { didSet { updatePopupPolicy() } }
    private let downloads: DownloadCenter
    private var observations: [NSKeyValueObservation] = []
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
    func load(_ url: URL) {
        guard AddressResolver.isWebURL(url) else { errorMessage = "This address is not supported."; return }
        errorMessage = nil; updatePopupPolicy(); webView.load(URLRequest(url: url))
    }
    func updatePopupPolicy() { webView.configuration.preferences.javaScriptCanOpenWindowsAutomatically = allowPopups?() == true }
    func reload() { errorMessage = nil; webView.reload() }
    func setZoom(_ value: Double) { zoom = min(3, max(0.5, value)); webView.pageZoom = zoom }
    func dispose() {
        webView.stopLoading(); webView.navigationDelegate = nil; webView.uiDelegate = nil
        observations.removeAll(); onChange = nil; onCreateWindow = nil; onClose = nil; allowPopups = nil
    }
    private func refresh(_ finished: Bool) {
        loading = webView.isLoading; canGoBack = webView.canGoBack; canGoForward = webView.canGoForward
        onChange?(finished)
    }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { errorMessage = nil; loading = true; refresh(false) }
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
        loading = false; errorMessage = "The website's process stopped. Reload the page to continue."; refresh(false)
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        if url.absoluteString == "about:blank" { decisionHandler(.allow); return }
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
        guard url == nil || url?.absoluteString == "about:blank" || url.map(AddressResolver.isWebURL) == true else { return nil }
        // WebKit's javaScriptCanOpenWindowsAutomatically setting blocks unsolicited popups.
        // Return a view using the supplied configuration; WebKit preserves the request and opener.
        return onCreateWindow?(configuration, url)
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
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable (Bool) -> Void) {
        let alert = siteAlert(frame, message); alert.addButton(withTitle: "OK"); alert.addButton(withTitle: "Cancel")
        completionHandler(alert.runModal() == .alertFirstButtonReturn)
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
    func saveScreenshot(app: AppState) {
        webView.takeSnapshot(with: nil) { [weak app] image, error in
            Task { @MainActor in
                guard let app else { return }
                if let error { app.notice = error.localizedDescription; return }
                guard let image, let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
                      let png = bitmap.representation(using: .png, properties: [:]) else { app.notice = "The page could not be captured."; return }
                app.saveFile(png, name: "Page Capture.png", type: .png)
            }
        }
    }
    func readerText() async throws -> String {
        let script = "(() => { const e = document.querySelector('article') || document.querySelector('main') || document.body; return e ? e.innerText.slice(0, 200000) : ''; })()"
        let result = try await webView.evaluateJavaScript(script)
        guard let text = result as? String, !text.isEmpty else { throw ValidationError("This page has no readable text.") }
        return text
    }
    func find(_ text: String, backwards: Bool = false) {
        guard !text.isEmpty else { return }
        let config = WKFindConfiguration(); config.backwards = backwards; config.wraps = true
        webView.find(text, configuration: config) { _ in }
    }
}
struct WebViewHost: NSViewRepresentable {
    let tab: WebTab
    func makeNSView(context: Context) -> WKWebView { tab.webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
