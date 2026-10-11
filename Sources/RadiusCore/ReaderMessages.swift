// SPDX-License-Identifier: MPL-2.0
import Foundation

public struct ReaderRequest: Codable, Sendable {
    public static let maximumHTMLBytes = 1024 * 1024
    public static let maximumMessageBytes = 2 * 1024 * 1024
    public let html: String
    public init(html: String) throws {
        guard html.utf8.count <= Self.maximumHTMLBytes else { throw ValidationError("Reader supports page snapshots up to 1 MB.") }
        self.html = html
    }
}
public struct ReaderResponse: Codable, Sendable {
    public static let maximumBytes = 2 * 1024 * 1024
    public let text: String
    public let error: String?
    public init(text: String = "", error: String? = nil) { self.text = text; self.error = error }
    public func validatedText() throws -> String {
        guard text.count <= 200_000, (error?.count ?? 0) <= 500 else { throw ValidationError("Reader returned an oversized result.") }
        if let error { throw ValidationError(error) }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ValidationError("This page has no readable text.") }
        return text
    }
}
