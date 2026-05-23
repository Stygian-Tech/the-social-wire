import CryptoKit
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

  public static func stableItemKey(from item: ParsedRssItem) -> String {
    if let guid = item.guid?.trimmingCharacters(in: .whitespacesAndNewlines), !guid.isEmpty {
      return "guid:\(guid)"
    }
    if let link = item.link?.trimmingCharacters(in: .whitespacesAndNewlines), !link.isEmpty {
      return "link:\(link)"
    }
    let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
    let date = item.publishedAtISO.trimmingCharacters(in: .whitespacesAndNewlines)
    return "fallback:\(title)\n\(date)"
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
