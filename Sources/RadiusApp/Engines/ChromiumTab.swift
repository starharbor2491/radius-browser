// SPDX-License-Identifier: MPL-2.0
import AppKit
import RadiusCore
import RadiusEngineABI
import UniformTypeIdentifiers

@MainActor
final class ChromiumTab: BrowserEngineTab {
    private let runtime: ChromiumRuntime
    private let downloads: DownloadCenter
    let profileID: UUID
    let privateSessionID: UUID?
    let isAuxiliary: Bool
    var downloadCenter: DownloadCenter { downloads }
    func cancelDownloads() async throws { try await downloads.cancelChromiumAndWait(ids: downloadIDs) }
    private let downloadPrefix = UUID().uuidString
    private var downloadIDs = Set<String>()
    private var disposing = false
    private var closeTask: Task<Void, Never>?
    @Published private(set) var chromeStyle = false
    override var hasNativeNavigationChrome: Bool { chromeStyle }
    override func focusAddressBar() -> Bool {
        guard chromeStyle else { return false }
        command(Int(RADIUS_CEF_FOCUS_LOCATION)); return true
    }
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
    var chromeWindow: NSWindow? { hostView.value(forKey: "browserWindow") as? NSWindow }
    override var url: URL? { pageURL }
    override var title: String? { pageTitle }
    override var engineID: BrowserEngineID { .chromium }

    init(runtime: ChromiumRuntime, page: UnsafeMutableRawPointer, downloads: DownloadCenter, profileID: UUID, privateSessionID: UUID?) {
        self.runtime = runtime; self.page = page; self.downloads = downloads
        self.profileID = profileID; self.privateSessionID = privateSessionID
        hostView = Unmanaged<NSView>.fromOpaque(runtime.api!.native_view(page)!).takeUnretainedValue()
        isAuxiliary = hostView.value(forKey: "auxiliary") as? Bool == true
        super.init()
        chromeStyle = hostView.value(forKey: "chromeStyle") as? Bool == true
        runtime.register(self)
        runtime.api!.set_callbacks(page, Unmanaged.passUnretained(self).toOpaque(), { context, event, json in
            guard let context, let json else { return }
            MainActor.assumeIsolated {
                Unmanaged<ChromiumTab>.fromOpaque(context).takeUnretainedValue().receive(event, json: String(cString: json))
            }
        }, { context, child, url in
            guard let context, let child else { return 0 }
            return MainActor.assumeIsolated {
                let parent = Unmanaged<ChromiumTab>.fromOpaque(context).takeUnretainedValue()
                let tab = ChromiumTab(runtime: parent.runtime, page: child, downloads: parent.downloads, profileID: parent.profileID, privateSessionID: parent.privateSessionID)
                if tab.isAuxiliary {
                    tab.onNotice = parent.onNotice
                    tab.onBrowserCommand = { [weak tab] command in
                        switch command {
                        case "quit": NSApp.terminate(nil)
                        case "closeTab", "closeWindow": tab?.dispose()
                        case "newWindow": ChromiumTab.performApplicationMenuItem("New window")
                        case "privateWindow": ChromiumTab.performApplicationMenuItem("New private window")
                        case "downloads": tab?.downloads.showWindow()
                        default: break
                        }
                    }
                    tab.allowPopups = parent.allowPopups
                    tab.updatePopupPolicy()
                    return 1
                }
                let target = url.flatMap { URL(string: String(cString: $0)) }
                let accepted = parent.onCreateWindow?(tab, target) == true
                if !accepted { tab.dispose() }
                return accepted ? 1 : 0
            }
        })
    }
    private static func performApplicationMenuItem(_ title: String) {
        func perform(in menu: NSMenu) -> Bool {
            for (index, item) in menu.items.enumerated() {
                if item.title == title, item.isEnabled { menu.performActionForItem(at: index); return true }
                if let submenu = item.submenu, perform(in: submenu) { return true }
            }
            return false
        }
        // Dispatch the app's existing File command, which remains available
        // after the originating SwiftUI browser window has closed.
        if let menu = NSApp.mainMenu { _ = perform(in: menu) }
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
    func showExtensions() { command(Int(RADIUS_CEF_EXTENSIONS)) }
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
    override func capturePNG() async throws -> Data {
        let data = try await request("Page.captureScreenshot", parameters: ["format": "png", "captureBeyondViewport": false])
        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let encoded = result["data"] as? String, encoded.utf8.count <= 45 * 1024 * 1024,
              let image = Data(base64Encoded: encoded), image.count <= 32 * 1024 * 1024,
              image.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) else {
            throw ValidationError("Chromium returned an invalid or oversized page capture.")
        }
        return image
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
            if let chrome = value["chromeStyle"] as? Bool { chromeStyle = chrome }
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
            downloads.chromiumOwnerClosed(ids: downloadIDs)
            downloadIDs.removeAll()
            page = nil; cancelRequests(); runtime.finishedClosing(self); onClose?()
        case Int32(RADIUS_CEF_ACTIVATE):
            onActivate?()
        case Int32(RADIUS_CEF_BROWSER_COMMAND):
            if let command = value["message"] as? String { onBrowserCommand?(command) }
        case Int32(RADIUS_CEF_DOWNLOAD_BEGIN):
            guard let id = value["id"] as? Int else { return }
            guard !disposing else {
                command(Int(RADIUS_CEF_DOWNLOAD_CANCEL), value: Double(id))
                command(Int(RADIUS_CEF_DOWNLOAD_PATH), value: Double(id))
                return
            }
            let key = downloadPrefix + ":" + String(id)
            downloadIDs.insert(key)
            let source = (value["url"] as? String).flatMap(URL.init(string:))
            downloads.beginChromium(id: key, suggestedName: value["name"] as? String ?? "Download", sourceURL: source, cancel: { [weak self] in
                self?.command(Int(RADIUS_CEF_DOWNLOAD_CANCEL), value: Double(id))
            }, completion: { [weak self] destination in
                self?.command(Int(RADIUS_CEF_DOWNLOAD_PATH), text: destination?.path ?? "", value: Double(id))
            })
        case Int32(RADIUS_CEF_DOWNLOAD_UPDATE):
            guard let id = value["id"] as? Int else { return }
            let key = downloadPrefix + ":" + String(id)
            let complete = value["complete"] as? Bool == true
            let cancelled = value["cancelled"] as? Bool == true
            let interrupted = value["interrupted"] as? Bool == true
            downloads.updateChromium(id: key, fraction: value["fraction"] as? Double ?? 0,
                                     complete: complete, cancelled: cancelled, interrupted: interrupted)
            if complete || cancelled || interrupted {
                downloadIDs.remove(key)
                if disposing && downloadIDs.isEmpty && closeTask == nil { closePage() }
            }
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
        guard page != nil, closeTask == nil else { return }
        let notice = onNotice
        if !disposing {
            disposing = true
            cancelRequests(); super.dispose()
        }
        // A previous cancellation attempt can time out while Chromium still
        // owns a file. Subsequent quit/close attempts must send cancellation
        // again, even after the outer tab and its model have disappeared.
        // CEF must retain the browser and callback receiver until cancellation
        // closes each download writer. Removing the native tab can happen now.
        if downloadIDs.isEmpty { closePage() }
        else {
            runtime.retainWhileClosing(self)
            closeTask = Task { [self] in
                defer { closeTask = nil }
                do {
                    try await downloads.cancelChromiumAndWait(ids: downloadIDs)
                    closePage()
                } catch {
                    // Keep the callback target alive. A late terminal update
                    // releases this page safely; quit remains available to retry.
                    runtime.reportCloseFailure(error.localizedDescription)
                    notice?(error.localizedDescription)
                }
            }
        }
    }
    private func closePage() {
        if let page { runtime.api?.close_page(page); self.page = nil }
        runtime.finishedClosing(self)
    }
}
