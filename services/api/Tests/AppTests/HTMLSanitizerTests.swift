import Foundation
import Testing

@testable import App

@Suite("HTMLSanitizer")
struct HTMLSanitizerTests {

  // MARK: - Safe HTML preserved

  @Test("preserves safe structural tags")
  func preservesSafeHTML() {
    let html = "<p>Hello <strong>world</strong>!</p><ul><li>Item</li></ul>"
    let result = HTMLSanitizer.sanitize(html)
    #expect(result == html)
  }

  @Test("preserves safe links")
  func preservesSafeLinks() {
    let html = #"<a href="https://example.com">Click here</a>"#
    let result = HTMLSanitizer.sanitize(html)
    #expect(result == html)
  }

  @Test("preserves images with safe src")
  func preservesSafeImages() {
    let html = #"<img src="https://example.com/photo.jpg" alt="photo">"#
    let result = HTMLSanitizer.sanitize(html)
    #expect(result == html)
  }

  // MARK: - Blocked tags removed

  @Test("removes script tags and content")
  func removesScriptTags() {
    let html = "<p>Text</p><script>alert('xss')</script><p>More</p>"
    let result = HTMLSanitizer.sanitize(html)
    #expect(!result.contains("<script"))
    #expect(!result.contains("alert('xss')"))
    #expect(result.contains("<p>Text</p>"))
    #expect(result.contains("<p>More</p>"))
  }

  @Test("removes iframe tags")
  func removesIframes() {
    let html = #"<p>Before</p><iframe src="https://evil.com"></iframe><p>After</p>"#
    let result = HTMLSanitizer.sanitize(html)
    #expect(!result.contains("<iframe"))
    #expect(result.contains("<p>Before</p>"))
    #expect(result.contains("<p>After</p>"))
  }

  @Test("removes style tags")
  func removesStyleTags() {
    let html = "<style>body { background: red }</style><p>content</p>"
    let result = HTMLSanitizer.sanitize(html)
    #expect(!result.contains("<style"))
    #expect(!result.contains("background: red"))
    #expect(result.contains("<p>content</p>"))
  }

  @Test("removes object and embed tags")
  func removesObjectEmbed() {
    let html = #"<object data="malware.swf"></object><embed src="bad.swf"><p>Safe</p>"#
    let result = HTMLSanitizer.sanitize(html)
    #expect(!result.contains("<object"))
    #expect(!result.contains("<embed"))
    #expect(result.contains("<p>Safe</p>"))
  }

  // MARK: - Event handler attributes removed

  @Test("removes onclick attribute")
  func removesOnclick() {
    let html = #"<a href="https://example.com" onclick="evil()">Click</a>"#
    let result = HTMLSanitizer.sanitize(html)
    #expect(!result.contains("onclick"))
    #expect(result.contains(#"href="https://example.com""#))
    #expect(result.contains("Click"))
  }

  @Test("removes onload attribute")
  func removesOnload() {
    let html = #"<img src="photo.jpg" onload="steal()">"#
    let result = HTMLSanitizer.sanitize(html)
    #expect(!result.contains("onload"))
    #expect(result.contains("photo.jpg"))
  }

  @Test("removes onerror attribute")
  func removesOnerror() {
    let html = #"<img src="x" onerror="alert(1)">"#
    let result = HTMLSanitizer.sanitize(html)
    #expect(!result.contains("onerror"))
  }

  // MARK: - javascript: URIs removed

  @Test("removes javascript: href")
  func removesJavascriptHref() {
    let html = #"<a href="javascript:alert('xss')">Click</a>"#
    let result = HTMLSanitizer.sanitize(html)
    #expect(!result.contains("javascript:"))
    #expect(result.contains("Click"))
  }

  @Test("removes javascript: src")
  func removesJavascriptSrc() {
    let html = #"<script src="javascript:evil()"></script><p>Safe</p>"#
    let result = HTMLSanitizer.sanitize(html)
    #expect(!result.contains("javascript:"))
  }

  // MARK: - data: URIs removed from src

  @Test("removes data: URI from img src")
  func removesDataURI() {
    let html = #"<img src="data:text/html,<script>alert(1)</script>">"#
    let result = HTMLSanitizer.sanitize(html)
    #expect(!result.contains("data:"))
  }

  // MARK: - Case insensitivity

  @Test("handles uppercase tag names")
  func handlesUppercaseTags() {
    let html = "<SCRIPT>alert('xss')</SCRIPT><p>Safe</p>"
    let result = HTMLSanitizer.sanitize(html)
    #expect(!result.contains("alert('xss')"))
    #expect(result.contains("<p>Safe</p>"))
  }

  @Test("handles mixed-case event handlers")
  func handlesMixedCaseAttributes() {
    let html = #"<a href="x" ONCLICK="bad()">Link</a>"#
    let result = HTMLSanitizer.sanitize(html)
    #expect(!result.lowercased().contains("onclick"))
  }

  // MARK: - Empty and trivial input

  @Test("handles empty string")
  func handlesEmptyString() {
    let result = HTMLSanitizer.sanitize("")
    #expect(result == "")
  }

  @Test("handles plain text (no tags)")
  func handlesPlainText() {
    let text = "Just a plain text article with no HTML."
    let result = HTMLSanitizer.sanitize(text)
    #expect(result == text)
  }
}
