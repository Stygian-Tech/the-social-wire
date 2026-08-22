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
      <meta name="author" content="Riley Reporter">
      <meta property="article:published_time" content="2026-08-21T10:15:30Z">
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
    #expect(parsed.authorName == "Riley Reporter")
    #expect(parsed.publishedAt == Date(timeIntervalSince1970: 1_787_307_330))
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
    #expect(parsed.authorName == nil)
    #expect(parsed.publishedAt == nil)
  }

  @Test("uses article JSON-LD for publisher, author, image, and dates")
  func parsesArticleJSONLD() throws {
    let html = #"""
      <html><head>
      <script type="application/ld+json">
      {
        "@context": "https://schema.org",
        "@type": "NewsArticle",
        "headline": "A JSON-LD headline",
        "description": "Structured story description",
        "image": { "url": "/images/structured.jpg" },
        "author": [
          { "@type": "Person", "name": "Jordan Writer" },
          { "@type": "Person", "name": "Second Writer" }
        ],
        "publisher": {
          "@type": "Organization",
          "name": "The Example Dispatch",
          "logo": { "url": "/branding/logo.png" }
        },
        "datePublished": "2026-08-22T14:30:00Z",
        "mainEntityOfPage": { "@id": "/news/structured-story" }
      }
      </script>
      </head></html>
      """#
    let parsed = try #require(
      WireOpenGraphParser.parse(html: html, pageURL: URL(string: "https://news.example/story")!)
    )
    #expect(parsed.title == "A JSON-LD headline")
    #expect(parsed.description == "Structured story description")
    #expect(parsed.siteName == "The Example Dispatch")
    #expect(parsed.authorName == "Jordan Writer")
    #expect(parsed.imageURL == "https://news.example/images/structured.jpg")
    #expect(parsed.iconURL == "https://news.example/branding/logo.png")
    #expect(parsed.canonicalURL == "https://news.example/news/structured-story")
    #expect(parsed.publishedAt == Date(timeIntervalSince1970: 1_787_409_000))
  }

  @Test("keeps explicit OpenGraph fields ahead of JSON-LD")
  func openGraphPrecedesJSONLD() throws {
    let html = #"""
      <html><head>
      <meta property="og:title" content="OpenGraph title">
      <meta property="og:site_name" content="OpenGraph site">
      <meta property="og:image" content="/og.jpg">
      <script type="application/ld+json">
      {
        "@type": "NewsArticle",
        "headline": "Structured title",
        "image": "/structured.jpg",
        "publisher": { "name": "Structured site" }
      }
      </script>
      </head></html>
      """#
    let parsed = try #require(
      WireOpenGraphParser.parse(html: html, pageURL: URL(string: "https://news.example/story")!)
    )
    #expect(parsed.title == "OpenGraph title")
    #expect(parsed.siteName == "OpenGraph site")
    #expect(parsed.imageURL == "https://news.example/og.jpg")
  }

  @Test("ignores malformed JSON-LD without losing HTML fallbacks")
  func malformedJSONLD() throws {
    let html = """
      <html><head><title>Fallback survives</title>
      <script type="application/ld+json">{not-json}</script>
      </head></html>
      """
    let parsed = try #require(
      WireOpenGraphParser.parse(html: html, pageURL: URL(string: "https://news.example/story")!)
    )
    #expect(parsed.title == "Fallback survives")
  }
}
