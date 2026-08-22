import Foundation

enum WireOpenGraphParser {
  private static let tagPattern = #"<(meta|link)\b[^>]*>"#
  private static let attributePattern = #"([A-Za-z_:][-A-Za-z0-9_:.]*)\s*=\s*(?:\"([^\"]*)\"|'([^']*)'|([^\s>]+))"#
  private static let titlePattern = #"<title\b[^>]*>(.*?)</title>"#

  static func parse(html: String, pageURL: URL) -> WireLinkMetadata? {
    let tags = matches(pattern: tagPattern, in: html, options: [.caseInsensitive])
    var properties: [String: String] = [:]
    var icon: String?
    var canonicalURL: String?

    for tag in tags {
      let attributes = attributes(in: tag)
      if tag.lowercased().hasPrefix("<meta") {
        guard let key = (attributes["property"] ?? attributes["name"])?.lowercased(),
          let content = normalized(attributes["content"])
        else { continue }
        if properties[key] == nil { properties[key] = content }
      } else {
        let relValues = Set(
          (attributes["rel"] ?? "").lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        )
        if relValues.contains("canonical"), canonicalURL == nil {
          canonicalURL = normalizedURL(attributes["href"], relativeTo: pageURL)
        }
        if !relValues.isDisjoint(with: ["icon", "shortcut", "apple-touch-icon"]), icon == nil {
          icon = normalizedURL(attributes["href"], relativeTo: pageURL)
        }
      }
    }

    let title = first([
      properties["og:title"], properties["twitter:title"], htmlTitle(in: html),
    ])
    let description = first([
      properties["og:description"], properties["twitter:description"], properties["description"],
    ])
    let imageURL = normalizedURL(
      first([properties["og:image:secure_url"], properties["og:image"], properties["twitter:image"]]),
      relativeTo: pageURL
    )
    let siteName = first([properties["og:site_name"], properties["application-name"]])
    let authorName = first([
      properties["article:author"], properties["author"], properties["byl"],
      properties["twitter:creator"],
    ])
    let publishedAt = first([
      properties["article:published_time"], properties["og:published_time"],
      properties["date"], properties["datepublished"],
    ]).flatMap(parseDate)
    let resolvedCanonical = normalizedURL(canonicalURL, relativeTo: pageURL) ?? pageURL.absoluteString
    guard title != nil || description != nil || imageURL != nil || siteName != nil
      || authorName != nil || publishedAt != nil || icon != nil
    else {
      return nil
    }
    return WireLinkMetadata(
      canonicalURL: resolvedCanonical,
      title: title,
      description: description,
      imageURL: imageURL,
      siteName: siteName,
      authorName: authorName,
      publishedAt: publishedAt,
      iconURL: icon,
      etag: nil,
      lastModified: nil,
      source: .openGraph
    )
  }

  private static func htmlTitle(in html: String) -> String? {
    guard let raw = matches(
      pattern: titlePattern,
      in: html,
      options: [.caseInsensitive, .dotMatchesLineSeparators],
      capture: 1
    ).first else { return nil }
    return normalized(raw)
  }

  private static func attributes(in tag: String) -> [String: String] {
    guard let expression = try? NSRegularExpression(
      pattern: attributePattern, options: [.caseInsensitive]) else { return [:] }
    let range = NSRange(tag.startIndex..<tag.endIndex, in: tag)
    var result: [String: String] = [:]
    for match in expression.matches(in: tag, range: range) {
      guard let keyRange = Range(match.range(at: 1), in: tag) else { continue }
      let key = tag[keyRange].lowercased()
      for capture in 2...4 where match.range(at: capture).location != NSNotFound {
        guard let valueRange = Range(match.range(at: capture), in: tag) else { continue }
        if result[key] == nil { result[key] = String(tag[valueRange]) }
        break
      }
    }
    return result
  }

  private static func matches(
    pattern: String,
    in value: String,
    options: NSRegularExpression.Options,
    capture: Int = 0
  ) -> [String] {
    guard let expression = try? NSRegularExpression(pattern: pattern, options: options) else {
      return []
    }
    let range = NSRange(value.startIndex..<value.endIndex, in: value)
    return expression.matches(in: value, range: range).compactMap { match in
      guard match.numberOfRanges > capture,
        let matchRange = Range(match.range(at: capture), in: value)
      else { return nil }
      return String(value[matchRange])
    }
  }

  private static func normalized(_ value: String?) -> String? {
    guard let value else { return nil }
    let decoded = value
      .replacingOccurrences(of: "&amp;", with: "&")
      .replacingOccurrences(of: "&quot;", with: "\"")
      .replacingOccurrences(of: "&#39;", with: "'")
      .replacingOccurrences(of: "&lt;", with: "<")
      .replacingOccurrences(of: "&gt;", with: ">")
      .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return decoded.isEmpty ? nil : String(decoded.prefix(2_000))
  }

  private static func first(_ values: [String?]) -> String? {
    values.lazy.compactMap(normalized).first
  }

  private static func parseDate(_ value: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: value) { return date }
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: value)
  }

  private static func normalizedURL(_ raw: String?, relativeTo pageURL: URL) -> String? {
    guard let raw = normalized(raw), let url = URL(string: raw, relativeTo: pageURL)?.absoluteURL,
      let scheme = url.scheme?.lowercased(), (scheme == "http" || scheme == "https"),
      url.host != nil
    else { return nil }
    return url.absoluteString
  }
}
