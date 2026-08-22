import Foundation
import Testing
@testable import WireWorker

@Suite("The Wire OpenGraph parser")
struct WireOpenGraphParserTests {
  @Test("prefers OpenGraph fields and resolves relative media")
  func parsesOpenGraph() throws {
    let html = """
      <html><head>
      <title>Fallback Title</title>
      <meta content="Newsroom" property="og:site_name">
      <meta property="og:title" content="Primary &amp; Accurate">
      <meta name="twitter:description" content="A useful description">
      <meta property="og:image" content="/images/lead.jpg">
      <link href="/favicon.png" rel="icon">
      <link rel="canonical" href="/canonical-story">
      </head></html>
      """
    let parsed = try #require(
      WireOpenGraphParser.parse(html: html, pageURL: URL(string: "https://news.example/story")!)
    )
    #expect(parsed.title == "Primary & Accurate")
    #expect(parsed.description == "A useful description")
    #expect(parsed.siteName == "Newsroom")
    #expect(parsed.imageURL == "https://news.example/images/lead.jpg")
    #expect(parsed.iconURL == "https://news.example/favicon.png")
    #expect(parsed.canonicalURL == "https://news.example/canonical-story")
  }

  @Test("falls back to HTML title and ignores unsafe media schemes")
  func fallbackTitle() throws {
    let html = """
      <html><head><title>  Plain   Title </title>
      <meta property='og:image' content='data:image/png;base64,bad'>
      </head></html>
      """
    let parsed = try #require(
      WireOpenGraphParser.parse(html: html, pageURL: URL(string: "https://news.example/story")!)
    )
    #expect(parsed.title == "Plain Title")
    #expect(parsed.imageURL == nil)
  }
}
