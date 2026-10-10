// SPDX-License-Identifier: MPL-2.0
import AppKit
@preconcurrency import WebKit
import RadiusCore

@MainActor
extension AppState {
    func deleteProfile(_ id: UUID, replacingWith replacement: UUID) async throws {
        guard !terminating, deletingProfileIDs.isEmpty else { throw ValidationError("Wait for the current operation to finish.") }
        var validation = library
        _ = try validation.removeProfile(id, replacingWith: replacement)
        deletingProfileIDs.insert(id)
        defer {
            deletingProfileIDs.remove(id)
            ChromiumRuntime.shared.blockProfilesPendingDeletion(Set((library.pendingProfileDeletions ?? []) + (library.pendingWebsiteDataClears ?? [])))
        }
        let affected = windows.values.compactMap(\.model).filter { $0.session.profileID == id }
        for window in affected { try await window.downloads.cancelAllAndWait() }
        try await ChromiumRuntime.shared.prepareToDeleteProfile(id)
        cancelReaderRequests()
        let removed = try library.removeProfile(id, replacingWith: replacement)
        guard await flush() else {
            library.restoreProfile(removed)
            for window in affected { window.disposeEngineTabs() }
            ChromiumRuntime.shared.blockProfilesPendingDeletion(Set((library.pendingProfileDeletions ?? []) + (library.pendingWebsiteDataClears ?? [])))
            throw ValidationError(notice ?? "The profile could not be saved. Nothing was erased.")
        }
        ChromiumRuntime.shared.blockProfilesPendingDeletion(Set((library.pendingProfileDeletions ?? []) + (library.pendingWebsiteDataClears ?? [])))
        for window in affected { window.resetAfterProfileDeletion(replacementID: replacement) }
        NotificationCenter.default.post(name: .radiusProfileDeleted, object: id)
        await finishPendingProfileDeletions()
        if (library.pendingProfileDeletions ?? []).contains(id) {
            notice = "The profile was deleted. Quit and reopen Radius to finish removing its website storage. Saved downloads, exports, and recovery backups remain on disk."
        } else { notice = "The profile and its website storage were deleted. Saved downloads, exports, and recovery backups remain on disk." }
    }

    /// Durable tombstones are processed before any restored tab can open its engine.
    func finishPendingProfileDeletions() async {
        let deleted = library.pendingProfileDeletions ?? []
        let clearRequests = library.pendingWebsiteDataClears ?? []
        let pending = Array(Set(deleted + clearRequests))
        ChromiumRuntime.shared.blockProfilesPendingDeletion(Set(pending))
        guard !pending.isEmpty else { return }
        // A queued request takes effect when cleanup starts. If either engine's
        // removal fails, do not reopen the profile with its previous cookies.
        profilesAwaitingWebsiteDataRemoval.formUnion(pending)
        for model in windows.values.compactMap(\.model) where profilesAwaitingWebsiteDataRemoval.contains(model.session.profileID) {
            model.disposeEngineTabs()
        }
        var completed = Set<UUID>()
        // Website-store removal has a deadline. All requests start together so a
        // damaged store cannot add an unbounded delay for each deleted profile.
        let requests = pending.map { id in
            (id, Task { @MainActor in
                do { try await WebsiteStoreRemoval.remove(id); return true }
                catch { return false }
            })
        }
        var webkitResults = Set<UUID>()
        await withTaskCancellationHandler {
            for (id, task) in requests { if await task.value { webkitResults.insert(id) } }
        } onCancel: { for (_, task) in requests { task.cancel() } }
        if webkitResults.count < pending.count { notice = "Some website storage could not be removed. Browsing in those profiles is paused. Quit and reopen Radius to retry." }
        for id in pending where webkitResults.contains(id) {
            do {
                try await ChromiumRuntime.shared.clearWebsiteData(profileID: id, dataDirectory: dataDirectory)
                completed.insert(id)
            } catch { notice = "Website storage removal is pending. Quit and reopen Radius to retry. \(error.localizedDescription)" }
        }
        if !completed.isEmpty {
            library.pendingProfileDeletions?.removeAll { completed.contains($0) }
            library.pendingWebsiteDataClears?.removeAll { completed.contains($0) }
            if !(await flush()) {
                // Keep the retry record if its removal could not be committed.
                library.pendingProfileDeletions = deleted
                library.pendingWebsiteDataClears = clearRequests
            }
        }
        ChromiumRuntime.shared.blockProfilesPendingDeletion(Set((library.pendingProfileDeletions ?? []) + (library.pendingWebsiteDataClears ?? [])))
        profilesAwaitingWebsiteDataRemoval = Set((library.pendingProfileDeletions ?? []) + (library.pendingWebsiteDataClears ?? []))
    }

    func requestWebsiteDataClear(_ id: UUID) async throws {
        guard !terminating, deletingProfileIDs.isEmpty, library.profiles.contains(where: { $0.id == id }) else { throw ValidationError("This profile is unavailable.") }
        let old = library.pendingWebsiteDataClears
        library.pendingWebsiteDataClears = Array(Set((old ?? []) + [id]))
        guard await flush() else { library.pendingWebsiteDataClears = old; throw ValidationError(notice ?? "The website data request could not be saved.") }
        // Storage can be in use in other tabs and extension workers. Retain the
        // durable request and perform removal before engines start next time.
        notice = "Quit and reopen Radius to clear this profile's website data. Your bookmarks, notes, history, and tab addresses are kept."
    }

    func prepareForChromiumRemoval() {
        for index in library.profiles.indices where library.profiles[index].engineID == .chromium { library.profiles[index].engineID = .webkit }
        for index in library.sessions.indices {
            for tabIndex in library.sessions[index].tabs.indices where library.sessions[index].tabs[tabIndex].engineID == .chromium {
                library.sessions[index].tabs[tabIndex].engineID = .webkit
                if let url = library.sessions[index].tabs[tabIndex].url, !AddressResolver.isWebURL(url) {
                    library.sessions[index].tabs[tabIndex].url = nil
                    library.sessions[index].tabs[tabIndex].title = "New tab"
                }
            }
        }
        for model in windows.values.compactMap(\.model) {
            for tab in model.session.tabs where tab.engineID == .chromium {
                if let url = tab.url, !AddressResolver.isWebURL(url), let index = model.session.tabs.firstIndex(where: { $0.id == tab.id }) {
                    model.session.tabs[index].url = nil; model.session.tabs[index].title = "New tab"
                }
                model.changeEngine(tab.id, to: .webkit)
            }
            for index in model.closedTabs.indices where model.closedTabs[index].engineID == .chromium {
                model.closedTabs[index].engineID = .webkit
                if let url = model.closedTabs[index].url, !AddressResolver.isWebURL(url) { model.closedTabs[index].url = nil; model.closedTabs[index].title = "New tab" }
            }
            model.address = model.selectedTab.url?.absoluteString ?? ""
        }
    }
}

@MainActor
private final class WebsiteStoreRemoval {
    private var continuation: CheckedContinuation<Void, any Error>?
    private var deadline: Task<Void, Never>?
    private init() {}
    static func remove(_ id: UUID) async throws {
        let request = WebsiteStoreRemoval()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                request.continuation = continuation
                request.deadline = Task {
                    do { try await Task.sleep(for: .seconds(8)) }
                    catch { return }
                    request.finish(ValidationError("WebKit storage removal timed out and will retry when Radius opens."))
                }
                WKWebsiteDataStore.remove(forIdentifier: id) { error in
                    Task { @MainActor in request.finish(error) }
                }
                if Task.isCancelled { request.finish(CancellationError()) }
            }
        } onCancel: { Task { @MainActor in request.finish(CancellationError()) } }
    }
    private func finish(_ error: (any Error)?) {
        guard let continuation else { return }
        self.continuation = nil; deadline?.cancel(); deadline = nil
        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
    }
}
