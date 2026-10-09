// SPDX-License-Identifier: MPL-2.0
import AppKit
import Security
import Darwin
import RadiusCore
import RadiusEngineABI
import SwiftUI

/// The optional runtime is embedded before the development app is signed.
/// App Support packages cannot run within the CEF helper sandbox.
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

    static var packageURL: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Frameworks/Chromium.radiusengine", isDirectory: true)
    }
    func isInstalled(in directory: URL) -> Bool {
        (try? ChromiumPackage.readManifest(Self.packageURL)) != nil
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
        let package = Self.packageURL
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
}

/// Ad-hoc signatures establish code integrity, not publisher identity.
/// The development app has no Developer ID or notarized distribution claim.
private enum ChromiumPackage {
    static func readManifest(_ package: URL) throws -> ChromiumManifest {
        let manifestURL = package.appendingPathComponent("Contents/Resources/manifest.json")
        let size = try manifestURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= 4096 else { throw ValidationError("The runtime manifest has an invalid size.") }
        let manifest = try JSONDecoder().decode(ChromiumManifest.self, from: Data(contentsOf: manifestURL))
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x86_64"
        #endif
        guard manifest.format == 2, manifest.abi == 1,
              manifest.architecture == architecture, manifest.cefVersion == ChromiumRuntime.cefVersion else {
            throw ValidationError("This Chromium package is incompatible with this Radius build or Mac architecture.")
        }
        return manifest
    }
    static func validate(_ package: URL) throws {
        _ = try readManifest(package)
        let root = package.resolvingSymlinksInPath().standardizedFileURL
        let appRoot = Bundle.main.bundleURL.resolvingSymlinksInPath().standardizedFileURL
        guard root.path.hasPrefix(appRoot.path + "/Contents/Frameworks/") else {
            throw ValidationError("The sandboxed Chromium runtime must be embedded inside Radius.app.")
        }
        // Resource links must remain inside the package and therefore inside
        // the parent app's sandbox read boundary.
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey]) else {
            throw ValidationError("Could not read the runtime package.")
        }
        for case let file as URL in enumerator {
            guard file.resolvingSymlinksInPath().path.hasPrefix(root.path + "/") else {
                throw ValidationError("The runtime package contains a link outside its directory.")
            }
        }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(root as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckNestedCode | kSecCSCheckAllArchitectures), nil) == errSecSuccess else {
            throw ValidationError("The embedded Chromium runtime failed its code-signature integrity check.")
        }
    }
}
