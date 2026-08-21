import Foundation

protocol WirePublicationResolving: Sendable {
  func observe(_ metadata: WirePublicationMetadata, asOf: Date) async throws
  func resolve(publicationURI: String, asOf: Date) async throws -> WirePublicationMetadata?
  func remove(publicationURI: String, observedAt: Date) async throws
}
