// SPDX-License-Identifier: MPL-2.0
import Foundation

public struct RemovedProfileContents: Sendable {
    public let profile: Profile
    public let bookmarks: [Bookmark]
    public let history: [HistoryEntry]
    public let notes: [Note]
    public let sessions: [WindowSession]
}
extension LibraryState {
    /// Website stores are erased separately; this durable tombstone makes interruption recoverable.
    public mutating func removeProfile(_ id: UUID, replacingWith replacement: UUID) throws -> RemovedProfileContents {
        guard id != replacement, let profile = profiles.first(where: { $0.id == id }),
              let target = profiles.first(where: { $0.id == replacement }), profiles.count > 1 else {
            throw ValidationError("Choose another profile before deleting this one.")
        }
        let contents = RemovedProfileContents(profile: profile, bookmarks: bookmarks.filter { $0.profileID == id },
            history: history.filter { $0.profileID == id }, notes: notes.filter { $0.profileID == id }, sessions: sessions.filter { $0.profileID == id })
        profiles.removeAll { $0.id == id }; bookmarks.removeAll { $0.profileID == id }
        history.removeAll { $0.profileID == id }; notes.removeAll { $0.profileID == id }
        for index in sessions.indices where sessions[index].profileID == id {
            sessions[index] = WindowSession(id: sessions[index].id, profileID: replacement, tabs: [BrowserTab(engineID: target.engineID ?? .webkit)])
        }
        if !(pendingProfileDeletions ?? []).contains(id) { pendingProfileDeletions = (pendingProfileDeletions ?? []) + [id] }
        return contents
    }
    /// A failed metadata commit restores only this profile, preserving concurrent edits elsewhere.
    public mutating func restoreProfile(_ contents: RemovedProfileContents) {
        let id = contents.profile.id
        guard !profiles.contains(where: { $0.id == id }) else { return }
        profiles.append(contents.profile)
        bookmarks.append(contentsOf: contents.bookmarks); history.append(contentsOf: contents.history); notes.append(contentsOf: contents.notes)
        for session in contents.sessions {
            if let index = sessions.firstIndex(where: { $0.id == session.id }) { sessions[index] = session }
            else { sessions.append(session) }
        }
        pendingProfileDeletions?.removeAll { $0 == id }
    }
}
