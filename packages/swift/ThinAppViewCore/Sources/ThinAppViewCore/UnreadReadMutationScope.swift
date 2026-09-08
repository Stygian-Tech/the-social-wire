import Foundation

/// Request-local scopes keep read snapshots independent of persisted sidebar projections.
struct UnreadReadMutationScope: Encodable {
  let publicationId: String
  let authorDid: String
  let scopeKeys: [String]
  let position: Int
  let unscoped: Bool

  static func overlappingAuthors(_ scopes: [AppViewPublicationScope]) -> [String] {
    let broad = Set(scopes.filter(\.scopeKeys.isEmpty).map(\.authorDid))
    let specific = Set(scopes.filter { !$0.scopeKeys.isEmpty }.map(\.authorDid))
    return broad.intersection(specific).sorted()
  }

  static func json(
    _ scopes: [AppViewPublicationScope], additionalSites: [String] = []
  ) throws -> String {
    let ordered = scopes.sorted { $0.publicationId < $1.publicationId }
    let candidates = Set(scopes.flatMap(\.scopeKeys) + additionalSites)
    // Normalize each candidate once. The final matcher still decides query-specific feed
    // membership, while unrelated publications no longer cause a quadratic URL-parsing pass.
    var candidatesByIdentity: [String: Set<String>] = [:]
    for candidate in candidates {
      for identity in identityKeys(candidate) {
        candidatesByIdentity[identity, default: []].insert(candidate)
      }
    }
    let values = ordered.enumerated().map { position, scope in
      var relatedCandidates = Set<String>()
      for key in scope.scopeKeys {
        for identity in identityKeys(key) {
          relatedCandidates.formUnion(candidatesByIdentity[identity] ?? [])
        }
      }
      return Self(
        publicationId: scope.publicationId, authorDid: scope.authorDid,
        scopeKeys: relatedCandidates.filter {
          AppViewUnreadCounterSupport.contentMatchesScope(
            authorDid: scope.authorDid, publicationSite: $0, scope: scope
          )
        }.sorted(), position: position, unscoped: scope.scopeKeys.isEmpty
      )
    }
    return String(decoding: try JSONEncoder().encode(values), as: UTF8.self)
  }

  private static func identityKeys(_ site: String) -> [String] {
    var keys: [String] = []
    if let atUri = RenderFieldExtractor.canonicalPublicationAtUriKey(site) {
      keys.append("at:\(atUri)")
    }
    if let feed = RssFeedIdentity.normalizeFeedUrl(site) {
      keys.append("feed:\(feed)")
    }
    if let url = RenderFieldExtractor.normalizePublicationSiteUrl(site) {
      keys.append("site:\(url)")
    }
    return keys
  }
}
