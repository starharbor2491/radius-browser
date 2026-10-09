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
    private struct PendingRequest {
        let continuation: CheckedContinuation<Data, any Error>
        let timeout: Task<Void, Never>
    }
    private var pending: [Int: PendingRequest] = [:]
    private var readerContexts: [Int: String] = [:]
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
    override func goBack() { errorMessage = nil; command(Int(RADIUS_CEF_BACK)) }
    override func goForward() { errorMessage = nil; command(Int(RADIUS_CEF_FORWARD)) }
    override func setZoom(_ value: Double) { super.setZoom(value); command(Int(RADIUS_CEF_ZOOM), value: zoom) }
    override func updatePopupPolicy() { command(Int(RADIUS_CEF_POPUPS), value: allowPopups?() == true ? 1 : 0) }
    override func focus() { command(Int(RADIUS_CEF_FOCUS)) }
    override func find(_ text: String, backwards: Bool = false) { command(Int(RADIUS_CEF_FIND), text: text, value: backwards ? 1 : 0) }
    override func pageHTML() async throws -> String {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(8))
        func remaining() throws -> Duration {
            let duration = clock.now.duration(to: deadline)
            guard duration > .zero else { throw ValidationError("Chromium did not capture the page before the snapshot timed out.") }
            return duration
        }
        _ = try await request("Runtime.enable", parameters: [:], timeout: remaining())
        let treeData = try await request("Page.getFrameTree", parameters: [:], timeout: remaining())
        guard let tree = try JSONSerialization.jsonObject(with: treeData) as? [String: Any],
              let frameTree = tree["frameTree"] as? [String: Any],
              let frame = frameTree["frame"] as? [String: Any], let frameID = frame["id"] as? String else {
            throw ValidationError("Chromium could not find the page to capture.")
        }
        // Page JavaScript cannot replace this world's native XMLSerializer or
        // document accessors. No cross-origin access is granted to the world.
        let worldData = try await request("Page.createIsolatedWorld", parameters: ["frameId": frameID, "worldName": "org.radius.reader"], timeout: remaining())
        guard let world = try JSONSerialization.jsonObject(with: worldData) as? [String: Any],
              let contextID = world["executionContextId"] as? Int,
              let uniqueContextID = readerContexts[contextID] else {
            throw ValidationError("Chromium could not isolate the page snapshot.")
        }
        let expression = "(() => { const html = document.documentElement ? new XMLSerializer().serializeToString(document.documentElement) : ''; if (html.length > 1048576) throw new Error('Page snapshot exceeds 1 MB.'); return html; })()"
        let budget = try remaining()
        let components = budget.components
        let milliseconds = Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15
        // Numeric context IDs can be reused after a process-changing navigation.
        // A vanished unique context fails safely instead of evaluating page code.
        let data = try await request("Runtime.evaluate", parameters: ["expression": expression, "returnByValue": true, "uniqueContextId": uniqueContextID, "timeout": milliseconds], timeout: budget)
        guard let response = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = response["result"] as? [String: Any], let html = result["value"] as? String,
              html.utf8.count <= ReaderRequest.maximumHTMLBytes else {
            throw ValidationError("Chromium could not capture this page within the 1 MB snapshot limit.")
        }
        return html
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
    func request(_ method: String, parameters: [String: Any], timeout: Duration = .seconds(15)) async throws -> Data {
        try Task.checkCancellation()
        guard let page, let api = runtime.api else { throw ValidationError("This Chromium page is closed.") }
        let json = String(decoding: try JSONSerialization.data(withJSONObject: parameters), as: UTF8.self)
        let id = nextRequest; nextRequest += 1
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                let timer = Task { [weak self] in
                    do { try await Task.sleep(for: timeout) } catch { return }
                    self?.completeRequest(id, result: .failure(ValidationError("Chromium did not respond before the request timed out.")))
                }
                pending[id] = PendingRequest(continuation: continuation, timeout: timer)
                method.withCString { method in json.withCString { api.devtools(page, Int32(id), method, $0) } }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.completeRequest(id, result: .failure(CancellationError())) }
        }
    }
    private func completeRequest(_ id: Int, result: Result<Data, any Error>) {
        guard let request = pending.removeValue(forKey: id) else { return }
        request.timeout.cancel()
        request.continuation.resume(with: result)
    }
    private func receive(_ event: Int32, json: String) {
        guard let data = json.data(using: .utf8), let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        switch event {
        case Int32(RADIUS_CEF_STATE), Int32(RADIUS_CEF_FINISHED):
            if value["navigationStart"] as? Bool == true { didStartNavigation(); return }
            if let address = value["url"] as? String { pageURL = URL(string: address) }
            if let title = value["title"] as? String { pageTitle = title.isEmpty ? nil : title }
            if let value = value["loading"] as? Bool {
                loading = value; progress = value ? 0.4 : 1
                if value { errorMessage = nil }
            }
            if let value = value["canGoBack"] as? Bool { canGoBack = value }
            if let value = value["canGoForward"] as? Bool { canGoForward = value }
            onChange?(event == Int32(RADIUS_CEF_FINISHED))
        case Int32(RADIUS_CEF_ERROR):
            errorMessage = value["message"] as? String
            loading = false; progress = 0
        case Int32(RADIUS_CEF_NOTICE):
            if let message = value["message"] as? String { onNotice?(message) }
        case Int32(RADIUS_CEF_CLOSED):
            page = nil; cancelRequests(); onClose?()
        case Int32(RADIUS_CEF_READER_CONTEXT):
            if value["clear"] as? Bool == true { readerContexts.removeAll() }
            else if value["destroyed"] as? Bool == true {
                if let uniqueID = value["uniqueID"] as? String, !uniqueID.isEmpty {
                    readerContexts = readerContexts.filter { $0.value != uniqueID }
                } else if let id = value["id"] as? Int { readerContexts.removeValue(forKey: id) }
            } else if let id = value["id"] as? Int, id > 0,
                      let uniqueID = value["uniqueID"] as? String, !uniqueID.isEmpty, uniqueID.utf8.count <= 256 {
                if readerContexts.count >= 16 { readerContexts.removeAll() }
                readerContexts[id] = uniqueID
            }
        case Int32(RADIUS_CEF_RESULT):
            guard let id = value["id"] as? Int else { return }
            if value["success"] as? Bool == true, let result = value["result"], let data = try? JSONSerialization.data(withJSONObject: result) {
                completeRequest(id, result: .success(data))
            } else { completeRequest(id, result: .failure(ValidationError("The Chromium page operation failed."))) }
        default: break
        }
    }
    private func cancelRequests() {
        readerContexts.removeAll()
        let requests = pending.values; pending.removeAll()
        for request in requests {
            request.timeout.cancel()
            request.continuation.resume(throwing: ValidationError("The Chromium page was closed."))
        }
    }
    override func dispose() {
        if let page { runtime.api?.close_page(page); self.page = nil }
        cancelRequests(); super.dispose()
    }
}
