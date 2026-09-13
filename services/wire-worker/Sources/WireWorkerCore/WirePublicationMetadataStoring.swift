import Foundation

protocol WirePublicationMetadataStoring: Sendable {
  func load(publicationURI: String, asOf: Date) async throws -> WirePublicationMetadata?
  func loadForCaching(publicationURI: String, asOf: Date) async throws -> WirePublicationCacheValue
  func upsert(_ metadata: WirePublicationMetadata, asOf: Date) async throws
  func remove(publicationURI: String, observedAt: Date) async throws
}

extension WirePublicationMetadataStoring {
  func loadForCaching(publicationURI: String, asOf: Date) async throws -> WirePublicationCacheValue {
    .init(metadata: try await load(publicationURI: publicationURI, asOf: asOf),
      expiresAt: asOf.addingTimeInterval(60))
  }
}
