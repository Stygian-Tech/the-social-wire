import Foundation

protocol WireLinkMetadataStoring: Sendable {
  func seedEmbedded(
    canonicalKey: String,
    metadata: WireLinkMetadata,
    asOf: Date
  ) async throws
  func claimDue(limit: Int, asOf: Date) async throws -> [WireLinkMetadataTarget]
  func markNotModified(
    canonicalKey: String,
    etag: String?,
    lastModified: String?,
    asOf: Date
  ) async throws
  func store(
    canonicalKey: String,
    metadata: WireLinkMetadata,
    asOf: Date
  ) async throws
  func markFailure(
    canonicalKey: String,
    negative: Bool,
    asOf: Date
  ) async throws
  func healthSnapshot(asOf: Date) async throws -> WireEnrichmentHealthSnapshot?
}

extension WireLinkMetadataStoring {
  func healthSnapshot(asOf: Date) async throws -> WireEnrichmentHealthSnapshot? { nil }
}
