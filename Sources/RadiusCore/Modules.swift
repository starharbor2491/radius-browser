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
    public init(id: String, name: String, version: Int = 1, summary: String, publisher: String = "Radius",
                source: URL = URL(string: "https://github.com/starharbor2491/radius-browser")!,
                capability: ModuleCapability, dependencies: [String] = [], defaultInstalled: Bool = true) {
        self.id = id; self.name = name; self.version = version; self.summary = summary
        self.publisher = publisher; self.source = source; self.capability = capability
        self.dependencies = dependencies; self.defaultInstalled = defaultInstalled
    }
    public func validate() throws {
        guard Self.validID(id), dependencies.allSatisfy(Self.validID), Set(dependencies).count == dependencies.count,
              !dependencies.contains(id) else { throw ValidationError("Invalid module ID or dependencies.") }
        guard version > 0, !name.isEmpty, name.count <= 100, summary.count <= 1000, publisher.count <= 100,
              source.scheme == "https", source.host != nil, source.user == nil, source.password == nil else {
            throw ValidationError("The module manifest contains invalid metadata.")
        }
    }
    public static func validID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 80 && !id.hasPrefix(".") && !id.contains("..") &&
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

/// Declarative packages only. The host exposes five narrow capabilities, never arbitrary native code.
/// Removing a package deletes its files; activation depends on a valid installed manifest and receipt.
public struct ModuleRepository: Sendable {
    public let root: URL
    public init(root: URL) throws {
        self.root = root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    public func installed() throws -> [InstalledModule] {
        let folders = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey], options: [.skipsHiddenFiles])
        for folder in folders { try rejectLink(folder) }
        return try folders.filter { try $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true }.map { directory in
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
            return InstalledModule(manifest: manifest, enabled: receipt.enabled, diskBytes: data.count + receiptData.count)
        }.sorted { $0.manifest.name < $1.manifest.name }
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
    public func install(_ manifest: ModuleManifest, enabled: Bool? = nil) throws {
        try manifest.validate()
        let previous = try installed().first { $0.id == manifest.id }
        let activate = enabled ?? previous?.enabled ?? true
        let directory = root.appendingPathComponent(manifest.id, isDirectory: true)
        let staging = root.appendingPathComponent(".stage-" + UUID().uuidString, isDirectory: true)
        let backup = root.appendingPathComponent(".backup-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: staging) }
        try JSONEncoder().encode(manifest).write(to: staging.appendingPathComponent("manifest.json"), options: .atomic)
        try JSONEncoder().encode(ModuleReceipt(enabled: activate)).write(to: staging.appendingPathComponent("receipt.json"), options: .atomic)
        let replacing = FileManager.default.fileExists(atPath: directory.path)
        if replacing { try rejectLink(directory); try FileManager.default.moveItem(at: directory, to: backup) }
        do {
            try FileManager.default.moveItem(at: staging, to: directory)
            if replacing { try FileManager.default.removeItem(at: backup) }
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
        try JSONEncoder().encode(ModuleReceipt(enabled: enabled)).write(to: root.appendingPathComponent(id).appendingPathComponent("receipt.json"), options: .atomic)
    }
    public func uninstall(_ id: String) throws {
        guard ModuleManifest.validID(id) else { throw ValidationError("Invalid module ID.") }
        let modules = try installed()
        guard modules.contains(where: { $0.id == id }) else { throw ValidationError("Module is not installed.") }
        try requireNoDependents(id, modules: modules)
        let directory = root.appendingPathComponent(id, isDirectory: true)
        try rejectLink(directory)
        try FileManager.default.removeItem(at: directory)
    }
    public func disableAll() throws {
        for module in try installed() {
            try JSONEncoder().encode(ModuleReceipt(enabled: false)).write(to: root.appendingPathComponent(module.id).appendingPathComponent("receipt.json"), options: .atomic)
        }
    }
    public func seedDefaults(_ catalog: [ModuleManifest]) throws {
        let marker = root.appendingPathComponent(".initialized")
        guard !FileManager.default.fileExists(atPath: marker.path) else { return }
        for manifest in catalog where manifest.defaultInstalled {
            for item in try installationPlan(for: manifest.id, catalog: catalog) { try install(item) }
        }
        try Data("1".utf8).write(to: marker, options: .atomic)
    }
    private func requireNoDependents(_ id: String, modules: [InstalledModule]) throws {
        if let dependent = modules.first(where: { $0.manifest.dependencies.contains(id) }) {
            throw ValidationError("Remove or disable \(dependent.manifest.name) first; it needs this module.")
        }
    }
    private func rejectLink(_ url: URL) throws {
        if try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true { throw ValidationError("Symbolic links are not accepted in module packages.") }
    }
    private func boundedRead(_ url: URL, limit: Int) throws -> Data {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= limit else { throw ValidationError("Module file is too large.") }
        let data = try Data(contentsOf: url)
        guard data.count <= limit else { throw ValidationError("Module file is too large.") }
        return data
    }
}
