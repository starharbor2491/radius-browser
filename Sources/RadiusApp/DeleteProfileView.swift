// SPDX-License-Identifier: MPL-2.0
import AppKit
import SwiftUI
import RadiusCore

struct DeleteProfileView: View {
    let profile: Profile
    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var replacement: UUID?
    @State private var busy = false
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Delete \(profile.name)?").font(.title2.weight(.semibold))
            Text("This permanently removes this profile's bookmarks, history, notes, cookies, and website storage. Its open windows receive a blank tab in the replacement profile. Unfinished downloads are cancelled. Unsaved page work is lost.")
            Text("Saved downloads, exported files, and recovery backups remain on disk.").font(.callout).foregroundStyle(.secondary)
            Picker("Replacement profile", selection: $replacement) {
                ForEach(app.library.profiles.filter { $0.id != profile.id }) { Text($0.name).tag(Optional($0.id)) }
            }
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                if busy { ProgressView().controlSize(.small); Text("Deleting profile…").font(.callout) }
                Spacer()
                Button("Cancel") { dismiss() }.disabled(busy).keyboardShortcut(.cancelAction)
                Button("Delete profile", role: .destructive) {
                    guard let replacement else { return }
                    busy = true; error = nil
                    Task {
                        do { try await app.deleteProfile(profile.id, replacingWith: replacement); dismiss() }
                        catch { self.error = error.localizedDescription }
                        busy = false
                    }
                }.disabled(busy || replacement == nil)
            }
        }.padding(28).frame(width: 520)
        .interactiveDismissDisabled(busy)
        .onAppear { replacement = app.library.profiles.first(where: { $0.id != profile.id })?.id }
    }
}
