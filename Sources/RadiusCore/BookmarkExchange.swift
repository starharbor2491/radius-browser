// SPDX-License-Identifier: MPL-2.0
import Foundation

public enum BookmarkExchange {
    public static func export(_ bookmarks: [Bookmark]) -> Data {
        func escape(_ text: String) -> String {
            text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
                .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        }
        let entries = bookmarks.map { "<DT><A HREF=\"\(escape($0.url.absoluteString))\">\(escape($0.title))</A>" }.joined(separator: "\n")
        return Data("<!DOCTYPE NETSCAPE-Bookmark-file-1>\n<META HTTP-EQUIV=\"Content-Type\" CONTENT=\"text/html; charset=UTF-8\">\n<TITLE>Radius Bookmarks</TITLE>\n<DL><p>\n\(entries)\n</DL><p>\n".utf8)
    }
    public static func parse(_ data: Data, profileID: UUID) throws -> [Bookmark] {
        guard data.count <= 10 * 1024 * 1024, let text = String(data: data, encoding: .utf8) else {
            throw ValidationError("Choose a UTF-8 bookmarks HTML file smaller than 10 MB.")
        }
        let regex = try NSRegularExpression(pattern: #"<a\s+[^>]*href\s*=\s*["']([^"']+)["'][^>]*>([\s\S]*?)</a\s*>"#, options: [.caseInsensitive])
        func unescape(_ value: String) -> String {
            value.replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&#39;", with: "'")
                .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
                .replacingOccurrences(of: "&amp;", with: "&")
        }
        var seen = Set<String>()
        let bookmarks = regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).prefix(10_000).compactMap { match -> Bookmark? in
            guard let urlRange = Range(match.range(at: 1), in: text), let titleRange = Range(match.range(at: 2), in: text),
                  let url = URL(string: unescape(String(text[urlRange]))), AddressResolver.isWebURL(url),
                  seen.insert(url.absoluteString).inserted else { return nil }
            let title = unescape(String(text[titleRange]).replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression))
            return Bookmark(profileID: profileID, title: title.isEmpty ? (url.host ?? "Bookmark") : String(title.prefix(512)), url: url)
        }
        guard !bookmarks.isEmpty else { throw ValidationError("No HTTP or HTTPS bookmarks were found in that file.") }
        return bookmarks
    }
}
