// SPDX-License-Identifier: MPL-2.0
import AppKit
import Foundation
import RadiusCore

struct ModuleApprovalSnapshot: Equatable {
    let rootIDs: [String]
    let requirements: [ModuleManifest]
    let repositoryRoot: URL
    let installed: [InstalledModule]
    let catalogPayloadSHA256: [String: String]
}

@MainActor
extension AppState {
    func captureModuleApproval(_ requirements: [ModuleManifest], rootIDs: [String]) throws -> ModuleApprovalSnapshot {
        guard let repository, requirements.count <= 128, Set(requirements.map(\.id)).count == requirements.count,
              rootIDs.count <= 64 else { throw ValidationError("This module operation exceeds its package limit.") }
        var hashes: [String: String] = [:]
        for manifest in requirements {
            if let payload = modulePayloads[manifest.id] { hashes[manifest.id] = ModuleDigest.sha256(payload) }
        }
        return ModuleApprovalSnapshot(rootIDs: rootIDs, requirements: requirements, repositoryRoot: repository.root,
                                      installed: try repository.installed(), catalogPayloadSHA256: hashes)
    }
    func validateModuleApproval(_ approval: ModuleApprovalSnapshot, requirements: [ModuleManifest]) throws {
        guard try captureModuleApproval(requirements, rootIDs: approval.rootIDs) == approval else {
            throw ValidationError("The packages or active providers changed while the approval was open. Review the updated modules and permissions before trying again.")
        }
    }
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
            // Preferences are separate data, so publishing an edit must not
            // invalidate running workers or unrelated in-flight page actions.
            objectWillChange.send()
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
    func moduleManifestCandidate(_ id: String) -> ModuleManifest? {
        let available = catalog.first(where: { $0.id == id }), existing = installedModules.first(where: { $0.id == id })?.manifest
        if let existing, existing.version >= (available?.version ?? 0) { return existing }
        return available ?? existing
    }
    func validateModuleRequirements(for ids: [String], replacingRootProviders: Bool = true, preparingActivation: Bool = true, repairingIDs: Set<String> = []) throws -> [ModuleManifest] {
        guard ids.count <= 64, let repository else { throw ValidationError("Repair module storage first.") }
        var result: [ModuleManifest] = [], seen = Set<String>(), roles: [ModuleCapability: String] = [:]
        for id in ids {
            for manifest in try repository.installationPlan(for: id, catalog: catalog, includeInstalled: true) where seen.insert(manifest.id).inserted {
                if manifest.capability.isExclusive, let other = roles[manifest.capability], other != manifest.id {
                    throw ValidationError("These requirements choose multiple providers for \(manifest.capability.rawValue). Choose one before applying the setup.")
                }
                if manifest.capability.isExclusive { roles[manifest.capability] = manifest.id }
                if let existing = installedModules.first(where: { $0.id == manifest.id }),
                   existing.manifest.capability != manifest.capability || (existing.manifest.runtime != nil && existing.manifest.runtime != manifest.runtime) {
                    throw ValidationError("A package update cannot change its module role or runtime. Import it with a new module ID instead.")
                }
                if !repairingIDs.contains(manifest.id), let existing = installedModules.first(where: { $0.id == manifest.id && $0.manifest == manifest }) {
                    try validateModulePayload(existing, requireEnabled: false)
                } else {
                    guard let payload = modulePayloads[manifest.id] else { throw ValidationError("The catalog is missing \(manifest.name)'s package payload.") }
                    if manifest.runtime == .behaviorProgram { try ModuleProgram.decode(payload).validate(capability: manifest.capability) }
                    else if manifest.runtime == .declarative { try validateDefinitionForPlatform(ModuleDefinition.decode(payload, capability: manifest.capability)) }
                    else { guard manifest.runtime?.isNative == true, bundledModuleIDs.contains(manifest.id), !payload.isEmpty, payload.count <= 8 * 1024 * 1024 else { throw ValidationError("This native package is not a trusted bundled worker.") } }
                }
                result.append(manifest)
            }
        }
        if !preparingActivation {
            for manifest in result where installedModules.contains(where: { $0.id == manifest.id && $0.enabled }) {
                guard manifest.dependencies.allSatisfy({ id in
                    installedModules.contains { $0.id == id && $0.enabled } &&
                    (result.first(where: { $0.id == id })?.version ?? 0) >= (manifest.dependencyVersions?[id] ?? 1)
                }) else { throw ValidationError("Update \(manifest.name) separately first. Updating this disabled module must not disable or replace an active dependency.") }
            }
        }
        // An enabled external dependent cannot be left attached to a provider
        // that a setup replaces. Dependencies included in this plan are checked
        // against their candidate manifests instead of their old manifests.
        for active in installedModules where active.enabled && active.manifest.capability.isExclusive {
            guard let next = roles[active.manifest.capability], next != active.id else { continue }
            if !preparingActivation || (!replacingRootProviders && ids.contains(next)) { continue }
            for dependent in installedModules where dependent.enabled && dependent.manifest.dependencies.contains(active.id) {
                let candidate = result.first(where: { $0.id == dependent.id })?.dependencies
                guard candidate != nil && candidate?.contains(active.id) == false else { throw ValidationError("Disable \(dependent.manifest.name) before replacing \(active.manifest.name).") }
            }
        }
        return result
    }
    func compatibleReinstallationManifest(for id: String) throws -> ModuleManifest {
        guard let current = installedModules.first(where: { $0.id == id }),
              let available = catalog.first(where: { $0.id == id && $0.runtime != nil }) else { throw ValidationError("This package has no available catalog source. Add or refresh its source catalog before reinstalling.") }
        if available.version > current.manifest.version {
            throw ValidationError("Choose Update to review the newer package and its dependencies before reinstalling it.")
        }
        guard available == current.manifest else { throw ValidationError("The catalog does not contain this installed version and definition. Refresh its source catalog before reinstalling. The installed package is kept.") }
        return available
    }
    /// All candidates start with their existing activation choice, and new
    /// packages stay disabled until the approved closure is ready to activate.
    func installApprovedModuleCode(_ requirements: [ModuleManifest], repairingIDs: Set<String> = []) throws {
        guard let repository else { throw ValidationError("Repair module storage first.") }
        for manifest in requirements {
            if !repairingIDs.contains(manifest.id), installedModules.contains(where: { $0.id == manifest.id && $0.manifest == manifest }) { continue }
            ResourceWorker.stopAll(moduleID: manifest.id); cancelReaderRequests(moduleID: manifest.id)
            let previous = installedModules.first(where: { $0.id == manifest.id })?.enabled ?? false
            try repository.install(manifest, enabled: previous, payload: modulePayloads[manifest.id])
        }
        installedModules = try repository.installed()
    }
    func activateApprovedModuleRequirements(_ requirements: [ModuleManifest]) throws {
        guard let repository else { throw ValidationError("Repair module storage first.") }
        for manifest in requirements {
            guard let installed = installedModules.first(where: { $0.id == manifest.id && $0.manifest == manifest }) else { throw ValidationError("A required package did not install.") }
            if !installed.enabled {
                if manifest.capability.isExclusive {
                    if manifest.capability == .resourceMonitor { try replaceResourceProvider(with: manifest.id) }
                    else { try repository.replaceProvider(role: manifest.capability, with: manifest.id) }
                } else { try repository.setEnabled(manifest.id, true) }
                installedModules = try repository.installed()
            }
        }
    }
    func withAtomicModuleChanges<T>(for ids: [String], _ operation: () throws -> T) throws -> T {
        guard let repository else { throw ValidationError("Repair module storage first.") }
        if suspendingModuleContributions { return try operation() }
        let previous = installedModules, configuration = library.preferences.configuration
        suspendingModuleContributions = true
        defer { suspendingModuleContributions = false; invalidateModuleExecution() }
        do {
            let result = try repository.withAtomicChanges(for: ids, operation)
            installedModules = try repository.installed()
            suspendingModuleContributions = false
            synchronizeModuleContributions(previous: previous)
            return result
        } catch {
            installedModules = (try? repository.installed()) ?? previous
            applyConfiguration(configuration)
            throw error
        }
    }
    func loadCommunityCatalogs() throws {
        guard let repository else { return }
        let communities = try repository.communityCatalogs()
        var manifests = catalog.filter { bundledModuleIDs.contains($0.id) }
        var payloads = modulePayloads.filter { bundledModuleIDs.contains($0.key) }
        var seen = bundledModuleIDs
        for community in communities {
            for package in community.packages {
                guard seen.insert(package.manifest.id).inserted else { throw ValidationError("A community catalog conflicts with another installed catalog.") }
                manifests.append(package.manifest); payloads[package.manifest.id] = try package.payload()
            }
        }
        communityCatalogNames = communities.map(\.name).sorted()
        modulePayloads = payloads
        catalog = manifests.sorted { $0.name < $1.name }
    }
    func importCatalog() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.canChooseDirectories = false
        panel.message = "Choose a community catalog containing bounded declarative or behavior packages. Adding a catalog does not install its modules."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        perform {
            guard let repository else { throw ValidationError("Repair module storage first.") }
            let catalog = try DeclarativeModuleCatalog.decode(readModuleFile(url, limit: 2 * 1024 * 1024))
            let replacing = try repository.communityCatalogs().contains { $0.name == catalog.name }
            try addCatalog(catalog, replaceExisting: replacing)
        }
    }
    func addCatalog(_ catalog: DeclarativeModuleCatalog, replaceExisting: Bool = false) throws {
        guard let repository else { throw ValidationError("Repair module storage first.") }
        let alert = NSAlert(); alert.messageText = replaceExisting ? "Refresh \(catalog.name)?" : "Add \(catalog.name)?"
        alert.informativeText = "\(catalog.packages.count) data packages will appear in Discover. Publishers are self-reported. No modules will be installed or granted permissions until you approve their installation."
        alert.addButton(withTitle: replaceExisting ? "Refresh catalog" : "Add catalog"); alert.addButton(withTitle: "Cancel")
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
        let dependents = installedModules.filter { $0.manifest.dependencies.contains(current.id) && (removeAfterReplacement || $0.enabled) }
        guard dependents.isEmpty else {
            notice = (removeAfterReplacement ? "Remove these dependent modules first: " : "Disable these dependent modules first: ") + dependents.map { $0.manifest.name }.joined(separator: ", ")
            return
        }
        let candidates = Set(catalog.map(\.id) + installedModules.map(\.id))
        let replacements = candidates.compactMap(moduleManifestCandidate).filter { $0.id != current.id && $0.capability == .tabSystem && $0.runtime == .declarative }.sorted { $0.name < $1.name }
        guard !replacements.isEmpty else { notice = "Install a compatible tab system before removing the active one. Your tabs are kept."; return }
        let alert = NSAlert(); alert.messageText = "Choose a replacement for \(current.manifest.name)"
        alert.informativeText = "Your open tabs, pinned tabs, tree relationships, and split panes are kept. The chosen replacement is validated before activation. " + (removeAfterReplacement ? "The current package is then removed." : "The current package stays installed and becomes inactive.")
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 330, height: 28))
        popup.addItems(withTitles: replacements.map(\.name)); alert.accessoryView = popup
        alert.addButton(withTitle: removeAfterReplacement ? "Replace and uninstall" : "Replace"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn, replacements.indices.contains(popup.indexOfSelectedItem) else { return }
        let replacement = replacements[popup.indexOfSelectedItem]
        perform {
            let requirements = try validateModuleRequirements(for: [replacement.id])
            let approval = try captureModuleApproval(requirements, rootIDs: [replacement.id])
            guard approveModules(requirements, activateRequirements: true, activationTitle: "Activate \(replacement.name)?") else { return }
            try replaceTabProviderApproved(currentID: current.id, replacementID: replacement.id, removeCurrent: removeAfterReplacement, approval: approval)
        }
    }
    func replaceTabProviderApproved(currentID: String, replacementID: String, removeCurrent: Bool, approval: ModuleApprovalSnapshot? = nil) throws {
        guard let repository, currentID != replacementID,
              let current = installedModules.first(where: { $0.id == currentID && $0.enabled && $0.manifest.capability == .tabSystem }),
              moduleManifestCandidate(replacementID)?.capability == .tabSystem else { throw ValidationError("Choose a compatible replacement for the active tab system.") }
        let dependents = installedModules.filter { $0.manifest.dependencies.contains(current.id) && (removeCurrent || $0.enabled) }
        guard dependents.isEmpty else { throw ValidationError("Resolve these dependent modules before replacing the tab system: " + dependents.map { $0.manifest.name }.joined(separator: ", ")) }
        let requirements = try validateModuleRequirements(for: [replacementID])
        if let approval { try validateModuleApproval(approval, requirements: requirements) }
        try withAtomicModuleChanges(for: Array(Set(requirements.map(\.id) + [currentID]))) {
            try installApprovedModule(replacementID)
            try repository.replaceProvider(role: .tabSystem, with: replacementID)
            if removeCurrent { try repository.uninstall(currentID) }
            installedModules = try repository.installed()
        }
    }
}
