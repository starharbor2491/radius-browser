// SPDX-License-Identifier: MPL-2.0
import AppKit
import RadiusCore

/// Preserve tab placement and its engine choice when a removable runtime is absent or broken.
@MainActor
final class UnavailableEngineTab: BrowserEngineTab {
    private let engine: BrowserEngineID
    private let reason: String
    private let view = NSView()
    private var address: URL?
    override var engineID: BrowserEngineID { engine }
    override var nativeView: NSView { view }
    override var url: URL? { address }
    init(engine: BrowserEngineID, reason: String) {
        self.engine = engine; self.reason = reason
        super.init(); errorMessage = reason
    }
    override func load(_ url: URL) { address = url; errorMessage = reason }
    override func reload() { errorMessage = reason }
    override func stop() {}
    override func goBack() {}
    override func goForward() {}
    override func find(_ text: String, backwards: Bool = false) {}
}
