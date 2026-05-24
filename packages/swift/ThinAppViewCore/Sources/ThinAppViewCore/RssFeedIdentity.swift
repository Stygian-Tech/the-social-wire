import Crypto
import Foundation

/// RSS / Skyreader identity helpers aligned with web `rssFeedCore.ts`.
public enum RssFeedLexicons {
  public static let rssAuthorDid = "did:web:skyreader.rss"
  public static let skyreaderFeedSubscription = "app.skyreader.feed.subscription"
  public static let skyreaderFeedEntry = "app.skyreader.feed.entry"
  public static let publicationPrefix = "rss:"
  public static let entryPrefix = "rssentry:"
}

public enum RssFeedIdentity {
  public static func normalizeFeedUrl(_ raw: String) -> String? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    var href = trimmed
    if !href.lowercased().hasPrefix("http://"), !href.lowercased().hasPrefix("https://") {
      href = "https://\(href)"
    }
    guard var components = URLComponents(string: href),
          let scheme = components.scheme?.lowercased(),
          scheme == "http" || scheme == "https",
          let host = components.host?.trimmingCharacters(in: .whitespacesAndNewlines),
          !host.isEmpty
    else { return nil }
    if scheme == "http" { components.scheme = "https" }
    components.fragment = nil
    components.user = nil
    components.password = nil
    guard let url = components.url else { return nil }
    var out = url.absoluteString
    if out.hasSuffix("/") { out.removeLast() }
    return out
  }

  public static func isFetchableFeedUrl(_ raw: String) -> Bool {
    guard let normalized = normalizeFeedUrl(raw) else { return false }
    guard let host = URL(string: normalized)?.host?.lowercased() else { return false }
    return !isBlockedFetchHostname(host)
  }

  public static func rssPublicationId(from normalizedFeedUrl: String) -> String {
    "\(RssFeedLexicons.publicationPrefix)\(utf8ToBase64Url(normalizedFeedUrl))"
  }

  public static func normalizedFeedUrl(fromRssPublicationId pubId: String) -> String? {
    guard pubId.hasPrefix(RssFeedLexicons.publicationPrefix) else { return nil }
    let payload = String(pubId.dropFirst(RssFeedLexicons.publicationPrefix.count))
    return base64UrlToUtf8(payload)
  }

  /// Prefer normalized article links over opaque GUIDs so re-polls do not mint duplicate rows.
  public static func stableItemKey(from item: ParsedRssItem) -> String {
    if let linkKey = stableLinkKey(from: item.link) {
      return linkKey
    }
    if let guidKey = stableGuidKey(from: item.guid) {
      return guidKey
    }
    let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
    let date = item.publishedAtISO.trimmingCharacters(in: .whitespacesAndNewlines)
    return "fallback:\(title)\n\(date)"
  }

  public static func decodeEntryId(_ entryId: String) -> (feedUrl: String, stableItemKey: String)? {
    guard entryId.hasPrefix(RssFeedLexicons.entryPrefix) else { return nil }
    let payload = String(entryId.dropFirst(RssFeedLexicons.entryPrefix.count))
    guard let inner = base64UrlToUtf8(payload) else { return nil }
    if let data = inner.data(using: .utf8),
       let object = try? JSONSerialization.jsonObject(with: data) as? [String: String],
       let feedUrl = object["f"],
       let stableItemKey = object["k"]
    {
      return (feedUrl, stableItemKey)
    }
    guard let pipe = inner.firstIndex(of: "|") else { return nil }
    let feedUrl = String(inner[..<pipe])
    let stableItemKey = String(inner[inner.index(after: pipe)...])
    guard !feedUrl.isEmpty, !stableItemKey.isEmpty else { return nil }
    return (feedUrl, stableItemKey)
  }

  public static func canonicalLinkFromStableItemKey(_ stableItemKey: String) -> String? {
    if stableItemKey.hasPrefix("link:") {
      let raw = String(stableItemKey.dropFirst("link:".count))
      return normalizeFeedUrl(raw) ?? raw
    }
    if stableItemKey.hasPrefix("guid:") {
      let raw = String(stableItemKey.dropFirst("guid:".count))
      guard raw.lowercased().hasPrefix("http") else { return nil }
      return normalizeFeedUrl(raw)
    }
    return nil
  }

  public static func canonicalLinkForEntryListItem(_ item: AppViewEntryListItem) -> String? {
    if item.entryId.hasPrefix(RssFeedLexicons.entryPrefix),
       let decoded = decodeEntryId(item.entryId),
       let link = canonicalLinkFromStableItemKey(decoded.stableItemKey)
    {
      return link
    }
    if let summary = item.summary?.trimmingCharacters(in: .whitespacesAndNewlines),
       summary.lowercased().hasPrefix("http"),
       let normalized = normalizeFeedUrl(summary)
    {
      return normalized
    }
    return nil
  }

  public static func dedupeEntryListItems(_ items: [AppViewEntryListItem]) -> [AppViewEntryListItem] {
    var seenEntryIds = Set<String>()
    var seenCanonicalLinks = Set<String>()
    var seenTitlePublished = Set<String>()
    var deduped: [AppViewEntryListItem] = []
    deduped.reserveCapacity(items.count)

    for item in items {
      guard seenEntryIds.insert(item.entryId).inserted else { continue }

      if let link = canonicalLinkForEntryListItem(item) {
        guard seenCanonicalLinks.insert(link).inserted else { continue }
      } else {
        let titleKey =
          "\(item.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())|\(Int(item.publishedAt.timeIntervalSince1970))"
        guard seenTitlePublished.insert(titleKey).inserted else { continue }
      }

      deduped.append(item)
    }
    return deduped
  }

  private static func stableLinkKey(from raw: String?) -> String? {
    guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
      return nil
    }
    if let normalized = normalizeFeedUrl(trimmed) {
      return "link:\(normalized)"
    }
    return "link:\(trimmed)"
  }

  private static func stableGuidKey(from raw: String?) -> String? {
    guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
      return nil
    }
    if let normalized = normalizeFeedUrl(trimmed) {
      return "guid:\(normalized)"
    }
    return "guid:\(trimmed)"
  }

  public static func rssEntryId(normalizedFeedUrl: String, stableItemKey: String) -> String {
    let inner: [String: String] = ["f": normalizedFeedUrl, "k": stableItemKey]
    guard
      let data = try? JSONSerialization.data(withJSONObject: inner),
      let json = String(data: data, encoding: .utf8)
    else {
      return "\(RssFeedLexicons.entryPrefix)\(utf8ToBase64Url(normalizedFeedUrl + "|" + stableItemKey))"
    }
    return "\(RssFeedLexicons.entryPrefix)\(utf8ToBase64Url(json))"
  }

  public static func deterministicCid(for entryUri: String) -> String {
    let digest = SHA256.hash(data: Data(entryUri.utf8))
    let hex = digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    return "rss:\(hex)"
  }

  private static func utf8ToBase64Url(_ text: String) -> String {
    let data = Data(text.utf8)
    return data.base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  private static func base64UrlToUtf8(_ b64url: String) -> String? {
    var s = b64url.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    let pad = s.count % 4
    if pad != 0 { s += String(repeating: "=", count: 4 - pad) }
    guard let data = Data(base64Encoded: s) else { return nil }
    return String(data: data, encoding: .utf8)
  }

  private static func isBlockedFetchHostname(_ hostname: String) -> Bool {
    let h = hostname.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if h.isEmpty { return true }
    if h == "localhost" || h.hasSuffix(".localhost") || h.hasSuffix(".local") { return true }
    if h == "[::1]" || h == "::1" { return true }

    let parts = h.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
    if parts.count == 4, let a = Int(parts[0]), let b = Int(parts[1]) {
      if a == 127 || a == 0 || a == 10 { return true }
      if a == 192 && b == 168 { return true }
      if a == 172 && (16 ... 31).contains(b) { return true }
      if a == 169 && b == 254 { return true }
    }
    return false
  }
}
