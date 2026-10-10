// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
@testable import RadiusApp

struct ChromiumProfileDataTests {
    @Test func erasesOnlySelectedProfileAndDoesNotFollowInteriorLinks() throws {
        let root = temporaryDirectory(), id = UUID(), other = UUID()
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = root.appendingPathComponent("Chromium/Profiles/\(id.uuidString)")
        let otherProfile = root.appendingPathComponent("Chromium/Profiles/\(other.uuidString)")
        let outside = root.appendingPathComponent("Keep")
        for directory in [profile.appendingPathComponent("Local Storage/leveldb"), otherProfile, outside] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try Data("remove".utf8).write(to: profile.appendingPathComponent("Local Storage/leveldb/log"))
        try Data("keep".utf8).write(to: outside.appendingPathComponent("important"))
        try FileManager.default.createSymbolicLink(at: profile.appendingPathComponent("linked"), withDestinationURL: outside)
        try ChromiumProfileData.erase(profileID: id, dataDirectory: root)
        #expect(!FileManager.default.fileExists(atPath: profile.path))
        #expect(FileManager.default.fileExists(atPath: otherProfile.path))
        #expect(try Data(contentsOf: outside.appendingPathComponent("important")) == Data("keep".utf8))
        // Retrying an already completed tombstone succeeds.
        try ChromiumProfileData.erase(profileID: id, dataDirectory: root)
    }
    @Test func refusesSymbolicLinkAtProfilesBoundary() throws {
        let root = temporaryDirectory(), id = UUID()
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = root.appendingPathComponent("Outside")
        let profile = outside.appendingPathComponent(id.uuidString)
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Chromium"), withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: profile.appendingPathComponent("important"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Chromium/Profiles"), withDestinationURL: outside)
        #expect(throws: (any Error).self) { try ChromiumProfileData.erase(profileID: id, dataDirectory: root) }
        #expect(try Data(contentsOf: profile.appendingPathComponent("important")) == Data("keep".utf8))
    }
    @Test func refusesSymbolicLinkForProfileRoot() throws {
        let root = temporaryDirectory(), id = UUID()
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = root.appendingPathComponent("Outside")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Chromium/Profiles"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: outside.appendingPathComponent("important"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Chromium/Profiles/\(id.uuidString)"), withDestinationURL: outside)
        #expect(throws: (any Error).self) { try ChromiumProfileData.erase(profileID: id, dataDirectory: root) }
        #expect(FileManager.default.fileExists(atPath: outside.appendingPathComponent("important").path))
    }
    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("RadiusProfileErase-\(UUID().uuidString)", isDirectory: true)
    }
}
