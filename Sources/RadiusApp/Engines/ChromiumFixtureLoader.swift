// SPDX-License-Identifier: MPL-2.0
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import RadiusCore

/// Uses Chrome's supported browser CDP endpoint only in the isolated fixture run.
@MainActor
enum ChromiumFixtureLoader {
    static func load(manager: ChromiumTab, dataDirectory: URL) async throws {
        let environment = ProcessInfo.processInfo.environment
        guard CommandLine.arguments.contains("--smoke-test"),
              let smokePath = environment["RADIUS_SMOKE_TEST_DATA"], !smokePath.isEmpty,
              let sourcePath = environment["RADIUS_SMOKE_TEST_EXTENSION_FIXTURE"], !sourcePath.isEmpty,
              let address = environment["RADIUS_SMOKE_TEST_URL"],
              let pageURL = URL(string: address), pageURL.scheme == "http", pageURL.host == "127.0.0.1",
              manager.privateSessionID == nil, isManagerURL(manager.url) else {
            throw ValidationError("The MV3 fixture loader requires the isolated loopback smoke-test manager.")
        }
        let root = dataDirectory.standardizedFileURL.resolvingSymlinksInPath()
        guard root == URL(fileURLWithPath: smokePath, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath() else {
            throw ValidationError("The MV3 fixture loader does not own this data directory.")
        }
        let fixture = root.appendingPathComponent("Chromium/ExtensionAcceptance/current", isDirectory: true)
        guard fixture.resolvingSymlinksInPath() == fixture,
              try fixture.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true,
              try fixture.appendingPathComponent("manifest.json").resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]).isRegularFile == true,
              fixture.appendingPathComponent("manifest.json").resolvingSymlinksInPath() == fixture.appendingPathComponent("manifest.json") else {
            throw ValidationError("The isolated MV3 fixture directory is missing or redirects outside its fixed location.")
        }

        let pageInfoData = try await manager.request("Target.getTargetInfo", parameters: [:], timeout: .seconds(5))
        guard let pageInfo = try JSONSerialization.jsonObject(with: pageInfoData) as? [String: Any],
              let target = pageInfo["targetInfo"] as? [String: Any],
              let targetID = target["targetId"] as? String, !targetID.isEmpty,
              let contextID = target["browserContextId"] as? String, !contextID.isEmpty,
              target["type"] as? String == "page",
              isManagerURL((target["url"] as? String).flatMap(URL.init(string:))) else {
            throw ValidationError("Chrome did not identify the fixture manager's page and profile.")
        }

        let endpoint = try await discoverEndpoint(root: root)
        let client = BrowserConnection(endpoint: endpoint)
        defer { client.close() }
        // Confirm the endpoint belongs to the process containing this exact page.
        let remoteInfo = try await client.request("Target.getTargetInfo", parameters: ["targetId": targetID])
        guard let remoteTarget = remoteInfo["targetInfo"] as? [String: Any],
              remoteTarget["targetId"] as? String == targetID,
              remoteTarget["browserContextId"] as? String == contextID,
              remoteTarget["type"] as? String == "page",
              isManagerURL((remoteTarget["url"] as? String).flatMap(URL.init(string:))) else {
            throw ValidationError("The fixture endpoint does not contain the expected extension manager.")
        }

        var contexts = try await client.request("Target.getBrowserContexts")
        if contexts["defaultBrowserContextId"] as? String != contextID {
            // Chrome's normal browser activation updates its last-used profile.
            // Activation alone is insufficient: verify the resulting context.
            _ = try await client.request("Target.activateTarget", parameters: ["targetId": targetID])
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            repeat {
                contexts = try await client.request("Target.getBrowserContexts", timeout: .seconds(2))
                if contexts["defaultBrowserContextId"] as? String == contextID { break }
                guard ContinuousClock.now < deadline else { break }
                try await Task.sleep(for: .milliseconds(100))
            } while true
        }
        guard contexts["defaultBrowserContextId"] as? String == contextID,
              manager.privateSessionID == nil, isManagerURL(manager.url) else {
            let actual = contexts["defaultBrowserContextId"] as? String ?? "missing"
            throw ValidationError("Chrome's default fixture context \(actual) differs from manager \(contextID); no extension was loaded.")
        }

        let loaded = try await client.request("Extensions.loadUnpacked", parameters: ["path": fixture.path], timeout: .seconds(30))
        guard loaded["id"] as? String == "pomncmnnjempbbdlbamhjphmpidacofc" else {
            throw ValidationError("Chrome returned an unexpected extension ID for the isolated MV3 fixture.")
        }
    }

    private static func isManagerURL(_ url: URL?) -> Bool {
        url?.scheme == "chrome" && url?.host == "extensions"
    }

    private static func discoverEndpoint(root: URL) async throws -> URL {
        let portFile = root.appendingPathComponent("Chromium/Profiles/DevToolsActivePort")
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        repeat {
            try Task.checkCancellation()
            if FileManager.default.fileExists(atPath: portFile.path) {
                let values = try portFile.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true,
                      portFile.resolvingSymlinksInPath() == portFile,
                      (values.fileSize ?? 0) <= 4096 else {
                    throw ValidationError("The isolated Chrome endpoint file is invalid.")
                }
                let contents: String
                do {
                    let data = try BoundedImportFile.read(portFile, maximumBytes: 4096, kind: .setup)
                    guard let decoded = String(data: data, encoding: .utf8) else {
                        throw ValidationError("Invalid endpoint text.")
                    }
                    contents = decoded
                } catch {
                    throw ValidationError("The isolated Chrome endpoint must be a regular UTF-8 file of at most 4 KB.")
                }
                let lines = contents.split(whereSeparator: \.isNewline)
                if lines.count == 2, let port = Int(lines[0]), (1...65535).contains(port) {
                    let path = String(lines[1])
                    let prefix = "/devtools/browser/"
                    guard path.hasPrefix(prefix), UUID(uuidString: String(path.dropFirst(prefix.count))) != nil else {
                        throw ValidationError("Chrome did not publish a valid browser endpoint.")
                    }
                    var endpoint = URLComponents()
                    endpoint.scheme = "ws"; endpoint.host = "127.0.0.1"; endpoint.port = port; endpoint.path = path
                    if let url = endpoint.url { return url }
                }
            }
            guard ContinuousClock.now < deadline else { break }
            try await Task.sleep(for: .milliseconds(100))
        } while true
        throw ValidationError("Chrome did not publish its isolated browser endpoint before the fixture deadline.")
    }

    @MainActor
    private final class BrowserConnection {
        private let session: URLSession
        private let socket: URLSessionWebSocketTask
        private var nextID = 0
        private var timedOut = false

        init(endpoint: URL) {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 10
            configuration.timeoutIntervalForResource = 60
            configuration.httpShouldSetCookies = false
            configuration.httpCookieStorage = nil
            configuration.urlCredentialStorage = nil
            configuration.urlCache = nil
            configuration.connectionProxyDictionary = [:]
            session = URLSession(configuration: configuration, delegate: ChromiumFixtureSessionDelegate(), delegateQueue: nil)
            socket = session.webSocketTask(with: endpoint)
            socket.maximumMessageSize = 1_048_576
            socket.resume()
        }

        func close() {
            socket.cancel(with: .goingAway, reason: nil)
            session.invalidateAndCancel()
        }

        func request(_ method: String, parameters: [String: Any] = [:], timeout: Duration = .seconds(5)) async throws -> [String: Any] {
            try Task.checkCancellation()
            nextID += 1
            let id = nextID
            let payload = try JSONSerialization.data(withJSONObject: ["id": id, "method": method, "params": parameters])
            let socket = self.socket
            timedOut = false
            let deadline = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: timeout) } catch { return }
                guard let self else { return }
                self.timedOut = true
                self.close()
            }
            defer { deadline.cancel() }
            do {
                return try await withTaskCancellationHandler {
                    try await socket.send(.string(String(decoding: payload, as: UTF8.self)))
                    while true {
                        try Task.checkCancellation()
                        let message = try await socket.receive()
                        let data: Data
                        switch message {
                        case .data(let value): data = value
                        case .string(let value): data = Data(value.utf8)
                        @unknown default:
                            throw ValidationError("Chrome returned an unsupported fixture protocol message.")
                        }
                        guard let response = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                            throw ValidationError("Chrome returned invalid fixture protocol JSON.")
                        }
                        guard let responseID = response["id"] as? Int else { continue } // CDP event.
                        guard responseID == id else {
                            throw ValidationError("Chrome returned an unexpected fixture protocol response.")
                        }
                        if let error = response["error"] as? [String: Any] {
                            let message = String((error["message"] as? String ?? "Unknown protocol error").prefix(500))
                            throw ValidationError("Chrome fixture command \(method) failed: \(message)")
                        }
                        guard let result = response["result"] as? [String: Any] else {
                            throw ValidationError("Chrome fixture command \(method) returned no result.")
                        }
                        return result
                    }
                } onCancel: {
                    socket.cancel(with: .goingAway, reason: nil)
                }
            } catch {
                if Task.isCancelled { throw CancellationError() }
                if timedOut { throw ValidationError("Chrome fixture command \(method) timed out.") }
                throw error
            }
        }
    }
}

private final class ChromiumFixtureSessionDelegate: NSObject, URLSessionTaskDelegate {
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                               newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
