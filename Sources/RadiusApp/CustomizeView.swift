// SPDX-License-Identifier: MPL-2.0
import AppKit
import SwiftUI
import RadiusCore

struct CustomizeView: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var draft = Configuration()
    @State private var undoStack: [(configuration: Configuration, requirements: [String])] = []
    @State private var selection = 0
    @State private var preview = false
    @State private var setupName = "My setup"
    @State private var initialized = false
    @State private var requirements: [String] = []
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SheetHeader(title: "Customize", subtitle: "Change the look. Arrange your space. Keep your place.")
            HStack(alignment: .top, spacing: 28) {
                VStack(alignment: .leading, spacing: 16) {
                    Picker("Customize category", selection: $selection) { Text("Appearance").tag(0); Text("Layout").tag(1); Text("Saved setups").tag(2) }.pickerStyle(.segmented).labelsHidden()
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
                    guard let previous = undoStack.popLast() else { return }; draft = previous.configuration; requirements = previous.requirements
                }.disabled(undoStack.isEmpty)
                Button("Restore defaults") { change { $0 = Configuration() } }
                Spacer()
                Button("Cancel") { app.previewConfiguration = nil; dismiss() }.keyboardShortcut(.cancelAction)
                Button("Apply") { app.perform { if try app.applySetup(draft, requirements: requirements) { dismiss() } } }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }.padding(28).frame(width: 820, height: 650)
        .onAppear { if !initialized { draft = app.library.preferences.configuration; requirements = app.configurationModuleRequirements; initialized = true } }
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
                                .overlay { if draft.theme.accent == accent { Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(accent == .teal || accent == .orange ? Color.black : Color.white) } }
                                .overlay { if draft.theme.accent == accent { Circle().stroke(.primary, lineWidth: 2).padding(-3) } }
                                .padding(4).contentShape(Rectangle())
                        }.buttonStyle(.plain).help(accent.rawValue.capitalized).accessibilityLabel("\(accent.rawValue.capitalized) accent")
                            .accessibilityAddTraits(draft.theme.accent == accent ? .isSelected : [])
                    }
                }
            }
            field("Density") { Picker("Density", selection: binding(\.theme.density)) { ForEach(Density.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) } }.pickerStyle(.segmented).labelsHidden() }
            field("Corners · \(Int(draft.theme.cornerRadius)) pt") { Slider(value: binding(\.theme.cornerRadius), in: 0...24, step: 2).accessibilityLabel("Corner radius") }
            Toggle("Transparent surfaces", isOn: binding(\.theme.transparency))
            Toggle("Reduce motion", isOn: binding(\.theme.reducedMotion))
            Text("System accessibility settings take precedence. Text keeps a visible keyboard focus ring.").font(.caption).foregroundStyle(.secondary)
            AdvancedAppearance(configuration: Binding(get: { draft }, set: { value in change { $0 = value } }))
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
            Toggle("Tree tabs", isOn: Binding(get: { draft.layout.treeTabs == true }, set: { enabled in
                change { $0.layout.treeTabs = enabled; if enabled && ($0.layout.tabs == .top || $0.layout.tabs == .bottom) { $0.layout.tabs = .leading } }
            }))
            Text("Group related pages under a parent tab. Tree tabs use a vertical tab strip.").font(.caption).foregroundStyle(.secondary)
            field("Browsing panes") {
                Picker("Browsing panes", selection: binding(\.layout.split)) {
                    Text("One pane").tag(Optional<SplitAxis>.none)
                    Text("Side by side").tag(Optional(SplitAxis.sideBySide))
                    Text("Stacked").tag(Optional(SplitAxis.stacked))
                }.labelsHidden()
            }
            Text("Split panes open when you apply the setup. Live preview leaves your open tabs intact.").font(.caption).foregroundStyle(.secondary)
            field("Navigation bar") { Picker("Navigation bar placement", selection: binding(\.layout.navigation)) { Text("Top").tag(BarPlacement.top); Text("Bottom").tag(BarPlacement.bottom) }.pickerStyle(.segmented).labelsHidden() }
            field("Sidebar") { Picker("Sidebar placement", selection: binding(\.layout.sidebar)) { Text("Left").tag(SidebarPlacement.leading); Text("Right").tag(SidebarPlacement.trailing); Text("Hidden").tag(SidebarPlacement.hidden) }.pickerStyle(.segmented).labelsHidden() }
            field("Sidebar width · \(Int(draft.layout.sidebarWidth)) pt") { Slider(value: binding(\.layout.sidebarWidth), in: 180...360, step: 10).accessibilityLabel("Sidebar width") }
            Toggle("Hide tab strip", isOn: Binding(get: { draft.layout.hideTabStrip == true }, set: { value in change { $0.layout.hideTabStrip = value } }))
            Text("Use the Tabs menu or keyboard shortcuts when the strip is hidden.").font(.caption).foregroundStyle(.secondary)
            field("Vertical tab width") { Slider(value: Binding(get: { draft.layout.tabsWidth ?? 190 }, set: { value in change { $0.layout.tabsWidth = value } }), in: 140...320, step: 10).accessibilityLabel("Vertical tab width") }
            field("Address width") { Slider(value: Binding(get: { draft.layout.addressWidth ?? 1 }, set: { value in change { $0.layout.addressWidth = value } }), in: 0.4...1, step: 0.05).accessibilityLabel("Address width") }
            Toggle("Hide sidebar when switching tabs", isOn: Binding(get: { draft.layout.sidebarAutoHide == true }, set: { value in change { $0.layout.sidebarAutoHide = value } }))
            field("Second sidebar") {
                Picker("Second sidebar", selection: binding(\.layout.secondaryPanel)) {
                    Text("None").tag(Optional<String>.none)
                    ForEach(BrowserPanel.allCases) { Text($0.label).tag(Optional($0.rawValue)) }
                }.labelsHidden()
            }
            ToolbarCustomizer(layout: Binding(get: { draft.layout }, set: { value in change { $0.layout = value } }))
            Toggle("Show bookmarks bar", isOn: binding(\.layout.bookmarksBar))
            Toggle("Show status bar", isOn: binding(\.layout.statusBar))
            Divider()
            Text("Layout presets").font(.headline)
            HStack {
                Button("Classic") { change { $0.layout = BrowserLayout() } }
                Button("Sidebar") { change { $0.layout.tabs = .leading; $0.layout.sidebar = .trailing } }
                Button("Minimal") { change { $0.layout = BrowserLayout(); $0.layout.sidebar = .hidden; $0.layout.statusBar = false; $0.layout.bookmarksBar = false } }
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
                    var saved = NamedConfiguration(name: String(name.prefix(100)), configuration: draft)
                    saved.requiredModuleIDs = requirements
                    app.library.preferences.savedConfigurations.append(saved)
                }.disabled(setupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Export…") { app.perform { exportSetup(SetupPack(name: setupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "My setup" : String(setupName.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100)), configuration: draft, requiredModuleIDs: requirements)) } }
                Button("Import…") { importSetup() }
            }
            Text("Setup files contain appearance, layout, and required module IDs. No history, notes, cookies, or permission grants are shared.").font(.caption).foregroundStyle(.secondary)
            if !requirements.isEmpty {
                Text("Required modules").font(.headline)
                ForEach(requirements, id: \.self) { id in
                    HStack { Text(app.catalog.first(where: { $0.id == id })?.name ?? id).font(.caption); Spacer(); Button("Remove requirement") { requirements.removeAll { $0 == id } }.font(.caption) }
                }
            }
            ForEach(app.library.preferences.savedConfigurations) { saved in
                HStack {
                    Button(saved.name) { change { $0 = saved.configuration }; requirements = saved.requiredModuleIDs ?? [] }.buttonStyle(.plain)
                    Spacer(); IconButton(title: "Delete \(saved.name)", icon: "trash") { app.library.preferences.savedConfigurations.removeAll { $0.id == saved.id } }
                }.padding(10).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            }
        }.padding(.vertical, 12)
    }
    private func binding<T>(_ path: WritableKeyPath<Configuration, T>) -> Binding<T> {
        Binding(get: { draft[keyPath: path] }, set: { value in change { $0[keyPath: path] = value } })
    }
    private func change(_ mutation: (inout Configuration) -> Void) {
        undoStack.append((draft, requirements)); if undoStack.count > 50 { undoStack.removeFirst() }; mutation(&draft)
        if draft.layout.tabs == .top || draft.layout.tabs == .bottom { draft.layout.treeTabs = false }
        if requirements.contains("org.radius.tree-tabs") || requirements.contains("org.radius.standard-tabs") {
            requirements.removeAll { $0 == "org.radius.tree-tabs" || $0 == "org.radius.standard-tabs" }
            requirements.append(draft.layout.treeTabs == true ? "org.radius.tree-tabs" : "org.radius.standard-tabs")
        }
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
    private func exportSetup(_ pack: SetupPack) throws {
        let data = try JSONEncoder().encode(pack)
        _ = try SetupPack.decode(data)
        app.saveFile(data, name: "Radius Setup.json", type: .json)
    }
    private func importSetup() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        app.perform {
            guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 64 * 1024 else { throw ValidationError("Setup packs must be smaller than 64 KB.") }
            let pack = try SetupPack.decode(Data(contentsOf: url))
            let required = pack.requiredModuleIDs ?? []
            let plan = try app.moduleInstallationPlan(for: required)
            let alert = NSAlert(); alert.messageText = "Preview \(pack.name)"
            alert.informativeText = "This setup changes appearance and layout.\n\nRequired packages:\n" + (plan.isEmpty ? "None" : plan.map { "\($0.name) · \($0.publisher)" }.joined(separator: "\n")) + "\n\nPackages and permissions are reviewed before Apply. Importing this preview does not install anything."
            alert.addButton(withTitle: "Preview setup"); alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            change { $0 = pack.configuration }; setupName = pack.name; requirements = required
        }
    }
}
struct LayoutPreview: View {
    let configuration: Configuration
    private var layout: BrowserLayout { configuration.layout }
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
                Group {
                    if layout.split == .sideBySide { HStack(spacing: 0) { miniDocument; Divider(); miniDocument } }
                    else if layout.split == .stacked { VStack(spacing: 0) { miniDocument; Divider(); miniDocument } }
                    else { miniDocument }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                if layout.sidebar == .trailing { miniSidebar }
                if layout.tabs == .trailing { verticalTabs }
            }
            if layout.navigation == .bottom { miniNavigation }
            if layout.tabs == .bottom { miniTabs }
            if layout.statusBar { Text("WebKit").font(.system(size: 7)).frame(maxWidth: .infinity, alignment: .leading).padding(5) }
        }.modifier(ChromeSurface(theme: theme)).clipShape(RoundedRectangle(cornerRadius: theme.cornerRadius))
            .overlay(RoundedRectangle(cornerRadius: theme.cornerRadius).stroke(.primary.opacity(0.15)))
            .environment(\.browserTheme, theme).font(theme.interfaceFont()).preferredColorScheme(theme.scheme).accessibilityLabel("Preview of \(theme.design.label) with tabs at \(layout.tabs.rawValue)")
    }
    private var miniTabs: some View { HStack { Text("New tab").padding(5).background(.background, in: RoundedRectangle(cornerRadius: 4)); Text("+"); Spacer() }.font(.system(size: 8)).padding(5).background(theme.tint.opacity(0.08)) }
    private var miniNavigation: some View { HStack { Text("‹  ›"); Text("Search or enter website").frame(maxWidth: .infinity).padding(5).background(.background, in: RoundedRectangle(cornerRadius: 4)); Text("···") }.font(.system(size: 8)).padding(5) }
    private var miniSidebar: some View { VStack(alignment: .leading, spacing: 10) { Text("Bookmarks").bold(); Text("A good find"); Spacer() }.font(.system(size: 8)).padding(8).frame(width: 70).background(.quaternary) }
    private var miniDocument: some View {
        VStack(alignment: .leading, spacing: 7) {
            RoundedRectangle(cornerRadius: 3).fill(.primary.opacity(0.7)).frame(maxWidth: 95).frame(height: 9)
            ForEach(0..<3) { _ in RoundedRectangle(cornerRadius: 2).fill(.primary.opacity(0.12)).frame(height: 5) }
            Spacer(minLength: 2)
        }.padding(12).frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(nsColor: .textBackgroundColor))
    }
    private var verticalTabs: some View { VStack(alignment: .leading) { Text("New tab"); if layout.treeTabs == true { Text("Reference").padding(.leading, 8) }; Text("+"); Spacer() }.font(.system(size: 8)).padding(7).frame(width: 55).background(theme.tint.opacity(0.08)) }
}
