import Foundation

/// Extracts Level-1 list-row fields from standard.site-shaped ATProto records.
public enum RenderFieldExtractor {
  static let publicationRecordCollections: Set<String> = [
    "site.standard.publication",
    "com.standard.publication",
  ]

  public static func extractRenderFields(
    from record: [String: Any],
    repoDid: String? = nil,
    pdsBase: String? = nil
  ) -> ContentRenderFields {
    let title =
      HtmlTextDecoder.decodePlainText(
        string(record["title"])
          ?? string(record["name"])
          ?? slugFromPath(string(record["path"]))
          ?? "Untitled"
      )

    let publishedAt =
      string(record["publishedAt"])
      ?? string(record["createdAt"])
      ?? string(record["indexedAt"])
      ?? ISO8601DateFormatter().string(from: Date())

    let summary = string(record["summary"]).map(HtmlTextDecoder.decodePlainText)
      ?? string(record["description"]).map(HtmlTextDecoder.decodePlainText)
    let thumbnailUrl =
      extractHttpsThumbnail(from: record)
      ?? publicationImageUrl(
        from: record,
        keys: ["coverImage", "thumbnail", "image", "heroImage", "socialImage"],
        repoDid: repoDid,
        pdsBase: pdsBase
      )

    return ContentRenderFields(
      title: title,
      publishedAt: publishedAt,
      summary: summary,
      thumbnailUrl: thumbnailUrl,
      articleUrl: articleUrl(from: record)
    )
  }

  /// Resolves a publication sidebar icon from HTTPS fields or a non-Bridgy blob URL.
  public static func publicationIconUrl(
    from record: [String: Any],
    repoDid: String,
    pdsBase: String?
  ) -> String? {
    publicationImageUrl(
      from: record,
      keys: ["icon", "iconUrl", "iconImage", "iconImageUrl", "avatar", "avatarUrl", "logo", "logoUrl", "favicon"],
      repoDid: repoDid,
      pdsBase: pdsBase
    )
  }

  public static func publicationSiteField(from record: [String: Any]) -> String? {
    for key in ["site", "publication", "publicationUri", "publicationId"] {
      if let site = string(record[key]) {
        return site
      }
      if let ref = record[key] as? [String: Any], let uri = string(ref["uri"]) {
        return uri
      }
    }
    return nil
  }

  public static func normalizePublicationSiteUrl(_ raw: String) -> String? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.lowercased().hasPrefix("http://") || trimmed.lowercased().hasPrefix("https://") else {
      return nil
    }
    guard var components = URLComponents(string: trimmed) else { return nil }
    components.fragment = nil
    components.query = nil
    guard let url = components.url else { return nil }
    var href = url.absoluteString
    if href.hasSuffix("/") { href.removeLast() }
    return href
  }

  public static func matchesPublication(
    siteField: String?,
    publicationAtUri: String?,
    publicationScopeAtUris: [String] = [],
    publicationSiteUrls: [String] = []
  ) -> Bool {
    let scoped = publicationAtUri != nil || !publicationScopeAtUris.isEmpty || !publicationSiteUrls.isEmpty
    guard scoped else { return true }
    guard let siteField else { return false }

    var wantAtKeys = Set<String>()
    if let publicationAtUri {
      wantAtKeys.formUnion(publicationFilterEquivalenceKeys(publicationAtUri: publicationAtUri))
    }
    for uri in publicationScopeAtUris {
      if let key = canonicalPublicationAtUriKey(uri) {
        wantAtKeys.insert(key)
      }
    }
    if let got = canonicalPublicationAtUriKey(siteField), wantAtKeys.contains(got) {
      return true
    }

    let wantSiteUrls = Set(publicationSiteUrls.compactMap { normalizePublicationSiteUrl($0) })
    if let gotSite = normalizePublicationSiteUrl(siteField), wantSiteUrls.contains(gotSite) {
      return true
    }

    return false
  }

  /// Matches web `entryRecordMatchesPublication` site equivalence keys.
  public static func matchesPublicationAtUriOnly(siteField: String?, publicationAtUri: String) -> Bool {
    matchesPublication(siteField: siteField, publicationAtUri: publicationAtUri, publicationSiteUrls: [])
  }

  public static func createdAtDate(from record: [String: Any], fallback render: ContentRenderFields) -> Date {
    if let parsed = parseISO8601(render.publishedAt) {
      return parsed
    }
    return Date()
  }

  public static func canonicalPublicationAtUriKey(_ uri: String) -> String? {
    guard let parsed = parseAtUri(uri) else { return nil }
    let did = parsed.did.lowercased().hasPrefix("did:plc:") ? parsed.did.lowercased() : parsed.did
    return "at://\(did)/\(parsed.collection)/\(parsed.rkey)"
  }

  public static func publicationFilterEquivalenceKeys(publicationAtUri: String) -> Set<String> {
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

  public static func parseAtUri(_ uri: String) -> (did: String, collection: String, rkey: String)? {
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

  public static func buildEntryUri(did: String, collection: String, rkey: String) -> String {
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

  private static func articleUrl(from record: [String: Any]) -> String? {
    for key in ["url", "externalUrl", "canonicalUrl", "href", "permalink"] {
      if let normalized = normalizeArticleUrl(string(record[key])) {
        return normalized
      }
    }

    guard
      let site = string(record["site"]),
      let base = normalizePublicationSiteUrl(site),
      let path = string(record["path"])
    else {
      return nil
    }

    if let normalized = normalizeArticleUrl(path) {
      return normalized
    }

    let cleanPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    guard !cleanPath.isEmpty else { return base }
    return normalizeArticleUrl("\(base)/\(cleanPath)")
  }

  private static func normalizeArticleUrl(_ raw: String?) -> String? {
    guard let raw else { return nil }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.lowercased().hasPrefix("http://") || trimmed.lowercased().hasPrefix("https://") else {
      return nil
    }
    guard var components = URLComponents(string: trimmed) else { return nil }
    components.fragment = nil
    guard let url = components.url else { return nil }
    var href = url.absoluteString
    if href.lowercased().hasPrefix("http://") {
      href = "https://" + href.dropFirst("http://".count)
    }
    return href
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

  private static func publicationImageUrl(
    from record: [String: Any],
    keys: [String],
    repoDid: String?,
    pdsBase: String?
  ) -> String? {
    for key in keys {
      if let url = httpsUrl(string(record[key])) { return url }
      if let cid = extractBlobLink(record[key]),
         let repoDid,
         let built = buildSyncGetBlobUrl(pdsBase: pdsBase, repoDid: repoDid, cid: cid)
      {
        return built
      }
    }
    return nil
  }

  public static func extractBlobLink(_ value: Any?) -> String? {
    guard let value else { return nil }
    if let link = value as? String, !link.isEmpty { return link }
    guard let object = value as? [String: Any] else { return nil }
    if let link = string(object["$link"]) { return link }
    if let ref = object["ref"] as? [String: Any], let link = string(ref["$link"]) { return link }
    return nil
  }

  public static func buildSyncGetBlobUrl(pdsBase: String?, repoDid: String, cid: String) -> String? {
    guard let pdsBase else { return nil }
    let normalized = normalizePdsBase(pdsBase)
    guard !isBridgyPdsHost(normalized) else { return nil }
    var components = URLComponents(string: "\(normalized)/xrpc/com.atproto.sync.getBlob")!
    components.queryItems = [
      URLQueryItem(name: "did", value: repoDid),
      URLQueryItem(name: "cid", value: cid),
    ]
    return components.url?.absoluteString
  }

  public static func faviconUrl(forSiteOrFeedUrl raw: String) -> String? {
    guard let host = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines))?.host else {
      return nil
    }
    return "https://\(host)/favicon.ico"
  }

  private static func normalizePdsBase(_ endpoint: String) -> String {
    var s = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
    while s.hasSuffix("/") { s.removeLast() }
    return s
  }

  private static func isBridgyPdsHost(_ pdsBase: String) -> Bool {
    guard let host = URL(string: pdsBase)?.host?.lowercased() else { return false }
    return host == "atproto.brid.gy" || host.hasSuffix(".brid.gy")
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
