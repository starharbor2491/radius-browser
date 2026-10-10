// SPDX-License-Identifier: MPL-2.0
import Foundation
import Security
import Testing
import RadiusCore
import RadiusDistribution
@testable import RadiusApp

@Suite(.serialized)
struct DistributionNativeTests {
    @Test func consumerRequirementSupportsNotarizationAndRejectsUnidentifiedCode() throws {
        var requirement: SecRequirement?
        #expect(SecRequirementCreateWithString("notarized" as CFString, [], &requirement) == errSecSuccess)
        #expect(requirement != nil)
        // The real test executable is development-signed, never a consumer
        // publisher. No test policy is available to the installation UI.
        #expect(throws: (any Error).self) { try ReleaseTrust.publisherTeam(of: Bundle.main.bundleURL) }
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["RADIUS_DISTRIBUTION_TEST_APP"] != nil))
    func realSignedAppStagesAtomicallyAndDamagedCopyRollsBack() throws {
        let fixture = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["RADIUS_DISTRIBUTION_TEST_APP"]))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Radius-install-native-" + UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let candidate = root.appendingPathComponent("Candidate.app"), installed = root.appendingPathComponent("Radius.app")
        try FileManager.default.copyItem(at: fixture, to: candidate)
        try FileManager.default.copyItem(at: fixture, to: installed)
        let initial = try ReleaseTrust.metadata(of: candidate)
        let journal = root.appendingPathComponent("journal.json")
        let data = root.appendingPathComponent("UserData.json")
        try Data("kept".utf8).write(to: data)
        // Explicit CI-only verifier exercises the exact transaction with real
        // native bundles and code-integrity checks. Production calls always use
        // ReleaseTrust's Developer ID + same-publisher + notarized requirement.
        let integrity: (URL) throws -> Void = Self.verifyNativeFixture
        try AppReplacementTransaction.install(source: candidate, destination: installed, journalURL: journal, verify: integrity)
        #expect(try ReleaseTrust.metadata(of: installed) == initial)
        #expect(try String(contentsOf: data, encoding: .utf8) == "kept")
        try Data("damaged".utf8).write(to: candidate.appendingPathComponent("Contents/Resources/Distribution.json"))
        #expect(throws: (any Error).self) {
            try AppReplacementTransaction.install(source: candidate, destination: installed, journalURL: journal, verify: integrity)
        }
        #expect(try ReleaseTrust.metadata(of: installed) == initial)
        #expect(!FileManager.default.fileExists(atPath: journal.path))
        #expect(throws: (any Error).self) { try ReleaseTrust.publisherTeam(of: installed) }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["RADIUS_DISTRIBUTION_TEST_APP"] != nil))
    func replacingABundleAtTheSameURLReadsItsNewSignedVersionInsteadOfCachedInfo() throws {
        let fixture = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["RADIUS_DISTRIBUTION_TEST_APP"]))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Radius-version-update-" + UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let candidate = root.appendingPathComponent("Candidate.app"), installed = root.appendingPathComponent("Radius.app")
        try FileManager.default.copyItem(at: fixture, to: candidate)
        try FileManager.default.copyItem(at: fixture, to: installed)
        let old = try ReleaseTrust.metadata(of: installed)
        let cachedBundle = try #require(Bundle(url: installed))
        #expect(cachedBundle.infoDictionary?["CFBundleVersion"] as? String == String(old.build))
        try #require(old.build < Int.max)
        let replacement = DistributionRelease(build: old.build + 1, version: "\(old.build + 1).0.0", securityEpoch: old.securityEpoch,
            architecture: old.architecture, chromium: old.chromium, minimumMacOS: old.minimumMacOS ?? "14.0")
        let infoURL = candidate.appendingPathComponent("Contents/Info.plist")
        var info = try #require(PropertyListSerialization.propertyList(from: Data(contentsOf: infoURL), format: nil) as? [String: Any])
        info["CFBundleVersion"] = String(replacement.build)
        info["CFBundleShortVersionString"] = replacement.version
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: infoURL, options: .atomic)
        try JSONEncoder().encode(replacement).write(to: candidate.appendingPathComponent("Contents/Resources/Distribution.json"), options: .atomic)
        // Sign this fixture after changing its sealed metadata. Development
        // integrity is available only in this test, never in the consumer UI.
        let signer = Process()
        signer.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        signer.arguments = ["--force", "--sign", "-", "--preserve-metadata=identifier,entitlements,flags", "--timestamp=none", candidate.path]
        signer.standardInput = FileHandle.nullDevice
        try signer.run(); signer.waitUntilExit()
        try #require(signer.terminationStatus == 0)
        try Self.verifyNativeFixture(candidate)
        #expect(try ReleaseTrust.metadata(of: candidate) == replacement)

        try AppReplacementTransaction.install(source: candidate, destination: installed, journalURL: root.appendingPathComponent("journal.json"),
            verify: Self.verifyNativeFixture, verifyExisting: Self.verifyNativeFixture)

        // Keep the original Bundle alive across the rename. The updater must
        // inspect the new sealed files even if Foundation keeps the old cache.
        let activated = try withExtendedLifetime(cachedBundle) { try ReleaseTrust.metadata(of: installed) }
        #expect(activated == replacement)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("journal.json").path))
    }

    private static func verifyNativeFixture(_ app: URL) throws {
        try ReleaseTrust.verifyBundleTree(app)
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckNestedCode | kSecCSCheckAllArchitectures), nil) == errSecSuccess else {
            throw ValidationError("Damaged native fixture")
        }
        _ = try ReleaseTrust.metadata(of: app)
    }
}
