// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
import RadiusCore
@testable import RadiusApp

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
