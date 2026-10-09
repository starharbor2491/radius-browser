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
                        EmptyPanel(title: section == .updates ? "You're up to date" : "No modules found", icon: section == .updates ? "checkmark.circle" : "shippingbox", detail: section == .updates ? "This build checks for newer versions bundled with Radius. There is no remote update service yet." : "Try another search or discover a feature to install.").frame(height: 220)
                    }
                    ForEach(listings) { manifest in
                        ModuleCard(manifest: manifest, installed: app.installedModules.first { $0.id == manifest.id })
                    }
                }
            }
            Text("Packages control built-in features. Removing a package stops its feature; the implementation remains in Radius.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack { Button("Import local module…") { app.importModule() }; Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }.padding(28).frame(width: 760, height: 620)
    }
}
struct ModuleCard: View {
    @EnvironmentObject private var app: AppState
    let manifest: ModuleManifest
    let installed: InstalledModule?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: icon).font(.system(size: 22)).frame(width: 48, height: 48).background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 5) {
                    HStack { Text(manifest.name).font(.headline); Text("v\(manifest.version)").font(.caption).foregroundStyle(.secondary) }
                    Text(manifest.summary).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    HStack { Text(manifest.publisher); Text("· Native shell"); Link("Source", destination: manifest.source) }.font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let installed {
                    if manifest.version > installed.manifest.version { Button("Update") { app.install(manifest.id) } }
                    else { Button(installed.enabled ? "Disable" : "Enable") { app.toggleModule(installed) } }
                    Menu { Button("Uninstall…", role: .destructive) { app.uninstall(installed) } } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize()
                } else { Button("Install") { app.install(manifest.id) }.buttonStyle(.borderedProminent) }
            }
            HStack(spacing: 8) {
                Image(systemName: manifest.capability.permission == nil ? "checkmark.shield" : "hand.raised")
                Text(manifest.capability.permission ?? "No website or system permissions")
                Spacer()
                if let installed { Text(ByteCountFormatter.string(fromByteCount: Int64(installed.diskBytes), countStyle: .file)) }
            }.font(.caption).foregroundStyle(.secondary)
            Text("No restart required").font(.caption).foregroundStyle(.secondary)
        }.padding(16).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(.primary.opacity(0.1)))
    }
    private var icon: String {
        switch manifest.capability { case .resourceMonitor: "gauge.with.dots.needle.33percent"; case .notes: "note.text"; case .reader: "doc.plaintext"; case .screenshot: "camera.viewfinder"; case .focusMode: "viewfinder" }
    }
}
