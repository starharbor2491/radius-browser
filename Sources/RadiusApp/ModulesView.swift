// SPDX-License-Identifier: MPL-2.0
import SwiftUI
import RadiusCore

struct ModulesView: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var section = Section.discover
    @State private var query = ""
    enum Section: String, CaseIterable { case discover = "Discover", installed = "Installed", updates = "Updates" }
    private var updates: [ModuleManifest] {
        app.catalog.filter { manifest in app.installedModules.contains { $0.id == manifest.id && $0.manifest.version < manifest.version } }
    }
    private var listings: [ModuleManifest] {
        let list = switch section { case .discover: app.catalog; case .installed: app.installedModules.map(\.manifest); case .updates: updates }
        return list.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.summary.localizedCaseInsensitiveContains(query) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SheetHeader(title: "Modules", subtitle: "Choose what your browser contains.")
            HStack {
                Picker("Module catalog", selection: $section) { ForEach(Section.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented).labelsHidden().frame(width: 360)
                Spacer(); TextField("Search modules", text: $query).textFieldStyle(.roundedBorder).frame(width: 220)
            }
            ScrollView {
                LazyVStack(spacing: 12) {
                    if listings.isEmpty {
                        EmptyPanel(title: section == .updates ? updates.isEmpty ? "You're up to date" : "No matching updates" : "No modules found", icon: section == .updates && updates.isEmpty ? "checkmark.circle" : "shippingbox", detail: section == .updates && updates.isEmpty ? "Updates are checked against the bundled and added community catalogs. Refresh a community catalog to discover newer data packages." : "Try another search or discover a feature to install.").frame(height: 220)
                    }
                    ForEach(listings) { manifest in
                        ModuleCard(manifest: manifest, installed: app.installedModules.first { $0.id == manifest.id })
                    }
                }
            }
            Text("Installed packages contain their native worker, behavior program, or interface definition. Uninstall deletes that payload; retained data stays on this Mac.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Menu("Add modules") {
                    Button("Import local package…") { app.importModule() }
                    Button("Import community catalog…") { app.importCatalog() }
                    Button("Add catalog from HTTPS URL…") { app.addCatalogFromURL() }
                }
                if !app.communityCatalogNames.isEmpty {
                    Menu("Community catalogs") {
                        ForEach(app.communityCatalogNames, id: \.self) { name in
                            Button("Refresh \(name)…") { app.refreshCommunityCatalog(named: name) }
                            Button("Remove \(name)…") { app.removeCatalog(named: name) }
                        }
                    }
                }
                Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }.padding(28).frame(width: 760, height: 620)
    }
}
struct ModuleCard: View {
    @EnvironmentObject private var app: AppState
    let manifest: ModuleManifest
    let installed: InstalledModule?
    @State private var showingSettings = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: icon).font(.system(size: 22)).frame(width: 48, height: 48).background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 5) {
                    HStack { Text(manifest.name).font(.headline); Text("v\(manifest.version)").font(.caption).foregroundStyle(.secondary) }
                    Text(manifest.summary).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    HStack { Text(manifest.publisher); Text(packageKind); Link("Source", destination: manifest.source) }.font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let installed {
                    if manifest.version > installed.manifest.version { Button("Update") { app.install(manifest.id) } }
                    else { Button(installed.enabled ? manifest.capability == .tabSystem ? "Replace…" : "Disable" : enableLabel) { app.toggleModule(installed) } }
                    if !(installed.manifest.settings ?? []).isEmpty { Button("Settings") { showingSettings = true }.popover(isPresented: $showingSettings) { ModuleSettingsView(manifest: installed.manifest) } }
                    Menu {
                        if manifest.runtime != nil { Button("Reinstall package…") { app.reinstallWorker(installed) } }
                        Button("Uninstall…", role: .destructive) { app.uninstall(installed) }
                    } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize()
                } else { Button("Install") { app.install(manifest.id) }.buttonStyle(.borderedProminent) }
            }
            HStack(spacing: 8) {
                Image(systemName: manifest.capability.permission == nil ? "checkmark.shield" : "hand.raised")
                Text(manifest.capability.permission ?? "No website or system permissions")
                Spacer()
                if let installed { Text(ByteCountFormatter.string(fromByteCount: Int64(installed.diskBytes), countStyle: .file)) }
            }.font(.caption).foregroundStyle(.secondary)
            HStack {
                Text("No restart required")
                if let checksum = installed?.payloadSHA256 { Text("· SHA-256 " + String(checksum.prefix(12))).textSelection(.enabled) }
                Spacer()
                Text(app.bundledModuleIDs.contains(manifest.id) ? "Official bundled package" : "Publisher unverified")
            }.font(.caption).foregroundStyle(.secondary)
            if !manifest.dependencies.isEmpty { Text("Requires: " + manifest.dependencies.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary) }
            if installed != nil && (manifest.capability == .theme || manifest.capability == .layout) {
                Text(manifest.capability == .theme ? "Disabling or uninstalling keeps the applied appearance. Choose another theme or restore defaults in Customize to change it." : "Disabling or uninstalling keeps the applied arrangement. Choose another layout or restore defaults in Customize to change it.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if isLegacyReader {
                HStack {
                    Text("This legacy descriptor no longer provides Reader. Install or update the removable Reader package.")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    if let bundled = app.catalog.first(where: { $0.runtime == .nativeReaderWorker }) {
                        if let current = app.installedModules.first(where: { $0.id == bundled.id }) {
                            if current.manifest.version < bundled.version { Button("Update Reader") { app.install(bundled.id) } }
                            else if !current.enabled { Button("Enable Reader") { app.toggleModule(current) } }
                        } else { Button("Install Reader") { app.install(bundled.id) } }
                    }
                }.font(.caption)
            }
            if manifest.runtime?.isNative == true {
                Text(manifest.runtime == .nativeReaderWorker ? "Trusted first-party native code · Runs once per extraction, then exits · Same macOS user access as Radius" : "Trusted first-party native code · Same macOS user access as Radius · Runs only while its panel is open")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.padding(16).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(.primary.opacity(0.1)))
    }
    private var isLegacyReader: Bool { manifest.capability == .reader && manifest.runtime == nil }
    private var packageKind: String {
        if isLegacyReader { return "· Legacy Reader descriptor" }
        switch manifest.runtime {
        case .nativeReaderWorker, .nativeResourceWorker: return "· Removable native worker"
        case .behaviorProgram: return "· Constrained behavior program"
        case .declarative: return "· Declarative interface package"
        case nil: return "· Legacy descriptor — update required"
        }
    }
    private var icon: String {
        switch manifest.capability { case .resourceMonitor: "gauge.with.dots.needle.33percent"; case .notes: "note.text"; case .reader: "doc.plaintext"; case .screenshot: "camera.viewfinder"; case .focusMode: "viewfinder"; case .tabSystem: "rectangle.stack"; case .theme: "paintpalette"; case .layout: "rectangle.split.3x1"; case .icons: "square.grid.2x2"; case .menu: "line.3.horizontal"; case .startWidget: "sparkle" }
    }
    private var enableLabel: String {
        manifest.capability.isExclusive && app.installedModules.contains { $0.enabled && $0.manifest.capability == manifest.capability && $0.id != manifest.id } ? "Replace current" : "Enable"
    }
}
