// SPDX-License-Identifier: MPL-2.0
import Foundation
import Security
import RadiusCore

public enum ReleaseTrust {
    /// Publisher identity comes from the currently running signed app, never from
    /// an imported manifest, a hash supplied beside a download, or user defaults.
    public static func publisherTeam(of app: URL) throws -> String {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else {
            throw ValidationError("The current Radius application has no valid publisher signature.")
        }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let values = information as NSDictionary?,
              let team = values[kSecCodeInfoTeamIdentifier] as? String,
              team.count == 10, team.allSatisfy({ $0.isASCII && ($0.isUppercase || $0.isNumber) }) else {
            throw ValidationError("This development build has no Developer ID publisher identity. Consumer installation requires an official signed Radius release.")
        }
        try verifySignature(app, team: team, identifier: "org.radius.browser", notarized: false, deep: false)
        return team
    }
    public static func verifySignature(_ codeURL: URL, team: String, identifier: String, notarized: Bool, deep: Bool = true) throws {
        guard team.count == 10, team.allSatisfy({ $0.isASCII && ($0.isUppercase || $0.isNumber) }),
              ["org.radius.browser", "org.radius.updater"].contains(identifier) else {
            throw ValidationError("The publisher requirement is invalid.")
        }
        let requirementText = "anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"\(team)\" and identifier \"\(identifier)\"" + (notarized ? " and notarized" : "")
        var requirement: SecRequirement?
        var code: SecStaticCode?
        guard SecRequirementCreateWithString(requirementText as CFString, [], &requirement) == errSecSuccess,
              let requirement, SecStaticCodeCreateWithPath(codeURL as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code,
                SecCSFlags(rawValue: deep ? kSecCSStrictValidate | kSecCSCheckNestedCode | kSecCSCheckAllArchitectures : kSecCSStrictValidate), requirement) == errSecSuccess else {
            throw ValidationError("The application is damaged, unnotarized, or signed by a different publisher. The installed app has been kept.")
        }
    }
    public static func metadata(of app: URL, requireCompatibleArchitecture: Bool = true) throws -> DistributionRelease {
        guard let bundle = Bundle(url: app), bundle.bundleIdentifier == "org.radius.browser",
              bundle.executableURL?.lastPathComponent == "Radius",
              bundle.infoDictionary?["CFBundlePackageType"] as? String == "APPL" else {
            throw ValidationError("Choose a complete Radius application or Radius installer.")
        }
        let path = app.appendingPathComponent("Contents/Resources/Distribution.json")
        let values = try path.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size > 0, size <= 4096 else {
            throw ValidationError("This Radius release has no valid distribution metadata.")
        }
        let release = try JSONDecoder().decode(DistributionRelease.self, from: boundedData(at: path, maximum: 4096))
        guard bundle.infoDictionary?["CFBundleVersion"] as? String == String(release.build),
              bundle.infoDictionary?["CFBundleShortVersionString"] as? String == release.version else {
            throw ValidationError("The release version does not match the signed application.")
        }
        #if arch(arm64)
        let architecture = "arm64", cpu = 16_777_228
        #else
        let architecture = "x86_64", cpu = 16_777_223
        #endif
        guard !requireCompatibleArchitecture || bundle.executableArchitectures?.contains(NSNumber(value: cpu)) == true else {
            throw ValidationError("The Radius executable does not support this Mac.")
        }
        let runtime = app.appendingPathComponent("Contents/Frameworks/Chromium.radiusengine", isDirectory: true)
        let hasChromium = FileManager.default.fileExists(atPath: runtime.path)
        guard hasChromium == release.chromium else { throw ValidationError("The engine contents do not match the signed release metadata.") }
        if hasChromium {
            let manifest = runtime.appendingPathComponent("Contents/Resources/manifest.json")
            let size = try manifest.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size > 0, size <= 4096 else { throw ValidationError("The Chromium manifest is too large or empty.") }
            let engine = try JSONDecoder().decode(DistributionEngineManifest.self, from: boundedData(at: manifest, maximum: 4096))
            try engine.validate(release: release, architecture: requireCompatibleArchitecture ? architecture : nil)
        }
        return release
    }
    private static func boundedData(at file: URL, maximum: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximum + 1) ?? Data()
        guard !data.isEmpty, data.count <= maximum else { throw ValidationError("The signed release metadata is too large or empty.") }
        return data
    }
    public static func verifyBundleTree(_ app: URL) throws {
        let fm = FileManager.default
        let values = try app.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        let root = app.resolvingSymlinksInPath().standardizedFileURL
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw ValidationError("The imported application must be a real bundle directory.") }
        var enumerationError: Error?
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey], options: [], errorHandler: { _, error in enumerationError = error; return false }) else {
            throw ValidationError("The application could not be read.")
        }
        var count = 0, bytes: Int64 = 0
        for case let file as URL in enumerator {
            try Task.checkCancellation()
            count += 1
            let resolved = file.resolvingSymlinksInPath().standardizedFileURL
            guard count <= 200_000, resolved.path.hasPrefix(root.path + "/") else {
                throw ValidationError("The application contains an external link or too many files.")
            }
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey])
            if values.isRegularFile == true, values.isSymbolicLink != true { bytes += Int64(values.fileSize ?? 0) }
            guard bytes <= 10_000_000_000 else { throw ValidationError("The application is too large to install.") }
        }
        if let enumerationError { throw enumerationError }
    }
}
