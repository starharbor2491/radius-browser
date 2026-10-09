// SPDX-License-Identifier: MPL-2.0
import AppKit
import CryptoKit
import Darwin
import RadiusCore
import RadiusEngineABI
import SwiftUI

/// The runtime is process-wide. Once loaded, installation changes require a restart.
@MainActor
final class ChromiumRuntime: ObservableObject {
    static let shared = ChromiumRuntime()
    nonisolated static let cefVersion = "154.0.34+g14c5a08+chromium-154.0.8037.98"
    @Published private(set) var isLoaded = false
    @Published private(set) var status = "Chromium Alloy development runtime · No Chrome extensions"
    private var library: UnsafeMutableRawPointer?
    private(set) var api: radius_cef_api?
    private var loadedDataDirectory: URL?
    private var stopped = false
    private var installing = false

    static func packageURL(in directory: URL) -> URL {
        directory.appendingPathComponent("Engines/Chromium.radiusengine", isDirectory: true)
    }
    func isInstalled(in directory: URL) -> Bool {
        FileManager.default.fileExists(atPath: Self.packageURL(in: directory).appendingPathComponent("manifest.json").path)
    }
    func makeTab(profileID: UUID, privateSessionID: UUID?, dataDirectory: URL) throws -> ChromiumTab {
        try load(dataDirectory: dataDirectory)
        guard let api else { throw ValidationError("The Chromium runtime is not loaded.") }
        let page = profileID.uuidString.withCString { profile in
            (privateSessionID?.uuidString ?? "").withCString { privateID in api.create_page(profile, privateID) }
        }
        guard let page else { throw failure() }
        return ChromiumTab(runtime: self, page: page)
    }
    private func load(dataDirectory: URL) throws {
        guard !stopped else { throw ValidationError("Restart Radius before using Chromium again.") }
        if isLoaded {
            guard loadedDataDirectory == dataDirectory.standardizedFileURL else {
                throw ValidationError("Chromium is already using another Radius data directory. Restart Radius to change it.")
            }
            return
        }
        guard library == nil else { throw ValidationError("Restart Radius after the previous runtime loading failure.") }
        guard !installing else { throw ValidationError("Wait for the Chromium runtime installation to finish.") }
        let package = Self.packageURL(in: dataDirectory)
        try ChromiumPackage.validate(package)
        let bridge = package.appendingPathComponent("Contents/MacOS/RadiusChromiumBridge.dylib")
        guard let handle = dlopen(bridge.path, RTLD_NOW | RTLD_LOCAL) else {
            throw ValidationError("Could not load the Chromium bridge: \(String(cString: dlerror()))")
        }
        // CEF/Objective-C class registrations make unloading unsafe, even after failure.
        library = handle
        guard let symbol = dlsym(handle, "radius_cef_get_api") else { throw ValidationError("This runtime has no Radius engine API.") }
        let getter = unsafeBitCast(symbol, to: radius_cef_get_api_function.self)
        guard let pointer = getter(), pointer.pointee.version == 1 else { throw ValidationError("This runtime uses an incompatible Radius engine API.") }
        let loadedAPI = pointer.pointee
        let success = package.path.withCString { packagePath in
            dataDirectory.path.withCString { dataPath in
                Bundle.main.bundlePath.withCString { bundlePath in loadedAPI.initialize(packagePath, dataPath, bundlePath) }
            }
        }
        api = loadedAPI
        guard success != 0 else { stopped = true; throw failure() }
        loadedDataDirectory = dataDirectory.standardizedFileURL
        isLoaded = true
        status = "Chromium Alloy loaded · \(Self.cefVersion) · No Chrome extensions"
    }
    func failure() -> ValidationError {
        ValidationError(api?.last_error().map { String(cString: $0) } ?? "The Chromium runtime failed.")
    }
    func install(from source: URL, dataDirectory: URL) async throws {
        guard library == nil else { throw ValidationError("Restart Radius before installing or replacing the loaded Chromium runtime.") }
        guard !installing else { throw ValidationError("A Chromium runtime installation is already in progress.") }
        installing = true
        defer { installing = false }
        status = "Checking and installing development runtime…"
        do {
            try await Task.detached(priority: .userInitiated) { try ChromiumPackage.install(source, in: dataDirectory) }.value
            status = "Chromium Alloy installed · No Chrome extensions"
        } catch { status = error.localizedDescription; throw error }
    }
    func uninstall(dataDirectory: URL) throws {
        guard !installing else { throw ValidationError("Wait for the Chromium runtime installation to finish.") }
        guard library == nil else { throw ValidationError("Restart Radius with WebKit selected before removing Chromium.") }
        let package = Self.packageURL(in: dataDirectory)
        if FileManager.default.fileExists(atPath: package.path) { try FileManager.default.removeItem(at: package) }
        status = "Chromium runtime removed. Profile website data was kept."
    }
    func clearWebsiteData(profileID: UUID, dataDirectory: URL) async throws {
        guard library == nil else { throw ValidationError("Restart Radius with WebKit selected before clearing Chromium website data.") }
        let path = dataDirectory.appendingPathComponent("Chromium/Profiles/\(profileID.uuidString)", isDirectory: true)
        if FileManager.default.fileExists(atPath: path.path) { try FileManager.default.removeItem(at: path) }
    }
    /// Call after all tab owners have disposed their pages, before AppKit replies to quit.
    func shutdown() async -> Bool {
        guard isLoaded, let api else { return true }
        for _ in 0..<200 {
            if api.live_pages() == 0 {
                let success = api.shutdown() != 0
                if success { isLoaded = false; stopped = true }
                return success
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        status = "Chromium pages did not finish closing. Retry quitting Radius."
        return false
    }
}

private struct ChromiumManifest: Decodable {
    let format: Int
    let abi: Int
    let architecture: String
    let cefVersion: String
    let files: [String: String]
}

/// Digests establish package integrity, not publisher trust. Installation is an explicit
/// local development action; this is not a signed consumer download/update channel.
private enum ChromiumPackage {
    static func validate(_ package: URL) throws {
        let manager = FileManager.default
        let root = package.resolvingSymlinksInPath().standardizedFileURL
        let manifestURL = root.appendingPathComponent("manifest.json")
        guard manifestURL.resolvingSymlinksInPath().path.hasPrefix(root.path + "/") else {
            throw ValidationError("The runtime manifest links outside its directory.")
        }
        let manifestSize = try manifestURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard manifestSize > 0, manifestSize <= 4_000_000 else { throw ValidationError("The runtime manifest has an invalid size.") }
        let data = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(ChromiumManifest.self, from: data)
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x86_64"
        #endif
        guard manifest.format == 1, manifest.abi == 1,
              manifest.architecture == architecture, manifest.cefVersion == ChromiumRuntime.cefVersion else {
            throw ValidationError("This Chromium package is incompatible with this Radius build or Mac architecture.")
        }
        guard !manifest.files.isEmpty, manifest.files.count < 20_000 else { throw ValidationError("Invalid runtime file manifest.") }
        let required = ["Contents/MacOS/RadiusChromiumBridge.dylib",
            "Contents/Frameworks/Chromium Embedded Framework.framework/Versions/A/Chromium Embedded Framework",
            "Contents/Frameworks/RadiusChromium Helper.app/Contents/MacOS/RadiusChromium Helper"]
        guard required.allSatisfy({ manifest.files[$0] != nil }) else { throw ValidationError("The runtime package is incomplete.") }
        guard let enumerator = manager.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else {
            throw ValidationError("Could not read the runtime package.")
        }
        var checked = Set<String>()
        for case let file as URL in enumerator {
            let relative = String(file.path.dropFirst(root.path.count + 1))
            guard file.resolvingSymlinksInPath().path.hasPrefix(root.path + "/") else {
                throw ValidationError("The runtime package contains a link outside its directory.")
            }
            let attributes = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if attributes.isSymbolicLink == true { continue }
            guard attributes.isRegularFile == true else { continue }
            if relative == "manifest.json" { continue }
            guard let expected = manifest.files[relative], expected.count == 64 else {
                throw ValidationError("The runtime contains an unlisted file: \(relative)")
            }
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            var hasher = SHA256()
            while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty { hasher.update(data: chunk) }
            let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            guard digest == expected else { throw ValidationError("The runtime file failed its integrity check: \(relative)") }
            checked.insert(relative)
        }
        guard checked == Set(manifest.files.keys) else { throw ValidationError("The runtime is missing files from its manifest.") }
    }
    static func install(_ source: URL, in directory: URL) throws {
        let manager = FileManager.default
        let destination = directory.appendingPathComponent("Engines/Chromium.radiusengine", isDirectory: true)
        let parent = destination.deletingLastPathComponent()
        try manager.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let staging = parent.appendingPathComponent(".chromium-install-" + UUID().uuidString)
        defer { try? manager.removeItem(at: staging) }
        try manager.copyItem(at: source, to: staging)
        try validate(staging)
        if manager.fileExists(atPath: destination.path) {
            _ = try manager.replaceItemAt(destination, withItemAt: staging)
        } else { try manager.moveItem(at: staging, to: destination) }
    }
}
