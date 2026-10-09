// SPDX-License-Identifier: MPL-2.0
import AppKit
import SwiftUI

struct RecoveryView: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SheetHeader(title: "Recovery", subtitle: "A reliable way back, even when a website or module fails.")
            recoveryAction("Restore the default interface", detail: "Reset appearance and layout. Bookmarks, notes, profiles, and tabs stay in place.", button: "Restore layout") {
                if confirm("Restore the default layout and theme?", "Your saved setups remain available in Customize.") { app.applyConfiguration(.init()) }
            }
            recoveryAction("Stop all optional modules", detail: "Move installed packages into a local backup and stop their features. Saved data is kept.", button: "Reset modules") {
                if confirm("Reset installed modules?", "All optional features will stop. Reinstall them in Modules when you're ready. A local backup is kept.") { app.resetModules() }
            }
            recoveryAction("Save current browser data", detail: "Retry any failed database writes.", button: "Retry save") {
                Task { if await app.flush() { app.notice = "Browser data saved." } }
            }
            recoveryAction("Inspect local backups", detail: "Open Radius's data folder in Finder. It can contain private browsing information from regular profiles.", button: "Show data folder") { NSWorkspace.shared.open(app.dataDirectory) }
            if let notice = app.notice { Text(notice).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
            Spacer(); HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }.padding(28).frame(width: 660, height: 570)
    }
    private func recoveryAction(_ title: String, detail: String, button: String, action: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 6) { Text(title).font(.headline); Text(detail).font(.callout).foregroundStyle(.secondary) }
            Spacer(); Button(button, action: action)
        }.padding(14).background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
    }
}
struct StartupRecovery: View {
    @EnvironmentObject private var app: AppState
    let error: String
    @State private var resetting = false
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Image(systemName: "lifepreserver").font(.system(size: 36)).foregroundStyle(Color.accentColor)
            Text("Let's get Radius open.").font(.largeTitle.weight(.semibold))
            Text("Your saved data could not be opened. It has not been deleted.").foregroundStyle(.secondary)
            Text(error).font(.callout).textSelection(.enabled).padding(16).background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
            HStack {
                Button("Try again") { Task { await app.load() } }
                Button("Show data folder") { NSWorkspace.shared.open(app.dataDirectory) }
                Button(resetting ? "Recovering…" : "Start with a fresh library…") {
                    if confirm("Start with a fresh library?", "Radius will move the old database into a Recovery folder without deleting it. The new library will not contain your saved tabs, bookmarks, notes, or profile definitions. Website storage is left untouched.") {
                        resetting = true; Task { await app.resetLibrary(); resetting = false }
                    }
                }.disabled(resetting)
            }
        }.padding(48).frame(maxWidth: 740).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
@MainActor
func confirm(_ title: String, _ detail: String) -> Bool {
    let alert = NSAlert(); alert.messageText = title; alert.informativeText = detail
    alert.addButton(withTitle: "Continue"); alert.addButton(withTitle: "Cancel")
    return alert.runModal() == .alertFirstButtonReturn
}
