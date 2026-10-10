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
        .task {
            if !app.ready { await app.load() }
            if app.ready && (model == nil || model?.isClosed == true) { createModel() }
        }
        .onOpenURL { url in
            guard AddressResolver.isWebURL(url) else { return }
            if let model, !model.isClosed { model.newTab(url: url) }
            else { pendingURLs.append(url); if app.ready { createModel() } }
        }
        .onChange(of: app.ready) { _, ready in
            if ready && model == nil { createModel() }
        }
    }
    private func createModel() {
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
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    private var layout: BrowserLayout { app.configuration.layout }
    private var theme: Theme { app.configuration.theme }
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
            if !model.focusMode {
                if layout.tabs == .top { tabs(vertical: false) }
                if layout.navigation == .top { navigation }
                if layout.bookmarksBar { bookmarksBar }
            }
            HStack(spacing: 0) {
                if !model.focusMode && layout.tabs == .leading { tabs(vertical: true).frame(width: 190) }
                if !model.focusMode && layout.sidebar == .leading && visiblePanel != nil { sidebar }
                page.frame(maxWidth: .infinity, maxHeight: .infinity)
                if !model.focusMode && layout.sidebar == .trailing && visiblePanel != nil { sidebar }
                if !model.focusMode && layout.tabs == .trailing { tabs(vertical: true).frame(width: 190) }
            }
            if !model.focusMode {
                if layout.navigation == .bottom { navigation }
                if layout.tabs == .bottom { tabs(vertical: false) }
                if layout.statusBar { statusBar }
            }
            if let notice = app.notice {
                HStack(spacing: 10) {
                    Image(systemName: "info.circle"); Text(notice).font(.callout).textSelection(.enabled)
                    Spacer(); IconButton(title: "Dismiss message", icon: "xmark") { app.notice = nil }
                }.padding(.horizontal, 14).padding(.vertical, 5).background(.bar)
            }
        }
        .tint(theme.accent.color).preferredColorScheme(theme.scheme).controlSize(theme.controlSize)
        .background(Color(nsColor: .windowBackgroundColor))
        .focusedSceneObject(model)
        .animation(theme.reducedMotion || systemReduceMotion ? nil : .easeOut(duration: 0.16), value: visiblePanel)
        .background(WindowCloseObserver(model: model))
    }
    private var presentation: some View {
        browserLayout
        .sheet(item: $model.sheet) { sheet in
            Group {
                switch sheet {
                case .modules: ModulesView()
                case .customize: CustomizeView()
                case .settings: SettingsView(model: model)
                case .recovery: RecoveryView()
                case .extensions: ChromiumExtensionsView()
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
            if notification.object as? UUID == model.session.id { addressFocused = !model.activeWebTab.focusAddressBar() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .radiusOpenBrowserWindow)) { notification in
            guard notification.object as? UUID == model.session.id else { return }
            openWindow(id: notification.userInfo?["private"] as? Bool == true ? "private" : "browser")
        }
        .onReceive(NotificationCenter.default.publisher(for: .radiusFind)) { notification in if notification.object as? UUID == model.session.id { findVisible = true; findFocused = true } }
        .onExitCommand { model.focusMode = false; findVisible = false; addressFocused = false; readerTask?.cancel(); reader = nil }
        .onChange(of: app.installedModules) { _, _ in
            if !app.enabled(.focusMode) { model.focusMode = false }
            if !app.enabled(.reader) { readerTask?.cancel(); reader = nil }
        }
        .onChange(of: model.session.selectedTabID) { _, _ in findVisible = false; model.addressEditing = addressFocused; readerTask?.cancel(); reader = nil }
    }
    private var readerLifecycle: some View {
        windowCommands
        .onChange(of: model.session.profileID) { _, _ in readerTask?.cancel(); reader = nil }
        .onChange(of: model.selectedTab.url) { _, _ in readerTask?.cancel(); reader = nil }
        .onReceive(model.activeWebTab.$navigationRevision.dropFirst()) { _ in readerTask?.cancel(); reader = nil }
        .onChange(of: model.sheet) { _, sheet in if sheet != nil { readerTask?.cancel(); reader = nil } }
        .onDisappear { readerTask?.cancel(); reader = nil }
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
            navigationButtons
            HStack(spacing: 6) {
                Image(systemName: model.isPrivate ? "hand.raised" : (model.selectedTab.url?.scheme == "https" ? "lock" : "globe"))
                    .foregroundStyle(.secondary).help(model.isPrivate ? "Private browsing" : (model.selectedTab.url?.scheme == "https" ? "HTTPS connection" : "Website address"))
                TextField("Search or enter website", text: $model.address)
                    .textFieldStyle(.plain).focused($addressFocused).onSubmit { model.addressEditing = false; model.navigate(model.address); addressFocused = false }
                    .accessibilityLabel("Website address or search")
                if model.selectedTab.url.map(AddressResolver.isWebURL) == true && !model.isPrivate {
                    IconButton(title: "Bookmark this page", icon: isBookmarked ? "star.fill" : "star", active: isBookmarked) { model.toggleBookmark() }
                }
            }
            .padding(.horizontal, 10).padding(.vertical, theme.density == .compact ? 3 : 5)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: theme.cornerRadius))
            .overlay(RoundedRectangle(cornerRadius: theme.cornerRadius).stroke(addressFocused ? Color.accentColor : .primary.opacity(0.16), lineWidth: addressFocused ? 2 : 1))
            Menu {
                ForEach(BrowserPanel.allCases.filter { available($0) }) { panel in
                    Button { model.togglePanel(panel) } label: { Label(panel.label, systemImage: panel.icon) }
                }
            } label: { Image(systemName: "sidebar.left").frame(width: 28, height: 28) }.menuStyle(.borderlessButton).fixedSize().help("Open a sidebar panel")
            Menu {
                Button("Modules") { model.sheet = .modules }
                Button("Customize") { model.sheet = .customize }
                Button("Settings") { model.sheet = .settings }
                Divider()
                if app.enabled(.reader) { Button(extracting ? "Preparing reader…" : "Reader") { openReader() }.disabled(!model.hasPage || extracting) }
                if app.enabled(.screenshot) { Button("Save screenshot…") { model.activeWebTab.saveScreenshot(app: app) }.disabled(!model.hasPage) }
                if app.enabled(.focusMode) { Button("Focus mode") { model.focusMode = true } }
                Button("Find in page…") { findVisible = true }.disabled(!model.hasPage)
                Menu("Split view") {
                    Button("Side by side") { model.beginSplit(.sideBySide) }
                    Button("Stacked") { model.beginSplit(.stacked) }
                    Button("Return to one pane") { model.endSplit() }.disabled(model.session.split == nil)
                }
                Divider()
                Button("New private window") { openWindow(id: "private") }
                Button("Recovery") { model.sheet = .recovery }
            } label: { Image(systemName: "ellipsis").frame(width: 28, height: 28) }.menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Browser menu")
        }.padding(.horizontal, 12).padding(.vertical, 6).modifier(ChromeSurface(theme: theme))
    }
    private var navigationButtons: some View { NavigationButtons(tab: model.activeWebTab, hasPage: model.hasPage) }
    private var isBookmarked: Bool { model.bookmarks.contains { $0.url == model.selectedTab.url } }
    private func available(_ panel: BrowserPanel) -> Bool {
        switch panel { case .notes: app.enabled(.notes); case .resources: app.enabled(.resourceMonitor); case .history: !model.isPrivate; default: true }
    }
    private func tabs(vertical: Bool) -> some View {
        Group {
            if vertical {
                VStack(spacing: 6) {
                    HStack { Text("Tabs").font(.headline); Spacer(); newTabButton }.padding(.horizontal, 12).padding(.top, 12)
                    ScrollView { LazyVStack(spacing: 4) { ForEach(layout.treeTabs == true ? model.session.visibleTreeTabs : model.session.tabs) { tabRow($0, vertical: true) } }.padding(6) }
                    profileMenu.padding(12)
                }
            } else {
                HStack(spacing: 8) {
                    ScrollView(.horizontal, showsIndicators: false) { HStack(spacing: 4) { ForEach(model.session.tabs) { tabRow($0, vertical: false) } } }
                    newTabButton
                    profileMenu
                }.padding(.horizontal, 12).padding(.vertical, 6)
            }
        }.modifier(ChromeSurface(theme: theme))
    }
    private func tabRow(_ tab: BrowserTab, vertical: Bool) -> some View {
        HStack(spacing: 5) {
            if vertical && layout.treeTabs == true && model.session.tabs.contains(where: { $0.parentID == tab.id }) {
                Button { model.toggleBranch(tab.id) } label: { Image(systemName: tab.collapsed == true ? "chevron.right" : "chevron.down").font(.caption).frame(width: 18, height: 24) }
                    .buttonStyle(.plain).accessibilityLabel("\(tab.collapsed == true ? "Expand" : "Collapse") \(tab.title)")
            }
            Button { model.selectTab(tab.id) } label: {
                HStack(spacing: 7) {
                    Image(systemName: tab.pinned ? "pin.fill" : "globe").font(.caption).foregroundStyle(.secondary)
                    Text(tab.title).font(.callout).lineLimit(1)
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).help(tab.title)
            Button { model.closeTab(tab.id) } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).frame(width: 22, height: 24) }
                .buttonStyle(.plain).help("Close \(tab.title)").accessibilityLabel("Close \(tab.title)")
        }
        .padding(.leading, 10).padding(.trailing, 4).padding(.vertical, theme.density == .compact ? 2 : 5)
        .frame(width: vertical ? nil : 180)
        .background(tab.id == model.session.selectedTabID ? Color(nsColor: .textBackgroundColor) : Color.clear, in: RoundedRectangle(cornerRadius: theme.cornerRadius))
        .overlay(RoundedRectangle(cornerRadius: theme.cornerRadius).stroke(tab.id == model.session.selectedTabID ? Color.primary.opacity(0.18) : .clear))
        .contextMenu {
            Button(tab.pinned ? "Unpin tab" : "Pin tab") { model.pinTab(tab.id) }
            Button("Move earlier") { model.moveTab(tab.id, by: -1) }
            Button("Move later") { model.moveTab(tab.id, by: 1) }
            Button("Duplicate tab") { model.newTab(url: tab.url, engine: tab.engineID ?? .webkit) }
            Menu("Reopen with another engine") {
                ForEach(BrowserEngineID.allCases, id: \.self) { engine in
                    Button(engine.label) { model.reopenTab(tab.id, with: engine) }.disabled(engine == (tab.engineID ?? .webkit))
                }
            }
            if layout.treeTabs == true {
                Button("New child tab") { model.newTab(parentID: tab.id); addressFocused = true }
                Button("Move to top level") { _ = model.session.setParent(tab.id, to: nil) }.disabled(tab.parentID == nil)
                Menu("Move under tab") {
                    ForEach(model.session.tabs.filter { $0.id != tab.id && !model.session.ancestors(of: $0.id).contains(tab.id) }) { parent in
                        Button(parent.title) {
                            if !model.session.setParent(tab.id, to: parent.id) { app.notice = "Tab trees support up to eight levels. Pinned tabs stay at the top level." }
                        }
                    }
                }.disabled(tab.pinned)
            }
            Divider(); Button("Close tab") { model.closeTab(tab.id) }
        }
        .draggable(tab.id.uuidString)
        .dropDestination(for: String.self) { items, _ in
            guard let value = items.first, let id = UUID(uuidString: value) else { return false }
            return model.moveTab(id, before: tab.id)
        }
        .accessibilityElement(children: .contain).accessibilityValue(tab.id == model.session.selectedTabID ? "Selected tab" : "Tab")
        .padding(.leading, vertical && layout.treeTabs == true ? CGFloat(model.session.ancestors(of: tab.id).count * 10) : 0)
    }
    private var newTabButton: some View { IconButton(title: "New tab", icon: "plus") { model.newTab(); addressFocused = true } }
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
        .overlay(alignment: .topTrailing) {
            if model.focusMode { Button("Exit focus  esc") { model.focusMode = false }.padding(10).background(.regularMaterial, in: Capsule()).padding(12) }
        }
    }
    private func splitPane(_ id: UUID) -> some View {
        let descriptor = model.session.tabs.first(where: { $0.id == id })
        let selected = id == model.session.selectedTabID
        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button { model.selectTab(id) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: selected ? "circle.inset.filled" : "circle").foregroundStyle(selected ? theme.accent.color : .secondary)
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
                    HStack {
                        Button("Import bookmarks…") { if app.importBookmarks(profileID: model.session.profileID) { app.library.preferences.completedOnboarding = true } }
                        Button("Start browsing") { app.library.preferences.completedOnboarding = true; addressFocused = true }.buttonStyle(.borderedProminent)
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
            HStack(spacing: 16) {
                Button("Modules") { model.sheet = .modules }
                Button("Customize") { model.sheet = .customize }
                Button("Settings") { model.sheet = .settings }
            }.buttonStyle(.plain).foregroundStyle(Color.accentColor)
        }.padding(48).frame(maxWidth: 820).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .background(Color(nsColor: .textBackgroundColor))
    }
    private var sidebar: some View {
        SidebarView(model: model, panel: visiblePanel ?? .bookmarks).frame(width: layout.sidebarWidth)
            .background(Color(nsColor: .windowBackgroundColor)).overlay(alignment: layout.sidebar == .leading ? .trailing : .leading) { Divider() }
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
    private func openReader() {
        let source = model.activeWebTab, descriptor = model.selectedTab, profileID = model.session.profileID
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
            if let error = tab.errorMessage {
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
                MainActor.assumeIsolated { model?.updateFocusedTab(window?.firstResponder) }
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

struct NavigationButtons: View {
    @ObservedObject var tab: BrowserEngineTab
    let hasPage: Bool
    var body: some View {
        HStack(spacing: 2) {
            IconButton(title: "Back", icon: "chevron.left") { tab.goBack() }.disabled(!tab.canGoBack)
            IconButton(title: "Forward", icon: "chevron.right") { tab.goForward() }.disabled(!tab.canGoForward)
            IconButton(title: tab.loading ? "Stop loading" : "Reload", icon: tab.loading ? "xmark" : "arrow.clockwise") {
                if tab.loading { tab.stop() } else { tab.reload() }
            }.disabled(!hasPage)
        }
    }
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
