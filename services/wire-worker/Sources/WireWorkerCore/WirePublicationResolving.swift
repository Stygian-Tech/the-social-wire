import Foundation

protocol WirePublicationResolving: Sendable {
  func invalidateAccount(repoDID: String) async
  func invalidate(publicationURI: String) async
  func observe(_ metadata: WirePublicationMetadata, asOf: Date) async throws
  func resolve(publicationURI: String, asOf: Date) async throws -> WirePublicationMetadata?
  func remove(publicationURI: String, observedAt: Date) async throws
}

extension WirePublicationResolving {
  func invalidateAccount(repoDID: String) async {}
  func invalidate(publicationURI: String) async {}
}
