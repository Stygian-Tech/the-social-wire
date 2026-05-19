import Foundation

/// Extracts Level-1 list-row fields from standard.site-shaped ATProto records.
enum RenderFieldExtractor {
  static let publicationRecordCollections: Set<String> = [
    "site.standard.publication",
    "com.standard.publication",
  ]

  static func extractRenderFields(from record: [String: Any]) -> ContentRenderFields {
    let title =
      string(record["title"])
      ?? string(record["name"])
      ?? slugFromPath(string(record["path"]))
      ?? "Untitled"

    let publishedAt =
      string(record["publishedAt"])
      ?? string(record["createdAt"])
      ?? string(record["indexedAt"])
      ?? ISO8601DateFormatter().string(from: Date())

    let summary = string(record["summary"]) ?? string(record["description"])
    let thumbnailUrl = extractHttpsThumbnail(from: record)

    return ContentRenderFields(
      title: title,
      publishedAt: publishedAt,
      summary: summary,
      thumbnailUrl: thumbnailUrl
    )
  }

  static func publicationSiteField(from record: [String: Any]) -> String? {
    if let site = string(record["site"]) {
      return site
    }
    if let ref = record["site"] as? [String: Any], let uri = string(ref["uri"]) {
      return uri
    }
    return nil
  }

  static func createdAtDate(from record: [String: Any], fallback render: ContentRenderFields) -> Date {
    if let parsed = parseISO8601(render.publishedAt) {
      return parsed
    }
    return Date()
  }

  /// Matches web `entryRecordMatchesPublication` site equivalence keys.
  static func matchesPublication(siteField: String?, publicationAtUri: String) -> Bool {
    guard let siteField else { return false }
    let wantKeys = publicationFilterEquivalenceKeys(publicationAtUri: publicationAtUri)
    guard let got = canonicalPublicationAtUriKey(siteField) else { return false }
    return wantKeys.contains(got)
  }

  static func canonicalPublicationAtUriKey(_ uri: String) -> String? {
    guard let parsed = parseAtUri(uri) else { return nil }
    let did = parsed.did.lowercased().hasPrefix("did:plc:") ? parsed.did.lowercased() : parsed.did
    return "at://\(did)/\(parsed.collection)/\(parsed.rkey)"
  }

  static func publicationFilterEquivalenceKeys(publicationAtUri: String) -> Set<String> {
    var keys = Set<String>()
    if let primary = canonicalPublicationAtUriKey(publicationAtUri) {
      keys.insert(primary)
    }
    guard let parsed = parseAtUri(publicationAtUri) else { return keys }
    guard publicationRecordCollections.contains(parsed.collection) else { return keys }

    let didNorm = parsed.did.lowercased().hasPrefix("did:plc:") ? parsed.did.lowercased() : parsed.did
    if parsed.collection == "site.standard.publication" {
      keys.insert("at://\(didNorm)/com.standard.publication/\(parsed.rkey)")
    } else if parsed.collection == "com.standard.publication" {
      keys.insert("at://\(didNorm)/site.standard.publication/\(parsed.rkey)")
    }
    return keys
  }

  static func parseAtUri(_ uri: String) -> (did: String, collection: String, rkey: String)? {
    let pattern = #"^at://([^/]+)/([^/]+)/([^/]+)$"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
    let range = NSRange(uri.startIndex..., in: uri)
    guard
      let match = regex.firstMatch(in: uri, range: range),
      match.numberOfRanges == 4,
      let didRange = Range(match.range(at: 1), in: uri),
      let collectionRange = Range(match.range(at: 2), in: uri),
      let rkeyRange = Range(match.range(at: 3), in: uri)
    else { return nil }

    return (
      String(uri[didRange]),
      String(uri[collectionRange]),
      String(uri[rkeyRange])
    )
  }

  static func buildEntryUri(did: String, collection: String, rkey: String) -> String {
    "at://\(did)/\(collection)/\(rkey)"
  }

  // MARK: - Private

  private static func string(_ value: Any?) -> String? {
    guard let s = value as? String else { return nil }
    let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private static func slugFromPath(_ path: String?) -> String? {
    guard let path else { return nil }
    let parts = path.split(separator: "/").map(String.init).filter { !$0.isEmpty }
    return parts.last
  }

  private static func extractHttpsThumbnail(from record: [String: Any]) -> String? {
    for key in ["thumbnailUrl", "coverImageUrl", "image", "heroImage", "socialImage"] {
      if let url = httpsUrl(string(record[key])) { return url }
    }
    if let cover = record["coverImage"] {
      if let url = httpsUrl(string(cover)) { return url }
    }
    if let thumb = record["thumbnail"] {
      if let url = httpsUrl(string(thumb)) { return url }
    }
    return nil
  }

  private static func httpsUrl(_ raw: String?) -> String? {
    guard let raw else { return nil }
    let lower = raw.lowercased()
    guard lower.hasPrefix("https://") || lower.hasPrefix("http://") else { return nil }
    return raw
  }

  private static func parseISO8601(_ raw: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: raw) { return date }
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: raw)
  }
}
