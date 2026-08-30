import Foundation

enum WireOpenGraphParser {
  private static let languageNameCodes: [String: String] = [
    "arabic": "ar", "bengali": "bn", "chinese": "zh", "czech": "cs",
    "danish": "da", "dutch": "nl", "english": "en", "finnish": "fi",
    "french": "fr", "german": "de", "greek": "el", "hebrew": "he",
    "hindi": "hi", "hungarian": "hu", "indonesian": "id", "italian": "it",
    "japanese": "ja", "korean": "ko", "malay": "ms", "norwegian": "no",
    "persian": "fa", "polish": "pl", "portuguese": "pt", "romanian": "ro",
    "russian": "ru", "spanish": "es", "swedish": "sv", "thai": "th",
    "turkish": "tr", "ukrainian": "uk", "vietnamese": "vi",
  ]
  private static let tagPattern = #"<(meta|link)\b[^>]*>"#
  private static let attributePattern = #"([A-Za-z_:][-A-Za-z0-9_:.]*)\s*=\s*(?:\"([^\"]*)\"|'([^']*)'|([^\s>]+))"#
  private static let titlePattern = #"<title\b[^>]*>(.*?)</title>"#
  private static let htmlPattern = #"<html\b[^>]*>"#
  private static let jsonLDPattern = #"<script\b[^>]*type\s*=\s*(?:\"application/ld\+json\"|'application/ld\+json'|application/ld\+json)[^>]*>(.*?)</script>"#

  private struct JSONLDMetadata {
    var title: String?
    var description: String?
    var imageURL: String?
    var siteName: String?
    var authorName: String?
    var publishedAt: Date?
    var iconURL: String?
    var canonicalURL: String?
    var languageCode: String?
    var hasProductOfferSchema = false
    var hasAffiliateDisclosure = false
  }

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

    let jsonLD = jsonLDMetadata(in: html, pageURL: pageURL)
    let title = first([
      properties["og:title"], properties["twitter:title"], jsonLD.title, htmlTitle(in: html),
    ])
    let description = first([
      properties["og:description"], properties["twitter:description"], properties["description"],
      jsonLD.description,
    ])
    let imageURL = normalizedURL(
      first([
        properties["og:image:secure_url"], properties["og:image"], properties["twitter:image"],
        jsonLD.imageURL,
      ]),
      relativeTo: pageURL
    )
    let siteName = first([
      properties["og:site_name"], properties["application-name"], jsonLD.siteName,
    ])
    let authorName = first([
      properties["article:author"], properties["author"], properties["byl"],
      properties["twitter:creator"], jsonLD.authorName,
    ])
    let publishedAt = first([
      properties["article:published_time"], properties["og:published_time"],
      properties["date"], properties["datepublished"],
    ]).flatMap(parseDate) ?? jsonLD.publishedAt
    let resolvedCanonical = normalizedURL(
      canonicalURL ?? jsonLD.canonicalURL,
      relativeTo: pageURL
    ) ?? pageURL.absoluteString
    let languageCode = firstLanguageCode([
      jsonLD.languageCode,
      properties["og:locale"],
      htmlLanguage(in: html),
    ])
    icon = icon ?? normalizedURL(jsonLD.iconURL, relativeTo: pageURL)
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
      source: .openGraph,
      languageCode: languageCode,
      hasProductOfferSchema: jsonLD.hasProductOfferSchema,
      hasAffiliateDisclosure: jsonLD.hasAffiliateDisclosure || hasAffiliateDisclosure(in: html)
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

  private static func jsonLDMetadata(in html: String, pageURL: URL) -> JSONLDMetadata {
    let blocks = matches(
      pattern: jsonLDPattern,
      in: html,
      options: [.caseInsensitive, .dotMatchesLineSeparators],
      capture: 1
    )
    var hasProductOfferSchema = false
    var hasAffiliateDisclosure = false
    var articleObject: [String: Any]?
    for block in blocks.prefix(20) {
      guard block.utf8.count <= 256_000,
        let data = block.data(using: .utf8),
        let root = try? JSONSerialization.jsonObject(with: data)
      else { continue }
      let objects = Array(jsonLDObjects(root).prefix(100))
      hasProductOfferSchema = hasProductOfferSchema || objects.contains(where: isProductOrOffer)
      hasAffiliateDisclosure = hasAffiliateDisclosure || objects.contains(where: hasAffiliateMarker)
      articleObject = articleObject ?? objects.first(where: isArticleLike)
    }
    guard let object = articleObject else {
      return JSONLDMetadata(
        hasProductOfferSchema: hasProductOfferSchema,
        hasAffiliateDisclosure: hasAffiliateDisclosure
      )
    }
    let publisher = object["publisher"] as? [String: Any]
    let isPartOf = object["isPartOf"] as? [String: Any]
    return JSONLDMetadata(
      title: first([string(object["headline"]), string(object["name"])]),
      description: normalized(string(object["description"])),
      imageURL: normalizedURL(jsonLDURLValue(object["image"]), relativeTo: pageURL),
      siteName: first([
        string(publisher?["name"]), string(isPartOf?["name"]),
      ]),
      authorName: jsonLDName(object["author"]),
      publishedAt: string(object["datePublished"]).flatMap(parseDate),
      iconURL: normalizedURL(jsonLDURLValue(publisher?["logo"]), relativeTo: pageURL),
      canonicalURL: normalizedURL(
        jsonLDURLValue(object["mainEntityOfPage"]) ?? string(object["url"]),
        relativeTo: pageURL
      ),
      languageCode: normalizedLanguageCode(jsonLDLanguageValue(object["inLanguage"])),
      hasProductOfferSchema: hasProductOfferSchema,
      hasAffiliateDisclosure: hasAffiliateDisclosure
    )
  }

  private static func hasAffiliateMarker(_ object: [String: Any]) -> Bool {
    ["keywords", "tags"].contains { key in
      stringValues(object[key]).contains { value in
        value.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
          .contains { $0 == "affiliate" || $0 == "affiliate-social" }
      }
    }
  }

  private static func hasAffiliateDisclosure(in html: String) -> Bool {
    let text = html.lowercased()
    return [
      "we may receive a portion of sales", "we may earn a commission",
      "may earn an affiliate commission", "may receive compensation through affiliate",
    ].contains { text.contains($0) }
  }

  private static func stringValues(_ value: Any?) -> [String] {
    if let value = value as? String { return [value] }
    if let values = value as? [String] { return values }
    if let values = value as? [Any] { return values.compactMap { $0 as? String } }
    return []
  }

  private static func isProductOrOffer(_ object: [String: Any]) -> Bool {
    let types = (object["@type"] as? [String]) ?? (object["@type"] as? String).map { [$0] } ?? []
    return types.contains { ["product", "offer"].contains($0.lowercased()) }
      || object["offers"] != nil
  }

  private static func jsonLDObjects(_ value: Any) -> [[String: Any]] {
    if let object = value as? [String: Any] {
      let graph = (object["@graph"] as? [Any] ?? []).flatMap(jsonLDObjects)
      return [object] + graph
    }
    if let array = value as? [Any] { return array.flatMap(jsonLDObjects) }
    return []
  }

  private static func isArticleLike(_ object: [String: Any]) -> Bool {
    let types: [String]
    if let type = object["@type"] as? String {
      types = [type]
    } else {
      types = object["@type"] as? [String] ?? []
    }
    return types.contains { type in
      ["article", "newsarticle", "blogposting", "reportagenewsarticle"]
        .contains(type.lowercased())
    }
  }

  private static func jsonLDName(_ value: Any?) -> String? {
    if let object = value as? [String: Any] { return normalized(string(object["name"])) }
    if let array = value as? [Any] {
      return array.lazy.compactMap(jsonLDName).first
    }
    return normalized(string(value))
  }

  private static func jsonLDURLValue(_ value: Any?) -> String? {
    if let value = string(value) { return value }
    if let object = value as? [String: Any] {
      return string(object["url"]) ?? string(object["@id"])
    }
    if let array = value as? [Any] {
      return array.lazy.compactMap(jsonLDURLValue).first
    }
    return nil
  }

  private static func jsonLDLanguageValue(_ value: Any?) -> String? {
    if let value = string(value) { return value }
    if let object = value as? [String: Any] {
      return string(object["name"]) ?? string(object["@id"])
    }
    if let array = value as? [Any] {
      return array.lazy.compactMap(jsonLDLanguageValue).first
    }
    return nil
  }

  private static func htmlLanguage(in html: String) -> String? {
    guard let tag = matches(pattern: htmlPattern, in: html, options: [.caseInsensitive]).first else {
      return nil
    }
    return attributes(in: tag)["lang"]
  }

  private static func firstLanguageCode(_ values: [String?]) -> String? {
    values.lazy.compactMap(normalizedLanguageCode).first
  }

  private static func normalizedLanguageCode(_ raw: String?) -> String? {
    guard let raw else { return nil }
    let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: "_", with: "-")
      .lowercased()
    if let mapped = languageNameCodes[normalized] { return mapped }
    guard let primary = normalized.split(separator: "-").first,
      primary.count == 2 || primary.count == 3,
      primary.allSatisfy({ $0.isASCII && $0.isLetter })
    else { return nil }
    return String(primary)
  }

  private static func string(_ value: Any?) -> String? { value as? String }

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
