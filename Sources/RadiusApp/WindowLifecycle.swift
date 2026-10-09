// SPDX-License-Identifier: MPL-2.0
import AppKit

/// Keeps SwiftUI's window delegate while intercepting a destructive window-close decision.
@MainActor
final class WindowDelegateProxy: NSObject, NSWindowDelegate {
    weak var original: (any NSWindowDelegate)?
    let model: BrowserModel
    init(original: (any NSWindowDelegate)?, model: BrowserModel) { self.original = original; self.model = model }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if model.downloads.hasActive && !model.app.terminating {
            let alert = NSAlert(); alert.messageText = "Cancel downloads and close this window?"
            alert.informativeText = "This window has active downloads. Their temporary files will be removed."
            alert.addButton(withTitle: "Keep window open"); alert.addButton(withTitle: "Cancel downloads and close")
            guard alert.runModal() == .alertSecondButtonReturn else { return false }
        }
        return original?.windowShouldClose?(sender) ?? true
    }
    override func responds(to selector: Selector!) -> Bool { super.responds(to: selector) || original?.responds(to: selector) == true }
    override func forwardingTarget(for selector: Selector!) -> Any? { original?.responds(to: selector) == true ? original : super.forwardingTarget(for: selector) }
}
