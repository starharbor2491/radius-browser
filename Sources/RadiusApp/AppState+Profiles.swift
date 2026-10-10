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
        defer { deletingProfileIDs.remove(id) }
        let affected = windows.values.compactMap(\.model).filter { $0.session.profileID == id }
        for window in affected { try await window.downloads.cancelAllAndWait() }
        try await ChromiumRuntime.shared.prepareToDeleteProfile(id)
        cancelReaderRequests()
        let removed = try library.removeProfile(id, replacingWith: replacement)
        guard await flush() else {
            library.restoreProfile(removed)
            ChromiumRuntime.shared.blockProfilesPendingDeletion(Set(library.pendingProfileDeletions ?? []))
            throw ValidationError(notice ?? "The profile could not be saved. Nothing was erased.")
        }
        ChromiumRuntime.shared.blockProfilesPendingDeletion(Set(library.pendingProfileDeletions ?? []))
        for window in affected { window.resetAfterProfileDeletion(replacementID: replacement) }
        NotificationCenter.default.post(name: .radiusProfileDeleted, object: id)
        await finishPendingProfileDeletions()
        if (library.pendingProfileDeletions ?? []).contains(id) {
            notice = "The profile was deleted. Quit and reopen Radius to finish removing its website storage. Saved downloads, exports, and recovery backups remain on disk."
        } else { notice = "The profile and its website storage were deleted. Saved downloads, exports, and recovery backups remain on disk." }
    }

    /// Durable tombstones are processed before any restored tab can open its engine.
    func finishPendingProfileDeletions() async {
        let pending = library.pendingProfileDeletions ?? []
        ChromiumRuntime.shared.blockProfilesPendingDeletion(Set(pending))
        guard !pending.isEmpty else { return }
        var completed = Set<UUID>()
        // Website-store removal has a deadline. All requests start together so a
        // damaged store cannot add an unbounded delay for each deleted profile.
        let webkitResults = await withTaskGroup(of: (UUID, Bool).self) { group in
            for id in pending {
                group.addTask { @MainActor in
                    do { try await WebsiteStoreRemoval.remove(id); return (id, true) }
                    catch { return (id, false) }
                }
            }
            var results = Set<UUID>()
            for await (id, success) in group where success { results.insert(id) }
            return results
        }
        for id in pending where webkitResults.contains(id) {
            do {
                try await ChromiumRuntime.shared.clearWebsiteData(profileID: id, dataDirectory: dataDirectory)
                completed.insert(id)
            } catch { notice = "Website storage removal is pending. Quit and reopen Radius to retry. \(error.localizedDescription)" }
        }
        if !completed.isEmpty {
            library.pendingProfileDeletions?.removeAll { completed.contains($0) }
            if !(await flush()) {
                // Keep the retry record if its removal could not be committed.
                library.pendingProfileDeletions = pending
            }
        }
        ChromiumRuntime.shared.blockProfilesPendingDeletion(Set(library.pendingProfileDeletions ?? []))
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
