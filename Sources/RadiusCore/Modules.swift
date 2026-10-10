// SPDX-License-Identifier: MPL-2.0
import Foundation

public enum ModuleCapability: String, Codable, CaseIterable, Sendable {
    case resourceMonitor, notes, reader, screenshot, focusMode, tabSystem, theme, layout, icons, menu, startWidget
    public var permission: String? {
        switch self {
        case .resourceMonitor: "Read system CPU and memory statistics. No browsing data is read."
        case .reader: "Read the current page when you choose Reader."
        case .screenshot: "Capture the current page when you choose Save screenshot."
        case .notes, .focusMode, .tabSystem, .theme, .layout, .icons, .menu, .startWidget: nil
        }
    }
    public var isExclusive: Bool { [.resourceMonitor, .notes, .screenshot, .focusMode, .tabSystem, .theme, .layout, .icons, .menu].contains(self) }
}
public enum ModuleRuntime: String, Codable, Sendable {
    case nativeResourceWorker, nativeReaderWorker, behaviorProgram, declarative
    public var isNative: Bool { self == .nativeResourceWorker || self == .nativeReaderWorker }
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
    public var settings: [ModuleSetting]?
    public var minimumHostVersion: Int?
    public var dependencyVersions: [String: Int]?
    public init(id: String, name: String, version: Int = 1, summary: String, publisher: String = "Radius",
                source: URL = URL(string: "https://github.com/starharbor2491/radius-browser")!,
                capability: ModuleCapability, dependencies: [String] = [], defaultInstalled: Bool = true, runtime: ModuleRuntime? = nil, settings: [ModuleSetting]? = nil, minimumHostVersion: Int? = nil, dependencyVersions: [String: Int]? = nil) {
        self.id = id; self.name = name; self.version = version; self.summary = summary
        self.publisher = publisher; self.source = source; self.capability = capability
        self.dependencies = dependencies; self.defaultInstalled = defaultInstalled
        self.runtime = runtime; self.settings = settings; self.minimumHostVersion = minimumHostVersion
        self.dependencyVersions = dependencyVersions
    }
    public func validate() throws {
        guard Self.validID(id), dependencies.count <= 32, dependencies.allSatisfy(Self.validID), Set(dependencies).count == dependencies.count,
              !dependencies.contains(id) else { throw ValidationError("Invalid module ID or dependencies.") }
        guard version > 0, !name.isEmpty, name.count <= 100, summary.count <= 1000, publisher.count <= 100,
              source.scheme == "https", source.host != nil, source.user == nil, source.password == nil else {
            throw ValidationError("The module manifest contains invalid metadata.")
        }
        guard (minimumHostVersion ?? 1) == 1 else { throw ValidationError("This module requires a newer Radius version.") }
        guard (dependencyVersions ?? [:]).allSatisfy({ dependencies.contains($0.key) && (1...100_000).contains($0.value) }) else {
            throw ValidationError("Dependency version requirements are invalid.")
        }
        guard (settings?.count ?? 0) <= 16, Set((settings ?? []).map(\.id)).count == (settings?.count ?? 0) else { throw ValidationError("Module settings are invalid.") }
        for setting in settings ?? [] { try setting.validate() }
        let declarativeRoles: Set<ModuleCapability> = [.tabSystem, .theme, .layout, .icons, .menu, .startWidget]
        guard runtime == nil || (runtime == .nativeResourceWorker && capability == .resourceMonitor) ||
              (runtime == .nativeReaderWorker && capability == .reader) ||
              (runtime == .behaviorProgram && [.notes, .screenshot, .focusMode].contains(capability)) ||
              (runtime == .declarative && declarativeRoles.contains(capability)) else { throw ValidationError("This module role and runtime are incompatible.") }
        guard try JSONEncoder().encode(self).count <= 32 * 1024 else { throw ValidationError("Module manifest exceeds 32 KB.") }
    }
    public static func validID(_ id: String) -> Bool {
        !id.isEmpty && id == id.lowercased() && id.count <= 80 && !id.hasPrefix(".") && !id.contains("..") &&
        id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }
    }
    public static func decode(_ data: Data) throws -> ModuleManifest {
        guard data.count <= 32 * 1024 else { throw ValidationError("Module manifest exceeds 32 KB.") }
        try ModuleJSONBounds.validate(data)
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
    public let payloadSHA256: String?
}
private struct ModuleReceipt: Codable { var enabled: Bool; var payloadSHA256: String? }
private struct ModuleTransaction: Codable { let id: String; let stage: String; let backup: String }
private struct ModuleBatchEntry: Codable { let id: String; let existed: Bool }
private struct ModuleBatchTransaction: Codable {
    let directory: String
    let entries: [ModuleBatchEntry]
    let selectors: [String: Data]
    let absentSelectors: [String]
}

/// Every modern package stores its native code, behavior program, or declarative definition.
/// Execution trust is checked by the application against its bundled first-party worker bytes.
public struct ModuleRepository: Sendable {
    public let root: URL
    public init(root: URL) throws {
        self.root = root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try rejectLink(root)
        try recoverInterruptedInstallation()
        try recoverBatchChanges()
        try cleanOrphanBatchBackups()
    }
    public func installed() throws -> [InstalledModule] {
        let folders = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey], options: [.skipsHiddenFiles])
        guard folders.count <= 512 else { throw ValidationError("The installed module inventory exceeds its size limit.") }
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
            if manifest.runtime?.isNative == true {
                let payload = directory.appendingPathComponent("worker")
                // Inventory must stay readable when a regular payload is damaged or missing,
                // so the native package's Reinstall action remains available after relaunch.
                payloadBytes = try workerPayloadSize(payload) ?? 0
            } else if manifest.runtime != nil {
                let payload = directory.appendingPathComponent(manifest.runtime == .behaviorProgram ? "program.json" : "definition.json")
                payloadBytes = try workerPayloadSize(payload) ?? 0
            } else { payloadBytes = 0 }
            return InstalledModule(manifest: manifest, enabled: receipt.enabled, diskBytes: data.count + receiptData.count + payloadBytes, payloadSHA256: receipt.payloadSHA256)
        }.sorted { $0.manifest.name < $1.manifest.name }
        let selection = try resourceProviderSelection()
        // A single atomic selector controls the role, including disabled/uninstalled selections.
        // Old receipts are honored until the user explicitly changes the selected provider.
        let selected = selection ?? result.first(where: { $0.enabled && $0.manifest.capability == .resourceMonitor && $0.manifest.defaultInstalled })?.id
            ?? result.first(where: { $0.enabled && $0.manifest.capability == .resourceMonitor })?.id
        for index in result.indices where result[index].manifest.capability == .resourceMonitor {
            result[index].enabled = result[index].id == selected
        }
        for role in ModuleCapability.allCases where role.isExclusive && role != .resourceMonitor {
            let selected = try roleSelection(role) ?? result.first(where: { $0.enabled && $0.manifest.capability == role && $0.manifest.runtime != nil })?.id
                ?? result.first(where: { $0.enabled && $0.manifest.capability == role })?.id
            for index in result.indices where result[index].manifest.capability == role {
                result[index].enabled = result[index].id == selected
            }
        }
        // Missing, disabled, or incompatible dependencies cannot leave a feature
        // executing after a damaged package or a recovered interrupted operation.
        for _ in 0..<result.count {
            var changed = false
            for index in result.indices where result[index].enabled {
                let manifest = result[index].manifest
                if depends(manifest, on: manifest.id, modules: result) || !manifest.dependencies.allSatisfy({ dependency in result.contains { $0.id == dependency && $0.enabled && $0.manifest.version >= (manifest.dependencyVersions?[dependency] ?? 1) } }) {
                    result[index].enabled = false; changed = true
                }
            }
            if !changed { break }
        }
        return result
    }
    public func installationPlan(for id: String, catalog: [ModuleManifest], includeInstalled: Bool = false) throws -> [ModuleManifest] {
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
            let catalogManifest = index[current]
            let installedManifest = existing.first(where: { $0.id == current })?.manifest
            let candidate: ModuleManifest?
            if let installedManifest, installedManifest.version >= (catalogManifest?.version ?? 0) { candidate = installedManifest }
            else { candidate = catalogManifest ?? installedManifest }
            guard let manifest = candidate else {
                throw ValidationError("A required module is missing: \(current).")
            }
            for dependency in manifest.dependencies {
                let availableVersion = max(index[dependency]?.version ?? 0, existing.first(where: { $0.id == dependency })?.manifest.version ?? 0)
                guard availableVersion >= (manifest.dependencyVersions?[dependency] ?? 1) else {
                    throw ValidationError("\(manifest.name) requires \(dependency) v\(manifest.dependencyVersions?[dependency] ?? 1) or later.")
                }
                try visit(dependency)
            }
            visiting.remove(current); visited.insert(current)
            if includeInstalled || !existing.contains(where: { $0.id == current && $0.manifest.version >= manifest.version && $0.enabled }) {
                result.append(manifest)
            }
        }
        try visit(id)
        return result
    }
    /// Dependency/setup changes either commit together or restore their package
    /// and provider snapshots, including after a process interruption. Module data
    /// lives separately and is deliberately not changed by this transaction.
    public func withAtomicChanges<T>(for ids: [String], _ operation: () throws -> T) throws -> T {
        guard !ids.isEmpty else { return try operation() }
        guard ids.count <= 128, Set(ids).count == ids.count, ids.allSatisfy(ModuleManifest.validID) else { throw ValidationError("A module transaction exceeds its package limit.") }
        let journal = root.appendingPathComponent(".batch-transaction.json")
        guard !FileManager.default.fileExists(atPath: journal.path) else { throw ValidationError("Another module operation is pending. Relaunch Radius to recover it.") }
        try recoverInterruptedInstallation()
        let modules = try installed()
        let backup = root.appendingPathComponent(".batch-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var journalWritten = false
        defer { if !journalWritten { try? FileManager.default.removeItem(at: backup) } }
        var entries: [ModuleBatchEntry] = [], bytes = 0
        for id in ids {
            let existing = modules.first(where: { $0.id == id })
            entries.append(ModuleBatchEntry(id: id, existed: existing != nil))
            if let existing {
                let directory = root.appendingPathComponent(id), destination = backup.appendingPathComponent(id, isDirectory: true)
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
                let payload = existing.manifest.runtime?.isNative == true ? "worker" : existing.manifest.runtime == .behaviorProgram ? "program.json" : "definition.json"
                for name in ["manifest.json", "receipt.json"] + (existing.manifest.runtime == nil ? [] : [payload]) {
                    let file = directory.appendingPathComponent(name)
                    guard FileManager.default.fileExists(atPath: file.path) else { continue }
                    guard let size = try workerPayloadSize(file), size <= (name == "worker" ? 8 * 1024 * 1024 : name == "manifest.json" ? 32 * 1024 : name == "receipt.json" ? 1024 : 128 * 1024) else { throw ValidationError("A damaged package cannot be backed up. Reinstall it before changing a setup.") }
                    bytes += size
                    guard bytes <= 128 * 1024 * 1024 else { throw ValidationError("This module operation exceeds the 128 MB backup limit.") }
                    try FileManager.default.copyItem(at: file, to: destination.appendingPathComponent(name))
                }
            }
        }
        var selectors: [String: Data] = [:], absent: [String] = []
        for name in selectorNames {
            let file = root.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: file.path) { try rejectLink(file); selectors[name] = try boundedRead(file, limit: 1024) }
            else { absent.append(name) }
        }
        let transaction = ModuleBatchTransaction(directory: backup.lastPathComponent, entries: entries, selectors: selectors, absentSelectors: absent)
        try JSONEncoder().encode(transaction).write(to: journal, options: .atomic); journalWritten = true
        do {
            let result = try operation()
            try FileManager.default.removeItem(at: journal)
            journalWritten = false
            return result
        } catch {
            try recoverInterruptedInstallation()
            try recoverBatchChanges(); journalWritten = false
            throw error
        }
    }
    public func install(_ manifest: ModuleManifest, enabled: Bool? = nil, payload: Data? = nil) throws {
        try manifest.validate()
        if manifest.runtime?.isNative == true {
            guard let payload, !payload.isEmpty, payload.count <= 8 * 1024 * 1024 else {
                throw ValidationError("A native package needs its executable payload (up to 8 MB).")
            }
        } else if manifest.runtime == .behaviorProgram {
            guard let payload else { throw ValidationError("A behavior package needs its program.") }; try ModuleProgram.decode(payload).validate(capability: manifest.capability)
        } else if manifest.runtime == .declarative {
            guard let payload else { throw ValidationError("A declarative package needs its definition.") }; _ = try ModuleDefinition.decode(payload, capability: manifest.capability)
        } else if payload != nil { throw ValidationError("Legacy descriptor packages cannot contain payloads.") }
        try recoverInterruptedInstallation()
        let existing = try installed()
        let previous = existing.first { $0.id == manifest.id }
        let exclusive = manifest.capability.isExclusive
        let hasProvider = existing.contains { exclusive && $0.enabled && $0.manifest.capability == manifest.capability && $0.id != manifest.id && (manifest.runtime == nil || $0.manifest.runtime != nil) }
        let activate = enabled ?? previous?.enabled ?? !hasProvider
        let directory = root.appendingPathComponent(manifest.id, isDirectory: true)
        let staging = root.appendingPathComponent(".stage-" + UUID().uuidString, isDirectory: true)
        let backup = root.appendingPathComponent(".backup-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: staging) }
        try JSONEncoder().encode(manifest).write(to: staging.appendingPathComponent("manifest.json"), options: .atomic)
        try JSONEncoder().encode(ModuleReceipt(enabled: activate, payloadSHA256: payload.map(ModuleDigest.sha256))).write(to: staging.appendingPathComponent("receipt.json"), options: .atomic)
        if let payload {
            let executable = staging.appendingPathComponent(manifest.runtime?.isNative == true ? "worker" : manifest.runtime == .behaviorProgram ? "program.json" : "definition.json")
            try payload.write(to: executable, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: manifest.runtime?.isNative == true ? 0o700 : 0o600], ofItemAtPath: executable.path)
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
            if exclusive && !hasProvider {
                if manifest.capability == .resourceMonitor { try writeResourceProviderSelection(activate ? manifest.id : "") }
                else { try writeRoleSelection(manifest.capability, id: activate ? manifest.id : "") }
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
            guard module.manifest.dependencies.allSatisfy({ dep in modules.contains { $0.id == dep && $0.enabled && $0.manifest.version >= (module.manifest.dependencyVersions?[dep] ?? 1) } }) else {
                throw ValidationError("Enable this module's dependencies first.")
            }
        } else { try requireNoDependents(id, modules: modules.filter(\.enabled)) }
        if module.manifest.capability.isExclusive && module.manifest.capability != .resourceMonitor {
            guard module.manifest.capability != .tabSystem || enabled || !module.enabled else { throw ValidationError("Replace the active tab system before disabling it. Your tabs are kept.") }
            if enabled, let active = modules.first(where: { $0.enabled && $0.manifest.capability == module.manifest.capability && $0.id != id }) {
                throw ValidationError("Choose Replace to switch from \(active.manifest.name).")
            }
            if enabled || module.enabled { try writeRoleSelection(module.manifest.capability, id: enabled ? id : "") }
            return
        }
        if module.manifest.capability == .resourceMonitor {
            if enabled, let active = modules.first(where: { $0.enabled && $0.manifest.capability == .resourceMonitor && $0.id != id }) {
                throw ValidationError("Choose Replace to switch from \(active.manifest.name).")
            }
            if enabled || module.enabled { try writeResourceProviderSelection(enabled ? id : "") }
            return
        }
        try JSONEncoder().encode(ModuleReceipt(enabled: enabled, payloadSHA256: module.payloadSHA256)).write(to: root.appendingPathComponent(id).appendingPathComponent("receipt.json"), options: .atomic)
    }
    public func replaceResourceProvider(with id: String) throws {
        let modules = try installed()
        guard let replacement = modules.first(where: { $0.id == id }), replacement.manifest.runtime == .nativeResourceWorker else {
            throw ValidationError("Choose an installed native resource provider.")
        }
        guard replacement.manifest.dependencies.allSatisfy({ dependency in modules.contains { $0.id == dependency && $0.enabled && $0.manifest.version >= (replacement.manifest.dependencyVersions?[dependency] ?? 1) } }) else {
            throw ValidationError("Enable this provider's dependencies first.")
        }
        for active in modules where active.enabled && active.manifest.capability == .resourceMonitor && active.id != id {
            guard !depends(replacement.manifest, on: active.id, modules: modules) else { throw ValidationError("A replacement cannot depend on the provider it replaces.") }
            try requireNoDependents(active.id, modules: modules.filter(\.enabled))
        }
        try writeResourceProviderSelection(id)
    }
    public func replaceProvider(role: ModuleCapability, with id: String) throws {
        guard role.isExclusive else { throw ValidationError("This module role allows multiple independent modules.") }
        if role == .resourceMonitor { try replaceResourceProvider(with: id); return }
        let modules = try installed()
        guard let replacement = modules.first(where: { $0.id == id && $0.manifest.capability == role }) else { throw ValidationError("Choose an installed provider for this role.") }
        if replacement.manifest.runtime == .behaviorProgram { _ = try behaviorProgram(for: id, requireEnabled: false) }
        else if replacement.manifest.runtime == .declarative { _ = try definition(for: id, requireEnabled: false) }
        else { throw ValidationError("Choose a compatible data program or declarative provider.") }
        guard replacement.manifest.dependencies.allSatisfy({ dependency in modules.contains { $0.id == dependency && $0.enabled && $0.manifest.version >= (replacement.manifest.dependencyVersions?[dependency] ?? 1) } }) else {
            throw ValidationError("Enable this provider's dependencies first.")
        }
        for active in modules where active.enabled && active.manifest.capability == role && active.id != id {
            guard !depends(replacement.manifest, on: active.id, modules: modules) else { throw ValidationError("A replacement cannot depend on the provider it replaces.") }
            try requireNoDependents(active.id, modules: modules.filter(\.enabled))
        }
        try writeRoleSelection(role, id: id)
    }
    public func behaviorProgram(for id: String, requireEnabled: Bool = true) throws -> ModuleProgram {
        let payload = try dataPayload(for: id, runtime: .behaviorProgram, requireEnabled: requireEnabled)
        let program = try ModuleProgram.decode(payload)
        guard let module = try installed().first(where: { $0.id == id }) else { throw ValidationError("This module is not installed.") }
        try program.validate(capability: module.manifest.capability)
        return program
    }
    public func definition(for id: String, requireEnabled: Bool = true) throws -> ModuleDefinition {
        let modules = try installed()
        guard let manifest = modules.first(where: { $0.id == id })?.manifest else { throw ValidationError("This module is not installed.") }
        return try ModuleDefinition.decode(dataPayload(for: id, runtime: .declarative, requireEnabled: requireEnabled), capability: manifest.capability)
    }
    public func dataPayload(for id: String, runtime: ModuleRuntime, requireEnabled: Bool = true) throws -> Data {
        guard !runtime.isNative, let module = try installed().first(where: { $0.id == id }),
              module.manifest.runtime == runtime, !requireEnabled || module.enabled else { throw ValidationError("This module package is not enabled.") }
        let url = root.appendingPathComponent(id).appendingPathComponent(runtime == .behaviorProgram ? "program.json" : "definition.json")
        guard let size = try workerPayloadSize(url), size > 0, size <= 128 * 1024 else { throw ValidationError("The module payload is missing or damaged. Reinstall its package.") }
        let payload = try boundedRead(url, limit: 128 * 1024)
        guard let checksum = module.payloadSHA256, ModuleDigest.sha256(payload) == checksum else { throw ValidationError("This module's payload differs from its installation receipt. Reinstall its package.") }
        return payload
    }
    public func settings(for id: String) throws -> [String: ModuleValue] {
        guard let module = try installed().first(where: { $0.id == id }) else { throw ValidationError("This module is not installed.") }
        var values = Dictionary(uniqueKeysWithValues: (module.manifest.settings ?? []).map { ($0.id, $0.defaultValue) })
        let url = try settingsURL(id)
        if FileManager.default.fileExists(atPath: url.path) {
            try rejectLink(url)
            let data = try boundedRead(url, limit: 64 * 1024)
            try ModuleJSONBounds.validate(data)
            let saved = try JSONDecoder().decode([String: ModuleValue].self, from: data)
            try ModuleValue.object(saved).validate()
            for schema in module.manifest.settings ?? [] {
                if let value = saved[schema.id], (try? schema.validate(value: value)) != nil { values[schema.id] = value }
            }
        }
        return values
    }
    public func setSetting(_ key: String, value: ModuleValue, for id: String) throws {
        guard let schema = try installed().first(where: { $0.id == id })?.manifest.settings?.first(where: { $0.id == key }) else {
            throw ValidationError("This module has no setting with that name.")
        }
        try schema.validate(value: value)
        var values = try settings(for: id); values[key] = value
        let data = try JSONEncoder().encode(values)
        guard data.count <= 64 * 1024 else { throw ValidationError("Module settings exceed 64 KB.") }
        try data.write(to: settingsURL(id), options: .atomic)
    }
    public func deleteSettings(for id: String) throws {
        let url = try settingsURL(id)
        if FileManager.default.fileExists(atPath: url.path) { try rejectLink(url); try FileManager.default.removeItem(at: url) }
    }
    public func communityCatalogs() throws -> [DeclarativeModuleCatalog] {
        let paths = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(".catalog-") && $0.pathExtension == "json" }
        guard paths.count <= 16 else { throw ValidationError("Too many community catalogs. Remove a catalog before adding another.") }
        return try paths.map { try rejectLink($0); return try DeclarativeModuleCatalog.decode(boundedRead($0, limit: 2 * 1024 * 1024)) }
    }
    public func addCommunityCatalog(_ catalog: DeclarativeModuleCatalog, reservedIDs: Set<String>, replaceExisting: Bool = false) throws {
        let encoded = try JSONEncoder().encode(catalog)
        _ = try DeclarativeModuleCatalog.decode(encoded)
        let existing = try communityCatalogs()
        let previous = existing.first(where: { $0.name == catalog.name })
        let existingIDs = Set(existing.filter { $0.name != catalog.name }.flatMap { $0.packages.map { $0.manifest.id } })
        guard (existing.count < 16 || previous != nil), (previous == nil || replaceExisting),
              catalog.packages.allSatisfy({ !reservedIDs.contains($0.manifest.id) && !existingIDs.contains($0.manifest.id) }) else {
            throw ValidationError("This catalog conflicts with an existing catalog or bundled module.")
        }
        if let previous {
            for item in catalog.packages {
                if let older = previous.packages.first(where: { $0.manifest.id == item.manifest.id }) {
                    guard item.manifest.version >= older.manifest.version else { throw ValidationError("A community catalog cannot downgrade its module versions.") }
                }
            }
            for path in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
                where path.lastPathComponent.hasPrefix(".catalog-") && path.pathExtension == "json" {
                try rejectLink(path)
                if try DeclarativeModuleCatalog.decode(boundedRead(path, limit: 2 * 1024 * 1024)).name == catalog.name {
                    try encoded.write(to: path, options: .atomic); return
                }
            }
        }
        try encoded.write(to: root.appendingPathComponent(".catalog-" + UUID().uuidString + ".json"), options: .atomic)
    }
    public func removeCommunityCatalog(named name: String) throws {
        for path in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            where path.lastPathComponent.hasPrefix(".catalog-") && path.pathExtension == "json" {
            try rejectLink(path)
            if try DeclarativeModuleCatalog.decode(boundedRead(path, limit: 2 * 1024 * 1024)).name == name { try FileManager.default.removeItem(at: path) }
        }
    }
    public func workerURL(for id: String, requireEnabled: Bool = true) throws -> URL {
        guard let module = try installed().first(where: { $0.id == id }), !requireEnabled || module.enabled,
              module.manifest.runtime?.isNative == true else { throw ValidationError("This native worker is not enabled.") }
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
        guard !modules.contains(where: { $0.id == id && $0.enabled && $0.manifest.capability == .tabSystem }) else {
            throw ValidationError("Replace the active tab system before uninstalling it. Your tabs are kept.")
        }
        let directory = root.appendingPathComponent(id, isDirectory: true)
        try rejectLink(directory)
        try FileManager.default.removeItem(at: directory)
        if modules.contains(where: { $0.id == id && $0.enabled && $0.manifest.capability == .resourceMonitor }) {
            try writeResourceProviderSelection("")
        }
    }
    public func disableAll() throws {
        try writeResourceProviderSelection("")
        for role in ModuleCapability.allCases where role.isExclusive && role != .resourceMonitor { try writeRoleSelection(role, id: "") }
        for module in try installed() {
            try JSONEncoder().encode(ModuleReceipt(enabled: false, payloadSHA256: module.payloadSHA256)).write(to: root.appendingPathComponent(module.id).appendingPathComponent("receipt.json"), options: .atomic)
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
    private var selectorNames: [String] {
        [".resource-provider.json"] + ModuleCapability.allCases.filter { $0.isExclusive && $0 != .resourceMonitor }.map { ".role-" + $0.rawValue + ".json" }
    }
    private func recoverBatchChanges() throws {
        let journal = root.appendingPathComponent(".batch-transaction.json")
        guard FileManager.default.fileExists(atPath: journal.path) else { return }
        try rejectLink(journal)
        let transaction = try JSONDecoder().decode(ModuleBatchTransaction.self, from: boundedRead(journal, limit: 32 * 1024))
        guard transaction.directory.hasPrefix(".batch-"), UUID(uuidString: String(transaction.directory.dropFirst(7))) != nil,
              transaction.entries.count <= 128, !transaction.entries.isEmpty,
              transaction.entries.allSatisfy({ ModuleManifest.validID($0.id) }),
              Set(transaction.entries.map(\.id)).count == transaction.entries.count,
              Set(transaction.selectors.keys).isDisjoint(with: transaction.absentSelectors),
              Set(transaction.selectors.keys).union(transaction.absentSelectors) == Set(selectorNames),
              transaction.selectors.values.allSatisfy({ $0.count <= 1024 }) else { throw ValidationError("An interrupted module operation has an invalid recovery journal.") }
        let backup = root.appendingPathComponent(transaction.directory, isDirectory: true)
        try rejectLink(backup)
        guard try backup.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { throw ValidationError("Module recovery backups are missing. Open Recovery.") }
        // Validate every backup before restoring any package.
        for entry in transaction.entries where entry.existed {
            let directory = backup.appendingPathComponent(entry.id); try rejectLink(directory)
            let file = directory.appendingPathComponent("manifest.json"); try rejectLink(file)
            guard try ModuleManifest.decode(boundedRead(file, limit: 32 * 1024)).id == entry.id else { throw ValidationError("A module recovery backup has invalid metadata.") }
            for child in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) { try rejectLink(child) }
        }
        for entry in transaction.entries {
            let destination = root.appendingPathComponent(entry.id)
            if entry.existed {
                let restore = root.appendingPathComponent(".restore-" + UUID().uuidString)
                try FileManager.default.copyItem(at: backup.appendingPathComponent(entry.id), to: restore)
                defer { try? FileManager.default.removeItem(at: restore) }
                if FileManager.default.fileExists(atPath: destination.path) { try rejectLink(destination); try FileManager.default.removeItem(at: destination) }
                try FileManager.default.moveItem(at: restore, to: destination)
            } else if FileManager.default.fileExists(atPath: destination.path) { try rejectLink(destination); try FileManager.default.removeItem(at: destination) }
        }
        for (name, data) in transaction.selectors {
            let file = root.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: file.path) { try rejectLink(file) }
            try data.write(to: file, options: .atomic)
        }
        for name in transaction.absentSelectors {
            let file = root.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: file.path) { try rejectLink(file); try FileManager.default.removeItem(at: file) }
        }
        try FileManager.default.removeItem(at: journal)
        try FileManager.default.removeItem(at: backup)
    }
    private func cleanOrphanBatchBackups() throws {
        for path in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            where path.lastPathComponent.hasPrefix(".batch-") && UUID(uuidString: String(path.lastPathComponent.dropFirst(7))) != nil {
            try rejectLink(path); try FileManager.default.removeItem(at: path)
        }
    }
    private func requireNoDependents(_ id: String, modules: [InstalledModule]) throws {
        if let dependent = modules.first(where: { $0.manifest.dependencies.contains(id) }) {
            throw ValidationError("Remove or disable \(dependent.manifest.name) first; it needs this module.")
        }
    }
    private func depends(_ manifest: ModuleManifest, on id: String, modules: [InstalledModule]) -> Bool {
        var pending = manifest.dependencies, seen = Set<String>()
        while let current = pending.popLast() {
            if current == id { return true }
            if seen.insert(current).inserted, let dependency = modules.first(where: { $0.id == current }) { pending.append(contentsOf: dependency.manifest.dependencies) }
        }
        return false
    }
    private func settingsURL(_ id: String) throws -> URL {
        guard ModuleManifest.validID(id) else { throw ValidationError("Invalid module ID.") }
        let directory = root.deletingLastPathComponent().appendingPathComponent("ModuleData", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try rejectLink(directory)
        let url = directory.appendingPathComponent(id + ".json")
        if FileManager.default.fileExists(atPath: url.path) { try rejectLink(url) }
        return url
    }
    private func roleSelection(_ role: ModuleCapability) throws -> String? {
        let file = root.appendingPathComponent(".role-" + role.rawValue + ".json")
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        try rejectLink(file)
        let id = try JSONDecoder().decode(String.self, from: boundedRead(file, limit: 1024))
        guard id.isEmpty || ModuleManifest.validID(id) else { throw ValidationError("The module role selection is invalid.") }
        return id
    }
    private func writeRoleSelection(_ role: ModuleCapability, id: String) throws {
        let file = root.appendingPathComponent(".role-" + role.rawValue + ".json")
        if FileManager.default.fileExists(atPath: file.path) { try rejectLink(file) }
        try JSONEncoder().encode(id).write(to: file, options: .atomic)
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
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        let data = try file.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw ValidationError("Module file is too large.") }
        return data
    }
}
