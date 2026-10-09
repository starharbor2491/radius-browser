// SPDX-License-Identifier: MPL-2.0
import AppKit
import SwiftUI
import RadiusCore

struct CustomizeView: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var draft = Configuration()
    @State private var undoStack: [Configuration] = []
    @State private var selection = 0
    @State private var preview = false
    @State private var setupName = "My setup"
    @State private var initialized = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SheetHeader(title: "Customize", subtitle: "Change the look. Arrange your space. Keep your place.")
            HStack(alignment: .top, spacing: 28) {
                VStack(alignment: .leading, spacing: 16) {
                    Picker("Customize category", selection: $selection) { Text("Appearance").tag(0); Text("Layout").tag(1); Text("Saved setups").tag(2) }.pickerStyle(.segmented)
                    ScrollView { if selection == 0 { appearance } else if selection == 1 { layout } else { savedSetups } }.frame(maxHeight: .infinity)
                }.frame(width: 340)
                VStack(alignment: .leading, spacing: 16) {
                    Text("Preview").font(.headline)
                    LayoutPreview(configuration: draft).frame(height: 285)
                    Text(designDescription).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Toggle("Preview in browser windows", isOn: $preview)
                    Text("Appearance changes leave tab and panel placement as you set them. Website content is unaffected.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }.frame(maxWidth: .infinity)
            }
            Divider()
            HStack {
                Button("Undo") {
                    guard let previous = undoStack.popLast() else { return }; draft = previous
                }.disabled(undoStack.isEmpty)
                Button("Restore defaults") { change { $0 = Configuration() } }
                Spacer()
                Button("Cancel") { app.previewConfiguration = nil; dismiss() }.keyboardShortcut(.cancelAction)
                Button("Apply") { app.applyConfiguration(draft); dismiss() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }.padding(28).frame(width: 820, height: 650)
        .onAppear { if !initialized { draft = app.library.preferences.configuration; initialized = true } }
        .onChange(of: draft) { _, value in if preview { app.previewConfiguration = value } }
        .onChange(of: preview) { _, enabled in app.previewConfiguration = enabled ? draft : nil }
        .onDisappear { app.previewConfiguration = nil }
    }
    private var appearance: some View {
        VStack(alignment: .leading, spacing: 22) {
            field("Design system") { Picker("Design system", selection: binding(\.theme.design)) { ForEach(DesignSystem.allCases, id: \.self) { Text($0.label).tag($0) } }.labelsHidden() }
            field("Color mode") { Picker("Color mode", selection: binding(\.theme.colorMode)) { ForEach(ColorMode.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) } }.pickerStyle(.segmented).labelsHidden() }
            field("Accent") {
                HStack(spacing: 12) {
                    ForEach(Accent.allCases, id: \.self) { accent in
                        Button { change { $0.theme.accent = accent } } label: {
                            Circle().fill(accent.color).frame(width: 28, height: 28)
                                .overlay { if draft.theme.accent == accent { Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(.white) } }
                        }.buttonStyle(.plain).help(accent.rawValue.capitalized).accessibilityLabel("\(accent.rawValue.capitalized) accent")
                    }
                }
            }
            field("Density") { Picker("Density", selection: binding(\.theme.density)) { ForEach(Density.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) } }.pickerStyle(.segmented).labelsHidden() }
            field("Corners · \(Int(draft.theme.cornerRadius)) pt") { Slider(value: binding(\.theme.cornerRadius), in: 0...24, step: 2).accessibilityLabel("Corner radius") }
            Toggle("Transparent surfaces", isOn: binding(\.theme.transparency))
            Toggle("Reduce motion", isOn: binding(\.theme.reducedMotion))
            Text("System accessibility settings take precedence. Text keeps native contrast and a visible keyboard focus ring.").font(.caption).foregroundStyle(.secondary)
        }.padding(.vertical, 12)
    }
    private var layout: some View {
        VStack(alignment: .leading, spacing: 22) {
            field("Tabs") {
                Picker("Tab placement", selection: binding(\.layout.tabs)) {
                    Text("Top").tag(TabPlacement.top); Text("Bottom").tag(TabPlacement.bottom)
                    Text("Left").tag(TabPlacement.leading); Text("Right").tag(TabPlacement.trailing)
                }.labelsHidden()
            }
            field("Navigation bar") { Picker("Navigation bar placement", selection: binding(\.layout.navigation)) { Text("Top").tag(BarPlacement.top); Text("Bottom").tag(BarPlacement.bottom) }.pickerStyle(.segmented).labelsHidden() }
            field("Sidebar") { Picker("Sidebar placement", selection: binding(\.layout.sidebar)) { Text("Left").tag(SidebarPlacement.leading); Text("Right").tag(SidebarPlacement.trailing); Text("Hidden").tag(SidebarPlacement.hidden) }.pickerStyle(.segmented).labelsHidden() }
            field("Sidebar width · \(Int(draft.layout.sidebarWidth)) pt") { Slider(value: binding(\.layout.sidebarWidth), in: 180...360, step: 10).accessibilityLabel("Sidebar width") }
            Toggle("Show bookmarks bar", isOn: binding(\.layout.bookmarksBar))
            Toggle("Show status bar", isOn: binding(\.layout.statusBar))
            Divider()
            Text("Layout presets").font(.headline)
            HStack {
                Button("Classic") { change { $0.layout = Layout() } }
                Button("Sidebar") { change { $0.layout.tabs = .leading; $0.layout.sidebar = .trailing } }
                Button("Minimal") { change { $0.layout = Layout(); $0.layout.sidebar = .hidden; $0.layout.statusBar = false; $0.layout.bookmarksBar = false } }
            }
            Text("Drag tabs to reorder them, or use Move earlier / Move later in their context menu.").font(.caption).foregroundStyle(.secondary)
        }.padding(.vertical, 12)
    }
    private var savedSetups: some View {
        VStack(alignment: .leading, spacing: 16) {
            TextField("Setup name", text: $setupName).textFieldStyle(.roundedBorder)
            HStack {
                Button("Save setup") {
                    let name = setupName.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !name.isEmpty else { return }
                    app.library.preferences.savedConfigurations.append(NamedConfiguration(name: String(name.prefix(100)), configuration: draft))
                }.disabled(setupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Export…") { app.perform { app.saveFile(try JSONEncoder().encode(SetupPack(name: setupName.isEmpty ? "My setup" : String(setupName.prefix(100)), configuration: draft)), name: "Radius Setup.json", type: .json) } }
                Button("Import…") { importSetup() }
            }
            Text("Setup files contain appearance and layout only. No history, notes, cookies, or permission grants are shared.").font(.caption).foregroundStyle(.secondary)
            ForEach(app.library.preferences.savedConfigurations) { saved in
                HStack {
                    Button(saved.name) { change { $0 = saved.configuration } }.buttonStyle(.plain)
                    Spacer(); IconButton(title: "Delete \(saved.name)", icon: "trash") { app.library.preferences.savedConfigurations.removeAll { $0.id == saved.id } }
                }.padding(10).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            }
        }.padding(.vertical, 12)
    }
    private func binding<T>(_ path: WritableKeyPath<Configuration, T>) -> Binding<T> {
        Binding(get: { draft[keyPath: path] }, set: { value in change { $0[keyPath: path] = value } })
    }
    private func change(_ mutation: (inout Configuration) -> Void) {
        undoStack.append(draft); if undoStack.count > 50 { undoStack.removeFirst() }; mutation(&draft)
    }
    private func field<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) { Text(label).font(.callout.weight(.medium)); content() }
    }
    private var designDescription: String {
        switch draft.theme.design {
        case .native: "Familiar Mac controls, quiet surfaces, and a clear hierarchy."
        case .material: "Tinted surfaces, rounded controls, and a distinct accent. Inspired by Material design."
        case .liquidGlass: "Translucent native materials with clear boundaries. An interpretation of Liquid Glass that works on macOS 14 and later."
        case .graphite: "Neutral surfaces and crisp separators for a denser workspace."
        }
    }
    private func importSetup() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        app.perform {
            guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 64 * 1024 else { throw ValidationError("Setup packs must be smaller than 64 KB.") }
            let pack = try SetupPack.decode(Data(contentsOf: url)); change { $0 = pack.configuration }; setupName = pack.name
        }
    }
}
struct LayoutPreview: View {
    let configuration: Configuration
    private var layout: Layout { configuration.layout }
    private var theme: Theme { configuration.theme }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 5) { Circle().fill(.red); Circle().fill(.yellow); Circle().fill(.green); Spacer() }.frame(height: 8).padding(10)
            if layout.tabs == .top { miniTabs }
            if layout.navigation == .top { miniNavigation }
            if layout.bookmarksBar { Text("Bookmarks").font(.system(size: 8)).frame(maxWidth: .infinity, alignment: .leading).padding(5).background(.quaternary) }
            HStack(spacing: 0) {
                if layout.tabs == .leading { verticalTabs }
                if layout.sidebar == .leading { miniSidebar }
                VStack(alignment: .leading, spacing: 12) {
                    RoundedRectangle(cornerRadius: 3).fill(.primary.opacity(0.7)).frame(width: 95, height: 9)
                    ForEach(0..<4) { _ in RoundedRectangle(cornerRadius: 2).fill(.primary.opacity(0.12)).frame(height: 5) }
                    Spacer()
                }.padding(16).frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(nsColor: .textBackgroundColor))
                if layout.sidebar == .trailing { miniSidebar }
                if layout.tabs == .trailing { verticalTabs }
            }
            if layout.navigation == .bottom { miniNavigation }
            if layout.tabs == .bottom { miniTabs }
            if layout.statusBar { Text("WebKit").font(.system(size: 7)).frame(maxWidth: .infinity, alignment: .leading).padding(5) }
        }.modifier(ChromeSurface(theme: theme)).clipShape(RoundedRectangle(cornerRadius: theme.cornerRadius))
            .overlay(RoundedRectangle(cornerRadius: theme.cornerRadius).stroke(.primary.opacity(0.15)))
            .preferredColorScheme(theme.scheme).accessibilityLabel("Preview of \(theme.design.label) with tabs at \(layout.tabs.rawValue)")
    }
    private var miniTabs: some View { HStack { Text("New tab").padding(5).background(.background, in: RoundedRectangle(cornerRadius: 4)); Text("+"); Spacer() }.font(.system(size: 8)).padding(5).background(theme.accent.color.opacity(0.08)) }
    private var miniNavigation: some View { HStack { Text("‹  ›"); Text("Search or enter website").frame(maxWidth: .infinity).padding(5).background(.background, in: RoundedRectangle(cornerRadius: 4)); Text("···") }.font(.system(size: 8)).padding(5) }
    private var miniSidebar: some View { VStack(alignment: .leading, spacing: 10) { Text("Bookmarks").bold(); Text("A good find"); Spacer() }.font(.system(size: 8)).padding(8).frame(width: 70).background(.quaternary) }
    private var verticalTabs: some View { VStack(alignment: .leading) { Text("New tab"); Text("+"); Spacer() }.font(.system(size: 8)).padding(7).frame(width: 55).background(theme.accent.color.opacity(0.08)) }
}
