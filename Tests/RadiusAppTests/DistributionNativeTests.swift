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
        let integrity: (URL) throws -> Void = { app in
            try ReleaseTrust.verifyBundleTree(app)
            var code: SecStaticCode?
            guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code,
                  SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckNestedCode | kSecCSCheckAllArchitectures), nil) == errSecSuccess else {
                throw ValidationError("Damaged native fixture")
            }
            _ = try ReleaseTrust.metadata(of: app)
        }
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
}
