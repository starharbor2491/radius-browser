// SPDX-License-Identifier: MPL-2.0
import Foundation

public enum ModuleCapability: String, Codable, CaseIterable, Sendable {
    case resourceMonitor, notes, reader, screenshot, focusMode
    public var permission: String? {
        switch self {
        case .resourceMonitor: "Read system CPU and memory statistics. No browsing data is read."
        case .reader: "Read the current page when you choose Reader."
        case .screenshot: "Capture the current page when you choose Save screenshot."
        case .notes, .focusMode: nil
        }
    }
}
public enum ModuleRuntime: String, Codable, Sendable {
    case nativeResourceWorker
}
public struct ModuleManifest: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var version: Int
    public var summary: String
    public var publisher: String
    public var source: URL
    public var capability: ModuleCapability
    public var dependencies: [String]
    public var defaultInstalled: Bool
    public var runtime: ModuleRuntime?
    public init(id: String, name: String, version: Int = 1, summary: String, publisher: String = "Radius",
                source: URL = URL(string: "https://github.com/starharbor2491/radius-browser")!,
                capability: ModuleCapability, dependencies: [String] = [], defaultInstalled: Bool = true, runtime: ModuleRuntime? = nil) {
        self.id = id; self.name = name; self.version = version; self.summary = summary
        self.publisher = publisher; self.source = source; self.capability = capability
        self.dependencies = dependencies; self.defaultInstalled = defaultInstalled
        self.runtime = runtime
    }
    public func validate() throws {
        guard Self.validID(id), dependencies.allSatisfy(Self.validID), Set(dependencies).count == dependencies.count,
              !dependencies.contains(id) else { throw ValidationError("Invalid module ID or dependencies.") }
        guard version > 0, !name.isEmpty, name.count <= 100, summary.count <= 1000, publisher.count <= 100,
              source.scheme == "https", source.host != nil, source.user == nil, source.password == nil else {
            throw ValidationError("The module manifest contains invalid metadata.")
        }
        guard runtime == nil || capability == .resourceMonitor else { throw ValidationError("This native worker role is not supported.") }
    }
    public static func validID(_ id: String) -> Bool {
        !id.isEmpty && id == id.lowercased() && id.count <= 80 && !id.hasPrefix(".") && !id.contains("..") &&
        id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }
    }
    public static func decode(_ data: Data) throws -> ModuleManifest {
        guard data.count <= 32 * 1024 else { throw ValidationError("Module manifest exceeds 32 KB.") }
        let manifest = try JSONDecoder().decode(Self.self, from: data)
        try manifest.validate()
        return manifest
    }
}
public struct InstalledModule: Identifiable, Equatable, Sendable {
    public let manifest: ModuleManifest
    public var enabled: Bool
    public var id: String { manifest.id }
    public let diskBytes: Int
}
private struct ModuleReceipt: Codable { var enabled: Bool }
private struct ModuleTransaction: Codable { let id: String; let stage: String; let backup: String }

/// Native resource packages contain their executable payload. Other capabilities remain descriptors.
/// Execution trust is checked by the application against its bundled first-party worker bytes.
public struct ModuleRepository: Sendable {
    public let root: URL
    public init(root: URL) throws {
        self.root = root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try rejectLink(root)
        try recoverInterruptedInstallation()
    }
    public func installed() throws -> [InstalledModule] {
        let folders = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey], options: [.skipsHiddenFiles])
        for folder in folders { try rejectLink(folder) }
        var result = try folders.filter { try $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true }.map { directory in
            guard ModuleManifest.validID(directory.lastPathComponent) else { throw ValidationError("An installed module has an invalid folder name.") }
            try rejectLink(directory)
            let manifestURL = directory.appendingPathComponent("manifest.json")
            let receiptURL = directory.appendingPathComponent("receipt.json")
            try rejectLink(manifestURL); try rejectLink(receiptURL)
            let data = try boundedRead(manifestURL, limit: 32 * 1024)
            let manifest = try ModuleManifest.decode(data)
            guard manifest.id == directory.lastPathComponent else { throw ValidationError("Module folder and manifest IDs do not match.") }
            let receiptData = try boundedRead(receiptURL, limit: 1024)
            let receipt = try JSONDecoder().decode(ModuleReceipt.self, from: receiptData)
            let payloadBytes: Int
            if manifest.runtime != nil {
                let payload = directory.appendingPathComponent("worker")
                // Inventory must stay readable when a regular payload is damaged or missing,
                // so the native package's Reinstall action remains available after relaunch.
                payloadBytes = try workerPayloadSize(payload) ?? 0
            } else { payloadBytes = 0 }
            return InstalledModule(manifest: manifest, enabled: receipt.enabled, diskBytes: data.count + receiptData.count + payloadBytes)
        }.sorted { $0.manifest.name < $1.manifest.name }
        let selection = try resourceProviderSelection()
        // A single atomic selector controls the role, including disabled/uninstalled selections.
        // Old receipts are honored until the user explicitly changes the selected provider.
        let selected = selection ?? result.first(where: { $0.enabled && $0.manifest.capability == .resourceMonitor && $0.manifest.defaultInstalled })?.id
            ?? result.first(where: { $0.enabled && $0.manifest.capability == .resourceMonitor })?.id
        for index in result.indices where result[index].manifest.capability == .resourceMonitor {
            result[index].enabled = result[index].id == selected
        }
        return result
    }
    public func installationPlan(for id: String, catalog: [ModuleManifest]) throws -> [ModuleManifest] {
        let existing = try installed()
        var index: [String: ModuleManifest] = [:]
        for manifest in catalog {
            try manifest.validate()
            guard index.updateValue(manifest, forKey: manifest.id) == nil else { throw ValidationError("Catalog contains duplicate module IDs.") }
        }
        var visiting = Set<String>(), visited = Set<String>(), result: [ModuleManifest] = []
        func visit(_ current: String) throws {
            if visited.contains(current) { return }
            guard visiting.insert(current).inserted else { throw ValidationError("Modules have circular dependencies.") }
            guard let manifest = index[current] ?? existing.first(where: { $0.id == current })?.manifest else {
                throw ValidationError("A required module is missing: \(current).")
            }
            for dependency in manifest.dependencies { try visit(dependency) }
            visiting.remove(current); visited.insert(current)
            if !existing.contains(where: { $0.id == current && $0.manifest.version >= manifest.version && $0.enabled }) {
                result.append(manifest)
            }
        }
        try visit(id)
        return result
    }
    public func install(_ manifest: ModuleManifest, enabled: Bool? = nil, payload: Data? = nil) throws {
        try manifest.validate()
        if manifest.runtime != nil {
            guard let payload, !payload.isEmpty, payload.count <= 8 * 1024 * 1024 else {
                throw ValidationError("A native resource package needs its executable payload (up to 8 MB).")
            }
        } else if payload != nil { throw ValidationError("Descriptor packages cannot contain executable payloads.") }
        try recoverInterruptedInstallation()
        let existing = try installed()
        let previous = existing.first { $0.id == manifest.id }
        let hasProvider = existing.contains { $0.enabled && $0.manifest.capability == .resourceMonitor && $0.id != manifest.id }
        let activate = enabled ?? previous?.enabled ?? !(manifest.capability == .resourceMonitor && hasProvider)
        let directory = root.appendingPathComponent(manifest.id, isDirectory: true)
        let staging = root.appendingPathComponent(".stage-" + UUID().uuidString, isDirectory: true)
        let backup = root.appendingPathComponent(".backup-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: staging) }
        try JSONEncoder().encode(manifest).write(to: staging.appendingPathComponent("manifest.json"), options: .atomic)
        try JSONEncoder().encode(ModuleReceipt(enabled: activate)).write(to: staging.appendingPathComponent("receipt.json"), options: .atomic)
        if let payload {
            let executable = staging.appendingPathComponent("worker")
            try payload.write(to: executable, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        }
        let transaction = ModuleTransaction(id: manifest.id, stage: staging.lastPathComponent, backup: backup.lastPathComponent)
        let journal = root.appendingPathComponent(".transaction.json")
        try JSONEncoder().encode(transaction).write(to: journal, options: .atomic)
        let replacing = FileManager.default.fileExists(atPath: directory.path)
        if replacing { try rejectLink(directory); try FileManager.default.moveItem(at: directory, to: backup) }
        do {
            try FileManager.default.moveItem(at: staging, to: directory)
            if replacing { try FileManager.default.removeItem(at: backup) }
            try FileManager.default.removeItem(at: journal)
            if manifest.capability == .resourceMonitor && !hasProvider {
                try writeResourceProviderSelection(activate ? manifest.id : "")
            }
        } catch {
            if replacing && !FileManager.default.fileExists(atPath: directory.path) { try? FileManager.default.moveItem(at: backup, to: directory) }
            throw error
        }
    }
    public func setEnabled(_ id: String, _ enabled: Bool) throws {
        let modules = try installed()
        guard let module = modules.first(where: { $0.id == id }) else { throw ValidationError("Module is not installed.") }
        if enabled {
            guard module.manifest.dependencies.allSatisfy({ dep in modules.contains { $0.id == dep && $0.enabled } }) else {
                throw ValidationError("Enable this module's dependencies first.")
            }
        } else { try requireNoDependents(id, modules: modules.filter(\.enabled)) }
        if module.manifest.capability == .resourceMonitor {
            if enabled, let active = modules.first(where: { $0.enabled && $0.manifest.capability == .resourceMonitor && $0.id != id }) {
                throw ValidationError("Choose Replace to switch from \(active.manifest.name).")
            }
            if enabled || module.enabled { try writeResourceProviderSelection(enabled ? id : "") }
            return
        }
        try JSONEncoder().encode(ModuleReceipt(enabled: enabled)).write(to: root.appendingPathComponent(id).appendingPathComponent("receipt.json"), options: .atomic)
    }
    public func replaceResourceProvider(with id: String) throws {
        let modules = try installed()
        guard let replacement = modules.first(where: { $0.id == id }), replacement.manifest.runtime == .nativeResourceWorker else {
            throw ValidationError("Choose an installed native resource provider.")
        }
        guard replacement.manifest.dependencies.allSatisfy({ dependency in modules.contains { $0.id == dependency && $0.enabled } }) else {
            throw ValidationError("Enable this provider's dependencies first.")
        }
        for active in modules where active.enabled && active.manifest.capability == .resourceMonitor && active.id != id {
            try requireNoDependents(active.id, modules: modules.filter(\.enabled))
        }
        try writeResourceProviderSelection(id)
    }
    public func workerURL(for id: String) throws -> URL {
        guard let module = try installed().first(where: { $0.id == id }), module.enabled,
              module.manifest.runtime == .nativeResourceWorker else { throw ValidationError("This resource worker is not enabled.") }
        let url = root.appendingPathComponent(id).appendingPathComponent("worker")
        guard let size = try workerPayloadSize(url), size > 0, size <= 8 * 1024 * 1024,
              FileManager.default.isExecutableFile(atPath: url.path) else {
            throw ValidationError("This worker is missing, damaged, or not executable. Choose Reinstall bundled package in Modules.")
        }
        return url
    }
    public func uninstall(_ id: String) throws {
        guard ModuleManifest.validID(id) else { throw ValidationError("Invalid module ID.") }
        let modules = try installed()
        guard modules.contains(where: { $0.id == id }) else { throw ValidationError("Module is not installed.") }
        try requireNoDependents(id, modules: modules)
        let directory = root.appendingPathComponent(id, isDirectory: true)
        try rejectLink(directory)
        try FileManager.default.removeItem(at: directory)
        if modules.contains(where: { $0.id == id && $0.enabled && $0.manifest.capability == .resourceMonitor }) {
            try writeResourceProviderSelection("")
        }
    }
    public func disableAll() throws {
        try writeResourceProviderSelection("")
        for module in try installed() {
            try JSONEncoder().encode(ModuleReceipt(enabled: false)).write(to: root.appendingPathComponent(module.id).appendingPathComponent("receipt.json"), options: .atomic)
        }
    }
    public func seedDefaults(_ catalog: [ModuleManifest], payloads: [String: Data] = [:]) throws {
        let marker = root.appendingPathComponent(".initialized")
        guard !FileManager.default.fileExists(atPath: marker.path) else { return }
        for manifest in catalog where manifest.defaultInstalled {
            for item in try installationPlan(for: manifest.id, catalog: catalog) { try install(item, payload: payloads[item.id]) }
        }
        try Data("1".utf8).write(to: marker, options: .atomic)
    }
    private func recoverInterruptedInstallation() throws {
        let journal = root.appendingPathComponent(".transaction.json")
        guard FileManager.default.fileExists(atPath: journal.path) else { return }
        try rejectLink(journal)
        let transaction = try JSONDecoder().decode(ModuleTransaction.self, from: boundedRead(journal, limit: 1024))
        guard ModuleManifest.validID(transaction.id), transaction.stage.hasPrefix(".stage-"),
              UUID(uuidString: String(transaction.stage.dropFirst(7))) != nil,
              transaction.backup.hasPrefix(".backup-"), UUID(uuidString: String(transaction.backup.dropFirst(8))) != nil else {
            throw ValidationError("An interrupted module update has an invalid journal. Reset modules in Recovery.")
        }
        let destination = root.appendingPathComponent(transaction.id, isDirectory: true)
        let stage = root.appendingPathComponent(transaction.stage, isDirectory: true)
        let backup = root.appendingPathComponent(transaction.backup, isDirectory: true)
        for file in [destination, stage, backup] where FileManager.default.fileExists(atPath: file.path) { try rejectLink(file) }
        if !FileManager.default.fileExists(atPath: destination.path) {
            if FileManager.default.fileExists(atPath: backup.path) { try FileManager.default.moveItem(at: backup, to: destination) }
            else if FileManager.default.fileExists(atPath: stage.path) {
                let manifestURL = stage.appendingPathComponent("manifest.json"); try rejectLink(manifestURL)
                let manifest = try ModuleManifest.decode(boundedRead(manifestURL, limit: 32 * 1024))
                guard manifest.id == transaction.id else { throw ValidationError("An interrupted installation has mismatched metadata.") }
                try FileManager.default.moveItem(at: stage, to: destination)
            }
        }
        for file in [stage, backup] where FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        try FileManager.default.removeItem(at: journal)
    }
    private func requireNoDependents(_ id: String, modules: [InstalledModule]) throws {
        if let dependent = modules.first(where: { $0.manifest.dependencies.contains(id) }) {
            throw ValidationError("Remove or disable \(dependent.manifest.name) first; it needs this module.")
        }
    }
    private func resourceProviderSelection() throws -> String? {
        let file = root.appendingPathComponent(".resource-provider.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        try rejectLink(file)
        let id = try JSONDecoder().decode(String.self, from: boundedRead(file, limit: 1024))
        guard id.isEmpty || ModuleManifest.validID(id) else { throw ValidationError("The resource provider selection is invalid.") }
        return id
    }
    private func writeResourceProviderSelection(_ id: String) throws {
        let file = root.appendingPathComponent(".resource-provider.json")
        if FileManager.default.fileExists(atPath: file.path) { try rejectLink(file) }
        try JSONEncoder().encode(id).write(to: file, options: .atomic)
    }
    private func rejectLink(_ url: URL) throws {
        if try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true { throw ValidationError("Symbolic links are not accepted in module packages.") }
    }
    private func workerPayloadSize(_ url: URL) throws -> Int? {
        do {
            // attributesOfItem inspects the link itself, including dangling symlinks.
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else {
                throw ValidationError("Module workers must be regular files, not links or directories. Reset modules in Recovery.")
            }
            return attributes[.size] as? Int ?? 0
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return nil
        }
    }
    private func boundedRead(_ url: URL, limit: Int) throws -> Data {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= limit else { throw ValidationError("Module file is too large.") }
        let data = try Data(contentsOf: url)
        guard data.count <= limit else { throw ValidationError("Module file is too large.") }
        return data
    }
}
