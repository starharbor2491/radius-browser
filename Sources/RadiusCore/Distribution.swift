// SPDX-License-Identifier: MPL-2.0
import Foundation

/// Release metadata is sealed into the signed application. Catalog claims are never
/// a substitute for checking this copy after download.
public struct DistributionRelease: Codable, Equatable, Sendable {
    public let format: Int
    public let build: Int
    public let version: String
    public let securityEpoch: Int
    public let architecture: String
    public let chromium: Bool
    public init(build: Int, version: String, securityEpoch: Int, architecture: String, chromium: Bool) {
        self.format = 1; self.build = build; self.version = version
        self.securityEpoch = securityEpoch; self.architecture = architecture; self.chromium = chromium
    }
    public func validate(current: DistributionRelease, minimumEpoch: Int, architecture: String) throws {
        guard format == 1, build > 0, !version.isEmpty, version.count <= 64,
              version.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || ".-+".contains($0)) }), securityEpoch >= 0,
              self.architecture == architecture || self.architecture == "universal" else {
            throw ValidationError("This release is incompatible with this Mac.")
        }
        guard build >= current.build, securityEpoch >= max(current.securityEpoch, minimumEpoch) else {
            throw ValidationError("Radius will not install an older application or an engine below the accepted security version.")
        }
    }
}

public struct DistributionAsset: Codable, Equatable, Sendable {
    public let release: DistributionRelease
    public let url: URL
    public let sha256: String
    public let bytes: Int64
    public init(release: DistributionRelease, url: URL, sha256: String, bytes: Int64) {
        self.release = release; self.url = url; self.sha256 = sha256; self.bytes = bytes
    }
    public func validate() throws {
        guard url.scheme == "https", url.host == "github.com", url.user == nil, url.password == nil,
              url.path.hasPrefix("/starharbor2491/radius-browser/releases/download/"),
              url.path.hasSuffix(".dmg"), url.query == nil, url.fragment == nil,
              bytes > 0, bytes <= 4_000_000_000, sha256.count == 64,
              sha256.allSatisfy({ "0123456789abcdef".contains($0) }) else {
            throw ValidationError("The release catalog contains an invalid asset.")
        }
    }
}
public struct DistributionCatalog: Codable, Sendable {
    public let format: Int
    public let releases: [DistributionAsset]
    public init(releases: [DistributionAsset]) { self.format = 1; self.releases = releases }
    public func validate() throws {
        guard format == 1, releases.count <= 16 else { throw ValidationError("The release catalog is incompatible or too large.") }
        for release in releases { try release.validate() }
    }
}

/// Replacement is a same-directory rename transaction. User data is deliberately
/// outside this transaction. The caller must verify staged code before calling and
/// again after copying to the destination volume.
public enum AppReplacementTransaction {
    public struct Journal: Codable, Equatable, Sendable {
        public let destination: URL
        public let candidate: URL
        public let backup: URL
        public var phase: String
    }
    public static func install(source: URL, destination: URL, journalURL: URL,
                               verify: (URL) throws -> Void, verifyExisting: ((URL) throws -> Void)? = nil, checkpoint: (String) throws -> Void = { _ in }) throws {
        let fm = FileManager.default
        guard source.standardizedFileURL != destination.standardizedFileURL,
              source.isFileURL, destination.isFileURL, journalURL.isFileURL,
              destination.pathExtension == "app", !fm.fileExists(atPath: journalURL.path) else {
            throw ValidationError("Another application update is pending, or the destination is invalid.")
        }
        let parent = destination.deletingLastPathComponent()
        guard (try parent.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])).isDirectory == true,
              (try parent.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true else {
            throw ValidationError("The installation folder must be a real directory.")
        }
        if fm.fileExists(atPath: destination.path) {
            guard (try destination.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])).isSymbolicLink != true,
                  (try destination.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true else {
                throw ValidationError("The installed application is not a regular app bundle.")
            }
            if let verifyExisting { try verifyExisting(destination) } else { try verify(destination) }
        }
        try verify(source)
        let token = UUID().uuidString
        let candidate = parent.appendingPathComponent(".Radius-install-\(token).app", isDirectory: true)
        let backup = parent.appendingPathComponent(".Radius-previous-\(token).app", isDirectory: true)
        var journal = Journal(destination: destination, candidate: candidate, backup: backup, phase: "copying")
        try JSONEncoder().encode(journal).write(to: journalURL, options: [.atomic])
        do {
            try fm.copyItem(at: source, to: candidate)
            try verify(candidate)
            try checkpoint("copied")
            journal.phase = "prepared"
            try JSONEncoder().encode(journal).write(to: journalURL, options: [.atomic])
            if fm.fileExists(atPath: destination.path) { try fm.moveItem(at: destination, to: backup) }
            try checkpoint("previousMoved")
            try fm.moveItem(at: candidate, to: destination)
            journal.phase = "activated"
            // Activation has succeeded. Retain a recoverable journal if cleanup
            // fails instead of reporting the installed app as a failed update.
            try? JSONEncoder().encode(journal).write(to: journalURL, options: [.atomic])
            try? fm.removeItem(at: backup)
            if !fm.fileExists(atPath: backup.path) { try? fm.removeItem(at: journalURL) }
        } catch {
            // A candidate that cannot activate never replaces a working app. If
            // rollback fails, retain the journal and backup for native recovery.
            if !fm.fileExists(atPath: destination.path), fm.fileExists(atPath: backup.path) {
                try? fm.moveItem(at: backup, to: destination)
            }
            if fm.fileExists(atPath: destination.path) {
                try? fm.removeItem(at: candidate)
                if !fm.fileExists(atPath: candidate.path), !fm.fileExists(atPath: backup.path) { try? fm.removeItem(at: journalURL) }
            }
            throw error
        }
    }
    public static func recover(journalURL: URL, expectedDestination: URL, verify: (URL) throws -> Void, verifyExisting: ((URL) throws -> Void)? = nil) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: journalURL.path) else { return }
        let values = try journalURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard journalURL.isFileURL, values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size > 0, size <= 8192 else {
            throw ValidationError("The update journal is invalid or too large.")
        }
        let handle = try FileHandle(forReadingFrom: journalURL)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: 8193) ?? Data()
        guard data.count <= 8192 else { throw ValidationError("The update journal is too large.") }
        let journal = try JSONDecoder().decode(Journal.self, from: data)
        let parent = journal.destination.deletingLastPathComponent().standardizedFileURL
        let prefix = ".Radius-install-", suffix = ".app"
        let name = journal.candidate.lastPathComponent
        guard name.hasPrefix(prefix), name.hasSuffix(suffix) else { throw ValidationError("The update journal is invalid.") }
        let token = String(name.dropFirst(prefix.count).dropLast(suffix.count))
        guard UUID(uuidString: token)?.uuidString == token,
              journal.destination.isFileURL, journal.candidate.isFileURL, journal.backup.isFileURL,
              journal.destination.standardizedFileURL == expectedDestination.standardizedFileURL,
              journal.destination.pathExtension == "app",
              parent.resolvingSymlinksInPath() == parent,
              journal.candidate.deletingLastPathComponent().standardizedFileURL == parent,
              journal.backup.deletingLastPathComponent().standardizedFileURL == parent,
              journal.backup.lastPathComponent == ".Radius-previous-" + token + suffix,
              ["copying", "prepared", "activated"].contains(journal.phase) else {
            throw ValidationError("The update journal is invalid. Your previous application has been kept.")
        }
        for path in [journal.destination, journal.candidate, journal.backup] where fm.fileExists(atPath: path.path) {
            guard (try path.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true else {
                throw ValidationError("The update journal references a symbolic link.")
            }
        }
        if !fm.fileExists(atPath: journal.destination.path), fm.fileExists(atPath: journal.backup.path) {
            if let verifyExisting { try verifyExisting(journal.backup) } else { try verify(journal.backup) }
            try fm.moveItem(at: journal.backup, to: journal.destination)
        }
        if !fm.fileExists(atPath: journal.destination.path), !fm.fileExists(atPath: journal.backup.path) {
            if fm.fileExists(atPath: journal.candidate.path) {
                // A first installation has no previous bundle to restore. Only a
                // fully verified copied candidate may finish its interrupted move.
                try verify(journal.candidate)
                try fm.moveItem(at: journal.candidate, to: journal.destination)
            } else if journal.phase == "copying" {
                try fm.removeItem(at: journalURL)
                return
            }
        }
        if fm.fileExists(atPath: journal.destination.path) {
            if let verifyExisting { try verifyExisting(journal.destination) } else { try verify(journal.destination) }
            try? fm.removeItem(at: journal.candidate)
            try? fm.removeItem(at: journal.backup)
            if !fm.fileExists(atPath: journal.candidate.path), !fm.fileExists(atPath: journal.backup.path) { try fm.removeItem(at: journalURL) }
        } else {
            throw ValidationError("The installation was interrupted before an app could be activated. Import a verified Radius installer again.")
        }
    }
}
