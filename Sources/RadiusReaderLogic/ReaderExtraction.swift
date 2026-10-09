// SPDX-License-Identifier: MPL-2.0
import Foundation
import FoundationXML
import RadiusCore

/// Best-effort article/main/body extraction from an engine's XMLSerializer snapshot.
/// This target is linked into the removable worker only. Strict parsing never
/// executes page code, follows links, or loads entities.
public enum ReaderExtraction {
    public static func extract(_ html: String) throws -> String {
        _ = try ReaderRequest(html: html)
        guard !containsDeclaration(html) else {
            throw ValidationError("Reader does not accept document type or entity declarations.")
        }
        let data = Data(html.utf8)
        // XMLDocument can return a recovered tree for malformed input on some
        // Foundation implementations. Validate first so XPath only sees valid XML.
        let validator = XMLParser(data: data)
        validator.shouldResolveExternalEntities = false
        guard validator.parse(), validator.parserError == nil else {
            throw ValidationError("Reader requires a valid serialized page snapshot.")
        }
        let document = try XMLDocument(data: data, options: [.nodeLoadExternalEntitiesNever])
        for node in try document.nodes(forXPath: "//*[local-name()='head' or local-name()='script' or local-name()='style' or local-name()='nav' or local-name()='footer' or local-name()='aside' or local-name()='form' or local-name()='noscript' or local-name()='template' or @hidden or @aria-hidden='true']") {
            node.detach()
        }
        guard let root = try document.nodes(forXPath: "//*[local-name()='article']").first ?? document.nodes(forXPath: "//*[local-name()='main']").first ?? document.nodes(forXPath: "//*[local-name()='body']").first ?? document.rootElement() else {
            throw ValidationError("This page has no readable text.")
        }
        let blocks: Set<String> = ["p", "div", "section", "article", "main", "h1", "h2", "h3", "h4", "h5", "h6", "li", "blockquote", "pre", "tr", "td", "th", "br"]
        var stack: [(XMLNode, Bool)] = [(root, false)], visited = 0, output = "", length = 0
        func append(_ value: String) {
            let part = String(value.prefix(200_000 - length)); output += part; length += part.count
        }
        while let (node, closing) = stack.popLast(), length < 200_000 {
            visited += 1
            guard visited <= 100_000 else { throw ValidationError("This page is too complex for Reader.") }
            let block = blocks.contains(node.localName?.lowercased() ?? node.name?.lowercased() ?? "")
            if closing { if block { append("\n") }; continue }
            if node.kind == .text { append(node.stringValue ?? "") }
            else {
                if block { append("\n") }
                stack.append((node, true))
                for child in (node.children ?? []).reversed() { stack.append((child, false)) }
            }
        }
        let lines = output.components(separatedBy: .newlines).map {
            $0.replacingOccurrences(of: "[\\t\\r ]+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty }
        let text = String(lines.joined(separator: "\n\n").prefix(200_000))
        return try ReaderResponse(text: text).validatedText()
    }

    /// The engines serialize DOM text (including script text) with XML escaping.
    /// Only XML comments, CDATA, and quoted attributes can contain literal '<!'.
    private static func containsDeclaration(_ html: String) -> Bool {
        let bytes = Array(html.utf8)
        func matches(_ text: String, at index: Int, caseSensitive: Bool = false) -> Bool {
            let expected = Array(text.utf8)
            guard index + expected.count <= bytes.count else { return false }
            return expected.indices.allSatisfy { offset in
                let byte = bytes[index + offset]
                return (!caseSensitive && byte >= 65 && byte <= 90 ? byte + 32 : byte) == expected[offset]
            }
        }
        func after(_ terminator: String, from start: Int, comment: Bool = false) -> Int? {
            var index = start
            while index < bytes.count {
                if matches(terminator, at: index) { return index + terminator.utf8.count }
                if comment && matches("--", at: index) { return nil }
                index += 1
            }
            return nil
        }
        var index = 0
        while index < bytes.count {
            guard bytes[index] == 60 else { index += 1; continue }
            if matches("<!--", at: index) {
                guard let end = after("-->", from: index + 4, comment: true) else { return true }
                index = end; continue
            }
            if matches("<![CDATA[", at: index, caseSensitive: true) {
                guard let end = after("]]>", from: index + 9) else { return true }
                index = end; continue
            }
            // Any remaining markup declaration, including malformed/lowercase CDATA,
            // is rejected before reaching the system parser.
            if matches("<!", at: index) { return true }
            // Consume the opening tag, respecting quotes so literal < in an attribute
            // does not become a declaration. The real parser still validates the input.
            var quote: UInt8?
            index += 1
            while index < bytes.count {
                let byte = bytes[index]; index += 1
                if let current = quote { if byte == current { quote = nil } }
                else if byte == 34 || byte == 39 { quote = byte }
                else if byte == 62 { break }
            }
        }
        return false
    }
}
