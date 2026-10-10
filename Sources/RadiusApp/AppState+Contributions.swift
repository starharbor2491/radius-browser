// SPDX-License-Identifier: MPL-2.0
import RadiusCore

@MainActor
extension AppState {
    func synchronizeModuleContributions(previous: [InstalledModule]) {
        guard ready && !suspendingModuleContributions else { return }
        var next = library.preferences.configuration
        for role in [ModuleCapability.layout, .theme, .tabSystem] {
            guard let current = installedModules.first(where: { $0.enabled && $0.manifest.capability == role }) else { continue }
            let earlier = previous.first(where: { $0.enabled && $0.manifest.capability == role })
            // Appearance and arrangement defaults preserve edits across updates.
            // Tab presentation is the provider's behavior, so its updates apply.
            guard earlier?.id != current.id || (role == .tabSystem && earlier != current),
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
    func applySetup(_ configuration: Configuration, requirements: [String], approvalTitle: String? = nil) throws -> Bool {
        var required = requirements
        // A setup's tab behavior must have a real interchangeable provider.
        let desired = configuration.layout.treeTabs == true ? "org.radius.tree-tabs" : "org.radius.standard-tabs"
        if required.contains("org.radius.standard-tabs") || required.contains("org.radius.tree-tabs") {
            required.removeAll { $0 == "org.radius.standard-tabs" || $0 == "org.radius.tree-tabs" }; required.append(desired)
        }
        if !required.contains(where: { id in moduleManifestCandidate(id)?.capability == .tabSystem }) { required.append(desired) }
        let requirements = try validateModuleRequirements(for: required)
        let approval = try captureModuleApproval(requirements, rootIDs: required)
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
        guard approveModules(requirements, activateRequirements: true, activationTitle: approvalTitle) else { return false }
        try applyApprovedSetup(configuration, requirements: requirements, approval: approval)
        return true
    }
    func applyApprovedSetup(_ configuration: Configuration, requirements: [ModuleManifest], approval: ModuleApprovalSnapshot? = nil) throws {
        if let approval {
            guard requirements == approval.requirements else { throw ValidationError("This setup no longer matches its approved modules. Review its requirements again.") }
            let current = try validateModuleRequirements(for: approval.rootIDs)
            try validateModuleApproval(approval, requirements: current)
        }
        try withAtomicModuleChanges(for: requirements.map(\.id)) {
            // Release every old dependency using the already validated whole
            // setup before replacing any providers; required ID order is inert.
            try installApprovedModuleCode(requirements)
            try activateApprovedModuleRequirements(requirements)
            applyConfiguration(configuration)
        }
        // The setup explicitly supplies customized values; preserve them after
        // contribution defaults have been synchronized at the transaction boundary.
        applyConfiguration(configuration)
    }
    var configurationModuleRequirements: [String] {
        installedModules.filter { $0.enabled && [.tabSystem, .theme, .layout, .icons, .menu, .startWidget].contains($0.manifest.capability) }.map(\.id)
    }
}
