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
    @Published private(set) var status = "Chromium Chrome runtime"
    private var library: UnsafeMutableRawPointer?
    private(set) var api: radius_cef_api?
    private var loadedDataDirectory: URL?
    private var stopped = false
    private(set) var finalQuitFrozen = false
    private var inputFreezeMonitor: Any?
    func setFinalQuitFrozen(_ frozen: Bool) {
        finalQuitFrozen = frozen
        api?.set_final_quit_frozen(frozen ? 1 : 0)
        if let monitor = inputFreezeMonitor { NSEvent.removeMonitor(monitor); inputFreezeMonitor = nil }
        guard frozen else { return }
        // Chrome children, extension bubbles and auxiliary windows are outside
        // SwiftUI's disabled hierarchy. Pause application input at the final
        // snapshot boundary, while preserving the native save-decision alert.
        inputFreezeMonitor = NSEvent.addLocalMonitorForEvents(matching: [
            .keyDown, .keyUp, .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
            .otherMouseDown, .otherMouseUp, .leftMouseDragged, .rightMouseDragged,
            .otherMouseDragged, .scrollWheel
        ]) { event in
            let windowID = event.window.map(ObjectIdentifier.init)
            let allowed = MainActor.assumeIsolated {
                guard ChromiumRuntime.shared.finalQuitFrozen else { return true }
                guard let modal = NSApp.modalWindow else { return false }
                var window = windowID.flatMap { id in NSApp.windows.first { ObjectIdentifier($0) == id } } ?? NSApp.keyWindow
                while let current = window {
                    if current === modal { return true }
                    window = current.parent ?? current.sheetParent
                }
                return false
            }
            return allowed ? event : nil
        }
    }
    // Own every live callback receiver, including management pages and pages
    // awaiting download cancellation after their native tab has disappeared.
    private var tabs: [ObjectIdentifier: ChromiumTab] = [:]
    private var blockedProfileIDs = Set<UUID>()
    private var privateSessions = Set<UUID>()
    private var didShutDown = false
    func register(_ tab: ChromiumTab) { tabs[ObjectIdentifier(tab)] = tab }
    func retainWhileClosing(_ tab: ChromiumTab) { register(tab) }
    func finishedClosing(_ tab: ChromiumTab) {
        tabs.removeValue(forKey: ObjectIdentifier(tab))
    }
    func beginPrivateSession(_ id: UUID) { privateSessions.insert(id) }
    func canAdoptPage(profileID: UUID, privateSessionID: UUID?) -> Bool {
        guard !stopped, !finalQuitFrozen, !blockedProfileIDs.contains(profileID) else { return false }
        return privateSessionID.map { privateSessions.contains($0) } ?? true
    }
    func closePrivateSession(_ id: UUID) {
        privateSessions.remove(id)
        for tab in Array(tabs.values) where tab.privateSessionID == id { tab.dispose() }
        releasePrivateContexts(sessionID: id, profileID: nil)
    }
    func releasePrivateProfile(_ profileID: UUID, sessionID: UUID) {
        for tab in Array(tabs.values) where tab.privateSessionID == sessionID && tab.profileID == profileID { tab.dispose() }
        releasePrivateContexts(sessionID: sessionID, profileID: profileID)
    }
    private func releasePrivateContexts(sessionID: UUID?, profileID: UUID?) {
        guard let api else { return }
        (sessionID?.uuidString ?? "").withCString { session in
            (profileID?.uuidString ?? "").withCString { profile in api.release_private_contexts(session, profile) }
        }
    }
    var focusedNativeTab: ChromiumTab? {
        tabs.values.first { $0.chromeWindow?.isKeyWindow == true }
    }
    var auxiliaryTabs: [ChromiumTab] { tabs.values.filter(\.isAuxiliary) }
    var extensionManagementTabs: [ChromiumTab] {
        tabs.values.filter { $0.url?.scheme == "chrome" && $0.url?.host == "extensions" }
    }
    func reportCloseFailure(_ message: String) { status = message }
    var downloadCenters: [DownloadCenter] {
        var seen = Set<ObjectIdentifier>()
        return tabs.values.map(\.downloadCenter).filter { seen.insert(ObjectIdentifier($0)).inserted }
    }
    func blockProfilesPendingDeletion(_ ids: Set<UUID>) { blockedProfileIDs = ids }
    func prepareToDeleteProfile(_ id: UUID) async throws {
        blockedProfileIDs.insert(id)
        let affected = tabs.values.filter { $0.profileID == id }
        for tab in affected { try await tab.cancelDownloads() }
        for tab in affected { tab.dispose() }
        NotificationCenter.default.post(name: .radiusChromiumProfileClosed, object: id)
    }
    func finalizeProfileDeletion(_ id: UUID) {
        // Release only after the deletion tombstone is durably saved. A refused
        // save can reopen the existing private profile without losing its login.
        releasePrivateContexts(sessionID: nil, profileID: id)
    }

    static var packageURL: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Frameworks/Chromium.radiusengine", isDirectory: true)
    }
    func isInstalled(in directory: URL) -> Bool {
        (try? ChromiumPackage.readManifest(Self.packageURL)) != nil
    }
    func makeTab(profileID: UUID, privateSessionID: UUID?, dataDirectory: URL, downloads: DownloadCenter? = nil) throws -> ChromiumTab {
        guard !finalQuitFrozen else { throw ValidationError("Radius is saving its final browsing state.") }
        guard !blockedProfileIDs.contains(profileID) else {
            throw ValidationError("This profile is being deleted. Choose another profile.")
        }
        if let privateSessionID, !privateSessions.contains(privateSessionID) {
            throw ValidationError("This private browsing window is closed.")
        }
        try load(dataDirectory: dataDirectory)
        guard let api else { throw ValidationError("The Chromium runtime is not loaded.") }
        let page = profileID.uuidString.withCString { profile in
            (privateSessionID?.uuidString ?? "").withCString { privateID in api.create_page(profile, privateID) }
        }
        guard let page else { throw failure() }
        return ChromiumTab(runtime: self, page: page, downloads: downloads ?? DownloadCenter(), profileID: profileID, privateSessionID: privateSessionID)
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
        guard let pointer = getter(), UnsafeRawPointer(pointer).load(as: UInt32.self) == 4 else {
            throw ValidationError("This runtime uses an incompatible Radius engine API.")
        }
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
        status = "Chromium Chrome runtime loaded · \(Self.cefVersion)"
    }
    func failure() -> ValidationError {
        ValidationError(api?.last_error().map { String(cString: $0) } ?? "The Chromium runtime failed.")
    }
    func clearWebsiteData(profileID: UUID, dataDirectory: URL) async throws {
        guard library == nil || didShutDown else {
            throw ValidationError("Restart Radius before erasing Chromium website data. Its engine still owns profile files.")
        }
        if let loadedDataDirectory, didShutDown,
           loadedDataDirectory.resolvingSymlinksInPath() != dataDirectory.standardizedFileURL.resolvingSymlinksInPath() {
            throw ValidationError("The requested Chromium data directory differs from the one this engine used.")
        }
        try ChromiumProfileData.erase(profileID: profileID, dataDirectory: dataDirectory)
    }
    /// Call after all tab owners have disposed their pages, before AppKit replies to quit.
    func shutdown() async -> Bool {
        guard isLoaded, let api else { return true }
        // Settings and extension management also own engine pages, outside the
        // browser-window model registry. Close every runtime-owned page.
        for tab in Array(tabs.values) { tab.dispose() }
        for _ in 0..<200 {
            if api.live_pages() == 0 {
                let success = api.shutdown() != 0
                if success {
                    isLoaded = false; stopped = true; didShutDown = true; privateSessions.removeAll()
                    DownloadAdmission.shared.chromiumDidShutDown()
                }
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
    let runtimeStyle: String
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
        guard manifest.format == 2, manifest.abi == 4, manifest.runtimeStyle == "chrome",
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

extension Notification.Name {
    static let radiusChromiumProfileClosed = Notification.Name("radius.chromiumProfileClosed")
}
