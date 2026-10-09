// SPDX-License-Identifier: MPL-2.0
import AppKit
import SwiftUI
import RadiusCore

@MainActor
final class AppState: ObservableObject {
    @Published var library = LibraryState() { didSet { if ready { scheduleSave() } } }
    @Published var ready = false
    @Published var startupError: String?
    @Published var notice: String?
    @Published var installedModules: [InstalledModule] = []
    @Published var previewConfiguration: Configuration?
    let dataDirectory: URL
    private(set) var catalog: [ModuleManifest] = []
    private var startupTask: Task<Void, Never>?
    private var database: LibraryDatabase?
    private var repository: ModuleRepository?
    private var saveTask: Task<Void, Never>?
    private var revision: UInt64 = 0
    private var claimedSessions = Set<UUID>()
    var terminating = false
    var configuration: Configuration { previewConfiguration ?? library.preferences.configuration }

    init(directory: URL? = nil) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        dataDirectory = directory ?? support.appendingPathComponent("org.radius.browser", isDirectory: true)
        AppDelegate.state = self
    }
    func load() async {
        guard !ready else { return }
        if let startupTask { await startupTask.value; return }
        let task = Task { await self.loadInternal() }
        startupTask = task
        await task.value
        startupTask = nil
    }
    private func loadInternal() async {
        startupError = nil
        do {
            try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            let db = try LibraryDatabase(url: dataDirectory.appendingPathComponent("library.sqlite"))
            let state = try await db.load()
            database = db; library = state
            if !state.preferences.restoreSession { library.sessions = [] }
            try loadCatalog()
            do {
                let repo = try ModuleRepository(root: dataDirectory.appendingPathComponent("Modules", isDirectory: true))
                repository = repo
                try repo.seedDefaults(catalog)
                installedModules = try repo.installed()
            } catch { notice = "Optional modules could not load: \(error.localizedDescription). Open Recovery to repair them." }
            ready = true; startupError = nil
        } catch { startupError = error.localizedDescription }
    }
    private func loadCatalog() throws {
        let directory: URL
        if let packaged = Bundle.main.url(forResource: "Modules", withExtension: nil) { directory = packaged }
        else if let resources = Bundle.module.url(forResource: "Resources", withExtension: nil) { directory = resources.appendingPathComponent("Modules") }
        else { throw ValidationError("The application is missing its bundled resources. Rebuild or reinstall Radius.") }
        catalog = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.hasDirectoryPath }.map { try ModuleManifest.decode(Data(contentsOf: $0.appendingPathComponent("manifest.json"))) }
            .sorted { $0.name < $1.name }
    }
    func enabled(_ capability: ModuleCapability) -> Bool {
        installedModules.contains { $0.enabled && $0.manifest.capability == capability }
    }
    func install(_ id: String) {
        perform {
            guard let repository else { throw ValidationError("Open Recovery to repair module storage first.") }
            let plan = try repository.installationPlan(for: id, catalog: catalog)
            if !approveModules(plan) { return }
            let activate = installedModules.first { $0.id == id }?.enabled ?? true
            for manifest in plan { try repository.install(manifest, enabled: manifest.id != id && activate ? true : nil) }
            installedModules = try repository.installed()
        }
    }
    func importModule() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.canChooseDirectories = false
        panel.message = "Choose a declarative Radius module manifest. Native code and engine packages are not supported in this build."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        perform {
            guard let repository else { throw ValidationError("Repair module storage before importing packages.") }
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 32 * 1024 else { throw ValidationError("Module manifests must be smaller than 32 KB.") }
            let manifest = try ModuleManifest.decode(Data(contentsOf: url))
            guard manifest.dependencies.isEmpty else { throw ValidationError("Local modules with dependencies are not supported yet.") }
            guard !catalog.contains(where: { $0.id == manifest.id }), !installedModules.contains(where: { $0.id == manifest.id }) else {
                throw ValidationError("A module with that ID already exists. Use its official update instead.")
            }
            if approveModules([manifest], local: true) {
                try repository.install(manifest); installedModules = try repository.installed()
            }
        }
    }
    private func approveModules(_ manifests: [ModuleManifest], local: Bool = false) -> Bool {
        guard !manifests.isEmpty else { return true }
        let alert = NSAlert()
        alert.messageText = "Install \(manifests.map(\.name).joined(separator: ", "))?"
        let permissions = Set(manifests.compactMap { $0.capability.permission }).sorted()
        alert.informativeText = (local ? "Publisher information is self-reported. This package can only use Radius's listed declarative capabilities.\n\n" : "Packages are bundled with this Radius build.\n\n") +
            (permissions.isEmpty ? "No website or system permissions are requested." : permissions.joined(separator: "\n\n"))
        alert.addButton(withTitle: "Install"); alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
    func toggleModule(_ module: InstalledModule) {
        perform {
            try repository?.setEnabled(module.id, !module.enabled)
            installedModules = try repository?.installed() ?? []
        }
    }
    func uninstall(_ module: InstalledModule) {
        let alert = NSAlert(); alert.messageText = "Uninstall \(module.manifest.name)?"
        alert.informativeText = "The package will be deleted and its feature will stop. Saved notes and settings are kept unless you choose to delete them."
        alert.addButton(withTitle: "Uninstall and keep data"); alert.addButton(withTitle: "Cancel")
        if module.manifest.capability == .notes { alert.addButton(withTitle: "Uninstall and delete all notes") }
        let response = alert.runModal()
        guard response != .alertSecondButtonReturn else { return }
        perform {
            try repository?.uninstall(module.id)
            installedModules = try repository?.installed() ?? []
            if response == .alertThirdButtonReturn { library.notes.removeAll() }
        }
    }
    func claimSession(privateBrowsing: Bool) -> WindowSession {
        if !privateBrowsing, let saved = library.sessions.first(where: { !claimedSessions.contains($0.id) }) {
            claimedSessions.insert(saved.id); return saved
        }
        let session = WindowSession(profileID: library.profiles[0].id)
        if !privateBrowsing { claimedSessions.insert(session.id); library.sessions.append(session) }
        return session
    }
    func updateSession(_ session: WindowSession) {
        guard ready else { return }
        if let index = library.sessions.firstIndex(where: { $0.id == session.id }) { library.sessions[index] = session }
    }
    func closeSession(_ id: UUID) {
        if !terminating { library.sessions.removeAll { $0.id == id }; claimedSessions.remove(id) }
    }
    func addHistory(url: URL, title: String, profileID: UUID) {
        guard AddressResolver.isWebURL(url) else { return }
        if let last = library.history.last, last.url == url, last.profileID == profileID,
           Date().timeIntervalSince(last.visitedAt) < 2 { return }
        library.history.append(HistoryEntry(profileID: profileID, title: String(title.prefix(512)), url: url))
        if library.history.count > 10_000 { library.history.removeFirst(library.history.count - 10_000) }
    }
    func toggleBookmark(url: URL, title: String, profileID: UUID) {
        if library.bookmarks.contains(where: { $0.url == url && $0.profileID == profileID }) {
            library.bookmarks.removeAll { $0.url == url && $0.profileID == profileID }
        } else { library.bookmarks.append(Bookmark(profileID: profileID, title: title, url: url)) }
    }
    @discardableResult
    func importBookmarks(profileID: UUID) -> Bool {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.html]; panel.message = "Choose bookmarks exported from Safari, Chrome, or Firefox."
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        do {
            guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 10 * 1024 * 1024 else { throw ValidationError("Bookmark files must be smaller than 10 MB.") }
            let imported = try BookmarkExchange.parse(Data(contentsOf: url), profileID: profileID)
            var urls = Set(library.bookmarks.filter { $0.profileID == profileID }.map(\.url))
            let additions = imported.filter { urls.insert($0.url).inserted }
            library.bookmarks.append(contentsOf: additions)
            notice = "Imported \(additions.count) bookmarks."
            return true
        } catch { notice = error.localizedDescription; return false }
    }
    func exportBookmarks(profileID: UUID) {
        saveFile(BookmarkExchange.export(library.bookmarks.filter { $0.profileID == profileID }), name: "Radius Bookmarks.html", type: .html)
    }
    func applyConfiguration(_ configuration: Configuration) {
        var checked = configuration; checked.normalize()
        library.preferences.configuration = checked; previewConfiguration = nil
    }
    func resetModules() {
        perform {
            let old = dataDirectory.appendingPathComponent("Modules", isDirectory: true)
            if FileManager.default.fileExists(atPath: old.path) {
                try FileManager.default.moveItem(at: old, to: dataDirectory.appendingPathComponent("Modules-backup-" + UUID().uuidString))
            }
            let repo = try ModuleRepository(root: old)
            // An initialized empty catalog preserves removals and leaves all optional behavior stopped.
            try Data("1".utf8).write(to: old.appendingPathComponent(".initialized"), options: .atomic)
            repository = repo; installedModules = []; notice = "Modules reset. Reinstall the features you want in Modules."
        }
    }
    func resetLibrary() async {
        database = nil; saveTask?.cancel()
        do {
            let backup = dataDirectory.appendingPathComponent("Recovery-" + UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
            for name in ["library.sqlite", "library.sqlite-wal", "library.sqlite-shm"] {
                let file = dataDirectory.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.moveItem(at: file, to: backup.appendingPathComponent(name)) }
            }
            ready = false; claimedSessions = []; revision = 0
            await load()
        } catch { startupError = "Recovery could not finish: \(error.localizedDescription). The original files remain in Application Support." }
    }
    func flush() async -> Bool {
        saveTask?.cancel()
        guard ready, let database else { return true }
        revision += 1
        var snapshot = library; snapshot.normalize()
        do { try await database.save(snapshot, revision: revision); try await database.checkpoint(); return true }
        catch { notice = "Could not save Radius data: \(error.localizedDescription)"; return false }
    }
    private func scheduleSave() {
        revision += 1; let currentRevision = revision; var snapshot = library; snapshot.normalize()
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(250))
                guard let self, let database = self.database, !Task.isCancelled else { return }
                try await database.save(snapshot, revision: currentRevision)
            } catch is CancellationError { }
            catch { self?.notice = "Could not save your changes: \(error.localizedDescription). Retry saving in Recovery." }
        }
    }
    func perform(_ operation: () throws -> Void) {
        do { try operation() } catch { notice = error.localizedDescription }
    }
    func saveFile(_ data: Data, name: String, type: UTType) {
        let panel = NSSavePanel(); panel.nameFieldStringValue = name; panel.allowedContentTypes = [type]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        perform { try data.write(to: url, options: .atomic) }
    }
}

import UniformTypeIdentifiers

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var state: AppState?
    func applicationDidFinishLaunching(_ notification: Notification) { NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true) }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let state = Self.state else { return .terminateNow }
        state.terminating = true
        Task {
            if await state.flush() { sender.reply(toApplicationShouldTerminate: true) }
            else {
                let alert = NSAlert(); alert.messageText = "Your latest changes could not be saved."
                alert.informativeText = state.notice ?? "Retry saving from Recovery."
                alert.addButton(withTitle: "Keep Radius open"); alert.addButton(withTitle: "Quit without saving")
                let quit = alert.runModal() == .alertSecondButtonReturn
                state.terminating = quit; sender.reply(toApplicationShouldTerminate: quit)
            }
        }
        return .terminateLater
    }
}
