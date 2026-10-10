// SPDX-License-Identifier: MPL-2.0
import Foundation
import XCTest
@testable import RadiusCore

final class DistributionTests: XCTestCase {
    private func temporary() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func app(_ parent: URL, _ name: String, contents: String) throws -> URL {
        let url = parent.appendingPathComponent(name + ".app", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url.appendingPathComponent("version"))
        return url
    }
    func testReleaseRejectsOlderBuildArchitectureAndSecurityRollback() throws {
        let current = DistributionRelease(build: 20, version: "1.0.0", securityEpoch: 154, architecture: "arm64", chromium: true)
        try current.validate(current: current, minimumEpoch: 154, architecture: "arm64")
        for release in [DistributionRelease(build: 19, version: "1.0.0", securityEpoch: 154, architecture: "arm64", chromium: true),
                        DistributionRelease(build: 21, version: "1.0.1", securityEpoch: 153, architecture: "arm64", chromium: true),
                        DistributionRelease(build: 21, version: "1.0.1", securityEpoch: 154, architecture: "x86_64", chromium: true)] {
            XCTAssertThrowsError(try release.validate(current: current, minimumEpoch: 154, architecture: "arm64"))
        }
        let removal = DistributionRelease(build: 20, version: "1.0.0", securityEpoch: 154, architecture: "universal", chromium: false)
        try removal.validate(current: current, minimumEpoch: 154, architecture: "arm64")
        XCTAssertThrowsError(try current.validate(current: current, minimumEpoch: 155, architecture: "arm64"))
    }
    func testCatalogRejectsUntrustedPathsAndOversizedAssets() {
        let release = DistributionRelease(build: 1, version: "1.0.0", securityEpoch: 154, architecture: "arm64", chromium: true)
        for url in ["http://github.com/starharbor2491/radius-browser/releases/download/v1/Radius.dmg", "https://example.com/Radius.dmg", "https://github.com/other/project/releases/download/v1/Radius.dmg", "https://github.com/starharbor2491/radius-browser/releases/download/v1/Radius.zip"] {
            XCTAssertThrowsError(try DistributionAsset(release: release, url: URL(string: url)!, sha256: String(repeating: "a", count: 64), bytes: 100).validate())
        }
        XCTAssertThrowsError(try DistributionAsset(release: release, url: URL(string: "https://github.com/starharbor2491/radius-browser/releases/download/v1/Radius.dmg")!, sha256: String(repeating: "a", count: 64), bytes: 4_000_000_001).validate())
    }
    func testUpdateValidatesCopiedCandidateAndPreservesUserData() throws {
        let root = try temporary(), source = try app(root, "Candidate", contents: "new"), destination = try app(root, "Radius", contents: "old")
        let data = root.appendingPathComponent("UserData"); try Data("kept".utf8).write(to: data)
        let journal = root.appendingPathComponent("journal.json")
        var validated: [URL] = []
        try AppReplacementTransaction.install(source: source, destination: destination, journalURL: journal) { path in
            XCTAssertTrue(FileManager.default.fileExists(atPath: path.appendingPathComponent("version").path)); validated.append(path)
        }
        XCTAssertEqual(validated.count, 3)
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("version"), encoding: .utf8), "new")
        XCTAssertEqual(try String(contentsOf: data, encoding: .utf8), "kept")
        XCTAssertFalse(FileManager.default.fileExists(atPath: journal.path))
    }
    func testFailedVerificationAndActivationLeavePreviousApp() throws {
        let root = try temporary(), source = try app(root, "Candidate", contents: "new"), destination = try app(root, "Radius", contents: "old")
        let journal = root.appendingPathComponent("journal.json")
        XCTAssertThrowsError(try AppReplacementTransaction.install(source: source, destination: destination, journalURL: journal, verify: { path in
            if path.lastPathComponent.hasPrefix(".Radius-install-") { throw ValidationError("Damaged copied code") }
        }))
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("version"), encoding: .utf8), "old")
        XCTAssertThrowsError(try AppReplacementTransaction.install(source: source, destination: destination, journalURL: journal, verify: { _ in }, checkpoint: { phase in
            if phase == "previousMoved" { throw ValidationError("Injected rename failure") }
        }))
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("version"), encoding: .utf8), "old")
        XCTAssertFalse(FileManager.default.fileExists(atPath: journal.path))
    }
    func testInterruptedUpdateRestoresVerifiedPreviousAndRejectsForgedJournal() throws {
        let root = try temporary(), destination = root.appendingPathComponent("Radius.app")
        let token = UUID().uuidString
        let backup = try app(root, ".Radius-previous-" + token, contents: "old")
        let candidate = try app(root, ".Radius-install-" + token, contents: "new")
        let journal = root.appendingPathComponent("journal.json")
        let entry = AppReplacementTransaction.Journal(destination: destination, candidate: candidate, backup: backup, phase: "prepared")
        try JSONEncoder().encode(entry).write(to: journal)
        var validated = 0
        try AppReplacementTransaction.recover(journalURL: journal, expectedDestination: destination) { _ in validated += 1 }
        XCTAssertEqual(validated, 2)
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("version"), encoding: .utf8), "old")
        let other = try app(root, "Innocent", contents: "kept")
        try JSONEncoder().encode(AppReplacementTransaction.Journal(destination: destination, candidate: other, backup: backup, phase: "prepared")).write(to: journal)
        XCTAssertThrowsError(try AppReplacementTransaction.recover(journalURL: journal, expectedDestination: destination, verify: { _ in }))
        XCTAssertEqual(try String(contentsOf: other.appendingPathComponent("version"), encoding: .utf8), "kept")
    }
    func testFirstInstallationRecoveryAndSecurityAdvance() throws {
        let root = try temporary(), destination = root.appendingPathComponent("Radius.app")
        let token = UUID().uuidString
        let candidate = try app(root, ".Radius-install-" + token, contents: "new")
        let backup = root.appendingPathComponent(".Radius-previous-" + token + ".app")
        let journal = root.appendingPathComponent("journal.json")
        try JSONEncoder().encode(AppReplacementTransaction.Journal(destination: destination, candidate: candidate, backup: backup, phase: "prepared")).write(to: journal)
        try AppReplacementTransaction.recover(journalURL: journal, expectedDestination: destination) { path in
            XCTAssertEqual(try String(contentsOf: path.appendingPathComponent("version"), encoding: .utf8), "new")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: journal.path))
        let old = DistributionRelease(build: 20, version: "1.0.0", securityEpoch: 154, architecture: "arm64", chromium: true)
        let new = DistributionRelease(build: 21, version: "1.0.1", securityEpoch: 155, architecture: "arm64", chromium: true)
        // The accepted floor remains 154 until the new application activates;
        // requiring its future 155 floor for the old destination prevents updates.
        try old.validate(current: old, minimumEpoch: 154, architecture: "arm64")
        try new.validate(current: old, minimumEpoch: 154, architecture: "arm64")
        XCTAssertThrowsError(try old.validate(current: new, minimumEpoch: 155, architecture: "arm64"))
    }

    func testNewInstallerCanReplaceOlderTrustedDestinationWithoutAuthorizingOldCandidate() throws {
        let root = try temporary(), source = try app(root, "Candidate", contents: "20"), destination = try app(root, "Radius", contents: "19")
        let journal = root.appendingPathComponent("journal.json")
        let candidatePolicy: (URL) throws -> Void = { path in
            guard try String(contentsOf: path.appendingPathComponent("version"), encoding: .utf8) == "20" else { throw ValidationError("Older candidate") }
        }
        let existingTrust: (URL) throws -> Void = { path in
            let version = try String(contentsOf: path.appendingPathComponent("version"), encoding: .utf8)
            guard ["19", "20"].contains(version) else { throw ValidationError("Untrusted original app") }
        }
        XCTAssertThrowsError(try candidatePolicy(destination))
        try AppReplacementTransaction.install(source: source, destination: destination, journalURL: journal, verify: candidatePolicy, verifyExisting: existingTrust)
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("version"), encoding: .utf8), "20")
    }

    func testOlderRunningInstallerCannotOverwriteNewerDestination() throws {
        let root = try temporary(), source = try app(root, "Candidate", contents: "20"), destination = try app(root, "Radius", contents: "30")
        let journal = root.appendingPathComponent("journal.json")
        let candidate = DistributionRelease(build: 20, version: "1.0.0", securityEpoch: 155, architecture: "arm64", chromium: true)
        let running = DistributionRelease(build: 20, version: "1.0.0", securityEpoch: 155, architecture: "arm64", chromium: true)
        let installed = DistributionRelease(build: 30, version: "1.0.1", securityEpoch: 156, architecture: "arm64", chromium: true)
        try candidate.validate(current: running, minimumEpoch: 155, architecture: "arm64")
        XCTAssertThrowsError(try AppReplacementTransaction.install(source: source, destination: destination, journalURL: journal,
            verify: { _ in try candidate.validate(current: running, minimumEpoch: 155, architecture: "arm64") },
            verifyExisting: { _ in try candidate.validate(current: installed, minimumEpoch: 155, architecture: "arm64") }))
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("version"), encoding: .utf8), "30")
        XCTAssertFalse(FileManager.default.fileExists(atPath: journal.path))
    }

    func testWholeAppManifestAcceptsFutureABIWithoutWeakeningArchitectureOrSecurity() throws {
        let release = DistributionRelease(build: 30, version: "1.1.0", securityEpoch: 155, architecture: "arm64", chromium: true)
        try DistributionEngineManifest(abi: 3, architecture: "arm64", cefVersion: "155.0.1").validate(release: release, architecture: "arm64")
        for manifest in [DistributionEngineManifest(abi: 0, architecture: "arm64", cefVersion: "155.0.1"),
                         DistributionEngineManifest(abi: 1025, architecture: "arm64", cefVersion: "155.0.1"),
                         DistributionEngineManifest(abi: 3, architecture: "x86_64", cefVersion: "155.0.1"),
                         DistributionEngineManifest(abi: 3, architecture: "arm64", cefVersion: "156.0.1")] {
            XCTAssertThrowsError(try manifest.validate(release: release, architecture: "arm64"))
        }
        let booleanABI = Data(#"{"format":2,"abi":true,"runtimeStyle":"chrome","architecture":"arm64","cefVersion":"155.0.1"}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(DistributionEngineManifest.self, from: booleanABI))
    }

    func testReleaseRejectsUnsupportedMacOSAndKeepsLegacyMetadataCompatible() throws {
        let current = DistributionRelease(build: 20, version: "1.0.0", securityEpoch: 154, architecture: "universal", chromium: false)
        let candidate = DistributionRelease(build: 21, version: "1.0.1", securityEpoch: 154, architecture: "arm64", chromium: true, minimumMacOS: "14.5")
        let oldOS = OperatingSystemVersion(majorVersion: 14, minorVersion: 4, patchVersion: 99)
        XCTAssertThrowsError(try candidate.validate(current: current, minimumEpoch: 154, architecture: "arm64", operatingSystemVersion: oldOS))
        try candidate.validate(current: current, minimumEpoch: 154, architecture: "arm64", operatingSystemVersion: OperatingSystemVersion(majorVersion: 14, minorVersion: 5, patchVersion: 0))
        try candidate.validate(current: current, minimumEpoch: 154, architecture: "arm64", operatingSystemVersion: OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 0))
        for invalid in ["", "14", "14..5", "14.5beta", "-14.5", "14.5.0.0", "14.1000"] {
            XCTAssertThrowsError(try DistributionRelease.validateMinimumMacOS(invalid, operatingSystemVersion: oldOS))
        }
        let legacy = Data(#"{"format":1,"build":20,"version":"1.0.0","securityEpoch":154,"architecture":"universal","chromium":false}"#.utf8)
        let decoded = try JSONDecoder().decode(DistributionRelease.self, from: legacy)
        XCTAssertNil(decoded.minimumMacOS)
        try decoded.validate(current: current, minimumEpoch: 154, architecture: "arm64", operatingSystemVersion: OperatingSystemVersion(majorVersion: 14, minorVersion: 0, patchVersion: 0))
    }

}
