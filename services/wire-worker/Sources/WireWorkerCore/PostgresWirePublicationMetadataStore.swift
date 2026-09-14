import Foundation
import Logging
import PostgresNIO
import WireCore

struct PostgresWirePublicationMetadataStore: WirePublicationMetadataStoring {
  let pool: PostgresClient
  let logger: Logger

  func load(publicationURI: String, asOf: Date) async throws -> WirePublicationMetadata? {
    try await loadForCaching(publicationURI: publicationURI, asOf: asOf).metadata
  }

  func loadForCaching(publicationURI: String, asOf: Date) async throws -> WirePublicationCacheValue {
    let rows = try await pool.query(
      """
      SELECT publication_uri, repo_did, site_url, name, expires_at
      FROM wire_publications
      WHERE publication_uri = \(publicationURI) AND expires_at > \(asOf)
      LIMIT 1
      """,
      logger: logger
    )
    for try await row in rows {
      let value = try row.decode((String, String, String, String, Date).self)
      return WirePublicationCacheValue(metadata: WirePublicationMetadata(
        publicationURI: value.0,
        repoDID: value.1,
        siteURL: value.2,
        name: value.3
      ), expiresAt: value.4)
    }
    return .init(metadata: nil, expiresAt: asOf.addingTimeInterval(15))
  }

  func upsert(_ metadata: WirePublicationMetadata, asOf: Date) async throws {
    try await upsert(metadata, asOf: asOf, connection: nil)
  }

  func upsert(
    _ metadata: WirePublicationMetadata, asOf: Date, connection: PostgresConnection?, versionIsFenced: Bool = false
  ) async throws {
    let expiresAt = asOf.addingTimeInterval(WireDataPolicy.itemRetention)
    let query: PostgresQuery =
      """
      INSERT INTO wire_publications
        (publication_uri, repo_did, site_url, name, metadata,
         first_seen_at, last_seen_at, expires_at, updated_at)
      VALUES
        (\(metadata.publicationURI), \(metadata.repoDID), \(metadata.siteURL), \(metadata.name),
         '{}'::jsonb, \(asOf), \(asOf), \(expiresAt), \(asOf))
      ON CONFLICT (publication_uri) DO UPDATE SET
        repo_did = EXCLUDED.repo_did, site_url = EXCLUDED.site_url, name = EXCLUDED.name,
        last_seen_at = EXCLUDED.last_seen_at, expires_at = EXCLUDED.expires_at,
        updated_at = EXCLUDED.updated_at
      WHERE (\(versionIsFenced) OR wire_publications.last_seen_at <= EXCLUDED.last_seen_at)
        AND (wire_publications.repo_did, wire_publications.site_url, wire_publications.name,
             wire_publications.last_seen_at, wire_publications.expires_at)
          IS DISTINCT FROM (EXCLUDED.repo_did, EXCLUDED.site_url, EXCLUDED.name,
                            EXCLUDED.last_seen_at, EXCLUDED.expires_at)
      """
    if let connection {
      try await connection.query(query, logger: logger)
    } else {
      try await pool.query(query, logger: logger)
    }
  }

  func remove(publicationURI: String, observedAt: Date) async throws {
    try await remove(publicationURI: publicationURI, observedAt: observedAt, connection: nil)
  }

  func remove(
    publicationURI: String, observedAt: Date, connection: PostgresConnection?, versionIsFenced: Bool = false
  ) async throws {
    let query: PostgresQuery =
      "DELETE FROM wire_publications WHERE publication_uri = \(publicationURI) AND (\(versionIsFenced) OR last_seen_at <= \(observedAt))"
    if let connection {
      try await connection.query(query, logger: logger)
    } else {
      try await pool.query(query, logger: logger)
    }
  }
}
