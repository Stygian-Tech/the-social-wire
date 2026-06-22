import Testing
@testable import ThinAppViewCore

@Suite("RssHtmlBodyFormatter")
struct RssHtmlBodyFormatterTests {
  @Test("preserves publisher HTML bodies")
  func preservesHtmlBodies() {
    let html = "<article><p>Body</p><ul><li>One</li></ul></article>"
    #expect(RssHtmlBodyFormatter.htmlBody(contentHTML: html, summary: nil) == html)
  }

  @Test("formats plain text bodies into paragraphs and line breaks")
  func formatsPlainTextBodies() {
    let html = RssHtmlBodyFormatter.htmlBody(
      contentHTML: "First line\nsecond line\n\nSecond paragraph",
      summary: nil
    )
    #expect(html == "<p>First line<br />second line</p><p>Second paragraph</p>")
  }
}
