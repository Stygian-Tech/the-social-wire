import Foundation
import GatewayCore

/// Server-side HTML sanitization for entry content.
///
/// Strips dangerous tags (script, iframe, object, etc.) and unsafe attributes
/// (event handlers, javascript: hrefs) from entry HTML before sending to clients.
///
/// This is a defence-in-depth measure. The web client also runs DOMPurify on
/// received content before rendering.
enum HTMLSanitizer {
  // Tags that are completely removed (including their content)
  static let blockedTags: Set<String> = [
    "script", "style", "iframe", "object", "embed", "form",
    "input", "button", "select", "textarea", "meta", "link",
    "base", "applet", "frame", "frameset",
  ]

  // Attributes that are removed from any tag
  static let blockedAttributes: Set<String> = [
    "onclick", "onload", "onerror", "onmouseover", "onmouseout",
    "onfocus", "onblur", "onchange", "onsubmit", "onreset",
    "onkeydown", "onkeypress", "onkeyup", "oncontextmenu",
    "onscroll", "ondblclick", "onmousedown", "onmouseup",
    "onmousemove", "onmouseenter", "onmouseleave",
  ]

  /// Sanitizes the given HTML string, removing dangerous elements and attributes.
  static func sanitize(_ html: String) -> String {
    var result = html

    // Remove blocked tags and their contents
    for tag in blockedTags {
      // Remove open+content+close: <script...>...</script>
      let fullPattern = "<\(tag)(\\s[^>]*)?>.*?</\(tag)>"
      if let regex = try? NSRegularExpression(pattern: fullPattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) {
        let range = NSRange(result.startIndex..., in: result)
        result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: "")
      }
      // Remove self-closing XHTML: <embed ... />
      let selfClosingPattern = "<\(tag)(\\s[^>]*)?\\/>"
      if let regex = try? NSRegularExpression(pattern: selfClosingPattern, options: .caseInsensitive) {
        let range = NSRange(result.startIndex..., in: result)
        result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: "")
      }
      // Remove bare HTML5 void-element opening tags: <embed src="...">, <input type="...">, etc.
      // Runs after the above two patterns so only unclosed tags remain to be stripped.
      let openTagPattern = "<\(tag)(\\s[^>]*)?>?"
      if let regex = try? NSRegularExpression(pattern: openTagPattern, options: .caseInsensitive) {
        let range = NSRange(result.startIndex..., in: result)
        result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: "")
      }
    }

    // Remove blocked attributes
    for attr in blockedAttributes {
      let pattern = "\\s\(attr)\\s*=\\s*\"[^\"]*\""
      if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
        let range = NSRange(result.startIndex..., in: result)
        result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: "")
      }
      // Single-quoted variant
      let singlePattern = "\\s\(attr)\\s*=\\s*'[^']*'"
      if let regex = try? NSRegularExpression(pattern: singlePattern, options: .caseInsensitive) {
        let range = NSRange(result.startIndex..., in: result)
        result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: "")
      }
    }

    // Remove javascript: hrefs and src values
    let jsPattern = #"(href|src|action)\s*=\s*["']?\s*javascript:[^"'\s>]*["']?"#
    if let regex = try? NSRegularExpression(pattern: jsPattern, options: .caseInsensitive) {
      let range = NSRange(result.startIndex..., in: result)
      result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: "")
    }

    // Remove data: URIs from src (potential XSS vector)
    let dataURIPattern = #"src\s*=\s*["']?\s*data:[^"'\s>]*["']?"#
    if let regex = try? NSRegularExpression(pattern: dataURIPattern, options: .caseInsensitive) {
      let range = NSRange(result.startIndex..., in: result)
      result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: "")
    }

    return result
  }
}
