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
