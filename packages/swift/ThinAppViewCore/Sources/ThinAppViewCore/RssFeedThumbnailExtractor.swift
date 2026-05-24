import Foundation

/// Best-effort RSS / Atom entry thumbnail resolution for Skyreader ingestion.
public enum RssFeedThumbnailExtractor {
  public static func normalizeThumbnailURL(_ raw: String?, relativeTo base: String?) -> String? {
    guard var trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
      return nil
    }

    if !trimmed.lowercased().hasPrefix("http"), let base {
      if let resolved = URL(string: trimmed, relativeTo: URL(string: base))?.absoluteString {
        trimmed = resolved
      }
    }

    guard trimmed.lowercased().hasPrefix("http") else { return nil }
    return RssFeedIdentity.normalizeFeedUrl(trimmed)
  }

  public static func acceptsMediaURL(
    url: String?,
    type: String?,
    medium: String?
  ) -> Bool {
    guard let url, !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }

    let typeLower = type?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if let typeLower, typeLower.hasPrefix("image/") { return true }

    let mediumLower = medium?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if mediumLower == "image" { return true }

    if typeLower == nil, mediumLower == nil {
      return looksLikeImageURL(url)
    }

    return false
  }

  public static func firstImageURL(inHTML html: String?) -> String? {
    guard let html, !html.isEmpty else { return nil }

    if let match = firstCapture(in: html, pattern: #"<img\b[^>]*\bsrc=["']([^"']+)["']"#) {
      return match
    }
    if let match = firstCapture(in: html, pattern: #"<img\b[^>]*\bsrc=([^\s>]+)"#) {
      return match.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
    }
    if let match = firstCapture(in: html, pattern: #"<meta\b[^>]*property=["']og:image["'][^>]*content=["']([^"']+)["']"#) {
      return match
    }
    if let match = firstCapture(in: html, pattern: #"<meta\b[^>]*content=["']([^"']+)["'][^>]*property=["']og:image["']"#) {
      return match
    }
    return nil
  }

  public static func resolveThumbnail(
    storedURL: String?,
    contentHTML: String?,
    summary: String?,
    articleLink: String?,
    feedURL: String?
  ) -> String? {
    let base = articleLink ?? feedURL
    if let storedURL, let normalized = normalizeThumbnailURL(storedURL, relativeTo: base) {
      return normalized
    }
    if let fromContent = firstImageURL(inHTML: contentHTML),
       let normalized = normalizeThumbnailURL(fromContent, relativeTo: base)
    {
      return normalized
    }
    if let fromSummary = firstImageURL(inHTML: summary),
       let normalized = normalizeThumbnailURL(fromSummary, relativeTo: base)
    {
      return normalized
    }
    return nil
  }

  private static func looksLikeImageURL(_ url: String) -> Bool {
    let lower = url.lowercased()
    if lower.contains("gravatar.com/avatar") { return true }
    guard let path = URL(string: url)?.path.lowercased() else { return false }
    let extensions = [".jpg", ".jpeg", ".png", ".gif", ".webp", ".avif", ".svg", ".bmp"]
    return extensions.contains { path.hasSuffix($0) || path.contains("\($0)?") }
  }

  private static func firstCapture(in text: String, pattern: String) -> String? {
    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
      return nil
    }
    let range = NSRange(text.startIndex ..< text.endIndex, in: text)
    guard let match = regex.firstMatch(in: text, options: [], range: range),
          match.numberOfRanges > 1,
          let captureRange = Range(match.range(at: 1), in: text)
    else { return nil }
    let captured = String(text[captureRange]).trimmingCharacters(in: .whitespacesAndNewlines)
    return captured.isEmpty ? nil : captured
  }
}
