import Foundation

protocol WirePublicationMetadataStoring: Sendable {
  func load(publicationURI: String, asOf: Date) async throws -> WirePublicationMetadata?
  func upsert(_ metadata: WirePublicationMetadata, asOf: Date) async throws
  func remove(publicationURI: String, observedAt: Date) async throws
}
