import Foundation

protocol WireLinkMetadataStoring: Sendable {
  func seedEmbedded(
    canonicalKey: String,
    metadata: WireLinkMetadata,
    asOf: Date
  ) async throws
  func claimDue(limit: Int, asOf: Date) async throws -> [WireLinkMetadataTarget]
  func renewClaim(_ target: WireLinkMetadataTarget, asOf: Date) async throws -> WireLinkMetadataTarget?
  func markNotModified(
    canonicalKey: String,
    etag: String?,
    lastModified: String?,
    asOf: Date,
    leaseExpiresAt: Date?
  ) async throws
  func store(
    canonicalKey: String,
    metadata: WireLinkMetadata,
    asOf: Date,
    leaseExpiresAt: Date?
  ) async throws
  func markFailure(
    canonicalKey: String,
    negative: Bool,
    asOf: Date,
    leaseExpiresAt: Date?
  ) async throws
  func healthSnapshot(asOf: Date) async throws -> WireEnrichmentHealthSnapshot?
}

extension WireLinkMetadataStoring {
  // Direct metadata imports can remain unleased. Enrichment outcomes always carry
  // the lease returned by claimDue so a late fetch cannot replace newer work.
  func markNotModified(
    canonicalKey: String, etag: String?, lastModified: String?, asOf: Date
  ) async throws {
    try await markNotModified(
      canonicalKey: canonicalKey, etag: etag, lastModified: lastModified,
      asOf: asOf, leaseExpiresAt: nil)
  }

  func store(canonicalKey: String, metadata: WireLinkMetadata, asOf: Date) async throws {
    try await store(canonicalKey: canonicalKey, metadata: metadata, asOf: asOf, leaseExpiresAt: nil)
  }

  func markFailure(canonicalKey: String, negative: Bool, asOf: Date) async throws {
    try await markFailure(canonicalKey: canonicalKey, negative: negative, asOf: asOf, leaseExpiresAt: nil)
  }

  func healthSnapshot(asOf: Date) async throws -> WireEnrichmentHealthSnapshot? { nil }
}
