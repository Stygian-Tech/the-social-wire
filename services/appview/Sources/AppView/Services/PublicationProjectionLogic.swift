import Foundation
import GatewayCore
import ThinAppViewCore

// MARK: - Internal discovery row (pre-scope)

struct ProjectionDiscoveredRow: Sendable, Equatable {
  var publicationId: String
  var subscriptionPublicationId: String?
  var authorDid: String
  var authorHandle: String?
  var title: String
  var iconUrl: String?
  var avatarUrl: String?
  var discoveredAt: Date
}

// MARK: - Subscription matching (mirror web `publicationSubscriptionMatch.ts`)

enum PublicationProjectionLogic {
  private static let atUriPathPattern = #"^at://([^/]+)/([^/]+)/([^/]+)$"#

  static func normalizeAtRepoParam(_ raw: String) -> String {
    var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if s.hasPrefix("@") {
      s = String(s.dropFirst())
    }
    for _ in 0 ..< 3 {
      if s.hasPrefix("did:") {
        return s
      }
      if let decodedAtUri = decodeAtUriAuthorityAndCollection(s), decodedAtUri != s {
        s = decodedAtUri
        continue
      }
      guard let decoded = urlDecodedOnce(s), decoded != s else {
        return s
      }
      s = decoded
    }
    return s
  }

  static func publicationIdLookupKeys(for raw: String) -> [String] {
    var keys = Set<String>()
    keys.insert(raw)
    let normalized = normalizeAtRepoParam(raw)
    keys.insert(normalized)
    addPublicationSubscriptionLookupKeys(into: &keys, value: normalized)
    if let canonical = RenderFieldExtractor.canonicalPublicationAtUriKey(normalized) {
      keys.insert(canonical)
      addPublicationSubscriptionLookupKeys(into: &keys, value: canonical)
    }
    return Array(keys)
  }

  private static func urlDecodedOnce(_ value: String) -> String? {
    guard let decoded = value.removingPercentEncoding, decoded != value else { return nil }
    return decoded
  }

  private static func decodeUriEncodingLayers(_ segment: String) -> String {
    var s = segment
    for _ in 0 ..< 3 {
      guard s.contains("%"), let decoded = s.removingPercentEncoding, decoded != s else { break }
      s = decoded
    }
    return s
  }

  private static func decodeAtUriAuthorityAndCollection(_ uri: String) -> String? {
    guard let regex = try? NSRegularExpression(pattern: atUriPathPattern) else { return nil }
    let range = NSRange(uri.startIndex..., in: uri)
    guard
      let match = regex.firstMatch(in: uri, range: range),
      match.numberOfRanges == 4,
      let authRange = Range(match.range(at: 1), in: uri),
      let collRange = Range(match.range(at: 2), in: uri),
      let rkeyRange = Range(match.range(at: 3), in: uri)
    else { return nil }

    let auth = String(uri[authRange])
    let coll = String(uri[collRange])
    let rkey = String(uri[rkeyRange])
    let decodedAuth = decodeUriEncodingLayers(auth)
    let decodedColl = decodeUriEncodingLayers(coll)
    guard decodedAuth != auth || decodedColl != coll else { return nil }
    return "at://\(decodedAuth)/\(decodedColl)/\(rkey)"
  }

  static func publicationIdsMatch(_ lhs: String, _ rhs: String) -> Bool {
    let left = Set(publicationIdLookupKeys(for: lhs).map { normalizeAtRepoParam($0) })
    let right = Set(publicationIdLookupKeys(for: rhs).map { normalizeAtRepoParam($0) })
    return !left.isDisjoint(with: right)
  }

  static func prefsByPublicationId(
    _ prefs: [PublicationPrefsRecordDTO]
  ) -> [String: PublicationPrefsRecordDTO] {
    var byPublicationId: [String: PublicationPrefsRecordDTO] = [:]
    for pref in prefs.sorted(by: { $0.uri < $1.uri }) {
      byPublicationId[pref.publicationId] = pref
    }
    return byPublicationId
  }

  static func addPublicationSubscriptionLookupKeys(into keys: inout Set<String>, value: String?) {
    guard let value else { return }
    let normalized = normalizeAtRepoParam(value)

    if normalized.hasPrefix("did:") {
      keys.insert(normalized)
      return
    }

    guard let parsed = RenderFieldExtractor.parseAtUri(normalized) else { return }
    keys.insert(normalized)
    if parsed.collection == "site.standard.publication" {
      keys.insert("at://\(parsed.did)/com.standard.publication/\(parsed.rkey)")
    } else if parsed.collection == "com.standard.publication" {
      keys.insert("at://\(parsed.did)/site.standard.publication/\(parsed.rkey)")
    }
  }

  static func publicationSubscriptionMatchKeys(for row: ProjectionDiscoveredRow) -> [String] {
    var keys = Set<String>()
    addPublicationSubscriptionLookupKeys(into: &keys, value: row.subscriptionPublicationId)
    addPublicationSubscriptionLookupKeys(into: &keys, value: row.publicationId)
    return Array(keys)
  }

  static func subscriptionPublicationKeys(from subscriptions: [[String: Any]]) -> Set<String> {
    var keys = Set<String>()
    for value in subscriptions {
      if let pub = value["publication"] as? String {
        addPublicationSubscriptionLookupKeys(into: &keys, value: pub)
      }
    }
    return keys
  }

  static func viewerOwnsPublication(_ row: ProjectionDiscoveredRow, viewerDid: String?) -> Bool {
    guard let viewerDid else { return false }
    let viewer = normalizeDidForOwnership(viewerDid)
    if normalizeDidForOwnership(publicationRepoDid(row.publicationId)) == viewer { return true }
    if normalizeDidForOwnership(row.authorDid) == viewer { return true }
    return false
  }

  static func publicationRepoDid(_ publicationId: String) -> String {
    let normalized = normalizeAtRepoParam(publicationId)
    if let parsed = RenderFieldExtractor.parseAtUri(normalized),
       PublicationLexicons.publicationRecordCollections.contains(parsed.collection)
    {
      return parsed.did
    }
    if let parsed = RenderFieldExtractor.parseAtUri(normalized) {
      return parsed.did
    }
    return normalized
  }

  static func normalizeDidForOwnership(_ raw: String) -> String {
    let trimmed = normalizeAtRepoParam(raw)
    if trimmed.lowercased().hasPrefix("did:plc:") {
      return trimmed.lowercased()
    }
    return trimmed
  }

  static func isSubscribedPublication(
    _ row: ProjectionDiscoveredRow,
    subscriptionKeys: Set<String>
  ) -> Bool {
    publicationSubscriptionMatchKeys(for: row).contains { subscriptionKeys.contains($0) }
  }

  static func segmentDiscovery(
    _ discovered: [ProjectionDiscoveredRow],
    viewerDid: String?,
    subscriptionKeys: Set<String>
  ) -> (graphSubscribed: [ProjectionDiscoveredRow], followOwnedUnsubscribed: [ProjectionDiscoveredRow]) {
    guard let viewerDid else { return ([], []) }
    var graphSubscribed: [ProjectionDiscoveredRow] = []
    var followOwnedUnsubscribed: [ProjectionDiscoveredRow] = []
    for row in discovered {
      if viewerOwnsPublication(row, viewerDid: viewerDid) {
        graphSubscribed.append(row)
      } else if isSubscribedPublication(row, subscriptionKeys: subscriptionKeys) {
        graphSubscribed.append(row)
      } else {
        followOwnedUnsubscribed.append(row)
      }
    }
    return (graphSubscribed, followOwnedUnsubscribed)
  }

  static func mergeSubscribed(
    graphSubscribed: [ProjectionDiscoveredRow],
    rssRows: [ProjectionDiscoveredRow],
    graphOrphanRows: [ProjectionDiscoveredRow]
  ) -> [ProjectionDiscoveredRow] {
    var merged = graphSubscribed
    var ids = Set(graphSubscribed.map(\.publicationId))
    for row in rssRows + graphOrphanRows where !ids.contains(row.publicationId) {
      merged.append(row)
      ids.insert(row.publicationId)
    }
    return merged
  }

  static func filterFollowingTab(
    followOwnedUnsubscribed: [ProjectionDiscoveredRow],
    myPublications: [ProjectionDiscoveredRow]
  ) -> [ProjectionDiscoveredRow] {
    let myIds = Set(myPublications.map(\.publicationId))
    return followOwnedUnsubscribed.filter { !myIds.contains($0.publicationId) }
  }

  // MARK: - RSS projection

  static func rssPublicationId(from normalizedFeedUrl: String) -> String {
    RssFeedIdentity.rssPublicationId(from: normalizedFeedUrl)
  }

  static func normalizedFeedUrlFromRssPublicationId(_ pubId: String) -> String? {
    RssFeedIdentity.normalizedFeedUrl(fromRssPublicationId: pubId)
  }

  static func normalizeRssFeedUrl(_ raw: String) -> String? {
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

  static func skyreaderRows(from records: [(uri: String, value: PdsRecordJSON)]) -> [ProjectionDiscoveredRow] {
    var out: [ProjectionDiscoveredRow] = []
    var seen = Set<String>()
    let now = Date()

    for (uri, value) in records {
      let dict = value.values
      guard let rawUrl = (dict["feedUrl"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
            !rawUrl.isEmpty
      else { continue }
      if let src = (dict["sourceType"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
         !src.isEmpty, src != "rss"
      {
        continue
      }
      guard let normalized = normalizeRssFeedUrl(rawUrl) else { continue }
      let publicationId = rssPublicationId(from: normalized)
      guard !seen.contains(publicationId) else { continue }
      seen.insert(publicationId)

      let hostLabel = URL(string: normalized)?.host ?? normalized
      let title =
        (dict["customTitle"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        ?? (dict["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        ?? hostLabel

      let icon =
        (dict["customIconUrl"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        ?? (dict["siteUrl"] as? String).flatMap { RenderFieldExtractor.faviconUrl(forSiteOrFeedUrl: $0) }
        ?? RenderFieldExtractor.faviconUrl(forSiteOrFeedUrl: normalized)

      out.append(
        ProjectionDiscoveredRow(
          publicationId: publicationId,
          subscriptionPublicationId: uri,
          authorDid: PublicationLexicons.rssAuthorDid,
          authorHandle: "RSS",
          title: title,
          iconUrl: icon,
          avatarUrl: nil,
          discoveredAt: now
        )
      )
    }
    return out
  }

  static func orphanGraphSubscriptionUris(
    subscriptions: [[String: Any]],
    existingRows: [ProjectionDiscoveredRow]
  ) -> [String] {
    var existingKeys = Set<String>()
    for row in existingRows {
      for key in publicationSubscriptionMatchKeys(for: row) {
        existingKeys.insert(key)
      }
    }

    var uris = Set<String>()
    for value in subscriptions {
      guard let raw = (value["publication"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
            !raw.isEmpty
      else { continue }
      let normalized = normalizeAtRepoParam(raw)
      guard let parsed = RenderFieldExtractor.parseAtUri(normalized),
            PublicationLexicons.publicationRecordCollections.contains(parsed.collection)
      else { continue }

      var lookup = Set<String>()
      addPublicationSubscriptionLookupKeys(into: &lookup, value: normalized)
      if lookup.contains(where: { existingKeys.contains($0) }) { continue }
      uris.insert(normalized)
    }
    return uris.sorted()
  }
}

private extension String {
  var nilIfEmpty: String? {
    isEmpty ? nil : self
  }
}
