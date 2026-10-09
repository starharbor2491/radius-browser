// SPDX-License-Identifier: MPL-2.0
import SwiftUI
import RadiusCore

extension Accent {
    var color: Color { switch self { case .blue: .blue; case .teal: .teal; case .orange: .orange; case .purple: .purple; case .pink: .pink } }
}
extension Theme {
    var scheme: ColorScheme? { switch colorMode { case .system: nil; case .light: .light; case .dark: .dark } }
    var spacing: CGFloat { density == .compact ? 6 : 10 }
    var controlSize: ControlSize { density == .compact ? .small : .regular }
}
struct ChromeSurface: ViewModifier {
    let theme: Theme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    func body(content: Content) -> some View {
        switch theme.design {
        case .liquidGlass:
            content.background(theme.transparency && !reduceTransparency ? AnyShapeStyle(.ultraThinMaterial) : AnyShapeStyle(Color(nsColor: .windowBackgroundColor)))
                .overlay(alignment: .bottom) { Rectangle().fill(.primary.opacity(0.12)).frame(height: 1) }
        case .material:
            content.background(theme.accent.color.opacity(0.075))
                .overlay(alignment: .bottom) { Rectangle().fill(theme.accent.color.opacity(0.15)).frame(height: 1) }
        case .graphite:
            content.background(Color(nsColor: .controlBackgroundColor))
                .overlay(alignment: .bottom) { Rectangle().fill(.primary.opacity(0.2)).frame(height: 1) }
        case .native:
            content.background(Color(nsColor: .windowBackgroundColor))
                .overlay(alignment: .bottom) { Divider() }
        }
    }
}
struct IconButton: View {
    let title: String
    let icon: String
    var active = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: icon).frame(width: 28, height: 28)
                .foregroundStyle(active ? Color.accentColor : Color.primary)
                .background(active ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 7))
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
