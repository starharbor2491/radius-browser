// SPDX-License-Identifier: MPL-2.0
import AppKit
import RadiusCore
import RadiusEngineABI
import UniformTypeIdentifiers

@MainActor
final class ChromiumTab: BrowserEngineTab {
    private let runtime: ChromiumRuntime
    private var page: UnsafeMutableRawPointer?
    private let hostView: NSView
    private var pageURL: URL?
    private var pageTitle: String?
    private var nextRequest = 1
    private var pending: [Int: CheckedContinuation<Data, any Error>] = [:]
    override var nativeView: NSView { hostView }
    override var url: URL? { pageURL }
    override var title: String? { pageTitle }
    override var engineID: BrowserEngineID { .chromium }

    init(runtime: ChromiumRuntime, page: UnsafeMutableRawPointer) {
        self.runtime = runtime; self.page = page
        hostView = Unmanaged<NSView>.fromOpaque(runtime.api!.native_view(page)!).takeUnretainedValue()
        super.init()
        runtime.api!.set_callbacks(page, Unmanaged.passUnretained(self).toOpaque(), { context, event, json in
            guard let context, let json else { return }
            MainActor.assumeIsolated {
                Unmanaged<ChromiumTab>.fromOpaque(context).takeUnretainedValue().receive(event, json: String(cString: json))
            }
        }, { context, child, url in
            guard let context, let child else { return 0 }
            return MainActor.assumeIsolated {
                let parent = Unmanaged<ChromiumTab>.fromOpaque(context).takeUnretainedValue()
                let tab = ChromiumTab(runtime: parent.runtime, page: child)
                let target = url.flatMap { URL(string: String(cString: $0)) }
                let accepted = parent.onCreateWindow?(tab, target) == true
                if !accepted { tab.dispose() }
                return accepted ? 1 : 0
            }
        })
    }
    private func command(_ command: Int, text: String = "", value: Double = 0) {
        guard let page, let api = runtime.api else { return }
        text.withCString { api.command(page, Int32(command), $0, value) }
    }
    override func load(_ url: URL) {
        guard AddressResolver.isWebURL(url) else { errorMessage = "Only HTTP and HTTPS addresses are supported."; return }
        errorMessage = nil; pageURL = url; loading = true
        command(Int(RADIUS_CEF_LOAD), text: url.absoluteString)
    }
    override func reload() { errorMessage = nil; command(Int(RADIUS_CEF_RELOAD)) }
    override func stop() { command(Int(RADIUS_CEF_STOP)) }
    override func goBack() { command(Int(RADIUS_CEF_BACK)) }
    override func goForward() { command(Int(RADIUS_CEF_FORWARD)) }
    override func setZoom(_ value: Double) { super.setZoom(value); command(Int(RADIUS_CEF_ZOOM), value: zoom) }
    override func updatePopupPolicy() { command(Int(RADIUS_CEF_POPUPS), value: allowPopups?() == true ? 1 : 0) }
    override func find(_ text: String, backwards: Bool = false) { command(Int(RADIUS_CEF_FIND), text: text, value: backwards ? 1 : 0) }
    override func readerText() async throws -> String {
        let data = try await request("Runtime.evaluate", parameters: ["expression": "document.body ? document.body.innerText.slice(0, 200000) : ''", "returnByValue": true])
        guard let response = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = response["result"] as? [String: Any], let text = result["value"] as? String else {
            throw ValidationError("Chromium could not extract page text.")
        }
        return text
    }
    override func saveScreenshot(app: AppState) {
        Task {
            do {
                let data = try await request("Page.captureScreenshot", parameters: ["format": "png"])
                guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let encoded = result["data"] as? String, let image = Data(base64Encoded: encoded) else {
                    throw ValidationError("Chromium returned an invalid screenshot.")
                }
                app.saveFile(image, name: "Page.png", type: .png)
            } catch { app.notice = error.localizedDescription }
        }
    }
    /// Internal DevTools transport, never a listening debugging port.
    func request(_ method: String, parameters: [String: Any]) async throws -> Data {
        guard let page, let api = runtime.api else { throw ValidationError("This Chromium page is closed.") }
        let json = String(decoding: try JSONSerialization.data(withJSONObject: parameters), as: UTF8.self)
        let id = nextRequest; nextRequest += 1
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            method.withCString { method in json.withCString { api.devtools(page, Int32(id), method, $0) } }
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(15))
                self?.pending.removeValue(forKey: id)?.resume(throwing: ValidationError("Chromium did not respond before the request timed out."))
            }
        }
    }
    private func receive(_ event: Int32, json: String) {
        guard let data = json.data(using: .utf8), let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        switch event {
        case Int32(RADIUS_CEF_STATE), Int32(RADIUS_CEF_FINISHED):
            if let address = value["url"] as? String { pageURL = URL(string: address) }
            if let title = value["title"] as? String { pageTitle = title }
            if let value = value["loading"] as? Bool { loading = value; progress = value ? 0.4 : 1 }
            if let value = value["canGoBack"] as? Bool { canGoBack = value }
            if let value = value["canGoForward"] as? Bool { canGoForward = value }
            onChange?(event == Int32(RADIUS_CEF_FINISHED))
        case Int32(RADIUS_CEF_ERROR), Int32(RADIUS_CEF_NOTICE):
            errorMessage = value["message"] as? String
            if event == Int32(RADIUS_CEF_ERROR) { loading = false; progress = 0 }
        case Int32(RADIUS_CEF_CLOSED):
            page = nil; cancelRequests(); onClose?()
        case Int32(RADIUS_CEF_RESULT):
            guard let id = value["id"] as? Int, let continuation = pending.removeValue(forKey: id) else { return }
            if value["success"] as? Bool == true, let result = value["result"], let data = try? JSONSerialization.data(withJSONObject: result) {
                continuation.resume(returning: data)
            } else { continuation.resume(throwing: ValidationError("The Chromium page operation failed.")) }
        default: break
        }
    }
    private func cancelRequests() {
        let requests = pending.values; pending.removeAll()
        for request in requests { request.resume(throwing: ValidationError("The Chromium page was closed.")) }
    }
    override func dispose() {
        if let page { runtime.api?.close_page(page); self.page = nil }
        cancelRequests(); super.dispose()
    }
}
