// SPDX-License-Identifier: MPL-2.0
import AppKit
import Foundation
import RadiusCore

@MainActor
extension AppState {
    /// Application updates can change a worker's code signature without changing
    /// its manifest version. Refresh only already installed official native roles;
    /// removed packages and user activation choices survive the application update.
    func refreshBundledNativePackages() throws {
        guard let repository else { return }
        for current in installedModules where current.manifest.runtime?.isNative == true {
            guard bundledModuleIDs.contains(current.id), let factory = catalog.first(where: { $0.id == current.id }),
                  let trusted = modulePayloads[current.id], current.manifest.version <= factory.version,
                  current.manifest.runtime == factory.runtime, current.manifest.capability == factory.capability,
                  current.manifest.publisher == factory.publisher, current.manifest.source == factory.source,
                  current.manifest.dependencies == factory.dependencies,
                  current.manifest.dependencyVersions == factory.dependencyVersions,
                  current.manifest.settings == factory.settings else { continue }
            let existing: Data?
            if let url = try? repository.workerURL(for: current.id, requireEnabled: false) {
                existing = try? readModuleFile(url, limit: 8 * 1024 * 1024)
            } else { existing = nil }
            if current.manifest != factory || existing != trusted {
                ResourceWorker.stopAll(moduleID: current.id); cancelReaderRequests(moduleID: current.id)
                try repository.install(factory, enabled: current.enabled, payload: trusted)
            }
        }
        installedModules = try repository.installed()
    }
    func behaviorResult(_ capability: ModuleCapability, event: String, input: [String: ModuleValue] = [:]) throws -> [String: ModuleValue] {
        guard !terminating, let repository,
              let module = installedModules.first(where: { $0.enabled && $0.manifest.capability == capability && $0.manifest.runtime == .behaviorProgram }) else {
            throw ValidationError("Install and enable this feature's behavior package in Modules.")
        }
        let settings = try repository.settings(for: module.id)
        let values = settings.merging(input) { _, supplied in supplied }
        return try repository.behaviorProgram(for: module.id).run(event, input: values)
    }
    func declarativeDefinition(_ capability: ModuleCapability) -> ModuleDefinition? {
        guard let repository, let module = installedModules.first(where: {
            $0.enabled && $0.manifest.capability == capability && $0.manifest.runtime == .declarative
        }) else { return nil }
        guard let definition = try? repository.definition(for: module.id), (try? validateDefinitionForPlatform(definition)) != nil else { return nil }
        return definition
    }
    var startWidgets: [ModuleDefinition] {
        guard let repository else { return [] }
        return installedModules.filter { $0.enabled && $0.manifest.capability == .startWidget && $0.manifest.runtime == .declarative }
            .compactMap { try? repository.definition(for: $0.id) }
    }
    func requestedFocusPresentation() throws -> (moduleID: String, hiddenComponents: Set<String>) {
        let output = try behaviorResult(.focusMode, event: "enter")
        guard let active = output["active"]?.bool, let components = output["hiddenComponents"]?.array,
              components.allSatisfy({ $0.string != nil }), let module = installedModules.first(where: { $0.enabled && $0.manifest.capability == .focusMode && $0.manifest.runtime == .behaviorProgram }) else { throw ValidationError("Focus Mode returned an invalid transition.") }
        let names = Set(components.compactMap(\.string))
        guard names.isSubset(of: ["tabs", "navigation", "sidebar", "bookmarks", "status"]), names.count <= 5 else { throw ValidationError("Focus Mode requested unsupported interface components.") }
        return (module.id, active ? names : [])
    }
    func pageCaptureSpecification() throws -> (filename: String, visibleOnly: Bool) {
        let values = try behaviorResult(.screenshot, event: "prepare")
        guard values["format"]?.string == "png", let name = values["filename"]?.string,
              let visibleOnly = values["visibleOnly"]?.bool, visibleOnly else { throw ValidationError("This Page Capture package requested an unsupported format or capture area.") }
        let cleaned = name.filter { !"/\\:\0\r\n".contains($0) }
        return (cleaned.isEmpty ? "Page Capture.png" : String(cleaned.prefix(100)) + ".png", visibleOnly)
    }
    func createModuleNote(profileID: UUID) throws -> UUID {
        guard library.profiles.contains(where: { $0.id == profileID }) else { throw ValidationError("This profile no longer exists.") }
        let values = try behaviorResult(.notes, event: "create")
        guard let title = values["title"]?.string, let text = values["text"]?.string,
              title.count <= 100, text.count <= 200_000 else { throw ValidationError("The Notes package returned invalid note fields.") }
        let note = Note(profileID: profileID, title: title, text: text)
        library.notes.append(note); return note.id
    }
    func updateModuleNote(id: UUID, profileID: UUID, field: String, value: String) throws {
        guard ["title", "text"].contains(field), let index = library.notes.firstIndex(where: { $0.id == id && $0.profileID == profileID }) else { throw ValidationError("This note no longer exists in this profile.") }
        let result = try behaviorResult(.notes, event: "update", input: ["field": .string(field), "value": .string(value)])
        guard let output = result["value"]?.string, output.count <= (field == "title" ? 100 : 200_000) else { throw ValidationError("The Notes package returned an oversized field.") }
        if field == "title" { library.notes[index].title = output }
        else { library.notes[index].text = output }
        library.notes[index].modifiedAt = Date()
    }
    func deleteModuleNote(id: UUID, profileID: UUID) throws {
        guard try behaviorResult(.notes, event: "delete")["delete"]?.bool == true else { throw ValidationError("The Notes package did not approve this operation.") }
        library.notes.removeAll { $0.id == id && $0.profileID == profileID }
    }
    func moduleSetting(_ schema: ModuleSetting, moduleID: String) -> ModuleValue {
        guard let repository, let values = try? repository.settings(for: moduleID) else { return schema.defaultValue }
        return values[schema.id] ?? schema.defaultValue
    }
    func setModuleSetting(_ schema: ModuleSetting, value: ModuleValue, moduleID: String) {
        perform {
            guard let repository else { throw ValidationError("Repair module storage first.") }
            try repository.setSetting(schema.id, value: value, for: moduleID)
            installedModules = try repository.installed()
        }
    }
    func validateModulePayload(_ module: InstalledModule, requireEnabled: Bool) throws {
        guard let repository else { throw ValidationError("Repair module storage first.") }
        switch module.manifest.runtime {
        case .nativeReaderWorker, .nativeResourceWorker:
            _ = try validatedWorkerPackage(id: module.id, requireEnabled: requireEnabled)
        case .behaviorProgram: _ = try repository.behaviorProgram(for: module.id, requireEnabled: requireEnabled)
        case .declarative: try validateDefinitionForPlatform(repository.definition(for: module.id, requireEnabled: requireEnabled))
        case nil: throw ValidationError("This legacy descriptor no longer provides a feature. Update or replace it in Modules.")
        }
    }
    func validateDefinitionForPlatform(_ definition: ModuleDefinition) throws {
        if let icons = definition.icons, !icons.values.allSatisfy({ NSImage(systemSymbolName: $0, accessibilityDescription: nil) != nil }) {
            throw ValidationError("This icon package contains symbols unavailable on this Mac.")
        }
    }
    func moduleInstallationPlan(for ids: [String]) throws -> [ModuleManifest] {
        guard ids.count <= 64, let repository else { throw ValidationError("Repair module storage before installing setup requirements.") }
        var seen = Set<String>(), result: [ModuleManifest] = []
        for id in ids {
            for manifest in try repository.installationPlan(for: id, catalog: catalog) where seen.insert(manifest.id).inserted {
                result.append(manifest)
            }
        }
        return result
    }
    func loadCommunityCatalogs() throws {
        guard let repository else { return }
        let communities = try repository.communityCatalogs()
        var manifests = catalog.filter { bundledModuleIDs.contains($0.id) }
        var seen = bundledModuleIDs
        for community in communities {
            for package in community.packages {
                guard seen.insert(package.manifest.id).inserted else { throw ValidationError("A community catalog conflicts with another installed catalog.") }
                manifests.append(package.manifest); modulePayloads[package.manifest.id] = try package.payload()
            }
        }
        communityCatalogNames = communities.map(\.name).sorted()
        catalog = manifests.sorted { $0.name < $1.name }
    }
    func importCatalog() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.canChooseDirectories = false
        panel.message = "Choose a community catalog containing bounded declarative or behavior packages. Adding a catalog does not install its modules."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        perform { try addCatalog(DeclarativeModuleCatalog.decode(readModuleFile(url, limit: 2 * 1024 * 1024))) }
    }
    func addCatalog(_ catalog: DeclarativeModuleCatalog, replaceExisting: Bool = false) throws {
        guard let repository else { throw ValidationError("Repair module storage first.") }
        let alert = NSAlert(); alert.messageText = replaceExisting ? "Refresh \(catalog.name)?" : "Add \(catalog.name)?"
        alert.informativeText = "\(catalog.packages.count) data packages will appear in Discover. Publishers are self-reported. No modules will be installed or granted permissions until you approve their installation."
        alert.addButton(withTitle: "Add catalog"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        try repository.addCommunityCatalog(catalog, reservedIDs: bundledModuleIDs, replaceExisting: replaceExisting); try loadCommunityCatalogs()
    }
    func removeCatalog(named name: String) {
        let alert = NSAlert(); alert.messageText = "Remove \(name)?"
        alert.informativeText = "Its packages disappear from Discover and Updates. Already installed modules and their data are kept."
        alert.addButton(withTitle: "Remove catalog"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        perform {
            try repository?.removeCommunityCatalog(named: name); try loadCommunityCatalogs()
            notice = "The catalog was removed. Already installed modules and their data are kept."
        }
    }
    func readModuleFile(_ url: URL, limit: Int) throws -> Data {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? 0) <= limit else { throw ValidationError("Choose a regular JSON file within the package size limit.") }
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        let bytes = try file.read(upToCount: limit + 1) ?? Data()
        guard bytes.count <= limit else { throw ValidationError("The package exceeds its size limit.") }
        return bytes
    }
    func presentTabReplacementBeforeRemoval(_ current: InstalledModule, removeAfterReplacement: Bool = true) {
        let replacements = catalog.filter { $0.id != current.id && $0.capability == .tabSystem && $0.runtime == .declarative }
        guard !replacements.isEmpty else { notice = "Install a compatible tab system before removing the active one. Your tabs are kept."; return }
        let alert = NSAlert(); alert.messageText = "Choose a replacement for \(current.manifest.name)"
        alert.informativeText = "Your open tabs, pinned tabs, tree relationships, and split panes are kept. The chosen replacement is validated before activation. " + (removeAfterReplacement ? "The current package is then removed." : "The current package stays installed and becomes inactive.")
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 330, height: 28))
        popup.addItems(withTitles: replacements.map(\.name)); alert.accessoryView = popup
        alert.addButton(withTitle: removeAfterReplacement ? "Replace and uninstall" : "Replace"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn, replacements.indices.contains(popup.indexOfSelectedItem) else { return }
        let replacement = replacements[popup.indexOfSelectedItem]
        perform {
            let plan = try moduleInstallationPlan(for: [replacement.id])
            guard approveModules(plan) else { return }
            try installApprovedModule(replacement.id)
            guard let repository else { throw ValidationError("Repair module storage first.") }
            try repository.replaceProvider(role: .tabSystem, with: replacement.id)
            if removeAfterReplacement { try repository.uninstall(current.id) }
            installedModules = try repository.installed()
        }
    }
}
