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
    let values = ordered.enumerated().map { position, scope in
      Self(
        publicationId: scope.publicationId, authorDid: scope.authorDid,
        scopeKeys: candidates.filter {
          AppViewUnreadCounterSupport.contentMatchesScope(
            authorDid: scope.authorDid, publicationSite: $0, scope: scope
          )
        }.sorted(), position: position, unscoped: scope.scopeKeys.isEmpty
      )
    }
    return String(decoding: try JSONEncoder().encode(values), as: UTF8.self)
  }
}
