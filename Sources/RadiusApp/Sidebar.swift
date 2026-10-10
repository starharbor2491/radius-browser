// SPDX-License-Identifier: MPL-2.0
import AppKit
import SwiftUI
import RadiusCore

struct SidebarView: View {
    @ObservedObject var model: BrowserModel
    let panel: BrowserPanel
    @State private var search = ""
    var body: some View {
        VStack(spacing: 0) {
            HStack { Label(panel.label, systemImage: panel.icon).font(.headline); Spacer(); IconButton(title: "Close sidebar", icon: "xmark") { model.panel = nil } }.padding(12)
            Divider()
            switch panel {
            case .bookmarks: bookmarks
            case .history: history
            case .downloads: DownloadsPanel(center: model.downloads)
            case .notes: NotesPanel(profileID: model.session.profileID, isPrivate: model.isPrivate)
            case .resources: ResourcePanel()
            }
        }
    }
    private var bookmarks: some View {
        VStack(spacing: 10) {
            TextField("Search bookmarks", text: $search).textFieldStyle(.roundedBorder).padding(.horizontal, 12).padding(.top, 10)
            if model.bookmarks.isEmpty { EmptyPanel(title: "Keep a good find", icon: "bookmark", detail: "Use the star beside an address to save a bookmark.") }
            else {
                List {
                    ForEach(model.bookmarks.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) || $0.url.absoluteString.localizedCaseInsensitiveContains(search) }) { bookmark in
                        Button { model.navigate(bookmark.url.absoluteString) } label: {
                            VStack(alignment: .leading, spacing: 4) { Text(bookmark.title).lineLimit(1); Text(bookmark.url.host ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                                .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.plain).contextMenu {
                            Button("Open in new tab") { model.newTab(url: bookmark.url) }
                            Button("Delete bookmark", role: .destructive) { model.app.library.bookmarks.removeAll { $0.id == bookmark.id } }
                        }
                    }
                }.listStyle(.sidebar)
            }
            HStack { Button("Import…") { model.app.importBookmarks(profileID: model.session.profileID) }; Button("Export…") { model.app.exportBookmarks(profileID: model.session.profileID) } }.padding(12)
        }
    }
    private var history: some View {
        let entries = model.app.library.history.filter { $0.profileID == model.session.profileID }.reversed().filter {
            search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) || $0.url.absoluteString.localizedCaseInsensitiveContains(search)
        }
        return VStack(spacing: 10) {
            TextField("Search history", text: $search).textFieldStyle(.roundedBorder).padding(.horizontal, 12).padding(.top, 10)
            if entries.isEmpty { EmptyPanel(title: "Nothing here yet", icon: "clock", detail: "Pages you visit in this profile appear here.") }
            else {
                List(Array(entries)) { entry in
                    Button { model.navigate(entry.url.absoluteString) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.title).lineLimit(1)
                            Text(entry.visitedAt, format: .dateTime.month().day().hour().minute()).font(.caption).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.buttonStyle(.plain).contextMenu {
                        Button("Open in new tab") { model.newTab(url: entry.url) }
                        Button("Remove from history", role: .destructive) { model.app.library.history.removeAll { $0.id == entry.id } }
                    }
                }.listStyle(.sidebar)
            }
        }
    }
}
struct DownloadsPanel: View {
    @ObservedObject var center: DownloadCenter
    var body: some View {
        if center.items.isEmpty { EmptyPanel(title: "No downloads", icon: "arrow.down.circle", detail: "Downloads from this window appear here. You choose where every file is saved.") }
        else { ScrollView { LazyVStack(alignment: .leading, spacing: 16) { ForEach(center.items) { DownloadRow(item: $0, center: center) } }.padding(14) } }
    }
}
struct DownloadRow: View {
    @ObservedObject var item: DownloadItem
    let center: DownloadCenter
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(item.name).font(.callout.weight(.medium)).lineLimit(2)
            Text(item.status).font(.caption).foregroundStyle(.secondary).lineLimit(3)
            if item.active {
                ProgressView(value: item.fraction)
                Button("Cancel") { center.cancel(item) }
            } else if let url = item.staging ?? (item.status == "Finished" ? item.destination : nil) {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
            Divider()
        }
    }
}
struct NotesPanel: View {
    @EnvironmentObject private var app: AppState
    let profileID: UUID
    let isPrivate: Bool
    @State private var selection: UUID?
    var body: some View {
        if isPrivate { EmptyPanel(title: "Notes stay out of private windows", icon: "hand.raised", detail: "Use a regular window to create and edit saved notes.") }
        else {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Menu {
                        ForEach(app.library.notes.filter { $0.profileID == profileID }) { note in Button(displayTitle(note)) { selection = note.id } }
                    } label: { Text(selectedNote.map(displayTitle) ?? "Select a note").lineLimit(1) }
                    Spacer()
                    IconButton(title: "New note", icon: "plus") {
                        app.perform { selection = try app.createModuleNote(profileID: profileID) }
                    }
                }
                if let id = selection, selectedNote != nil {
                    TextField("Title", text: noteBinding(id, field: \.title)).textFieldStyle(.roundedBorder)
                    TextEditor(text: noteBinding(id, field: \.text)).font(.body)
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(.primary.opacity(0.12)))
                    HStack {
                        Button("Export…") { if let note = selectedNote { app.saveFile(Data(note.text.utf8), name: "\(displayTitle(note)).txt", type: .plainText) } }
                        Spacer()
                        Button("Delete", role: .destructive) {
                            let alert = NSAlert(); alert.messageText = "Delete this note?"; alert.informativeText = "This cannot be undone."
                            alert.addButton(withTitle: "Delete"); alert.addButton(withTitle: "Cancel")
                            if alert.runModal() == .alertFirstButtonReturn { app.perform { try app.deleteModuleNote(id: id, profileID: profileID); selection = nil } }
                        }
                    }
                } else { EmptyPanel(title: "A place to think", icon: "note.text", detail: "Add a note with +. Your notes stay on this Mac, in this profile.") }
            }.padding(12).onChange(of: profileID) { _, _ in selection = nil }
        }
    }
    private var selectedNote: Note? { app.library.notes.first { $0.id == selection && $0.profileID == profileID } }
    private func displayTitle(_ note: Note) -> String {
        let title = note.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? "Untitled note" : title
    }
    private func noteBinding(_ id: UUID, field: WritableKeyPath<Note, String>) -> Binding<String> {
        Binding(get: { app.library.notes.first { $0.id == id }?[keyPath: field] ?? "" }, set: { value in
            app.perform { try app.updateModuleNote(id: id, profileID: profileID, field: field == \.title ? "title" : "text", value: value) }
        })
    }
}
