// SPDX-License-Identifier: MPL-2.0
import AppKit
import SwiftUI
import RadiusCore

struct BrowserWindowRoot: View {
    @EnvironmentObject private var app: AppState
    let isPrivate: Bool
    @State private var model: BrowserModel?
    @State private var pendingURLs: [URL] = []
    var body: some View {
        Group {
            if let model, app.ready { BrowserWindow(model: model) }
            else if let error = app.startupError { StartupRecovery(error: error) }
            else { ProgressView("Opening Radius…").frame(maxWidth: .infinity, maxHeight: .infinity) }
        }
        .frame(minWidth: 760, minHeight: 520)
        .disabled(app.finalQuitDataFrozen)
        .task {
            if !app.ready { await app.load() }
            if app.ready && (model == nil || model?.isClosed == true) { createModel() }
        }
        .onOpenURL { url in
            guard !app.finalQuitDataFrozen, AddressResolver.isWebURL(url) else { return }
            if let model, !model.isClosed { model.newTab(url: url) }
            else { pendingURLs.append(url); if app.ready { createModel() } }
        }
        .onChange(of: app.ready) { _, ready in
            if ready && model == nil { createModel() }
        }
        .onChange(of: app.finalQuitDataFrozen) { _, frozen in
            if !frozen && app.ready && (model == nil || model?.isClosed == true) { createModel() }
        }
    }
    private func createModel() {
        guard !app.finalQuitDataFrozen else { return }
        let created = BrowserModel(app: app, isPrivate: isPrivate)
        model = created
        for url in pendingURLs { created.newTab(url: url) }
        pendingURLs.removeAll()
    }
}
struct BrowserWindow: View {
    @ObservedObject var model: BrowserModel
    @EnvironmentObject private var app: AppState
    @FocusState private var addressFocused: Bool
    @FocusState private var findFocused: Bool
    @State private var findVisible = false
    @State private var findText = ""
    @State private var reader: String?
    @State private var readerTitle = ""
    @State private var extracting = false
    @State private var readerTask: Task<Void, Never>?
    @State private var captureTask: Task<Void, Never>?
    @State private var capturing = false
    @State private var navigationEpoch = 0
    @State private var windowWidth: CGFloat = 760
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.colorSchemeContrast) private var systemContrast
    private var layout: BrowserLayout { app.configuration.layout }
    private var theme: Theme {
        var value = app.configuration.theme
        if systemContrast == .increased { value.textHex = nil; value.surfaceHex = nil; value.accentHex = nil }
        return value
    }
    private var tabsTheme: Theme { theme.component(theme.tabsAppearance) }
    private var navigationTheme: Theme { theme.component(theme.navigationAppearance) }
    private var sidebarTheme: Theme { theme.component(theme.sidebarAppearance) }
    private var treeTabs: Bool { layout.treeTabs == true && (app.previewConfiguration != nil || app.declarativeDefinition(.tabSystem)?.treeTabs == true) }
    private var usesChromeNavigation: Bool { navigationEpoch >= 0 && model.hasPage && model.activeWebTab.hasNativeNavigationChrome }
    private func hidden(_ component: String) -> Bool { model.focusMode && model.focusHiddenComponents.contains(component) }
    private var showTabs: Bool { !hidden("tabs") && layout.hideTabStrip != true }
    private var hasChromePanes: Bool { model.session.tabs.contains { $0.engineID == .chromium } }
    private var secondaryPanel: BrowserPanel? {
        guard windowWidth >= 1100, let value = layout.secondaryPanel, let panel = BrowserPanel(rawValue: value), available(panel), panel != visiblePanel, !hidden("sidebar") else { return nil }; return panel
    }
    private var visiblePanel: BrowserPanel? {
        guard let panel = model.panel else { return nil }
        if panel == .notes && !app.enabled(.notes) { return nil }
        if panel == .resources && !app.enabled(.resourceMonitor) { return nil }
        return panel
    }
    var body: some View {
        if model.isClosed { Color.clear }
        else { content }
    }
    private var browserLayout: some View {
        VStack(spacing: 0) {
            if model.focusMode {
                HStack { Text("Focus mode").font(.caption); Spacer(); Button("Exit focus · Esc") { model.exitFocus() } }.padding(.horizontal, 12).padding(.vertical, 6).background(.bar)
            }
            if showTabs && layout.tabs == .top { tabs(vertical: false) }
            if !hidden("navigation") {
                customStrip(.top)
                if layout.navigation == .top { navigation }
            }
            if !hidden("bookmarks") && layout.bookmarksBar { bookmarksBar }
            HStack(spacing: 0) {
                if showTabs && layout.tabs == .leading { tabs(vertical: true).frame(width: min(layout.tabsWidth ?? 190, max(140, windowWidth * 0.22))).background(BrowserLayoutRegion(identifier: "radius.verticalTabs")) }
                if !hidden("sidebar") && layout.sidebar == .leading && visiblePanel != nil { sidebar }
                if let secondaryPanel, layout.sidebar != .leading { secondarySidebar(secondaryPanel) }
                page.frame(maxWidth: .infinity, maxHeight: .infinity).background(BrowserLayoutRegion(identifier: "radius.page"))
                if !hidden("sidebar") && layout.sidebar == .trailing && visiblePanel != nil { sidebar }
                if let secondaryPanel, layout.sidebar == .leading { secondarySidebar(secondaryPanel) }
                if showTabs && layout.tabs == .trailing { tabs(vertical: true).frame(width: min(layout.tabsWidth ?? 190, max(140, windowWidth * 0.22))).background(BrowserLayoutRegion(identifier: "radius.verticalTabs")) }
            }
            if !hidden("navigation") {
                if layout.navigation == .bottom { navigation }
                customStrip(.bottom)
            }
            if showTabs && layout.tabs == .bottom { tabs(vertical: false) }
            if !hidden("status") && layout.statusBar { statusBar }
            if let notice = app.notice {
                HStack(spacing: 10) {
                    Image(systemName: "info.circle"); Text(notice).font(.callout).textSelection(.enabled)
                    Spacer(); IconButton(title: "Dismiss message", icon: "xmark") { app.notice = nil }
                }.padding(.horizontal, 14).padding(.vertical, 5).background(.bar)
            }
        }
        .tint(theme.tint).environment(\.browserTheme, theme).environment(\.browserSymbols, app.declarativeDefinition(.icons)?.icons ?? [:]).font(theme.interfaceFont()).preferredColorScheme(theme.scheme).controlSize(theme.controlSize)
        .background(Color(nsColor: .windowBackgroundColor))
        .focusedSceneObject(model)
        .animation(theme.reducedMotion || systemReduceMotion ? nil : .easeOut(duration: 0.16), value: visiblePanel)
        .background(WindowCloseObserver(model: model))
        .background(BrowserLayoutRegion(identifier: "radius.browserLayout", onWindowWidth: { width in if windowWidth != width { windowWidth = width } }))
    }
    private var presentation: some View {
        browserLayout
        .sheet(item: $model.sheet) { sheet in
            Group {
                switch sheet {
                case .modules: ModulesView()
                case .customize: CustomizeView()
                case .settings: SettingsView(model: model)
                case .engines: SettingsView(model: model, initialSection: .engines)
                case .recovery: RecoveryView()
                case .extensions: ChromiumExtensionsView(initialProfileID: model.session.profileID, onOpenSettings: { model.sheet = .engines })
                }
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .sheet(isPresented: Binding(get: { reader != nil }, set: { if !$0 { readerTask?.cancel(); reader = nil } })) {
            VStack(alignment: .leading, spacing: 16) {
                HStack { Text(readerTitle).font(.title2); Spacer(); Button("Done") { readerTask?.cancel(); reader = nil }.keyboardShortcut(.defaultAction) }
                ScrollView { Text(reader ?? "").font(.system(size: 18, design: .serif)).lineSpacing(7).textSelection(.enabled).frame(maxWidth: 660, alignment: .leading).padding(24).frame(maxWidth: .infinity) }
            }.padding(24).frame(width: 760, height: 640).background(Color(nsColor: .windowBackgroundColor))
        }
    }
    private var windowCommands: some View {
        presentation
        .onReceive(NotificationCenter.default.publisher(for: .radiusFocusAddress)) { notification in
            if notification.object as? UUID == model.session.id { focusAddress() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .radiusOpenBrowserWindow)) { notification in
            guard notification.object as? UUID == model.session.id else { return }
            openWindow(id: notification.userInfo?["private"] as? Bool == true ? "private" : "browser")
        }
        .onReceive(NotificationCenter.default.publisher(for: .radiusFind)) { notification in if notification.object as? UUID == model.session.id { findVisible = true; findFocused = true } }
        .onExitCommand { model.exitFocus(); findVisible = false; addressFocused = false; readerTask?.cancel(); reader = nil }
        .onChange(of: app.installedModules) { _, _ in
            if !app.installedModules.contains(where: { $0.id == model.focusProviderID && $0.enabled }) { model.exitFocus() }
            if !app.enabled(.reader) { readerTask?.cancel(); reader = nil }
            captureTask?.cancel()
        }
        .onChange(of: model.session.selectedTabID) { _, _ in captureTask?.cancel(); if layout.sidebarAutoHide == true { model.panel = nil }; findVisible = false; model.addressEditing = addressFocused; readerTask?.cancel(); reader = nil }
    }
    private var readerLifecycle: some View {
        windowCommands
        .onChange(of: model.session.profileID) { _, _ in captureTask?.cancel(); readerTask?.cancel(); reader = nil }
        .onChange(of: model.selectedTab.url) { _, _ in readerTask?.cancel(); reader = nil }
        .onReceive(model.activeWebTab.$navigationRevision.dropFirst()) { _ in captureTask?.cancel(); readerTask?.cancel(); reader = nil }
        .onReceive(model.activeWebTab.objectWillChange) { _ in navigationEpoch &+= 1 }
        .onChange(of: model.sheet) { _, sheet in if sheet != nil { readerTask?.cancel(); reader = nil } }
        .onDisappear { captureTask?.cancel(); readerTask?.cancel(); reader = nil }
    }
    private var content: some View {
        readerLifecycle
        .onChange(of: addressFocused) { _, focused in model.addressEditing = focused }
        .onChange(of: findVisible) { _, visible in if visible { findFocused = true } }
        .onChange(of: app.library.preferences.blockPopups) { _, _ in model.updatePopupPolicy() }
        .onAppear { model.synchronizeSplit() }
        .onChange(of: layout.split) { _, _ in model.synchronizeSplit() }
        .onChange(of: app.previewConfiguration) { _, value in if value == nil { model.synchronizeSplit() } }
    }
    private var navigation: some View {
        HStack(spacing: theme.spacing) {
            componentStrip(.beforeAddress)
            if !usesChromeNavigation {
            HStack(spacing: 6) {
                Image(systemName: model.isPrivate ? "hand.raised" : (model.selectedTab.url?.scheme == "https" ? "lock" : "globe"))
                    .foregroundStyle(.secondary).help(model.isPrivate ? "Private browsing" : (model.selectedTab.url?.scheme == "https" ? "HTTPS connection" : "Website address"))
                TextField("Search or enter website", text: $model.address)
                    .foregroundStyle(Color(nsColor: .textColor)).font(navigationTheme.interfaceFont())
                    .textFieldStyle(.plain).focused($addressFocused).onSubmit { model.addressEditing = false; model.navigate(model.address); addressFocused = false }
                    .accessibilityLabel("Website address or search")
                if model.selectedTab.url.map(AddressResolver.isWebURL) == true && !model.isPrivate {
                    IconButton(title: "Bookmark this page", icon: isBookmarked ? "star.fill" : "star", active: isBookmarked) { model.toggleBookmark() }
                }
            }
            .padding(.horizontal, 10).padding(.vertical, navigationTheme.density == .compact ? 3 : 5)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: navigationTheme.cornerRadius))
            .overlay(RoundedRectangle(cornerRadius: navigationTheme.cornerRadius).stroke(addressFocused ? navigationTheme.tint : .primary.opacity(0.16), lineWidth: addressFocused ? 2 : 1))
            .frame(maxWidth: layout.addressWidth.map { CGFloat(640 * $0) } ?? .infinity)
            } else {
                Text(model.isPrivate ? "Private Chromium" : "Chromium").font(navigationTheme.interfaceFont()).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            componentStrip(.afterAddress)
            browserMenu
        }.padding(.horizontal, 12).padding(.vertical, 6).modifier(ChromeSurface(theme: navigationTheme))
    }
    private var panelMenu: some View {
            Menu {
                ForEach(BrowserPanel.allCases.filter { available($0) }) { panel in
                    Button { model.togglePanel(panel) } label: { Label(panel.label, systemImage: panel.icon) }
                }
            } label: { Image(systemName: "sidebar.left").frame(width: 28, height: 28) }.menuStyle(.borderlessButton).fixedSize().help("Open a sidebar panel")
    }
    private var browserMenu: some View {
        Menu {
            ForEach(Array((app.declarativeDefinition(.menu)?.menu ?? []).enumerated()), id: \.offset) { _, item in
                Button(item.title) { contributedAction(item.action) }
            }
            ForEach(components(in: .overflow)) { item in
                if item.command == .separator { Divider() }
                else { Button(item.command.label) { execute(item.command) }.disabled(!commandAvailable(item.command)) }
            }
            Button("Modules") { model.sheet = .modules }
            Button("Customize") { model.sheet = .customize }
            Button("Settings") { model.sheet = .settings }
            if layout.secondaryPanel != nil && windowWidth < 1100 { Text("Widen this window to show the second sidebar") }
            Button("Chromium extensions…") { model.sheet = .extensions }.disabled(model.isPrivate)
            Menu(hasChromePanes ? "Browsing panes" : "Tabs") {
                Button(hasChromePanes ? "New browsing pane" : "New tab") { model.newTab(); focusAddress() }
                ForEach(model.session.tabs) { tab in Button(tab.title) { model.selectTab(tab.id) } }
            }
            Divider()
            if app.enabled(.reader) { Button(extracting ? "Preparing reader…" : "Reader") { openReader() }.disabled(!model.hasPage || extracting) }
            if app.enabled(.screenshot) { Button(capturing ? "Capturing…" : "Save screenshot…") { capturePage() }.disabled(!model.hasPage || capturing) }
            if app.enabled(.focusMode) { Button("Focus mode") { model.enterFocus() } }
            Button("Find in page…") { findVisible = true }.disabled(!model.hasPage)
            Menu("Split view") {
                Button("Side by side") { model.beginSplit(.sideBySide) }
                Button("Stacked") { model.beginSplit(.stacked) }
                Button("Return to one pane") { model.endSplit() }.disabled(model.session.split == nil)
            }
            Divider()
            Button("New private window") { openWindow(id: "private") }
            Button("Recovery") { model.sheet = .recovery }
        } label: { BrowserSymbol(name: "ellipsis").frame(width: 28, height: 28) }.menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Browser menu")
    }
    private var isBookmarked: Bool { model.bookmarks.contains { $0.url == model.selectedTab.url } }
    private func available(_ panel: BrowserPanel) -> Bool {
        switch panel { case .notes: app.enabled(.notes); case .resources: app.enabled(.resourceMonitor); case .history: !model.isPrivate; default: true }
    }
    private func tabs(vertical: Bool) -> some View {
        Group {
            if vertical {
                VStack(spacing: 6) {
                    HStack { Text(hasChromePanes ? "Browsing panes" : "Tabs").font(.headline); Spacer(); newTabButton }.padding(.horizontal, 12).padding(.top, 12)
                    ScrollView { LazyVStack(spacing: 4) { ForEach(treeTabs ? model.session.visibleTreeTabs : model.session.tabs) { tabRow($0, vertical: true) } }.padding(6) }
                    profileMenu.padding(12)
                }
            } else {
                HStack(spacing: 8) {
                    ScrollView(.horizontal, showsIndicators: false) { HStack(spacing: 4) { ForEach(model.session.tabs) { tabRow($0, vertical: false) } } }
                    newTabButton
                    profileMenu
                }.padding(.horizontal, 12).padding(.vertical, 6)
            }
        }.modifier(ChromeSurface(theme: tabsTheme))
    }
    private func tabRow(_ tab: BrowserTab, vertical: Bool) -> some View {
        let chrome = tab.engineID == .chromium
        let closeLabel = chrome ? "Close browsing pane: \(tab.title)" : "Close \(tab.title)"
        return HStack(spacing: 5) {
            if vertical && treeTabs && model.session.tabs.contains(where: { $0.parentID == tab.id }) {
                Button { model.toggleBranch(tab.id) } label: { Image(systemName: tab.collapsed == true ? "chevron.right" : "chevron.down").font(.caption).frame(width: 18, height: 24) }
                    .buttonStyle(.plain).accessibilityLabel("\(tab.collapsed == true ? "Expand" : "Collapse") \(tab.title)")
            }
            Button { model.selectTab(tab.id) } label: {
                HStack(spacing: 7) {
                    BrowserSymbol(name: tab.pinned ? "pin.fill" : "globe").font(.caption).foregroundStyle(tab.id == model.session.selectedTabID ? Color(nsColor: .secondaryLabelColor) : theme.foreground.opacity(0.75))
                    Text(tab.title).font(tabsTheme.interfaceFont()).foregroundStyle(tab.id == model.session.selectedTabID ? Color(nsColor: .textColor) : (theme.textHex.flatMap(InterfaceColor.init(hex:))?.color ?? Color.primary)).lineLimit(1)
                    if chrome, let count = tab.chromiumPages?.count, count > 1 {
                        Text("\(count) tabs").font(.caption2).foregroundStyle(.secondary).fixedSize()
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).help(tab.title)
            Button { model.closeTab(tab.id) } label: { BrowserSymbol(name: "xmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(tab.id == model.session.selectedTabID ? Color(nsColor: .textColor) : theme.foreground).frame(width: 22, height: 24) }
                .buttonStyle(.plain).help(chrome ? "Close this browsing pane and all its Chrome tabs" : closeLabel).accessibilityLabel(closeLabel)
        }
        .padding(.leading, 10).padding(.trailing, 4).padding(.vertical, tabsTheme.density == .compact ? 2 : 5)
        .frame(width: vertical ? nil : 180)
        .background(tab.id == model.session.selectedTabID ? Color(nsColor: .textBackgroundColor) : Color.clear, in: RoundedRectangle(cornerRadius: tabsTheme.cornerRadius))
        .overlay(RoundedRectangle(cornerRadius: tabsTheme.cornerRadius).stroke(tab.id == model.session.selectedTabID ? Color.primary.opacity(0.18) : .clear))
        .contextMenu {
            Button("\(tab.pinned ? "Unpin" : "Pin") \(chrome ? "pane" : "tab")") { model.pinTab(tab.id) }
            Button("Move earlier") { model.moveTab(tab.id, by: -1) }
            Button("Move later") { model.moveTab(tab.id, by: 1) }
            Button(chrome ? "Open active page in new pane" : "Duplicate tab") { model.newTab(url: tab.url, engine: tab.engineID ?? .webkit) }
                .disabled(chrome && tab.url.map(AddressResolver.isWebURL) != true)
            Menu("Reopen with another engine") {
                ForEach(BrowserEngineID.allCases, id: \.self) { engine in
                    Button(engine.label) { model.reopenTab(tab.id, with: engine) }.disabled(engine == (tab.engineID ?? .webkit))
                }
            }
            if treeTabs {
                Button(hasChromePanes ? "New child pane" : "New child tab") { model.newTab(parentID: tab.id); addressFocused = true }
                Button("Move to top level") { _ = model.session.setParent(tab.id, to: nil) }.disabled(tab.parentID == nil)
                Menu(hasChromePanes ? "Move under pane" : "Move under tab") {
                    ForEach(model.session.tabs.filter { $0.id != tab.id && !model.session.ancestors(of: $0.id).contains(tab.id) }) { parent in
                        Button(parent.title) {
                            if !model.session.setParent(tab.id, to: parent.id) { app.notice = "Tab trees support up to eight levels. Pinned tabs stay at the top level." }
                        }
                    }
                }.disabled(tab.pinned)
            }
            Divider(); Button(chrome ? "Close browsing pane" : "Close tab") { model.closeTab(tab.id) }
        }
        .draggable(tab.id.uuidString)
        .dropDestination(for: String.self) { items, _ in
            guard let value = items.first, let id = UUID(uuidString: value) else { return false }
            return model.moveTab(id, before: tab.id)
        }
        .accessibilityElement(children: .contain).accessibilityValue("\(tab.id == model.session.selectedTabID ? "Selected " : "")\(chrome ? "browsing pane" : "tab")")
        .padding(.leading, vertical && treeTabs ? CGFloat(model.session.ancestors(of: tab.id).count * 10) : 0)
    }
    private var newTabButton: some View { IconButton(title: hasChromePanes ? "New browsing pane" : "New tab", icon: "plus") { model.newTab(); focusAddress() } }
    private var profileMenu: some View {
        Menu {
            ForEach(app.library.profiles) { profile in Button(profile.name) { model.switchProfile(profile.id) } }
            Divider(); Button("Manage profiles") { model.sheet = .settings }
        } label: { Label(model.isPrivate ? "Private" : model.profile.name, systemImage: model.isPrivate ? "hand.raised" : "person.crop.circle").font(.callout).lineLimit(1) }
            .menuStyle(.borderlessButton).fixedSize().help("Browsing profile")
    }
    private var page: some View {
        VStack(spacing: 0) {
            if findVisible {
                HStack {
                    TextField("Find on this page", text: $findText).textFieldStyle(.roundedBorder).focused($findFocused).onSubmit { model.activeWebTab.find(findText) }
                    Button("Previous") { model.activeWebTab.find(findText, backwards: true) }
                    Button("Next") { model.activeWebTab.find(findText) }
                    IconButton(title: "Close find", icon: "xmark") { findVisible = false }
                }.padding(10).background(.bar)
            }
            if let pair = model.session.split, let axis = layout.split {
                if axis == .sideBySide {
                    HSplitView { splitPane(pair.first); splitPane(pair.second) }
                } else { VSplitView { splitPane(pair.first); splitPane(pair.second) } }
            } else {
                BrowserTabContent(tab: model.activeWebTab, hasPage: model.hasPage, onUseWebKit: { model.reopenTab(model.session.selectedTabID, with: .webkit) }) { startPage }
                    .id(ObjectIdentifier(model.activeWebTab))
            }
        }
    }
    private func splitPane(_ id: UUID) -> some View {
        let descriptor = model.session.tabs.first(where: { $0.id == id })
        let selected = id == model.session.selectedTabID
        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button { model.selectTab(id) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: selected ? "circle.inset.filled" : "circle").foregroundStyle(selected ? theme.tint : .secondary)
                        Text(descriptor?.title ?? "New tab").lineLimit(1)
                        Spacer()
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("Select pane: \(descriptor?.title ?? "New tab")")
                IconButton(title: "Return to one pane", icon: "rectangle") { model.selectTab(id); model.endSplit() }
            }.font(.caption).padding(.horizontal, 12).padding(.vertical, 8).background(.bar)
            BrowserTabContent(tab: model.webTab(id), hasPage: descriptor?.url != nil, onUseWebKit: { model.reopenTab(id, with: .webkit) }) {
                VStack(spacing: 14) {
                    Text("New tab").font(.title2)
                    Button("Enter a website…") { model.selectTab(id); addressFocused = true }.buttonStyle(.borderedProminent)
                }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(nsColor: .textBackgroundColor))
            }.id(ObjectIdentifier(model.webTab(id)))
        }.frame(minWidth: 180, minHeight: 120).frame(maxHeight: .infinity)
            .accessibilityElement(children: .contain).accessibilityLabel(selected ? "Active browsing pane" : "Browsing pane")
    }
    private var startPage: some View {
        GeometryReader { viewport in
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(model.isPrivate ? "Private window" : "New tab").font(.system(size: 34, weight: .semibold))
                        Text(model.isPrivate ? "This window won't save tabs or history. Downloads you save stay on disk. Websites and your network can still see your activity." : "Enter a website or search in the address bar. Press ⌘L to focus it.")
                            .font(.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    if !app.library.preferences.completedOnboarding && !model.isPrivate {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Bring your bookmarks").font(.headline)
                            Text("Export an HTML bookmarks file from your current browser, then import it here.").foregroundStyle(.secondary)
                            ViewThatFits(in: .horizontal) {
                                HStack { onboardingActions }.fixedSize()
                                VStack(alignment: .leading, spacing: 8) { onboardingActions }
                            }
                        }.padding(20).background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: theme.cornerRadius))
                    }
                    if !model.bookmarks.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Bookmarks").font(.headline)
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 160))], alignment: .leading, spacing: 12) {
                                ForEach(Array(model.bookmarks.prefix(12))) { bookmark in
                                    Button { model.navigate(bookmark.url.absoluteString) } label: {
                                        HStack(spacing: 10) { Image(systemName: "bookmark"); Text(bookmark.title).lineLimit(1); Spacer() }.padding(12)
                                    }.buttonStyle(.bordered)
                                }
                            }
                        }
                    }
                    ForEach(Array(app.startWidgets.enumerated()), id: \.offset) { _, widget in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(widget.widgetTitle ?? "").font(theme.interfaceFont(17, weight: .semibold))
                            Text(widget.widgetBody ?? "").font(theme.interfaceFont()).foregroundStyle(.secondary).textSelection(.enabled)
                        }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: theme.cornerRadius))
                    }
                    HStack(spacing: 16) {
                        Button("Modules") { model.sheet = .modules }
                        Button("Customize") { model.sheet = .customize }
                        Button("Settings") { model.sheet = .settings }
                    }.buttonStyle(.plain).foregroundStyle(theme.tint)
                }.padding(48).frame(maxWidth: 820).frame(maxWidth: .infinity, minHeight: viewport.size.height, alignment: .center)
                    .background(BrowserLayoutRegion(identifier: "radius.startPageContent"))
            }.background(BrowserLayoutRegion(identifier: "radius.startPageScroll"))
        }.background(Color(nsColor: .textBackgroundColor))
    }
    @ViewBuilder private var onboardingActions: some View {
        Button("Import bookmarks…") { if app.importBookmarks(profileID: model.session.profileID) { app.library.preferences.completedOnboarding = true } }
        Button("Start browsing") { app.library.preferences.completedOnboarding = true; focusAddress() }.buttonStyle(.borderedProminent)
        Button("Set up Chrome extensions") { model.sheet = ChromiumRuntime.shared.isInstalled(in: app.dataDirectory) ? .extensions : .engines }
    }
    private var sidebar: some View {
        SidebarView(model: model, panel: visiblePanel ?? .bookmarks).frame(width: min(layout.sidebarWidth, max(180, windowWidth * 0.24)))
            .modifier(ChromeSurface(theme: sidebarTheme)).overlay(alignment: layout.sidebar == .leading ? .trailing : .leading) { Divider() }
            .background(BrowserLayoutRegion(identifier: "radius.primarySidebar"))
    }
    private var bookmarksBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 16) { ForEach(model.bookmarks) { bookmark in Button(bookmark.title) { model.navigate(bookmark.url.absoluteString) }.buttonStyle(.plain).font(.caption).lineLimit(1) } }
                .padding(.horizontal, 16).padding(.vertical, 8)
        }.modifier(ChromeSurface(theme: theme))
    }
    private var statusBar: some View {
        HStack(spacing: 8) {
            Image(systemName: model.isPrivate ? "hand.raised" : "globe")
            Text("\(model.isPrivate ? "Private" : model.profile.name) · \((model.selectedTab.engineID ?? .webkit).label)")
            Spacer()
            if model.hasPage { ZoomControls(tab: model.activeWebTab) }
        }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 14).padding(.vertical, 6).background(.bar)
    }
    private func focusAddress() { addressFocused = !model.hasPage || !model.activeWebTab.focusAddressBar() }
    private func secondarySidebar(_ panel: BrowserPanel) -> some View {
        SidebarView(model: model, panel: panel, onClose: model.closeSecondarySidebar).frame(width: min(layout.sidebarWidth, max(180, windowWidth * 0.24))).modifier(ChromeSurface(theme: sidebarTheme))
            .background(BrowserLayoutRegion(identifier: "radius.secondarySidebar"))
    }
    private func components(in region: ToolbarRegion) -> [ToolbarComponent] {
        (layout.toolbarComponents ?? ToolbarComponent.browserDefaults).filter {
            $0.region == region && !(usesChromeNavigation && [.back, .forward, .reload, .bookmark].contains($0.command))
        }
    }
    @ViewBuilder private func customStrip(_ region: ToolbarRegion) -> some View {
        if !components(in: region).isEmpty {
            HStack { componentStrip(region); Spacer(minLength: 0) }.padding(.horizontal, 12).padding(.vertical, 4).modifier(ChromeSurface(theme: navigationTheme))
        }
    }
    private func componentStrip(_ region: ToolbarRegion) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: navigationTheme.spacing) {
                ForEach(components(in: region)) { item in
                    if item.command == .separator { Divider().frame(height: 22) }
                    else if item.command == .sidebar { panelMenu }
                    else { IconButton(title: item.command.label, icon: commandIcon(item.command)) { execute(item.command) }.disabled(!commandAvailable(item.command)) }
                }
            }
            Menu {
                ForEach(components(in: region)) { item in
                    if item.command == .separator { Divider() }
                    else if item.command == .sidebar {
                        ForEach(BrowserPanel.allCases.filter { available($0) }) { panel in Button(panel.label) { model.togglePanel(panel) } }
                    } else { Button(item.command.label) { execute(item.command) }.disabled(!commandAvailable(item.command)) }
                }
            } label: { BrowserSymbol(name: "line.3.horizontal").frame(width: 28, height: 28) }.menuStyle(.borderlessButton).fixedSize().accessibilityLabel("\(region.label) controls")
        }.frame(maxWidth: region == .beforeAddress || region == .afterAddress ? 240 : nil, alignment: .leading)
    }
    private func commandAvailable(_ command: ToolbarCommand) -> Bool {
        switch command {
        case .back: return model.activeWebTab.canGoBack
        case .forward: return model.activeWebTab.canGoForward
        case .reload: return model.hasPage
        case .bookmark: return !model.isPrivate && model.selectedTab.url.map(AddressResolver.isWebURL) == true
        case .reader: return app.enabled(.reader) && model.hasPage && !extracting
        case .screenshot: return app.enabled(.screenshot) && model.hasPage && !capturing
        case .focus: return app.enabled(.focusMode)
        default: return true
        }
    }
    private func commandIcon(_ command: ToolbarCommand) -> String {
        switch command {
        case .back: "chevron.left"; case .forward: "chevron.right"; case .reload: model.activeWebTab.loading ? "xmark" : "arrow.clockwise"
        case .newTab: "plus"; case .home: "house"; case .bookmark: isBookmarked ? "star.fill" : "star"; case .sidebar: "sidebar.left"
        case .reader: "doc.plaintext"; case .screenshot: "camera.viewfinder"; case .focus: "viewfinder"; case .downloads: "arrow.down.circle"
        case .modules: "square.grid.2x2"; case .customize: "slider.horizontal.3"; case .settings: "gearshape"; case .separator: "minus"
        }
    }
    private func execute(_ command: ToolbarCommand) {
        guard commandAvailable(command) else { return }
        switch command {
        case .back: model.activeWebTab.goBack()
        case .forward: model.activeWebTab.goForward()
        case .reload: if model.activeWebTab.loading { model.activeWebTab.stop() } else { model.activeWebTab.reload() }
        case .newTab: model.performTabCommand(.new)
        case .home: model.showStartPage(); focusAddress()
        case .bookmark: model.toggleBookmark()
        case .sidebar: model.togglePanel(.bookmarks)
        case .reader: openReader()
        case .screenshot: capturePage()
        case .focus: model.enterFocus()
        case .downloads: model.togglePanel(.downloads)
        case .modules: model.sheet = .modules
        case .customize: model.sheet = .customize
        case .settings: model.sheet = .settings
        case .separator: break
        }
    }
    private func contributedAction(_ action: NativeModuleAction) {
        switch action {
        case .newTab: model.performTabCommand(.new)
        case .bookmarks: model.togglePanel(.bookmarks)
        case .history: if !model.isPrivate { model.togglePanel(.history) }
        case .downloads: model.togglePanel(.downloads)
        case .modules: model.sheet = .modules
        case .customize: model.sheet = .customize
        case .settings: model.sheet = .settings
        case .recovery: model.sheet = .recovery
        }
    }
    private func capturePage() {
        let source = model.activeWebTab
        source.refreshActiveContent()
        let descriptor = model.selectedTab, profileID = model.session.profileID
        let revision = source.navigationRevision, generation = app.resourceWorkerGeneration
        do {
            let specification = try app.pageCaptureSpecification()
            capturing = true
            captureTask = Task {
                defer { capturing = false }
                do {
                    let bytes = try await source.capturePNG()
                    try Task.checkCancellation()
                    guard !model.isClosed, !app.terminating, app.resourceWorkerGeneration == generation,
                          model.session.profileID == profileID, model.selectedTab.id == descriptor.id,
                          model.activeWebTab === source, source.navigationRevision == revision, app.enabled(.screenshot) else { return }
                    app.saveFile(bytes, name: specification.filename, type: .png)
                } catch is CancellationError { }
                catch { if !model.isClosed, app.resourceWorkerGeneration == generation, source.navigationRevision == revision { app.notice = error.localizedDescription } }
            }
        } catch { app.notice = error.localizedDescription }
    }
    private func openReader() {
        let source = model.activeWebTab
        source.refreshActiveContent()
        let descriptor = model.selectedTab, profileID = model.session.profileID
        let revision = source.navigationRevision
        extracting = true
        readerTask = Task {
            defer { extracting = false }
            do {
                let text = try await app.readerText(from: source)
                try Task.checkCancellation()
                guard model.selectedTab.id == descriptor.id, model.selectedTab.url == descriptor.url,
                      model.session.profileID == profileID, model.activeWebTab === source, source.navigationRevision == revision else { return }
                readerTitle = descriptor.title; reader = text
            }
            catch is CancellationError { }
            catch {
                guard model.selectedTab.id == descriptor.id, model.selectedTab.url == descriptor.url,
                      model.session.profileID == profileID, model.activeWebTab === source, source.navigationRevision == revision else { return }
                app.notice = error.localizedDescription
            }
        }
    }
}
struct BrowserTabContent<Placeholder: View>: View {
    @ObservedObject var tab: BrowserEngineTab
    var hasPage: Bool
    var onUseWebKit: () -> Void
    @ViewBuilder var placeholder: () -> Placeholder
    var body: some View {
        if hasPage || tab.errorMessage != nil { BrowserPage(tab: tab, onUseWebKit: onUseWebKit) }
        else { placeholder() }
    }
}
struct BrowserPage: View {
    @ObservedObject var tab: BrowserEngineTab
    var onUseWebKit: (() -> Void)?
    var body: some View {
        VStack(spacing: 0) {
            if tab.loading { ProgressView(value: tab.progress).progressViewStyle(.linear).frame(height: 2) }
            if tab.hasNativeNavigationChrome {
                if let error = tab.errorMessage {
                    HStack(spacing: 12) {
                        Text(error).font(.callout).lineLimit(3).help(error).frame(maxWidth: .infinity, alignment: .leading)
                        Button("Reload page") { tab.reload() }.buttonStyle(.bordered)
                        if let onUseWebKit { Button("Reopen in WebKit") { onUseWebKit() }.buttonStyle(.bordered) }
                    }.padding(.horizontal, 16).padding(.vertical, 10)
                }
                // Keep Chrome's tab strip and sibling pages accessible on error.
                WebViewHost(tab: tab)
            } else if let error = tab.errorMessage {
                VStack(spacing: 16) {
                    EmptyPanel(title: "This page needs attention", icon: "exclamationmark.circle", detail: error)
                    Button("Reload page") { tab.reload() }.buttonStyle(.borderedProminent).padding(.bottom, 32)
                    if tab.engineID == .chromium, let onUseWebKit { Button("Reopen in WebKit") { onUseWebKit() }.padding(.bottom, 24) }
                }
            } else { WebViewHost(tab: tab) }
        }
    }
}
struct WindowCloseObserver: NSViewRepresentable {
    let model: BrowserModel
    func makeNSView(context: Context) -> ObserverView { ObserverView(model: model) }
    func updateNSView(_ nsView: ObserverView, context: Context) {}
    @MainActor final class ObserverView: NSView {
        let model: BrowserModel
        private var observation: NotificationObservation?
        private var focusObservation: NotificationObservation?
        private var delegateProxy: WindowDelegateProxy?
        init(model: BrowserModel) { self.model = model; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("Not used") }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, observation == nil else { return }
            window.title = model.isPrivate ? "Radius — Private" : "Radius"
            window.isRestorable = false
            let proxy = WindowDelegateProxy(original: window.delegate, model: model)
            delegateProxy = proxy; window.delegate = proxy
            focusObservation = NotificationObservation(NotificationCenter.default.addObserver(forName: NSWindow.didUpdateNotification, object: window, queue: .main) { [weak model, weak window] _ in
                MainActor.assumeIsolated {
                    guard let window, window.isKeyWindow else { return }
                    model?.updateFocusedTab(window.firstResponder)
                }
            })
            observation = NotificationObservation(NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [model] _ in
                Task { @MainActor in model.closeWindow() }
            })
        }
    }
}
extension Notification.Name {
    static let radiusFocusAddress = Notification.Name("radius.focusAddress")
    static let radiusFind = Notification.Name("radius.find")
    static let radiusOpenBrowserWindow = Notification.Name("radius.openBrowserWindow")
    static let radiusProfileDeleted = Notification.Name("radius.profileDeleted")
}

struct ZoomControls: View {
    @ObservedObject var tab: BrowserEngineTab
    var body: some View {
        HStack(spacing: 8) {
            Button("−") { tab.setZoom(tab.zoom - 0.1) }.buttonStyle(.plain).accessibilityLabel("Zoom out")
            Button("\(Int((tab.zoom * 100).rounded()))%") { tab.setZoom(1) }.buttonStyle(.plain).help("Reset zoom")
            Button("+") { tab.setZoom(tab.zoom + 0.1) }.buttonStyle(.plain).accessibilityLabel("Zoom in")
        }
    }
}

/// Native window notifications provide the actual content width even when
/// SwiftUI preference propagation is interrupted by presentation modifiers.
private struct BrowserLayoutRegion: NSViewRepresentable {
    let identifier: String
    var onWindowWidth: (@MainActor (CGFloat) -> Void)? = nil
    func makeNSView(context: Context) -> RegionView {
        let view = RegionView(); view.identifier = NSUserInterfaceItemIdentifier(identifier)
        view.onWindowWidth = onWindowWidth; return view
    }
    func updateNSView(_ view: RegionView, context: Context) {
        view.identifier = NSUserInterfaceItemIdentifier(identifier); view.onWindowWidth = onWindowWidth
    }
    @MainActor final class RegionView: NSView {
        var onWindowWidth: (@MainActor (CGFloat) -> Void)?
        private var resizeObservation: NotificationObservation?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow(); resizeObservation = nil
            guard let window, onWindowWidth != nil else { return }
            resizeObservation = NotificationObservation(NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.publishWindowWidth() }
            })
            // Attaching an AppKit view can happen during a SwiftUI update.
            Task { @MainActor [weak self] in self?.publishWindowWidth() }
        }
        private func publishWindowWidth() {
            guard let width = window?.contentView?.bounds.width, width.isFinite, width > 0 else { return }
            onWindowWidth?(width)
        }
    }
}
