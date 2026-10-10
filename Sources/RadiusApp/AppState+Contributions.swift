// SPDX-License-Identifier: MPL-2.0
import RadiusCore

@MainActor
extension AppState {
    func synchronizeModuleContributions(previous: [InstalledModule]) {
        guard ready && !suspendingModuleContributions else { return }
        var next = library.preferences.configuration
        for role in [ModuleCapability.layout, .theme, .tabSystem] {
            guard let current = installedModules.first(where: { $0.enabled && $0.manifest.capability == role }),
                  previous.first(where: { $0.enabled && $0.manifest.capability == role }) != current,
                  let definition = declarativeDefinition(role) else { continue }
            switch role {
            case .theme: if let theme = definition.theme { next.theme = theme }
            case .layout: if let layout = definition.layout { next.layout = layout }
            case .tabSystem: next.layout.treeTabs = definition.treeTabs
            default: break
            }
        }
        applyConfiguration(next)
    }
    func applySetup(_ configuration: Configuration, requirements: [String]) throws -> Bool {
        var required = requirements
        // A setup's tab behavior must have a real interchangeable provider.
        let desired = configuration.layout.treeTabs == true ? "org.radius.tree-tabs" : "org.radius.standard-tabs"
        if required.contains("org.radius.standard-tabs") || required.contains("org.radius.tree-tabs") {
            required.removeAll { $0 == "org.radius.standard-tabs" || $0 == "org.radius.tree-tabs" }; required.append(desired)
        }
        if !required.contains(where: { id in moduleManifestCandidate(id)?.capability == .tabSystem }) { required.append(desired) }
        let requirements = try validateModuleRequirements(for: required)
        if let tab = requirements.first(where: { $0.capability == .tabSystem }) {
            let definition: ModuleDefinition
            if let existing = installedModules.first(where: { $0.id == tab.id && $0.manifest == tab }) {
                guard let repository else { throw ValidationError("Repair module storage first.") }
                definition = try repository.definition(for: existing.id, requireEnabled: false)
            } else {
                guard let payload = modulePayloads[tab.id] else { throw ValidationError("The tab package payload is missing.") }
                definition = try ModuleDefinition.decode(payload, capability: .tabSystem)
            }
            guard definition.treeTabs == (configuration.layout.treeTabs == true) else { throw ValidationError("This setup's tab layout does not match its required tab-system package. Choose a compatible tab system before applying it.") }
        }
        // Preview publisher, all dependencies, and permission differences before
        // any installation, role replacement, or configuration mutation.
        guard approveModules(requirements, activateRequirements: true) else { return false }
        try withAtomicModuleChanges(for: requirements.map(\.id)) {
            for id in required { try installApprovedModule(id) }
            guard let repository else { throw ValidationError("Repair module storage first.") }
            for manifest in requirements {
                guard let installed = installedModules.first(where: { $0.id == manifest.id }) else { throw ValidationError("A required package did not install.") }
                if manifest.capability.isExclusive {
                    if manifest.capability == .resourceMonitor { try replaceResourceProvider(with: manifest.id) }
                    else { try repository.replaceProvider(role: manifest.capability, with: manifest.id) }
                } else if !installed.enabled { try repository.setEnabled(manifest.id, true) }
                installedModules = try repository.installed()
            }
            applyConfiguration(configuration)
        }
        // The setup explicitly supplies customized values; preserve them after
        // contribution defaults have been synchronized at the transaction boundary.
        applyConfiguration(configuration)
        return true
    }
    var configurationModuleRequirements: [String] {
        installedModules.filter { $0.enabled && [.tabSystem, .theme, .layout, .icons, .menu, .startWidget].contains($0.manifest.capability) }.map(\.id)
    }
}
