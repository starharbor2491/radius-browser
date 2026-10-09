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
        // Netscape bookmark exports are HTML, not well-formed XML. Scan each byte once;
        // a backtracking anchor regex can freeze the app on unterminated nested anchors.
        let bytes = Array(text.utf8)
        func whitespace(_ byte: UInt8) -> Bool { [9, 10, 12, 13, 32].contains(byte) }
        func href(from start: Int, to end: Int) -> String? {
            var i = start
            while i < end {
                while i < end && (whitespace(bytes[i]) || bytes[i] == 47) { i += 1 }
                let nameStart = i
                while i < end && !whitespace(bytes[i]) && bytes[i] != 61 && bytes[i] != 47 { i += 1 }
                let name = String(decoding: bytes[nameStart..<i], as: UTF8.self).lowercased()
                while i < end && whitespace(bytes[i]) { i += 1 }
                guard i < end, bytes[i] == 61 else { continue }
                i += 1
                while i < end && whitespace(bytes[i]) { i += 1 }
                guard i < end else { return nil }
                let quote = (bytes[i] == 34 || bytes[i] == 39) ? bytes[i] : nil
                if quote != nil { i += 1 }
                let valueStart = i
                while i < end && (quote != nil ? bytes[i] != quote! : !whitespace(bytes[i])) { i += 1 }
                if name == "href" {
                    guard i > valueStart, i - valueStart <= 8192 else { return nil }
                    return decodeEntities(String(decoding: bytes[valueStart..<i], as: UTF8.self))
                }
                if quote != nil && i < end { i += 1 }
            }
            return nil
        }
        var bookmarks: [Bookmark] = [], seen = Set<String>()
        var pendingHref: String?, title: [UInt8] = [], completed = 0, i = 0
        while i < bytes.count && completed < 10_000 {
            if bytes[i] != 60 {
                if pendingHref != nil && title.count < 16_384 { title.append(bytes[i]) }
                i += 1; continue
            }
            i += 1
            var closing = false
            if i < bytes.count && bytes[i] == 47 { closing = true; i += 1 }
            let nameStart = i
            while i < bytes.count && !whitespace(bytes[i]) && bytes[i] != 62 && bytes[i] != 47 && bytes[i] != 60 { i += 1 }
            let isAnchor = i - nameStart == 1 && (bytes[nameStart] == 65 || bytes[nameStart] == 97)
            let attributesStart = i
            var quote: UInt8?
            while i < bytes.count {
                let byte = bytes[i]
                if let current = quote { if byte == current { quote = nil } }
                else if byte == 34 || byte == 39 { quote = byte }
                else if byte == 62 || byte == 60 { break }
                i += 1
            }
            guard i < bytes.count else { break }
            if bytes[i] == 60 { continue } // Abandon an unterminated tag at the next tag.
            if isAnchor {
                if closing {
                    if let pendingHref {
                        completed += 1
                        if let url = URL(string: pendingHref), AddressResolver.isWebURL(url), seen.insert(url.absoluteString).inserted {
                            let label = decodeEntities(String(decoding: title, as: UTF8.self))
                            bookmarks.append(Bookmark(profileID: profileID, title: label.isEmpty ? (url.host ?? "Bookmark") : String(label.prefix(512)), url: url))
                        }
                    }
                    pendingHref = nil; title.removeAll(keepingCapacity: true)
                } else {
                    pendingHref = href(from: attributesStart, to: i)
                    title.removeAll(keepingCapacity: true)
                }
            }
            i += 1
        }
        guard !bookmarks.isEmpty else { throw ValidationError("No HTTP or HTTPS bookmarks were found in that file.") }
        return bookmarks
    }
    private static func decodeEntities(_ value: String) -> String {
        let bytes = Array(value.utf8)
        var output: [UInt8] = [], i = 0
        while i < bytes.count {
            if bytes[i] == 38 {
                var end = i + 1
                while end < bytes.count && end - i <= 32 && bytes[end] != 59 && bytes[end] != 38 { end += 1 }
                if end < bytes.count, bytes[end] == 59, end - i <= 32 {
                    let entity = String(decoding: bytes[(i + 1)..<end], as: UTF8.self)
                    var replacement: String?
                    switch entity {
                    case "amp", "AMP": replacement = "&"
                    case "quot", "QUOT": replacement = "\""
                    case "apos": replacement = "'"
                    case "lt", "LT": replacement = "<"
                    case "gt", "GT": replacement = ">"
                    case "nbsp": replacement = "\u{00a0}"
                    default:
                        if entity.hasPrefix("#") {
                            let hex = entity.hasPrefix("#x") || entity.hasPrefix("#X")
                            let digits = entity.dropFirst(hex ? 2 : 1)
                            if let number = UInt32(digits, radix: hex ? 16 : 10), number != 0, let scalar = UnicodeScalar(number) { replacement = String(scalar) }
                        }
                    }
                    if let replacement { output.append(contentsOf: replacement.utf8); i = end + 1; continue }
                }
            }
            output.append(bytes[i]); i += 1
        }
        return String(decoding: output, as: UTF8.self)
    }
}
