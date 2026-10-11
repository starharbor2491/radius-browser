// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
@testable import RadiusCore

@Test func nativeWorkersRequirePayloadAndRemovalDeletesIt() throws {
    let directory = moduleTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = try ModuleRepository(root: directory)
    let manifest = resourceModule("org.radius.resource-monitor")
    #expect(throws: (any Error).self) { try repository.install(manifest) }
    let bytes = Data("test native payload".utf8)
    try repository.install(manifest, payload: bytes)
    let url = try repository.workerURL(for: manifest.id)
    #expect(try Data(contentsOf: url) == bytes)
    #expect(try repository.installed()[0].diskBytes > bytes.count)
    try repository.uninstall(manifest.id)
    #expect(!FileManager.default.fileExists(atPath: url.path))
    #expect(throws: (any Error).self) { try repository.workerURL(for: manifest.id) }
    try repository.install(manifest, payload: bytes)
    #expect(try repository.installed().first?.enabled == true)
    #expect(try repository.workerURL(for: manifest.id) == url)
}

@Test func resourceProviderReplacementIsExclusiveAndPreservesDisabledStateAcrossLaunches() throws {
    let directory = moduleTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = try ModuleRepository(root: directory)
    let first = resourceModule("org.radius.resource-monitor")
    var second = resourceModule("org.radius.memory-monitor"); second.defaultInstalled = false
    let payload = Data("test native payload".utf8)
    try repository.install(first, payload: payload)
    try repository.install(second, payload: payload)
    #expect(try repository.installed().filter(\.enabled).map(\.id) == [first.id])
    #expect(throws: (any Error).self) { try repository.setEnabled(second.id, true) }
    try repository.replaceResourceProvider(with: second.id)
    #expect(try repository.installed().filter(\.enabled).map(\.id) == [second.id])
    try repository.setEnabled(second.id, false)
    #expect(try ModuleRepository(root: directory).installed().allSatisfy { !$0.enabled })
    try repository.replaceResourceProvider(with: first.id)
    try repository.uninstall(first.id)
    #expect(try repository.installed().allSatisfy { !$0.enabled })
    #expect(try repository.installed().map(\.id) == [second.id])
}

@Test func descriptorUpgradeRequiresPayloadAndHonorsDisabledAndRemovedChoices() throws {
    let directory = moduleTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = try ModuleRepository(root: directory)
    var old = resourceModule("org.radius.resource-monitor"); old.runtime = nil
    try repository.seedDefaults([old])
    try repository.setEnabled(old.id, false)
    var new = old; new.version = 2; new.runtime = .nativeResourceWorker
    let payload = Data("test native payload".utf8)
    try repository.seedDefaults([new], payloads: [new.id: payload])
    #expect(try repository.installed()[0].manifest.version == 1)
    try repository.install(new, payload: payload)
    #expect(try repository.installed()[0].manifest.runtime == .nativeResourceWorker)
    #expect(try repository.installed()[0].enabled == false)
    try repository.uninstall(new.id)
    try repository.seedDefaults([new], payloads: [new.id: payload])
    #expect(try repository.installed().isEmpty)
}

@Test func nativePayloadLinksAndMalformedDisplayFramesAreRejected() throws {
    let directory = moduleTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = try ModuleRepository(root: directory)
    let manifest = resourceModule("org.radius.resource-monitor")
    try repository.install(manifest, payload: Data("native".utf8))
    let url = try repository.workerURL(for: manifest.id)
    try FileManager.default.removeItem(at: url)
    try FileManager.default.createSymbolicLink(at: url, withDestinationURL: directory.appendingPathComponent(".initialized"))
    #expect(throws: (any Error).self) { try repository.installed() }
    let invalid = ResourceFrame(title: "Invalid", detail: "", metrics: [ResourceMetric("CPU", value: "200%", fraction: 2)])
    #expect(throws: (any Error).self) { try ResourceFrame.decode(JSONEncoder().encode(invalid)) }
    #expect(throws: (any Error).self) { try ResourceFrame.decode(Data(repeating: 0, count: 65_537)) }
}

@Test func damagedNativePayloadsStayVisibleAndRepairPreservesActivation() throws {
    let directory = moduleTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = try ModuleRepository(root: directory)
    let manifest = resourceModule("org.radius.resource-monitor")
    let trusted = Data("trusted test payload".utf8)
    try repository.install(manifest, payload: trusted)
    let url = try repository.workerURL(for: manifest.id)
    for active in [true, false] {
        try repository.setEnabled(manifest.id, active)
        for damage in ["missing", "empty", "oversized"] {
            try FileManager.default.removeItem(at: url)
            if damage != "missing" {
                try Data(repeating: 0, count: damage == "empty" ? 0 : 8 * 1024 * 1024 + 1).write(to: url)
            }
            let reopened = try ModuleRepository(root: directory)
            let installed = try #require(reopened.installed().first)
            #expect(installed.id == manifest.id)
            #expect(installed.enabled == active)
            #expect(throws: (any Error).self) { try reopened.workerURL(for: manifest.id) }
            try reopened.install(manifest, enabled: installed.enabled, payload: trusted)
            #expect(try reopened.installed().first?.enabled == active)
            #expect(try Data(contentsOf: url) == trusted)
        }
    }
}

private func moduleTestDirectory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("radius-module-test-" + UUID().uuidString) }
private func resourceModule(_ id: String) -> ModuleManifest {
    ModuleManifest(id: id, name: id, summary: "Test resource worker", capability: .resourceMonitor, runtime: .nativeResourceWorker)
}
