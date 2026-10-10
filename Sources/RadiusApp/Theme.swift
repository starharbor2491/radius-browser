// SPDX-License-Identifier: MPL-2.0
import AppKit
import SwiftUI
import RadiusCore

extension Accent {
    var color: Color { switch self { case .blue: .blue; case .teal: .teal; case .orange: .orange; case .purple: .purple; case .pink: .pink } }
}
extension InterfaceColor { var color: Color { Color(red: red, green: green, blue: blue) } }
extension Theme {
    var scheme: ColorScheme? { switch colorMode { case .system: nil; case .light: .light; case .dark: .dark } }
    var spacing: CGFloat { (density == .compact ? 6 : 10) * (spacingScale ?? 1) }
    var controlSize: ControlSize { density == .compact ? .small : .regular }
    var tint: Color { accentHex.flatMap(InterfaceColor.init(hex:))?.color ?? accent.color }
    func interfaceFont(_ size: CGFloat = 13, weight: Font.Weight = .regular) -> Font {
        let design: Font.Design = switch typography ?? .system { case .system: .default; case .rounded: .rounded; case .serif: .serif; case .monospaced: .monospaced }
        return .system(size: size * (fontScale ?? 1), weight: weight, design: design)
    }
    func component(_ appearance: ComponentAppearance?) -> Theme {
        var result = self
        if let density = appearance?.density { result.density = density }
        if let scale = appearance?.fontScale { result.fontScale = scale }
        if let radius = appearance?.cornerRadius { result.cornerRadius = radius }
        return result
    }
}
private struct BrowserThemeKey: EnvironmentKey { static let defaultValue = Theme() }
private struct BrowserSymbolsKey: EnvironmentKey { static let defaultValue: [String: String] = [:] }
extension EnvironmentValues {
    var browserTheme: Theme { get { self[BrowserThemeKey.self] } set { self[BrowserThemeKey.self] = newValue } }
    var browserSymbols: [String: String] { get { self[BrowserSymbolsKey.self] } set { self[BrowserSymbolsKey.self] = newValue } }
}
struct BrowserSymbol: View {
    let name: String
    @Environment(\.browserTheme) private var theme
    @Environment(\.browserSymbols) private var symbols
    private var resolved: String {
        let candidate = symbols[name] ?? name
        let filled = candidate.hasSuffix(".fill") ? candidate : candidate + ".fill"
        if theme.iconStyle == .filled, NSImage(systemSymbolName: filled, accessibilityDescription: nil) != nil { return filled }
        return NSImage(systemSymbolName: candidate, accessibilityDescription: nil) != nil ? candidate : name
    }
    var body: some View { Image(systemName: resolved) }
}
struct ChromeSurface: ViewModifier {
    let theme: Theme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    private var surface: AnyShapeStyle {
        if contrast == .increased { return AnyShapeStyle(Color(nsColor: .windowBackgroundColor)) }
        if let color = theme.surfaceHex.flatMap(InterfaceColor.init(hex:)) { return AnyShapeStyle(color.color) }
        switch theme.design {
        case .liquidGlass: return theme.transparency && !reduceTransparency ? AnyShapeStyle(.ultraThinMaterial) : AnyShapeStyle(Color(nsColor: .windowBackgroundColor))
        case .material: return AnyShapeStyle(theme.tint.opacity(0.075))
        case .graphite: return AnyShapeStyle(Color(nsColor: .controlBackgroundColor))
        case .native: return AnyShapeStyle(Color(nsColor: .windowBackgroundColor))
        }
    }
    private var foreground: Color {
        contrast == .increased ? .primary : (theme.textHex.flatMap(InterfaceColor.init(hex:))?.color ?? .primary)
    }
    func body(content: Content) -> some View {
        content.background(surface).foregroundStyle(foreground)
            .overlay(alignment: .bottom) { Rectangle().fill(contrast == .increased ? Color.primary : Color(nsColor: .separatorColor)).frame(height: contrast == .increased ? 1 : (theme.borderWidth ?? 1)) }
            .shadow(color: .black.opacity((theme.shadowStrength ?? 0) * 0.18), radius: (theme.shadowStrength ?? 0) * 6, y: 2)
            .font(theme.interfaceFont()).environment(\.browserTheme, theme)
    }
}
struct IconButton: View {
    let title: String
    let icon: String
    var active = false
    let action: () -> Void
    @Environment(\.browserTheme) private var theme
    var body: some View {
        Button(action: action) {
            BrowserSymbol(name: icon).frame(width: theme.density == .compact ? 28 : 32, height: theme.density == .compact ? 28 : 32)
                .foregroundStyle(active ? Color.accentColor : Color.primary)
                .background(active ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: theme.cornerRadius))
        }.buttonStyle(.plain).help(title).accessibilityLabel(title)
    }
}
struct EmptyPanel: View {
    let title: String
    let icon: String
    let detail: String
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon).font(.largeTitle).foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(detail).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
struct SheetHeader: View {
    let title: String
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 26, weight: .semibold))
            Text(subtitle).font(.callout).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 16)
    }
}
