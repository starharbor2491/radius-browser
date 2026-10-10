// SPDX-License-Identifier: MPL-2.0
import AppKit
import SwiftUI
import RadiusCore

extension ToolbarComponent {
    static let browserDefaults: [ToolbarComponent] = [
        .init(command: .back, region: .beforeAddress), .init(command: .forward, region: .beforeAddress),
        .init(command: .reload, region: .beforeAddress), .init(command: .sidebar, region: .afterAddress)
    ]
}

struct AdvancedAppearance: View {
    @Binding var configuration: Configuration
    var body: some View {
        DisclosureGroup("Typography and surfaces") {
            VStack(alignment: .leading, spacing: 14) {
                Picker("Typeface", selection: optional(\.typography, fallback: .system)) {
                    ForEach(InterfaceTypeface.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                }
                scale("Text size", path: \.fontScale, range: 0.85...1.4)
                scale("Spacing", path: \.spacingScale, range: 0.75...1.5)
                scale("Border width", path: \.borderWidth, range: 0...2)
                scale("Shadow strength", path: \.shadowStrength, range: 0...1)
                Picker("Icon style", selection: optional(\.iconStyle, fallback: .outline)) {
                    ForEach(InterfaceIconStyle.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                }
                Text("Style uses the active icon pack's available outline or filled variants.").font(.caption).foregroundStyle(.secondary)
                color("Custom accent", path: \.accentHex, fallback: .systemBlue)
                color("Surface color", path: \.surfaceHex, fallback: .windowBackgroundColor)
                color("Text color", path: \.textHex, fallback: .labelColor)
                if let text = configuration.theme.textHex.flatMap(InterfaceColor.init(hex:)),
                   let surface = configuration.theme.surfaceHex.flatMap(InterfaceColor.init(hex:)),
                   text.contrastRatio(against: surface) < 4.5 {
                    Label("These colors have less than 4.5:1 text contrast. Choose a lighter or darker pair.", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                }
                Text("Increase Contrast uses system colors. Custom text and surface colors apply together to browser controls.").font(.caption).foregroundStyle(.secondary)
                Button("Use system colors") { configuration.theme.accentHex = nil; configuration.theme.surfaceHex = nil; configuration.theme.textHex = nil }
            }.padding(.top, 10)
        }
        DisclosureGroup("Per-component appearance") {
            VStack(alignment: .leading, spacing: 12) {
                ComponentAppearanceEditor(title: "Tabs", appearance: component(\.tabsAppearance))
                ComponentAppearanceEditor(title: "Navigation", appearance: component(\.navigationAppearance))
                ComponentAppearanceEditor(title: "Sidebar", appearance: component(\.sidebarAppearance))
            }.padding(.top, 10)
        }
    }
    private func optional<T>(_ path: WritableKeyPath<Theme, T?>, fallback: T) -> Binding<T> {
        Binding(get: { configuration.theme[keyPath: path] ?? fallback }, set: { configuration.theme[keyPath: path] = $0 })
    }
    private func component(_ path: WritableKeyPath<Theme, ComponentAppearance?>) -> Binding<ComponentAppearance> {
        Binding(get: { configuration.theme[keyPath: path] ?? ComponentAppearance() }, set: { configuration.theme[keyPath: path] = $0 })
    }
    private func scale(_ label: String, path: WritableKeyPath<Theme, Double?>, range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.callout)
            Slider(value: optional(path, fallback: path == \.shadowStrength ? 0 : 1), in: range, step: 0.05).accessibilityLabel(label)
        }
    }
    private func color(_ label: String, path: WritableKeyPath<Theme, String?>, fallback: NSColor) -> some View {
        ColorPicker(label, selection: Binding(get: {
            configuration.theme[keyPath: path].flatMap(InterfaceColor.init(hex:))?.color ?? Color(nsColor: fallback)
        }, set: { color in
            guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return }
            configuration.theme[keyPath: path] = String(format: "#%02X%02X%02X", Int((rgb.redComponent * 255).rounded()), Int((rgb.greenComponent * 255).rounded()), Int((rgb.blueComponent * 255).rounded()))
            // Preserve a coherent color pair when the first custom color is chosen.
            if path == \.textHex && configuration.theme.surfaceHex == nil { configuration.theme.surfaceHex = hex(.windowBackgroundColor) }
            if path == \.surfaceHex && configuration.theme.textHex == nil { configuration.theme.textHex = hex(.labelColor) }
        }), supportsOpacity: false)
    }
    private func hex(_ color: NSColor) -> String {
        let rgb = color.usingColorSpace(.sRGB) ?? .black
        return String(format: "#%02X%02X%02X", Int((rgb.redComponent * 255).rounded()), Int((rgb.greenComponent * 255).rounded()), Int((rgb.blueComponent * 255).rounded()))
    }
}
private struct ComponentAppearanceEditor: View {
    let title: String
    @Binding var appearance: ComponentAppearance
    var body: some View {
        DisclosureGroup(title) {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Density", selection: $appearance.density) {
                    Text("Follow browser").tag(Optional<Density>.none)
                    Text("Comfortable").tag(Optional(Density.comfortable)); Text("Compact").tag(Optional(Density.compact))
                }
                Text("Text size").font(.caption)
                Slider(value: Binding(get: { appearance.fontScale ?? 1 }, set: { appearance.fontScale = $0 }), in: 0.85...1.4, step: 0.05).accessibilityLabel("\(title) text size")
                Text("Corner radius").font(.caption)
                Slider(value: Binding(get: { appearance.cornerRadius ?? 10 }, set: { appearance.cornerRadius = $0 }), in: 0...24, step: 2).accessibilityLabel("\(title) corner radius")
                Button("Follow browser appearance") { appearance = ComponentAppearance() }
            }.padding(.vertical, 8)
        }
    }
}
struct ToolbarCustomizer: View {
    @Binding var layout: BrowserLayout
    @State private var adding = ToolbarCommand.newTab
    private var components: [ToolbarComponent] { layout.toolbarComponents ?? ToolbarComponent.browserDefaults }
    var body: some View {
        DisclosureGroup("Arrange toolbar controls") {
            VStack(alignment: .leading, spacing: 14) {
                Text("Drag controls between regions, or use the placement menu and arrow buttons. The website address and browser menu stay accessible. Chromium keeps its own navigation toolbar.").font(.caption).foregroundStyle(.secondary)
                ForEach(ToolbarRegion.allCases, id: \.self) { region in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(region.label).font(.callout.weight(.semibold))
                        ForEach(components.filter { $0.region == region }) { item in row(item) }
                        if !components.contains(where: { $0.region == region }) { Text("Drop a control here").font(.caption).foregroundStyle(.secondary).padding(8).frame(maxWidth: .infinity, alignment: .leading) }
                    }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
                    .dropDestination(for: String.self) { values, _ in
                        guard let value = values.first, let id = UUID(uuidString: value), components.contains(where: { $0.id == id }) else { return false }
                        modify(id) { $0.region = region }; return true
                    }
                }
                HStack {
                    Picker("Add control", selection: $adding) { ForEach(ToolbarCommand.allCases, id: \.self) { Text($0.label).tag($0) } }.labelsHidden()
                    Button("Add") { var items = components; items.append(.init(command: adding, region: .overflow)); layout.toolbarComponents = items }
                        .disabled(components.count >= 32 || (adding != .separator && components.contains(where: { $0.command == adding })))
                }
                Button("Restore toolbar controls") { layout.toolbarComponents = nil }
            }.padding(.top, 10)
        }
    }
    private func row(_ item: ToolbarComponent) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal").foregroundStyle(.secondary).accessibilityHidden(true)
            Text(item.command.label).font(.caption).lineLimit(1)
            Spacer(minLength: 0)
            Menu { ForEach(ToolbarRegion.allCases, id: \.self) { region in Button(region.label) { modify(item.id) { $0.region = region } } } } label: { Image(systemName: "arrow.up.arrow.down") }.menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Placement for \(item.command.label)")
            Button { move(item.id, by: -1) } label: { Image(systemName: "arrow.up") }.help("Move earlier").accessibilityLabel("Move \(item.command.label) earlier").disabled(!canMove(item, by: -1))
            Button { move(item.id, by: 1) } label: { Image(systemName: "arrow.down") }.help("Move later").accessibilityLabel("Move \(item.command.label) later").disabled(!canMove(item, by: 1))
            Button { layout.toolbarComponents = components.filter { $0.id != item.id } } label: { Image(systemName: "xmark") }.help("Remove \(item.command.label)").accessibilityLabel("Remove \(item.command.label)")
        }.buttonStyle(.plain).padding(4).draggable(item.id.uuidString)
    }
    private func modify(_ id: UUID, mutation: (inout ToolbarComponent) -> Void) {
        var items = components; guard let i = items.firstIndex(where: { $0.id == id }) else { return }; mutation(&items[i]); layout.toolbarComponents = items
    }
    private func canMove(_ item: ToolbarComponent, by offset: Int) -> Bool {
        let siblings = components.filter { $0.region == item.region }
        guard let index = siblings.firstIndex(where: { $0.id == item.id }) else { return false }
        return siblings.indices.contains(index + offset)
    }
    private func move(_ id: UUID, by offset: Int) {
        var items = components; guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        let indices = items.indices.filter { items[$0].region == items[i].region }
        guard let position = indices.firstIndex(of: i), indices.indices.contains(position + offset) else { return }
        items.swapAt(i, indices[position + offset]); layout.toolbarComponents = items
    }
}
