// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
import RadiusCore
@testable import RadiusApp

extension NativeIntegrationTests {
struct BehaviorModuleTests {
@Test @MainActor func anApprovedModuleUpdateCannotDivergeFromItsSetupDuringTheFinalQuitFlush() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("radius-frozen-module-approval-" + UUID().uuidString)
    let previous = AppDelegate.state
    let app = AppState(directory: directory)
    defer { AppDelegate.state = previous; try? FileManager.default.removeItem(at: directory) }
    let repository = try ModuleRepository(root: directory.appendingPathComponent("Modules")); app.repository = repository
    var focus = ModuleManifest(id: "org.test.frozen-focus", name: "Focus", summary: "Approved update", capability: .focusMode, runtime: .behaviorProgram)
    let originalBytes = try completeBehaviorFixture(Data(#"{"formatVersion":1,"entrypoints":{"enter":{"op":"object","fields":{"active":{"op":"literal","value":true},"hiddenComponents":{"op":"literal","value":["tabs"]}}}}}"#.utf8), capability: .focusMode)
    let updatedBytes = try completeBehaviorFixture(Data(#"{"formatVersion":1,"entrypoints":{"enter":{"op":"object","fields":{"active":{"op":"literal","value":true},"hiddenComponents":{"op":"literal","value":["navigation"]}}}}}"#.utf8), capability: .focusMode)
    try repository.install(focus, payload: originalBytes); app.installedModules = try repository.installed()
    focus.version = 2; app.catalog = [focus]; app.modulePayloads = [focus.id: updatedBytes]
    let requirements = try app.validateModuleRequirements(for: [focus.id])
    let approval = try app.captureModuleApproval(requirements, rootIDs: [focus.id])
    let receipts = try repository.installed(), originalConfiguration = app.library.preferences.configuration
    var setup = originalConfiguration; setup.theme.accent = .orange

    // An already reviewed approval returns after the final durable snapshot starts.
    app.freezeQuitData()
    #expect(throws: (any Error).self) { try app.installApprovedModule(focus.id, approval: approval) }
    #expect(throws: (any Error).self) { try app.applyApprovedSetup(setup, requirements: requirements, approval: approval) }
    #expect(try repository.installed() == receipts)
    #expect(try repository.dataPayload(for: focus.id, runtime: .behaviorProgram) == originalBytes)
    #expect(app.library.preferences.configuration == originalConfiguration)

    // Canceling quit reopens the same unchanged approval for the real transaction.
    app.unfreezeQuitData()
    try app.applyApprovedSetup(setup, requirements: requirements, approval: approval)
    #expect(try repository.installed().first(where: { $0.id == focus.id })?.manifest.version == 2)
    #expect(try repository.dataPayload(for: focus.id, runtime: .behaviorProgram) == updatedBytes)
    #expect(app.library.preferences.configuration == setup)
    #expect(try app.requestedFocusPresentation().hiddenComponents == ["navigation"])
}

@Test @MainActor func multipleCustomizeEditorsOnlyUpdateAndCancelTheirOwnLivePreview() {
    let previous = AppDelegate.state
    defer { AppDelegate.state = previous }
    let app = AppState()
    let committed = app.library.preferences.configuration
    let firstEditor = UUID(), secondEditor = UUID()
    var first = committed; first.theme.accent = .orange
    var second = committed; second.theme.accent = .purple; second.layout.navigation = .bottom
    app.beginConfigurationPreview(first, owner: firstEditor)
    #expect(app.previewOwnerID == firstEditor && app.configuration == first)
    app.beginConfigurationPreview(second, owner: secondEditor)
    #expect(app.previewOwnerID == secondEditor && app.configuration == second)

    // A stale editor can keep changing or close after another takes over.
    first.theme.accent = .teal
    app.updateConfigurationPreview(first, owner: firstEditor)
    app.endConfigurationPreview(owner: firstEditor)
    #expect(app.previewOwnerID == secondEditor && app.configuration == second)
    #expect(app.library.preferences.configuration == committed)
    second.theme.cornerRadius = 18
    app.updateConfigurationPreview(second, owner: secondEditor)
    #expect(app.configuration == second)
    app.endConfigurationPreview(owner: secondEditor)
    #expect(app.previewOwnerID == nil && app.previewConfiguration == nil)
    #expect(app.configuration == committed)

    // Existing direct previews remain usable, and applying a setup ends them.
    app.previewConfiguration = first
    #expect(app.configuration == first && app.previewOwnerID == nil)
    app.previewConfiguration = nil
    app.beginConfigurationPreview(second, owner: secondEditor)
    app.applyConfiguration(first)
    #expect(app.previewOwnerID == nil && app.previewConfiguration == nil)
    #expect(app.configuration == first)
}

@Test @MainActor func restoringTheDefaultInterfaceReplacesCustomTreeTabsAndExportsAUsableSetup() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("radius-default-recovery-" + UUID().uuidString)
    let previous = AppDelegate.state
    let app = AppState(directory: directory)
    defer { app.ready = false; AppDelegate.state = previous; try? FileManager.default.removeItem(at: directory) }
    await app.load()
    try #require(app.ready, Comment(rawValue: app.startupError ?? "Recovery fixture did not load"))
    let repository = try #require(app.repository)
    let custom = ModuleManifest(id: "org.test.recovery-tree", name: "Custom tree", summary: "A replacement tab system", capability: .tabSystem, runtime: .declarative)
    try repository.install(custom, enabled: false, payload: Data(#"{"formatVersion":1,"treeTabs":true}"#.utf8))
    try repository.replaceProvider(role: .tabSystem, with: custom.id)
    app.installedModules = try repository.installed()
    try #require(app.library.preferences.configuration.layout.treeTabs == true)
    let profileID = app.library.profiles[0].id
    let root = BrowserTab(title: "Pinned root", url: URL(string: "https://recovery.fixture.invalid"), pinned: true)
    let child = BrowserTab(title: "Kept child", parentID: root.id)
    app.library.sessions = [WindowSession(profileID: profileID, tabs: [root, child])]
    app.library.notes = [Note(profileID: profileID, title: "Kept note", text: "Interface recovery preserves browser data")]
    let sessions = app.library.sessions, notes = app.library.notes

    // Recovery's approved setup transaction replaces the active tab provider,
    // rather than leaving its tree behavior paired with a flat configuration.
    let defaults = Configuration()
    let requirements = try app.validateModuleRequirements(for: ["org.radius.standard-tabs"])
    try app.applyApprovedSetup(defaults, requirements: requirements)
    #expect(app.library.preferences.configuration == defaults)
    #expect(app.installedModules.first(where: { $0.id == custom.id })?.enabled == false)
    #expect(app.installedModules.first(where: { $0.id == "org.radius.standard-tabs" })?.enabled == true)
    #expect(app.declarativeDefinition(.tabSystem)?.treeTabs == false)
    #expect(app.library.sessions == sessions)
    #expect(app.library.notes == notes)

    let pack = SetupPack(name: "Recovered interface", configuration: app.library.preferences.configuration,
                         requiredModuleIDs: app.configurationModuleRequirements)
    let imported = try SetupPack.decode(JSONEncoder().encode(pack))
    #expect(imported.requiredModuleIDs?.contains("org.radius.standard-tabs") == true)
    #expect(imported.requiredModuleIDs?.contains(custom.id) == false)
    try repository.replaceProvider(role: .tabSystem, with: custom.id)
    app.installedModules = try repository.installed()
    try #require(app.library.preferences.configuration.layout.treeTabs == true)
    let importedRequirements = try app.validateModuleRequirements(for: try #require(imported.requiredModuleIDs))
    try app.applyApprovedSetup(imported.configuration, requirements: importedRequirements)
    #expect(app.library.preferences.configuration == defaults)
    #expect(app.declarativeDefinition(.tabSystem)?.treeTabs == false)
    #expect(app.library.sessions == sessions)
    #expect(app.library.notes == notes)
    #expect(await app.flush())
}

@Test @MainActor func customizedTreeBehaviorReplacesCustomProvidersAndKeepsUnrelatedRequirements() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("radius-custom-tab-transition-" + UUID().uuidString)
    let previous = AppDelegate.state
    let app = AppState(directory: directory)
    defer { app.ready = false; AppDelegate.state = previous; try? FileManager.default.removeItem(at: directory) }
    let repository = try ModuleRepository(root: directory.appendingPathComponent("Modules")); app.repository = repository
    let standard = ModuleManifest(id: "org.radius.standard-tabs", name: "Standard tabs", summary: "Flat tabs", capability: .tabSystem, runtime: .declarative)
    let tree = ModuleManifest(id: "org.radius.tree-tabs", name: "Tree tabs", summary: "Nested tabs", capability: .tabSystem, runtime: .declarative)
    let customTree = ModuleManifest(id: "org.test.custom-tree", name: "Custom tree", summary: "Custom nested tabs", capability: .tabSystem, runtime: .declarative)
    let customFlat = ModuleManifest(id: "org.test.custom-flat", name: "Custom flat", summary: "Custom flat tabs", capability: .tabSystem, runtime: .declarative)
    let widget = ModuleManifest(id: "org.test.kept-widget", name: "Kept widget", summary: "Unrelated customization", capability: .startWidget, runtime: .declarative)
    let flatBytes = Data(#"{"formatVersion":1,"treeTabs":false}"#.utf8)
    let treeBytes = Data(#"{"formatVersion":1,"treeTabs":true}"#.utf8)
    let widgetBytes = Data(#"{"formatVersion":1,"widgetTitle":"Kept widget","widgetBody":"Kept during tab transitions"}"#.utf8)
    app.catalog = [standard, tree, customTree, customFlat, widget]
    app.modulePayloads = [standard.id: flatBytes, tree.id: treeBytes, customTree.id: treeBytes, customFlat.id: flatBytes, widget.id: widgetBytes]
    for manifest in app.catalog { try repository.install(manifest, enabled: manifest.id == standard.id || manifest.id == widget.id, payload: app.modulePayloads[manifest.id]) }
    app.installedModules = try repository.installed(); app.ready = true
    let pinned = BrowserTab(title: "Pinned", pinned: true), child = BrowserTab(title: "Child", parentID: pinned.id)
    app.library.sessions = [WindowSession(profileID: app.library.profiles[0].id, tabs: [pinned, child])]
    let sessions = app.library.sessions

    for scenario in 0..<4 {
        let custom = scenario == 1 ? customFlat : customTree
        try repository.replaceProvider(role: .tabSystem, with: custom.id)
        app.installedModules = try repository.installed()
        var before = app.library.preferences.configuration; before.layout.tabs = .leading
        app.applyConfiguration(before)
        var appearance = before; appearance.theme.accent = .orange
        var appearanceRequirements = [custom.id, widget.id]
        app.reconcileCustomizedTabRequirements(previous: before, draft: &appearance, requirements: &appearanceRequirements)
        #expect(appearanceRequirements == [custom.id, widget.id])
        let appearancePlan = try app.validateModuleRequirements(for: appearanceRequirements)
        try app.applyApprovedSetup(appearance, requirements: appearancePlan)
        #expect(app.installedModules.first(where: { $0.id == custom.id })?.enabled == true)

        var draft = appearance, requirements = appearanceRequirements
        if scenario == 0 { draft.layout.treeTabs = false }
        else if scenario == 1 { draft.layout.treeTabs = true }
        else { draft.layout.tabs = scenario == 2 ? .top : .bottom }
        app.reconcileCustomizedTabRequirements(previous: appearance, draft: &draft, requirements: &requirements)
        let expectedID = scenario == 1 ? tree.id : standard.id
        #expect(requirements.contains(expectedID) && requirements.contains(widget.id))
        #expect(!requirements.contains(custom.id))
        let plan = try app.validateModuleRequirements(for: requirements)
        let approval = try app.captureModuleApproval(plan, rootIDs: requirements)
        try app.applyApprovedSetup(draft, requirements: plan, approval: approval)
        #expect(app.installedModules.first(where: { $0.id == expectedID })?.enabled == true)
        #expect(app.installedModules.first(where: { $0.id == custom.id })?.enabled == false)
        #expect(app.installedModules.first(where: { $0.id == widget.id })?.enabled == true)
        #expect(app.declarativeDefinition(.tabSystem)?.treeTabs == (scenario == 1))
        #expect(app.library.preferences.configuration.layout.treeTabs == (scenario == 1))
        #expect(app.library.sessions == sessions)
    }
}

@Test @MainActor func changedCatalogDependenciesOrPayloadsRequireNewApprovalBeforeInstallingOrApplyingASetup() throws {
    let previous = AppDelegate.state
    defer { AppDelegate.state = previous }
    for changingDependencies in [true, false] {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("radius-approval-drift-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = AppState(directory: directory)
        let repo = try ModuleRepository(root: directory.appendingPathComponent("Modules")); app.repository = repo
        var focus = ModuleManifest(id: "org.test.focus", name: "Focus", summary: "Focus policy", capability: .focusMode, runtime: .behaviorProgram)
        let oldBytes = try completeBehaviorFixture(Data(#"{"formatVersion":1,"entrypoints":{"enter":{"op":"object","fields":{"active":{"op":"literal","value":true},"hiddenComponents":{"op":"literal","value":["tabs"]}}}}}"#.utf8), capability: .focusMode)
        app.catalog = [focus]; app.modulePayloads = [focus.id: oldBytes]
        let reviewed = try app.validateModuleRequirements(for: [focus.id], replacingRootProviders: false)
        let approval = try app.captureModuleApproval(reviewed, rootIDs: [focus.id])
        if changingDependencies {
            let capture = ModuleManifest(id: "org.test.capture", name: "Capture", summary: "New website permission", capability: .screenshot, runtime: .behaviorProgram)
            focus.version = 2; focus.dependencies = [capture.id]
            app.catalog = [focus, capture]
            app.modulePayloads[capture.id] = Data(#"{"formatVersion":1,"entrypoints":{"prepare":{"op":"object","fields":{"filename":{"op":"literal","value":"Capture"},"format":{"op":"literal","value":"png"},"visibleOnly":{"op":"literal","value":true}}}}}"#.utf8)
        } else {
            app.modulePayloads[focus.id] = try completeBehaviorFixture(Data(#"{"formatVersion":1,"entrypoints":{"enter":{"op":"object","fields":{"active":{"op":"literal","value":true},"hiddenComponents":{"op":"literal","value":["navigation"]}}}}}"#.utf8), capability: .focusMode)
        }
        var configuration = Configuration(); configuration.theme.accent = .orange
        let before = app.library.preferences.configuration
        #expect(throws: (any Error).self) { try app.installApprovedModule(focus.id, approval: approval) }
        #expect(throws: (any Error).self) { try app.applyApprovedSetup(configuration, requirements: reviewed, approval: approval) }
        #expect(try repo.installed().isEmpty)
        #expect(app.library.preferences.configuration == before)
        #expect(!app.enabled(.screenshot))

        let updated = try app.validateModuleRequirements(for: [focus.id], replacingRootProviders: false)
        let renewed = try app.captureModuleApproval(updated, rootIDs: [focus.id])
        try app.installApprovedModule(focus.id, approval: renewed)
        #expect(app.enabled(.focusMode))
        #expect(app.enabled(.screenshot) == changingDependencies)
        let expectedHidden: Set<String> = changingDependencies ? ["tabs"] : ["navigation"]
        #expect(try app.requestedFocusPresentation().hiddenComponents == expectedHidden)
    }
}

@Test @MainActor func applicationUpdatesRefreshNativeSignaturesWithoutRestoringRemovedOrDisabledPackages() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("radius-worker-upgrade-" + UUID().uuidString)
    let previous = AppDelegate.state
    defer { AppDelegate.state = previous; try? FileManager.default.removeItem(at: directory) }
    let app = AppState(directory: directory)
    let repo = try ModuleRepository(root: directory.appendingPathComponent("Modules")); app.repository = repo
    let manifest = ModuleManifest(id: "org.radius.resource-monitor", name: "Resources", summary: "Native resource worker", capability: .resourceMonitor, runtime: .nativeResourceWorker)
    var removed = manifest; removed.id = "org.radius.memory-monitor"; removed.defaultInstalled = false
    try repo.install(manifest, payload: Data("old signed bytes".utf8)); try repo.setEnabled(manifest.id, false)
    try repo.install(removed, payload: Data("old alternate".utf8)); try repo.uninstall(removed.id)
    let newBytes = Data("new timestamped signed bytes".utf8)
    app.catalog = [manifest, removed]; app.bundledModuleIDs = [manifest.id, removed.id]
    app.modulePayloads = [manifest.id: newBytes, removed.id: Data("new alternate".utf8)]
    app.installedModules = try repo.installed()
    try app.refreshBundledNativePackages()
    #expect(app.installedModules.map(\.id) == [manifest.id])
    #expect(app.installedModules.allSatisfy { !$0.enabled })
    #expect(try Data(contentsOf: repo.workerURL(for: manifest.id, requireEnabled: false)) == newBytes)
}

@Test @MainActor func newerDisabledDependencyEnablesItsExistingProgramWithoutDowngrading() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("radius-behavior-app-" + UUID().uuidString)
    let previous = AppDelegate.state
    defer { AppDelegate.state = previous; try? FileManager.default.removeItem(at: directory) }
    let app = AppState(directory: directory)
    let repo = try ModuleRepository(root: directory.appendingPathComponent("Modules")); app.repository = repo
    var newer = ModuleManifest(id: "org.test.notes", name: "New notes", version: 2, summary: "New program", capability: .notes, runtime: .behaviorProgram)
    let newerBytes = try completeBehaviorFixture(Data(#"{"formatVersion":1,"entrypoints":{"create":{"op":"object","fields":{"title":{"op":"literal","value":"Version two"},"text":{"op":"literal","value":""}}}}}"#.utf8), capability: .notes)
    try repo.install(newer, enabled: false, payload: newerBytes)
    newer.version = 1
    let olderBytes = try completeBehaviorFixture(Data(#"{"formatVersion":1,"entrypoints":{"create":{"op":"object","fields":{"title":{"op":"literal","value":"Old version"},"text":{"op":"literal","value":""}}}}}"#.utf8), capability: .notes)
    let dependent = ModuleManifest(id: "org.test.dependent", name: "Dependent", summary: "Requires new notes", capability: .focusMode, dependencies: [newer.id], runtime: .behaviorProgram, dependencyVersions: [newer.id: 2])
    let dependentBytes = try completeBehaviorFixture(Data(#"{"formatVersion":1,"entrypoints":{"enter":{"op":"object","fields":{"active":{"op":"literal","value":true},"hiddenComponents":{"op":"literal","value":["tabs"]}}}}}"#.utf8), capability: .focusMode)
    app.catalog = [newer, dependent]; app.modulePayloads = [newer.id: olderBytes, dependent.id: dependentBytes]
    app.installedModules = try repo.installed()
    try app.installApprovedModule(dependent.id)
    #expect(try repo.dataPayload(for: newer.id, runtime: .behaviorProgram) == newerBytes)
    #expect(try repo.installed().first(where: { $0.id == newer.id })?.manifest.version == 2)
    #expect(try app.behaviorResult(.notes, event: "create")["title"] == .string("Version two"))
    #expect(try app.requestedFocusPresentation().hiddenComponents == ["tabs"])
}

@Test @MainActor func notesBehaviorPolicyRunsBeforeMutationAndRemovalPreventsFurtherWrites() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("radius-behavior-note-" + UUID().uuidString)
    let previous = AppDelegate.state
    defer { AppDelegate.state = previous; try? FileManager.default.removeItem(at: directory) }
    let app = AppState(directory: directory)
    let repo = try ModuleRepository(root: directory.appendingPathComponent("Modules")); app.repository = repo
    let manifest = ModuleManifest(id: "org.test.notes", name: "Custom notes", summary: "Supplies note defaults", capability: .notes, runtime: .behaviorProgram)
    let bytes = try completeBehaviorFixture(Data(#"{"formatVersion":1,"entrypoints":{"create":{"op":"object","fields":{"title":{"op":"literal","value":"A package supplied this title"},"text":{"op":"literal","value":"A package supplied this body"}}}}}"#.utf8), capability: .notes)
    try repo.install(manifest, payload: bytes); app.installedModules = try repo.installed()
    let profileID = app.library.profiles[0].id
    let id = try app.createModuleNote(profileID: profileID)
    #expect(app.library.notes.first(where: { $0.id == id })?.text == "A package supplied this body")
    #expect(app.library.notes.first(where: { $0.id == id })?.title == "A package supplied this title")
    try app.removeModule(manifest.id)
    #expect(!app.enabled(.notes))
    #expect(throws: (any Error).self) { try app.createModuleNote(profileID: profileID) }
    #expect(app.library.notes.count == 1)
}

@Test @MainActor func tabReplacementPreflightsDisabledDependentsAndKeepsTabsAcrossRemoval() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("radius-tab-replacement-" + UUID().uuidString)
    let previous = AppDelegate.state
    defer { AppDelegate.state = previous; try? FileManager.default.removeItem(at: directory) }
    let app = AppState(directory: directory)
    let repo = try ModuleRepository(root: directory.appendingPathComponent("Modules")); app.repository = repo
    let standard = ModuleManifest(id: "org.test.standard", name: "Standard", summary: "Tabs", capability: .tabSystem, runtime: .declarative)
    var tree = standard; tree.id = "org.test.tree"; tree.name = "Tree"
    let dependent = ModuleManifest(id: "org.test.dependent", name: "Dependent", summary: "Uses standard tabs", capability: .startWidget, dependencies: [standard.id], runtime: .declarative)
    let normalBytes = Data(#"{"formatVersion":1,"treeTabs":false}"#.utf8), treeBytes = Data(#"{"formatVersion":1,"treeTabs":true}"#.utf8)
    try repo.install(standard, payload: normalBytes)
    try repo.install(dependent, enabled: false, payload: Data(#"{"formatVersion":1,"widgetTitle":"Dependent","widgetBody":"Uses the original provider"}"#.utf8))
    app.catalog = [standard, tree]; app.modulePayloads = [standard.id: normalBytes, tree.id: treeBytes]
    app.installedModules = try repo.installed()
    let parent = BrowserTab(title: "Pinned", pinned: true), child = BrowserTab(title: "Child", parentID: parent.id)
    app.library.sessions = [WindowSession(profileID: app.library.profiles[0].id, tabs: [parent, child])]
    let sessions = app.library.sessions
    #expect(throws: (any Error).self) { try app.replaceTabProviderApproved(currentID: standard.id, replacementID: tree.id, removeCurrent: true) }
    #expect(try repo.installed().first(where: { $0.id == standard.id })?.enabled == true)
    #expect(try repo.installed().allSatisfy { $0.id != tree.id })
    #expect(app.library.sessions == sessions)
    try repo.uninstall(dependent.id); app.installedModules = try repo.installed()
    try app.replaceTabProviderApproved(currentID: standard.id, replacementID: tree.id, removeCurrent: true)
    #expect(try repo.installed().map(\.id) == [tree.id])
    #expect(try repo.definition(for: tree.id).treeTabs == true)
    #expect(app.library.sessions == sessions)
}

@Test @MainActor func updatingADisabledBehaviorInstallsNewDependenciesWithoutEnablingThem() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("radius-disabled-update-" + UUID().uuidString)
    let previous = AppDelegate.state
    defer { AppDelegate.state = previous; try? FileManager.default.removeItem(at: directory) }
    let app = AppState(directory: directory)
    let repo = try ModuleRepository(root: directory.appendingPathComponent("Modules")); app.repository = repo
    var focus = ModuleManifest(id: "org.test.focus", name: "Focus", summary: "Focus policy", capability: .focusMode, runtime: .behaviorProgram)
    let focusBytes = try completeBehaviorFixture(Data(#"{"formatVersion":1,"entrypoints":{"enter":{"op":"object","fields":{"active":{"op":"literal","value":true},"hiddenComponents":{"op":"literal","value":["tabs"]}}}}}"#.utf8), capability: .focusMode)
    try repo.install(focus, enabled: false, payload: focusBytes)
    let dependency = ModuleManifest(id: "org.test.widget", name: "Widget", summary: "New dependency", capability: .startWidget, runtime: .declarative)
    focus.version = 2; focus.dependencies = [dependency.id]
    app.catalog = [focus, dependency]
    app.modulePayloads = [focus.id: focusBytes, dependency.id: Data(#"{"formatVersion":1,"widgetTitle":"Dependency","widgetBody":"Starts only when enabled"}"#.utf8)]
    app.installedModules = try repo.installed()
    try app.installApprovedModule(focus.id)
    #expect(app.installedModules.count == 2)
    #expect(app.installedModules.allSatisfy { !$0.enabled })
    #expect(app.installedModules.first(where: { $0.id == focus.id })?.manifest.version == 2)
    #expect(app.startWidgets.isEmpty)
}

@Test @MainActor func aDisabledUpdateCannotDisableAnActiveDependencyThroughItsNewRequirements() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("radius-active-dependency-" + UUID().uuidString)
    let previous = AppDelegate.state
    defer { AppDelegate.state = previous; try? FileManager.default.removeItem(at: directory) }
    let app = AppState(directory: directory)
    let repo = try ModuleRepository(root: directory.appendingPathComponent("Modules")); app.repository = repo
    var notes = ModuleManifest(id: "org.test.notes", name: "Notes", summary: "An active dependency", capability: .notes, runtime: .behaviorProgram)
    let notesBytes = try completeBehaviorFixture(Data(#"{"formatVersion":1,"entrypoints":{"create":{"op":"object","fields":{"title":{"op":"literal","value":"Existing notes"},"text":{"op":"literal","value":""}}}}}"#.utf8), capability: .notes)
    try repo.install(notes, payload: notesBytes)
    var focus = ModuleManifest(id: "org.test.focus", name: "Focus", summary: "Disabled consumer", capability: .focusMode, dependencies: [notes.id], runtime: .behaviorProgram)
    let focusBytes = try completeBehaviorFixture(Data(#"{"formatVersion":1,"entrypoints":{"enter":{"op":"object","fields":{"active":{"op":"literal","value":true},"hiddenComponents":{"op":"literal","value":["tabs"]}}}}}"#.utf8), capability: .focusMode)
    try repo.install(focus, enabled: false, payload: focusBytes)
    let widget = ModuleManifest(id: "org.test.widget", name: "Widget", summary: "New requirement", capability: .startWidget, runtime: .declarative)
    notes.version = 2; notes.dependencies = [widget.id]
    focus.version = 2; focus.dependencyVersions = [notes.id: 2]
    app.catalog = [focus, notes, widget]
    app.modulePayloads = [focus.id: focusBytes, notes.id: notesBytes, widget.id: Data(#"{"formatVersion":1,"widgetTitle":"Widget","widgetBody":"New dependency"}"#.utf8)]
    app.installedModules = try repo.installed()
    let before = app.installedModules
    #expect(throws: (any Error).self) { try app.installApprovedModule(focus.id) }
    #expect(try repo.installed() == before)
    #expect(try app.behaviorResult(.notes, event: "create")["title"] == .string("Existing notes"))
}

@Test @MainActor func reinstallRefusesCatalogDowngradesAndRepairsTheApprovedVersionWithDisabledDependencies() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("radius-exact-reinstall-" + UUID().uuidString)
    let previous = AppDelegate.state
    defer { AppDelegate.state = previous; try? FileManager.default.removeItem(at: directory) }
    let app = AppState(directory: directory)
    let repo = try ModuleRepository(root: directory.appendingPathComponent("Modules")); app.repository = repo
    let widget = ModuleManifest(id: "org.test.widget", name: "Widget", summary: "Dependency", capability: .startWidget, runtime: .declarative)
    let installed = ModuleManifest(id: "org.test.notes", name: "Notes", version: 2, summary: "Current notes", capability: .notes, dependencies: [widget.id], runtime: .behaviorProgram)
    let bytes = try completeBehaviorFixture(Data(#"{"formatVersion":1,"entrypoints":{"create":{"op":"object","fields":{"title":{"op":"literal","value":"Version two"},"text":{"op":"literal","value":""}}}}}"#.utf8), capability: .notes)
    try repo.install(installed, enabled: false, payload: bytes)
    var older = installed; older.version = 1
    app.catalog = [older, widget]; app.modulePayloads = [installed.id: bytes, widget.id: Data(#"{"formatVersion":1,"widgetTitle":"Widget","widgetBody":"Dependency"}"#.utf8)]
    app.installedModules = try repo.installed()
    #expect(throws: (any Error).self) { try app.reinstallApprovedWorker(installed.id) }
    #expect(try repo.installed().map(\.manifest) == [installed])
    #expect(try repo.dataPayload(for: installed.id, runtime: .behaviorProgram, requireEnabled: false) == bytes)
    app.catalog = [installed, widget]
    try Data("damaged".utf8).write(to: repo.root.appendingPathComponent(installed.id).appendingPathComponent("program.json"))
    try app.reinstallApprovedWorker(installed.id)
    #expect(try repo.dataPayload(for: installed.id, runtime: .behaviorProgram, requireEnabled: false) == bytes)
    #expect(app.installedModules.count == 2)
    #expect(app.installedModules.allSatisfy { !$0.enabled })
}

@Test @MainActor func aValidatedSetupReleasesOldDependenciesBeforeReplacingProvidersInEitherOrder() throws {
    let previous = AppDelegate.state
    defer { AppDelegate.state = previous }
    for providerFirst in [true, false] {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("radius-setup-order-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = AppState(directory: directory)
        let repo = try ModuleRepository(root: directory.appendingPathComponent("Modules")); app.repository = repo
        let original = ModuleManifest(id: "org.test.original", name: "Original", summary: "Original notes", capability: .notes, runtime: .behaviorProgram)
        var replacement = original; replacement.id = "org.test.replacement"; replacement.name = "Replacement"
        let originalBytes = try completeBehaviorFixture(Data(#"{"formatVersion":1,"entrypoints":{"create":{"op":"object","fields":{"title":{"op":"literal","value":"Original"},"text":{"op":"literal","value":""}}}}}"#.utf8), capability: .notes)
        let replacementBytes = try completeBehaviorFixture(Data(#"{"formatVersion":1,"entrypoints":{"create":{"op":"object","fields":{"title":{"op":"literal","value":"Replacement"},"text":{"op":"literal","value":""}}}}}"#.utf8), capability: .notes)
        try repo.install(original, payload: originalBytes)
        var widget = ModuleManifest(id: "org.test.widget", name: "Widget", summary: "Former dependent", capability: .startWidget, dependencies: [original.id], runtime: .declarative)
        let widgetBytes = Data(#"{"formatVersion":1,"widgetTitle":"Widget","widgetBody":"Old provider no longer required after update"}"#.utf8)
        try repo.install(widget, payload: widgetBytes)
        widget.version = 2; widget.dependencies = []
        app.catalog = [replacement, widget]; app.modulePayloads = [replacement.id: replacementBytes, widget.id: widgetBytes]
        app.installedModules = try repo.installed()
        let note = Note(profileID: app.library.profiles[0].id, title: "Saved", text: "Kept while providers change")
        app.library.notes = [note]
        let ids = providerFirst ? [replacement.id, widget.id] : [widget.id, replacement.id]
        let requirements = try app.validateModuleRequirements(for: ids)
        var configuration = Configuration(); configuration.theme.density = .compact
        try app.applyApprovedSetup(configuration, requirements: requirements)
        #expect(app.installedModules.first(where: { $0.id == replacement.id })?.enabled == true)
        #expect(app.installedModules.first(where: { $0.id == original.id })?.enabled == false)
        #expect(app.installedModules.first(where: { $0.id == widget.id })?.manifest.version == 2)
        #expect(try app.behaviorResult(.notes, event: "create")["title"] == .string("Replacement"))
        #expect(app.library.notes == [note])
        #expect(app.library.preferences.configuration == configuration)
    }
}

@Test @MainActor func appearancePackageUpdatesKeepCustomizationsAndNewProvidersApplyTheirDefaults() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("radius-appearance-update-" + UUID().uuidString)
    let previous = AppDelegate.state
    defer { AppDelegate.state = previous; try? FileManager.default.removeItem(at: directory) }
    let app = AppState(directory: directory)
    defer { app.ready = false }
    let repo = try ModuleRepository(root: directory.appendingPathComponent("Modules")); app.repository = repo
    var theme = ModuleManifest(id: "org.test.theme", name: "Theme", summary: "Appearance defaults", capability: .theme, runtime: .declarative)
    var layout = ModuleManifest(id: "org.test.layout", name: "Layout", summary: "Arrangement defaults", capability: .layout, runtime: .declarative)
    try repo.install(theme, payload: JSONEncoder().encode(AppearanceDefinitionFixture(theme: Theme())))
    try repo.install(layout, payload: JSONEncoder().encode(AppearanceDefinitionFixture(layout: BrowserLayout())))
    app.installedModules = try repo.installed(); app.ready = true
    var custom = Configuration()
    custom.theme.accent = .purple; custom.theme.fontScale = 1.2
    custom.layout.sidebarWidth = 315; custom.layout.navigation = .bottom
    app.applyConfiguration(custom)
    var newTheme = Theme(); newTheme.accent = .orange
    var newLayout = BrowserLayout(); newLayout.sidebar = .hidden
    theme.version = 2; layout.version = 2
    let themeBytes = try JSONEncoder().encode(AppearanceDefinitionFixture(theme: newTheme))
    let layoutBytes = try JSONEncoder().encode(AppearanceDefinitionFixture(layout: newLayout))
    app.catalog = [theme, layout]; app.modulePayloads = [theme.id: themeBytes, layout.id: layoutBytes]
    try app.installApprovedModule(theme.id)
    try app.installApprovedModule(layout.id)
    #expect(app.installedModules.allSatisfy { $0.enabled && $0.manifest.version == 2 })
    #expect(app.library.preferences.configuration == custom)
    #expect(try repo.definition(for: theme.id).theme == newTheme)
    #expect(try repo.definition(for: layout.id).layout == newLayout)

    // Changing providers is a separate user choice and still applies the new
    // package's defaults, including re-enabling after an explicit disable.
    var replacement = theme; replacement.id = "org.test.replacement-theme"
    app.catalog.append(replacement); app.modulePayloads[replacement.id] = themeBytes
    try app.installApprovedModule(replacement.id)
    #expect(app.library.preferences.configuration == custom)
    try app.setModuleEnabledApproved(theme.id, enabled: false)
    try app.setModuleEnabledApproved(replacement.id, enabled: true)
    #expect(app.library.preferences.configuration.theme == newTheme)
    #expect(app.library.preferences.configuration.layout == custom.layout)

    // Tab-system updates change provider behavior rather than user appearance
    // defaults. The exported configuration must match that updated behavior.
    var tabs = ModuleManifest(id: "org.test.tabs", name: "Tabs", summary: "Tab presentation", capability: .tabSystem, runtime: .declarative)
    app.catalog.append(tabs); app.modulePayloads[tabs.id] = Data(#"{"formatVersion":1,"treeTabs":false}"#.utf8)
    try app.installApprovedModule(tabs.id)
    let parent = BrowserTab(title: "Pinned", pinned: true), child = BrowserTab(title: "Child", parentID: parent.id)
    app.library.sessions = [WindowSession(profileID: app.library.profiles[0].id, tabs: [parent, child])]
    let sessions = app.library.sessions
    var expected = app.library.preferences.configuration
    expected.layout.treeTabs = true; expected.normalize()
    tabs.version = 2
    app.catalog.removeAll { $0.id == tabs.id }; app.catalog.append(tabs)
    app.modulePayloads[tabs.id] = Data(#"{"formatVersion":1,"treeTabs":true}"#.utf8)
    try app.installApprovedModule(tabs.id)
    #expect(app.library.preferences.configuration == expected)
    #expect(try repo.definition(for: tabs.id).treeTabs == app.library.preferences.configuration.layout.treeTabs)
    #expect(app.configurationModuleRequirements.contains(tabs.id))
    #expect(app.library.sessions == sessions)
}

}
}

private struct AppearanceDefinitionFixture: Encodable {
    let formatVersion = 1
    var theme: Theme? = nil
    var layout: BrowserLayout? = nil
}

private func completeBehaviorFixture(_ bytes: Data, capability: ModuleCapability) throws -> Data {
    var program = try ModuleProgram.decode(bytes)
    if capability == .notes {
        program.entrypoints["update"] = ModuleExpression(op: .object, fields: ["value": ModuleExpression(op: .prefix, limit: 100, arguments: [ModuleExpression(op: .input, key: "value")])])
        program.entrypoints["delete"] = ModuleExpression(op: .object, fields: ["delete": ModuleExpression(op: .literal, value: .bool(true))])
    } else if capability == .focusMode {
        program.entrypoints["exit"] = ModuleExpression(op: .object, fields: ["active": ModuleExpression(op: .literal, value: .bool(false)), "hiddenComponents": ModuleExpression(op: .literal, value: .array([]))])
    }
    return try JSONEncoder().encode(program)
}
