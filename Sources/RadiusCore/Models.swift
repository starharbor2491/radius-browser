// SPDX-License-Identifier: MPL-2.0
import Foundation

public enum SearchProvider: String, Codable, CaseIterable, Sendable {
    case duckDuckGo, google, bing
    public var label: String {
        switch self { case .duckDuckGo: "DuckDuckGo"; case .google: "Google"; case .bing: "Bing" }
    }
    public func searchURL(_ text: String) -> URL {
        let base = switch self {
        case .duckDuckGo: "https://duckduckgo.com/"
        case .google: "https://www.google.com/search"
        case .bing: "https://www.bing.com/search"
        }
        var parts = URLComponents(string: base)!
        parts.queryItems = [URLQueryItem(name: "q", value: text)]
        return parts.url!
    }
}

public enum AddressResolver {
    /// User-entered navigation only. Websites never gain access to local files or custom schemes.
    public static func resolve(_ input: String, search: SearchProvider = .duckDuckGo) -> URL? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if let components = URLComponents(string: value), let scheme = components.scheme {
            if ["http", "https"].contains(scheme.lowercased()),
               let host = components.host, !host.isEmpty, components.user == nil, components.password == nil {
                return components.url
            }
            // localhost:port and host:port are addresses, not executable schemes.
            if !value.contains("://"), isHostWithPort(value) {
                return URL(string: "http://" + value)
            }
            if ["javascript", "data", "file", "about", "vbscript"].contains(scheme.lowercased()) || value.contains("://") { return nil }
            return search.searchURL(value)
        }
        if !value.contains(where: { $0.isWhitespace }),
           (value.contains(".") || value == "localhost" || value.hasPrefix("localhost/") || value.hasPrefix("[")),
           let parts = URLComponents(string: "https://" + value),
           let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil {
            let scheme = (host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]") ? "http://" : "https://"
            return URL(string: scheme + value)
        }
        return search.searchURL(value)
    }
    private static func isHostWithPort(_ text: String) -> Bool {
        guard let parts = URLComponents(string: "http://" + text),
              let host = parts.host, parts.port != nil, parts.user == nil, parts.password == nil else { return false }
        return host == "localhost" || host.contains(".") || host.contains(":")
    }
    public static func isWebURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), let host = url.host, !host.isEmpty else { return false }
        return ["http", "https"].contains(scheme) && url.user == nil && url.password == nil
    }
}

public enum BrowserEngineID: String, Codable, CaseIterable, Sendable {
    case webkit, chromium
    public var label: String { self == .webkit ? "WebKit" : "Chromium" }
}
public struct BrowserTab: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var url: URL?
    public var pinned: Bool
    public var parentID: UUID?
    public var collapsed: Bool?
    public var engineID: BrowserEngineID?
    public init(id: UUID = UUID(), title: String = "New tab", url: URL? = nil, pinned: Bool = false, parentID: UUID? = nil, engineID: BrowserEngineID? = nil) {
        self.id = id; self.title = title; self.url = url; self.pinned = pinned; self.parentID = parentID; self.engineID = engineID
    }
}
public struct TabSplit: Codable, Equatable, Sendable {
    public var first: UUID
    public var second: UUID
    public init(first: UUID, second: UUID) { self.first = first; self.second = second }
    public func contains(_ id: UUID) -> Bool { first == id || second == id }
}
public struct WindowSession: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var profileID: UUID
    public var tabs: [BrowserTab]
    public var selectedTabID: UUID
    public var split: TabSplit?
    public var splitSuppressed: Bool?
    public init(id: UUID = UUID(), profileID: UUID, tabs: [BrowserTab] = []) {
        self.id = id; self.profileID = profileID
        self.tabs = tabs.isEmpty ? [BrowserTab()] : tabs
        self.selectedTabID = self.tabs[0].id
    }
    public mutating func normalize() {
        var seen = Set<UUID>()
        tabs = Array(tabs.filter { seen.insert($0.id).inserted }.prefix(200))
        for i in tabs.indices {
            if let url = tabs[i].url, !AddressResolver.isWebURL(url) { tabs[i].url = nil }
            tabs[i].title = String(tabs[i].title.prefix(512))
        }
        if tabs.isEmpty { tabs = [BrowserTab()] }
        tabs = tabs.filter(\.pinned) + tabs.filter { !$0.pinned }
        if !tabs.contains(where: { $0.id == selectedTabID }) { selectedTabID = tabs[0].id }
        let ids = Set(tabs.map(\.id))
        for i in tabs.indices {
            var visited: Set<UUID> = [tabs[i].id]
            var parent = tabs[i].parentID
            var depth = 0
            while let id = parent {
                depth += 1
                guard ids.contains(id), visited.insert(id).inserted, depth <= 8, !tabs[i].pinned else {
                    tabs[i].parentID = nil; break
                }
                parent = tabs.first(where: { $0.id == id })?.parentID
            }
        }
        if let pair = split, pair.first == pair.second || !ids.contains(pair.first) || !ids.contains(pair.second) { split = nil }
        if let pair = split, !pair.contains(selectedTabID) { split?.first = selectedTabID }
        if split != nil { splitSuppressed = nil }
        selectTab(selectedTabID)
    }
    public func ancestors(of id: UUID) -> [UUID] {
        var result: [UUID] = [], seen: Set<UUID> = [id]
        var parent = tabs.first(where: { $0.id == id })?.parentID
        while let current = parent, seen.insert(current).inserted, result.count < 8 {
            result.append(current); parent = tabs.first(where: { $0.id == current })?.parentID
        }
        return result
    }
    public var visibleTreeTabs: [BrowserTab] {
        var result: [BrowserTab] = []
        func appendChildren(of parent: UUID?) {
            for tab in tabs where tab.parentID == parent {
                result.append(tab)
                if tab.collapsed != true { appendChildren(of: tab.id) }
            }
        }
        appendChildren(of: nil)
        return result
    }
    @discardableResult public mutating func setParent(_ id: UUID, to parent: UUID?) -> Bool {
        guard let index = tabs.firstIndex(where: { $0.id == id }), !tabs[index].pinned,
              parent == nil || (parent != id && tabs.contains(where: { $0.id == parent }) && !ancestors(of: parent!).contains(id)) else { return false }
        let descendants = tabs.filter { ancestors(of: $0.id).contains(id) }
        let depth = parent.map { ancestors(of: $0).count + 1 } ?? 0
        guard descendants.allSatisfy({ ancestors(of: $0.id).count - ancestors(of: id).count + depth <= 8 }), depth <= 8 else { return false }
        tabs[index].parentID = parent
        selectTab(selectedTabID)
        return true
    }
    public mutating func selectTab(_ id: UUID) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        if let pair = split, !pair.contains(id) {
            if selectedTabID == pair.second { split?.second = id } else { split?.first = id }
        }
        selectedTabID = id
        for ancestor in ancestors(of: id) {
            if let index = tabs.firstIndex(where: { $0.id == ancestor }) { tabs[index].collapsed = false }
        }
    }
    public mutating func enableSplit(defaultEngine: BrowserEngineID = .webkit) {
        guard split == nil else { return }
        let other = tabs.first(where: { $0.id != selectedTabID }) ?? BrowserTab(engineID: defaultEngine)
        if !tabs.contains(where: { $0.id == other.id }) { tabs.append(other) }
        split = TabSplit(first: selectedTabID, second: other.id)
    }
}
public struct Profile: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var engineID: BrowserEngineID?
    public init(id: UUID = UUID(), name: String) { self.id = id; self.name = name }
}
public struct Bookmark: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var profileID: UUID
    public var title: String
    public var url: URL
    public var createdAt: Date
    public init(id: UUID = UUID(), profileID: UUID, title: String, url: URL, createdAt: Date = Date()) {
        self.id = id; self.profileID = profileID; self.title = title; self.url = url; self.createdAt = createdAt
    }
}
public struct HistoryEntry: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var profileID: UUID
    public var title: String
    public var url: URL
    public var visitedAt: Date
    public init(id: UUID = UUID(), profileID: UUID, title: String, url: URL, visitedAt: Date = Date()) {
        self.id = id; self.profileID = profileID; self.title = title; self.url = url; self.visitedAt = visitedAt
    }
}
public struct Note: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var profileID: UUID
    public var title: String
    public var text: String
    public var modifiedAt: Date
    public init(id: UUID = UUID(), profileID: UUID, title: String = "Untitled note", text: String = "") {
        self.id = id; self.profileID = profileID; self.title = title; self.text = text; self.modifiedAt = Date()
    }
}

public enum DesignSystem: String, Codable, CaseIterable, Sendable {
    case native, material, liquidGlass, graphite
    public var label: String {
        switch self { case .native: "macOS"; case .material: "Material"; case .liquidGlass: "Liquid Glass"; case .graphite: "Graphite" }
    }
}
public enum ColorMode: String, Codable, CaseIterable, Sendable { case system, light, dark }
public enum Accent: String, Codable, CaseIterable, Sendable { case blue, teal, orange, purple, pink }
public enum Density: String, Codable, CaseIterable, Sendable { case comfortable, compact }
public enum TabPlacement: String, Codable, CaseIterable, Sendable { case top, bottom, leading, trailing }
public enum BarPlacement: String, Codable, CaseIterable, Sendable { case top, bottom }
public enum SidebarPlacement: String, Codable, CaseIterable, Sendable { case leading, trailing, hidden }
public enum SplitAxis: String, Codable, CaseIterable, Sendable { case sideBySide, stacked }
public enum InterfaceTypeface: String, Codable, CaseIterable, Sendable { case system, rounded, serif, monospaced }
public enum InterfaceIconStyle: String, Codable, CaseIterable, Sendable { case outline, filled }
public struct ComponentAppearance: Codable, Equatable, Sendable {
    public var density: Density?
    public var fontScale: Double?
    public var cornerRadius: Double?
    public init() {}
    public mutating func normalize() {
        if let value = fontScale { fontScale = value.isFinite ? min(1.4, max(0.85, value)) : 1 }
        if let value = cornerRadius { cornerRadius = value.isFinite ? min(24, max(0, value)) : 10 }
    }
}
public struct InterfaceColor: Equatable, Sendable {
    public let red: Double, green: Double, blue: Double
    public init?(hex: String) {
        let value = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard value.count == 6, value.allSatisfy({ $0.isASCII && $0.isHexDigit }), let rgb = UInt32(value, radix: 16) else { return nil }
        red = Double((rgb >> 16) & 255) / 255; green = Double((rgb >> 8) & 255) / 255; blue = Double(rgb & 255) / 255
    }
    public func contrastRatio(against other: InterfaceColor) -> Double {
        func luminance(_ color: InterfaceColor) -> Double {
            func linear(_ value: Double) -> Double { value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4) }
            return 0.2126 * linear(color.red) + 0.7152 * linear(color.green) + 0.0722 * linear(color.blue)
        }
        let a = luminance(self), b = luminance(other)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
}
public enum ToolbarRegion: String, Codable, CaseIterable, Sendable {
    case beforeAddress, afterAddress, top, bottom, overflow
    public var label: String {
        switch self { case .beforeAddress: "Before address"; case .afterAddress: "After address"; case .top: "Top toolbar"; case .bottom: "Bottom toolbar"; case .overflow: "Browser menu" }
    }
}
public enum ToolbarCommand: String, Codable, CaseIterable, Sendable {
    case back, forward, reload, newTab, home, bookmark, sidebar, reader, screenshot, focus, downloads, modules, customize, settings, separator
    public var label: String {
        switch self {
        case .back: "Back"; case .forward: "Forward"; case .reload: "Reload or stop"; case .newTab: "New tab"; case .home: "Start page"; case .bookmark: "Bookmark page"; case .sidebar: "Sidebar panels"; case .reader: "Reader"; case .screenshot: "Capture page"; case .focus: "Focus mode"; case .downloads: "Downloads"; case .modules: "Modules"; case .customize: "Customize"; case .settings: "Settings"; case .separator: "Separator"
        }
    }
}
public struct ToolbarComponent: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var command: ToolbarCommand
    public var region: ToolbarRegion
    public init(id: UUID = UUID(), command: ToolbarCommand, region: ToolbarRegion) { self.id = id; self.command = command; self.region = region }
}
public struct Theme: Codable, Equatable, Sendable {
    public var design: DesignSystem = .native
    public var colorMode: ColorMode = .system
    public var accent: Accent = .blue
    public var density: Density = .comfortable
    public var cornerRadius: Double = 10
    public var transparency: Bool = true
    public var reducedMotion: Bool = false
    // Optional fields preserve decoding of existing user configurations and setup packs.
    public var typography: InterfaceTypeface?
    public var fontScale: Double?
    public var spacingScale: Double?
    public var accentHex: String?
    public var surfaceHex: String?
    public var textHex: String?
    public var borderWidth: Double?
    public var shadowStrength: Double?
    public var iconStyle: InterfaceIconStyle?
    public var tabsAppearance: ComponentAppearance?
    public var navigationAppearance: ComponentAppearance?
    public var sidebarAppearance: ComponentAppearance?
    public init() {}
    public mutating func normalize() {
        cornerRadius = cornerRadius.isFinite ? min(24, max(0, cornerRadius)) : 10
        if let value = fontScale { fontScale = value.isFinite ? min(1.4, max(0.85, value)) : 1 }
        if let value = spacingScale { spacingScale = value.isFinite ? min(1.5, max(0.75, value)) : 1 }
        if let value = borderWidth { borderWidth = value.isFinite ? min(2, max(0, value)) : 1 }
        if let value = shadowStrength { shadowStrength = value.isFinite ? min(1, max(0, value)) : 0 }
        if let value = accentHex, InterfaceColor(hex: value) == nil { accentHex = nil }
        if let value = surfaceHex, InterfaceColor(hex: value) == nil { surfaceHex = nil }
        if let value = textHex, InterfaceColor(hex: value) == nil { textHex = nil }
        tabsAppearance?.normalize(); navigationAppearance?.normalize(); sidebarAppearance?.normalize()
    }
}
public struct BrowserLayout: Codable, Equatable, Sendable {
    public var tabs: TabPlacement = .top
    public var navigation: BarPlacement = .top
    public var sidebar: SidebarPlacement = .leading
    public var sidebarWidth: Double = 240
    public var bookmarksBar: Bool = false
    public var statusBar: Bool = true
    public var treeTabs: Bool?
    public var split: SplitAxis?
    public var toolbarComponents: [ToolbarComponent]?
    public var addressWidth: Double?
    public var tabsWidth: Double?
    public var hideTabStrip: Bool?
    public var sidebarAutoHide: Bool?
    public var secondaryPanel: String?
    public init() {}
    public mutating func normalize() {
        sidebarWidth = sidebarWidth.isFinite ? min(360, max(180, sidebarWidth)) : 240
        if treeTabs == true && (tabs == .top || tabs == .bottom) { tabs = .leading }
        if let value = addressWidth { addressWidth = value.isFinite ? min(1, max(0.4, value)) : 1 }
        if let value = tabsWidth { tabsWidth = value.isFinite ? min(320, max(140, value)) : 190 }
        if let components = toolbarComponents {
            var ids = Set<UUID>(), commands = Set<ToolbarCommand>()
            toolbarComponents = Array(components.filter { ids.insert($0.id).inserted && ($0.command == .separator || commands.insert($0.command).inserted) }.prefix(32))
        }
        if let secondaryPanel, !["bookmarks", "history", "downloads", "notes", "resources"].contains(secondaryPanel) { self.secondaryPanel = nil }
    }
}
public struct Configuration: Codable, Equatable, Sendable {
    public var theme = Theme()
    public var layout = BrowserLayout()
    public init() {}
    public mutating func normalize() { theme.normalize(); layout.normalize() }
}
public struct NamedConfiguration: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var configuration: Configuration
    public var requiredModuleIDs: [String]?
    public init(id: UUID = UUID(), name: String, configuration: Configuration) {
        self.id = id; self.name = name; self.configuration = configuration
    }
}
public struct Preferences: Codable, Equatable, Sendable {
    public var search: SearchProvider = .duckDuckGo
    public var restoreSession: Bool = true
    public var blockPopups: Bool = true
    public var configuration = Configuration()
    public var savedConfigurations: [NamedConfiguration] = []
    public var completedOnboarding: Bool = false
    public init() {}
}
public struct LibraryState: Codable, Equatable, Sendable {
    public var profiles: [Profile] = [Profile(name: "Personal")]
    public var bookmarks: [Bookmark] = []
    public var history: [HistoryEntry] = []
    public var notes: [Note] = []
    public var sessions: [WindowSession] = []
    public var pendingProfileDeletions: [UUID]?
    public var preferences = Preferences()
    public init() {}
    public mutating func normalize() {
        var profilesSeen = Set<UUID>()
        profiles = Array(profiles.filter { profilesSeen.insert($0.id).inserted }.prefix(20))
        if profiles.isEmpty { profiles = [Profile(name: "Personal")] }
        let profileIDs = Set(profiles.map(\.id))
        if let pendingProfileDeletions {
            var seen = Set<UUID>()
            self.pendingProfileDeletions = Array(pendingProfileDeletions.filter { !profileIDs.contains($0) && seen.insert($0).inserted }.prefix(100))
        }
        bookmarks = bookmarks.filter { profileIDs.contains($0.profileID) && AddressResolver.isWebURL($0.url) }
        history = Array(history.filter { profileIDs.contains($0.profileID) && AddressResolver.isWebURL($0.url) }.suffix(10_000))
        notes = notes.filter { profileIDs.contains($0.profileID) }
        var sessionsSeen = Set<UUID>()
        sessions = sessions.filter { profileIDs.contains($0.profileID) && sessionsSeen.insert($0.id).inserted }
        for i in sessions.indices { sessions[i].normalize() }
        preferences.configuration.normalize()
        for i in preferences.savedConfigurations.indices { preferences.savedConfigurations[i].configuration.normalize() }
    }
}

/// Intentionally excludes browsing data, credentials, module grants and executable content.
public struct SetupPack: Codable, Equatable, Sendable {
    public let formatVersion: Int
    public var name: String
    public var configuration: Configuration
    public var requiredModuleIDs: [String]?
    public init(name: String, configuration: Configuration, requiredModuleIDs: [String]? = nil) {
        formatVersion = 1; self.name = name; self.configuration = configuration; self.requiredModuleIDs = requiredModuleIDs
    }
    public static func decode(_ data: Data) throws -> SetupPack {
        guard data.count <= 64 * 1024 else { throw ValidationError("Setup pack is too large.") }
        var pack = try JSONDecoder().decode(SetupPack.self, from: data)
        guard pack.formatVersion == 1 else { throw ValidationError("This setup pack needs a newer Radius version.") }
        guard !pack.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              pack.name.count <= 100 else { throw ValidationError("Use a setup name of 1–100 characters.") }
        if let requirements = pack.requiredModuleIDs {
            guard requirements.count <= 32, Set(requirements).count == requirements.count, requirements.allSatisfy(ModuleManifest.validID) else { throw ValidationError("Setup module requirements are invalid.") }
        }
        pack.configuration.normalize()
        return pack
    }
}
public struct ValidationError: LocalizedError, Equatable, Sendable {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
