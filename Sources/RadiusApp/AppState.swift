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
    @Published var installedModules: [InstalledModule] = [] { didSet { resourceWorkerGeneration = UUID() } }
    @Published private(set) var resourceWorkerGeneration = UUID()
    @Published var previewConfiguration: Configuration?
    let dataDirectory: URL
    private(set) var catalog: [ModuleManifest] = []
    private var modulePayloads: [String: Data] = [:]
    private var startupTask: Task<Void, Never>?
    private var database: LibraryDatabase?
    private var repository: ModuleRepository?
    private var saveTask: Task<Void, Never>?
    private var revision: UInt64 = 0
    private var claimedSessions = Set<UUID>()
    var terminating = false
    private(set) var windows: [UUID: BrowserReference] = [:]
    var configuration: Configuration { previewConfiguration ?? library.preferences.configuration }

    init(directory: URL? = nil) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let smokeDirectory = CommandLine.arguments.contains("--smoke-test") ? ProcessInfo.processInfo.environment["RADIUS_SMOKE_TEST_DATA"].map { URL(fileURLWithPath: $0, isDirectory: true) } : nil
        dataDirectory = directory ?? smokeDirectory ?? support.appendingPathComponent("org.radius.browser", isDirectory: true)
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
                let available = catalog.filter { $0.runtime == nil || modulePayloads[$0.id] != nil }
                try repo.seedDefaults(available, payloads: modulePayloads)
                installedModules = try repo.installed()
            } catch { notice = "Optional modules could not load: \(error.localizedDescription). Open Recovery to repair them." }
            ready = true; startupError = nil
        } catch { startupError = error.localizedDescription }
    }
    private func loadCatalog() throws {
        let directory: URL
        let developmentWorkerDirectory: URL?
        if let packaged = Bundle.main.url(forResource: "Modules", withExtension: nil) { directory = packaged; developmentWorkerDirectory = nil }
        else if let resources = Bundle.module.url(forResource: "Resources", withExtension: nil) {
            directory = resources.appendingPathComponent("Modules")
            developmentWorkerDirectory = Bundle.module.bundleURL.deletingLastPathComponent()
        }
        else { throw ValidationError("The application is missing its bundled resources. Rebuild or reinstall Radius.") }
        catalog = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.hasDirectoryPath }.map { try ModuleManifest.decode(Data(contentsOf: $0.appendingPathComponent("manifest.json"))) }
            .sorted { $0.name < $1.name }
        modulePayloads = [:]
        let workers = ["org.radius.resource-monitor": "RadiusResourceMonitor", "org.radius.memory-monitor": "RadiusMemoryMonitor"]
        for manifest in catalog where manifest.runtime == .nativeResourceWorker {
            do {
                guard let product = workers[manifest.id] else { throw ValidationError("An unrecognized native worker is bundled with Radius.") }
                let packaged = directory.appendingPathComponent(manifest.id).appendingPathComponent("worker")
                // SwiftPM development builds put executable products beside their resource bundle.
                let executable = developmentWorkerDirectory?.appendingPathComponent(product) ?? packaged
                let size = try executable.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey])
                guard size.isSymbolicLink != true, (size.fileSize ?? 0) > 0, (size.fileSize ?? 0) <= 8 * 1024 * 1024 else { throw ValidationError("Invalid bundled worker payload.") }
                modulePayloads[manifest.id] = try Data(contentsOf: executable)
            } catch { notice = "\(manifest.name) is unavailable because its bundled worker could not load. Rebuild or reinstall Radius to use it. Browsing is still available." }
        }
    }
    func enabled(_ capability: ModuleCapability) -> Bool {
        installedModules.contains { $0.enabled && $0.manifest.capability == capability }
    }
    func resourceWorkerPackage() throws -> (id: String, url: URL) {
        guard let module = installedModules.first(where: { $0.enabled && $0.manifest.capability == .resourceMonitor }) else {
            throw ValidationError("Enable a resource provider in Modules.")
        }
        guard module.manifest.runtime == .nativeResourceWorker else {
            throw ValidationError("Update Resource Monitor in Modules to install its removable worker package.")
        }
        guard let repository, let trusted = modulePayloads[module.id],
              catalog.contains(module.manifest) else { throw ValidationError("This worker is not a trusted package from this Radius build. Update it in Modules.") }
        let url = try repository.workerURL(for: module.id)
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let limit = 8 * 1024 * 1024
        var payload = Data()
        while let chunk = try file.read(upToCount: min(64 * 1024, limit + 1 - payload.count)), !chunk.isEmpty {
            payload.append(chunk)
            guard payload.count <= limit else { throw ValidationError("This worker exceeds the package size limit. Reinstall it in Modules.") }
        }
        guard payload == trusted else {
            throw ValidationError("This worker's code differs from the bundled first-party package. Reinstall it in Modules.")
        }
        return (module.id, url)
    }
    func install(_ id: String) {
        perform {
            guard let repository else { throw ValidationError("Open Recovery to repair module storage first.") }
            let plan = try repository.installationPlan(for: id, catalog: catalog)
            if !approveModules(plan) { return }
            try installApprovedModule(id)
        }
    }
    /// Called after the install dialog approves the bundled package and any dependencies.
    func installApprovedModule(_ id: String) throws {
        guard let repository else { throw ValidationError("Open Recovery to repair module storage first.") }
        let plan = try repository.installationPlan(for: id, catalog: catalog)
        defer { resourceWorkerGeneration = UUID() }
        let activate = installedModules.first { $0.id == id }?.enabled ?? true
        for manifest in plan {
            ResourceWorker.stopAll(moduleID: manifest.id)
            try repository.install(manifest, enabled: manifest.id != id && activate ? true : nil, payload: modulePayloads[manifest.id])
        }
        installedModules = try repository.installed()
    }
    func reinstallWorker(_ module: InstalledModule) {
        perform {
            guard let bundled = catalog.first(where: { $0.id == module.id && $0.runtime == .nativeResourceWorker }) else {
                throw ValidationError("This worker has no bundled replacement.")
            }
            guard approveModules([bundled]) else { return }
            try reinstallApprovedWorker(module.id)
        }
    }
    func reinstallApprovedWorker(_ id: String) throws {
        guard let repository, let bundled = catalog.first(where: { $0.id == id && $0.runtime == .nativeResourceWorker }),
              let current = installedModules.first(where: { $0.id == id }) else { throw ValidationError("This worker has no bundled replacement.") }
        defer { resourceWorkerGeneration = UUID() }
        ResourceWorker.stopAll(moduleID: id)
        try repository.install(bundled, enabled: current.enabled, payload: modulePayloads[id])
        installedModules = try repository.installed()
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
            guard manifest.runtime == nil, manifest.capability != .resourceMonitor else {
                throw ValidationError("Native resource workers must come from this Radius build. Install them from Discover; local native publisher verification is not available yet.")
            }
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
        if manifests.contains(where: { $0.runtime != nil }) {
            alert.informativeText += "\n\nThis installs trusted first-party native code. Workers run outside the app while their panel is open, with the same macOS user access as Radius. They are not sandboxed by the permissions listed above."
        }
        alert.addButton(withTitle: "Install"); alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
    func toggleModule(_ module: InstalledModule) {
        if !module.enabled, module.manifest.runtime == .nativeResourceWorker,
           let active = installedModules.first(where: { $0.enabled && $0.manifest.capability == .resourceMonitor && $0.id != module.id }) {
            let alert = NSAlert(); alert.messageText = "Replace \(active.manifest.name) with \(module.manifest.name)?"
            alert.informativeText = "The current worker will stop. The replacement will run when its panel is open. Your saved browser data is kept."
            alert.addButton(withTitle: "Replace"); alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            perform { try replaceResourceProvider(with: module.id) }
            return
        }
        perform {
            defer { resourceWorkerGeneration = UUID() }
            ResourceWorker.stopAll(moduleID: module.id)
            try repository?.setEnabled(module.id, !module.enabled)
            installedModules = try repository?.installed() ?? []
        }
    }
    func replaceResourceProvider(with id: String) throws {
        guard let repository else { throw ValidationError("Repair module storage first.") }
        defer { resourceWorkerGeneration = UUID() }
        ResourceWorker.stopAll()
        try repository.replaceResourceProvider(with: id)
        installedModules = try repository.installed()
    }
    func removeModule(_ id: String) throws {
        guard let repository else { throw ValidationError("Repair module storage first.") }
        defer { resourceWorkerGeneration = UUID() }
        ResourceWorker.stopAll(moduleID: id)
        try repository.uninstall(id)
        installedModules = try repository.installed()
    }
    func uninstall(_ module: InstalledModule) {
        let alert = NSAlert(); alert.messageText = "Uninstall \(module.manifest.name)?"
        alert.informativeText = module.manifest.runtime == nil ?
            "The package descriptor will be deleted and its feature will stop. The implementation remains in Radius. Saved notes and settings are kept unless you choose to delete them." :
            "The worker will stop and its installed executable package will be deleted. Saved browser data is kept. You can install this provider again from Discover."
        alert.addButton(withTitle: "Uninstall and keep data"); alert.addButton(withTitle: "Cancel")
        if module.manifest.capability == .notes { alert.addButton(withTitle: "Uninstall and delete all notes") }
        let response = alert.runModal()
        guard response != .alertSecondButtonReturn else { return }
        perform {
            try removeModule(module.id)
            if response == .alertThirdButtonReturn { library.notes.removeAll() }
        }
    }
    func claimSession(privateBrowsing: Bool) -> WindowSession {
        if !privateBrowsing, let saved = library.sessions.first(where: { !claimedSessions.contains($0.id) }) {
            claimedSessions.insert(saved.id); return saved
        }
        let session = WindowSession(profileID: library.profiles[0].id, tabs: [BrowserTab(engineID: library.profiles[0].engineID ?? .webkit)])
        if !privateBrowsing { claimedSessions.insert(session.id); library.sessions.append(session) }
        return session
    }
    func updateSession(_ session: WindowSession) {
        guard ready else { return }
        if let index = library.sessions.firstIndex(where: { $0.id == session.id }) { library.sessions[index] = session }
    }
    func registerWindow(_ model: BrowserModel) { windows[model.session.id] = BrowserReference(model) }
    func unregisterWindow(_ id: UUID) { windows.removeValue(forKey: id) }
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
        guard AddressResolver.isWebURL(url) else { notice = "Only HTTP and HTTPS pages can be saved as bookmarks."; return }
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
        let splitChanged = checked.layout.split != library.preferences.configuration.layout.split
        library.preferences.configuration = checked; previewConfiguration = nil
        windows.values.compactMap(\.model).forEach { $0.synchronizeSplit(force: splitChanged) }
    }
    func resetModules() {
        perform {
            defer { resourceWorkerGeneration = UUID() }
            ResourceWorker.stopAll()
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
    func applicationDidFinishLaunching(_ notification: Notification) {
        smokeTrace("applicationDidFinishLaunching: setting activation policy")
        NSApp.setActivationPolicy(.regular)
        smokeTrace("applicationDidFinishLaunching: activating application")
        NSApp.activate(ignoringOtherApps: true)
        smokeTrace("applicationDidFinishLaunching: activation returned")
        if CommandLine.arguments.contains("--smoke-test") { Task { await AppSmokeTest.run() } }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        smokeTrace("applicationShouldTerminate entered")
        guard let state = Self.state else {
            smokeTrace("No application state; returning terminateNow")
            return .terminateNow
        }
        let activeWindows = state.windows.values.compactMap(\.model).filter { $0.downloads.hasActive }
        if !activeWindows.isEmpty {
            let alert = NSAlert(); alert.messageText = "Cancel active downloads and quit Radius?"
            alert.informativeText = "There are unfinished downloads in \(activeWindows.count) windows."
            alert.addButton(withTitle: "Keep Radius open"); alert.addButton(withTitle: "Cancel downloads and quit")
            guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
        }
        state.terminating = true
        Task {
            self.smokeTrace("Termination task started; cancelling active downloads")
            for browser in activeWindows { await browser.downloads.cancelAllAndWait() }
            self.smokeTrace("Flushing application data before termination")
            let saved = await state.flush()
            self.smokeTrace("Termination flush completed: \(saved)")
            var quit = saved
            if !saved {
                let alert = NSAlert(); alert.messageText = "Your latest changes could not be saved."
                alert.informativeText = state.notice ?? "Retry saving from Recovery."
                alert.addButton(withTitle: "Keep Radius open"); alert.addButton(withTitle: "Quit without saving")
                quit = alert.runModal() == .alertSecondButtonReturn
            }
            if quit {
                for browser in state.windows.values.compactMap(\.model) { browser.disposeEngineTabs() }
                quit = await ChromiumRuntime.shared.shutdown()
                if !quit { state.notice = ChromiumRuntime.shared.status }
            }
            self.smokeTrace("Sending termination reply: \(quit)")
            state.terminating = quit
            sender.reply(toApplicationShouldTerminate: quit)
        }
        smokeTrace("Returning terminateLater")
        return .terminateLater
    }
    private func smokeTrace(_ message: String) {
        guard CommandLine.arguments.contains("--smoke-test") else { return }
        FileHandle.standardOutput.write(Data(("Radius app delegate: " + message + "\n").utf8))
    }
}

@MainActor
final class BrowserReference {
    weak var model: BrowserModel?
    init(_ model: BrowserModel) { self.model = model }
}
