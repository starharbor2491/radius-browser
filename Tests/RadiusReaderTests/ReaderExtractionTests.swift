// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
import RadiusCore
import RadiusReaderLogic

@Test func readerPrefersArticleAndDropsNonReadingContent() throws {
    let html = "<html><head><title>Not body</title><script>secret script</script></head><body><nav>Menu</nav><article><h1>A title</h1><p>One &amp; two <a href='https://example.test'>readable link</a>.</p><aside>Advert</aside><p hidden='hidden'>Hidden</p><p aria-hidden='true'>Aria hidden</p><style>css</style><script>code</script></article><footer>Footer</footer></body></html>"
    let text = try ReaderExtraction.extract(html)
    #expect(text == "A title\n\nOne & two readable link.")
}
@Test func readerRejectsRawMalformedHTMLAndFallsBackToMainOrBody() throws {
    #expect(try ReaderExtraction.extract("<html><body><main><p>First<br/></p><p>Second</p></main></body></html>").contains("Second"))
    #expect(try ReaderExtraction.extract("<html><body><p>Plain body</p></body></html>") == "Plain body")
    #expect(throws: (any Error).self) { try ReaderExtraction.extract("<html><body><main><p>First<br><p>Second</main></body></html>") }
    #expect(throws: (any Error).self) { try ReaderExtraction.extract("<script>script</script><html><body>Second root</body></html>") }
    #expect(throws: (any Error).self) { try ReaderExtraction.extract("<html><head><script>empty</script></head><body></body></html>") }
}
@Test func readerHandlesSerializedHTMLNamespacesAndUnicode() throws {
    let html = "<html xmlns='http://www.w3.org/1999/xhtml'><head><title>Head</title></head><body><nav>Menu</nav><main><p>One\u{00a0}two — 📖</p><script>not readable</script></main></body></html>"
    #expect(try ReaderExtraction.extract(html) == "One\u{00a0}two — 📖")
}
@Test func readerRejectsEntityDeclarationsAndOversizedInput() throws {
    for declaration in ["<!DOCTYPE html SYSTEM 'https://example.test/remote.dtd'>", "<!DOCTYPE x [<!ENTITY secret SYSTEM 'file:///etc/passwd'>]>", "<!ENTITY grow 'large'>"] {
        #expect(throws: (any Error).self) { try ReaderExtraction.extract(declaration + "<html><body><p>&secret;</p></body></html>") }
    }
    for mention in ["<!-- Example <!DOCTYPE html> -->", "<script>const iframe = '&lt;!DOCTYPE html&gt;&lt;html&gt;&lt;/html&gt;';</script>", "<style>/* &lt;!ENTITY example&gt; */</style>", "<script><![CDATA[const sample = '<!DOCTYPE html>';]]></script>"] {
        #expect(try ReaderExtraction.extract("<html><body><article>Readable article</article>" + mention + "</body></html>") == "Readable article")
    }
    #expect(throws: (any Error).self) { try ReaderExtraction.extract("<!-- harmless --><!dOcTyPe html SYSTEM 'https://example.test/remote.dtd'><html><body>Text</body></html>") }
    let entityDocument = "<!DOCTYPE html [<!ENTITY radius 'EXPANDED'>]><html><body><p>&radius;</p></body></html>"
    for prefix in ["<script/>", "<style/>", "<!--a--!>", "<![cdata[foo"] {
        #expect(throws: (any Error).self) { try ReaderExtraction.extract(prefix + entityDocument) }
    }
    #expect(throws: (any Error).self) { try ReaderExtraction.extract("<script><!DOCTYPE html [<!ENTITY radius 'EXPANDED'>]></script><html><body><p>&radius;</p></body></html>") }
    #expect(throws: (any Error).self) { try ReaderExtraction.extract(String(repeating: "x", count: ReaderRequest.maximumHTMLBytes + 1)) }
}
@Test func readerBoundsOutputWithoutExecutingPageCode() throws {
    let text = try ReaderExtraction.extract("<html><body><p>" + String(repeating: "x", count: 250_000) + "</p><script>while(true){}</script></body></html>")
    #expect(text.count <= 200_000 && text.count > 199_000)
    #expect(!text.contains("while"))
    #expect(throws: (any Error).self) { try ReaderResponse(text: String(repeating: "a", count: 200_001)).validatedText() }
}
