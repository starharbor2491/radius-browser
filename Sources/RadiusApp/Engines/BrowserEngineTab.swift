// SPDX-License-Identifier: MPL-2.0
import AppKit
import SwiftUI
import RadiusCore

/// Native browser controls observe this state; engines own their website context.
@MainActor
class BrowserEngineTab: NSObject, ObservableObject {
    @Published var loading = false
    @Published var progress = 0.0
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var errorMessage: String?
    @Published var zoom = 1.0
    @Published private(set) var navigationRevision = UUID()
    var onChange: ((Bool) -> Void)?
    var onCreateWindow: ((BrowserEngineTab, URL?) -> Bool)?
    var onClose: (() -> Void)?
    var onNotice: ((String) -> Void)?
    var allowPopups: (() -> Bool)? { didSet { updatePopupPolicy() } }
    var nativeView: NSView { preconditionFailure("An engine must provide its native view") }
    var url: URL? { nil }
    var title: String? { nil }
    var engineID: BrowserEngineID { preconditionFailure("An engine must identify itself") }
    func load(_ url: URL) { preconditionFailure("An engine must implement navigation") }
    func reload() { preconditionFailure("An engine must implement reload") }
    func stop() { preconditionFailure("An engine must implement stop") }
    func goBack() { preconditionFailure("An engine must implement back navigation") }
    func goForward() { preconditionFailure("An engine must implement forward navigation") }
    func didStartNavigation() { navigationRevision = UUID() }
    func setZoom(_ value: Double) { zoom = min(3, max(0.5, value)) }
    func updatePopupPolicy() {}
    func focus() { nativeView.window?.makeFirstResponder(nativeView) }
    func find(_ text: String, backwards: Bool = false) { preconditionFailure("An engine must implement find") }
    func pageHTML() async throws -> String { throw ValidationError("This engine cannot capture page HTML.") }
    func saveScreenshot(app: AppState) { app.notice = "This engine cannot capture the page." }
    func dispose() { onChange = nil; onCreateWindow = nil; onClose = nil; onNotice = nil; allowPopups = nil }
}
