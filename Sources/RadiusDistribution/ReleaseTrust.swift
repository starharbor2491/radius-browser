// SPDX-License-Identifier: MPL-2.0
import Foundation
import Security
import Darwin
import RadiusCore

public enum ReleaseTrust {
    /// A universal replacement launches natively, including when its current
    /// browser process runs under Rosetta. Choose the target Mac's CPU rather
    /// than sealing an Intel engine into a future Apple silicon host.
    public static var platformArchitecture: String {
        #if arch(arm64)
        return "arm64"
        #else
        var appleSilicon: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("hw.optional.arm64", &appleSilicon, &size, nil, 0) == 0 && appleSilicon == 1 ? "arm64" : "x86_64"
        #endif
    }
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
        // Foundation caches Bundle metadata for a URL. The same destination URL
        // contains a different app after atomic replacement, so read its sealed
        // property list and executable header directly on every verification.
        let infoPath = app.appendingPathComponent("Contents/Info.plist")
        guard let info = try PropertyListSerialization.propertyList(from: boundedData(at: infoPath, maximum: 65_536), format: nil) as? [String: Any],
              info["CFBundleIdentifier"] as? String == "org.radius.browser",
              info["CFBundleExecutable"] as? String == "Radius",
              info["CFBundlePackageType"] as? String == "APPL" else {
            throw ValidationError("Choose a complete Radius application or Radius installer.")
        }
        let path = app.appendingPathComponent("Contents/Resources/Distribution.json")
        let values = try path.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size > 0, size <= 4096 else {
            throw ValidationError("This Radius release has no valid distribution metadata.")
        }
        let release = try JSONDecoder().decode(DistributionRelease.self, from: boundedData(at: path, maximum: 4096))
        guard info["CFBundleVersion"] as? String == String(release.build),
              info["CFBundleShortVersionString"] as? String == release.version else {
            throw ValidationError("The release version does not match the signed application.")
        }
        guard let minimum = info["LSMinimumSystemVersion"] as? String,
              release.minimumMacOS == nil || release.minimumMacOS == minimum else {
            throw ValidationError("The macOS requirement does not match the signed application.")
        }
        if requireCompatibleArchitecture { try DistributionRelease.validateMinimumMacOS(minimum) }
        let architecture = platformArchitecture
        let cpu: UInt32 = architecture == "arm64" ? 16_777_228 : 16_777_223
        if requireCompatibleArchitecture {
            guard try executableSupportsCPU(app.appendingPathComponent("Contents/MacOS/Radius"), cpu: cpu) else {
                throw ValidationError("The Radius executable does not support this Mac.")
            }
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
    private static func executableSupportsCPU(_ executable: URL, cpu: UInt32) throws -> Bool {
        let values = try executable.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { return false }
        let handle = try FileHandle(forReadingFrom: executable)
        defer { try? handle.close() }
        let header = [UInt8](try handle.read(upToCount: 4096) ?? Data())
        func word(_ offset: Int, littleEndian: Bool = false) -> UInt32? {
            guard offset >= 0, offset + 4 <= header.count else { return nil }
            let bytes = Array(header[offset..<(offset + 4)])
            return (littleEndian ? Array(bytes.reversed()) : bytes).reduce(0) { ($0 << 8) | UInt32($1) }
        }
        guard let magic = word(0) else { return false }
        switch magic {
        case 0xfeedface, 0xfeedfacf: return word(4) == cpu
        case 0xcefaedfe, 0xcffaedfe: return word(4, littleEndian: true) == cpu
        case 0xcafebabe, 0xcafebabf, 0xbebafeca, 0xbfbafeca:
            let littleEndian = magic == 0xbebafeca || magic == 0xbfbafeca
            let stride = magic == 0xcafebabf || magic == 0xbfbafeca ? 32 : 20
            guard let count = word(4, littleEndian: littleEndian), count > 0, count <= 64,
                  8 + Int(count) * stride <= header.count else { return false }
            return (0..<Int(count)).contains { word(8 + $0 * stride, littleEndian: littleEndian) == cpu }
        default: return false
        }
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
