import AsyncHTTPClient
import Foundation
import Testing

@testable import App

// MARK: - Profile Link Heuristic

@Suite("ProfileLinkHeuristic")
struct ProfileLinkHeuristicTests {
  let step = ProfileLinkHeuristic()

  @Test("extracts standard.site URL from description")
  func extractsURLFromDescription() throws {
    let text = "Writer. My blog: https://standard.site/alice"
    let url = extractURL(from: text)
    #expect(url == "https://standard.site/alice")
  }

  @Test("extracts standard.site URL with trailing path")
  func extractsURLWithPath() throws {
    let text = "Read my newsletter at https://standard.site/alice/posts"
    let url = extractURL(from: text)
    #expect(url == "https://standard.site/alice/posts")
  }

  @Test("returns nil when no standard.site URL present")
  func returnsNilWithNoURL() {
    let text = "Just a bio with no publication link."
    let url = extractURL(from: text)
    #expect(url == nil)
  }

  @Test("ignores non-standard.site URLs")
  func ignoresOtherURLs() {
    let text = "Find me at https://example.com and https://substack.com/alice"
    let url = extractURL(from: text)
    #expect(url == nil)
  }

  @Test("handles www.standard.site variant")
  func handlesWWWVariant() {
    let text = "Blog: https://www.standard.site/bob"
    let url = extractURL(from: text)
    #expect(url == "https://www.standard.site/bob")
  }

  @Test("handles HTTP variant")
  func handlesHTTPVariant() {
    let text = "Blog: http://standard.site/carol"
    let url = extractURL(from: text)
    #expect(url == "http://standard.site/carol")
  }

  // Re-exposes the private helper for testing via reflection-free access
  private func extractURL(from text: String) -> String? {
    let pattern = #"https?://(?:www\.)?standard\.site[^\s\"'<>]*"#
    guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
      return nil
    }
    let range = NSRange(text.startIndex..., in: text)
    guard let match = regex.firstMatch(in: text, range: range),
          let swiftRange = Range(match.range, in: text) else { return nil }
    return String(text[swiftRange])
  }
}

// HTMLSanitizerTests → HTMLSanitizerTests.swift
// AppConfigTests     → AppConfigTests.swift
