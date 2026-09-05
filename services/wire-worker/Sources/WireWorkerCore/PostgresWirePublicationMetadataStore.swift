import Foundation
import Logging
import PostgresNIO
import WireCore

struct PostgresWirePublicationMetadataStore: WirePublicationMetadataStoring {
  let pool: PostgresClient
  let logger: Logger

  func load(publicationURI: String, asOf: Date) async throws -> WirePublicationMetadata? {
    let rows = try await pool.query(
      """
      SELECT publication_uri, repo_did, site_url, name
      FROM wire_publications
      WHERE publication_uri = \(publicationURI) AND expires_at > \(asOf)
      LIMIT 1
      """,
      logger: logger
    )
    for try await row in rows {
      let value = try row.decode((String, String, String, String).self)
      return WirePublicationMetadata(
        publicationURI: value.0,
        repoDID: value.1,
        siteURL: value.2,
        name: value.3
      )
    }
    return nil
  }

  func upsert(_ metadata: WirePublicationMetadata, asOf: Date) async throws {
    let expiresAt = asOf.addingTimeInterval(WireDataPolicy.itemRetention)
    try await pool.query(
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
      WHERE wire_publications.last_seen_at <= EXCLUDED.last_seen_at
        AND (wire_publications.repo_did, wire_publications.site_url, wire_publications.name,
             wire_publications.last_seen_at, wire_publications.expires_at)
          IS DISTINCT FROM (EXCLUDED.repo_did, EXCLUDED.site_url, EXCLUDED.name,
                            EXCLUDED.last_seen_at, EXCLUDED.expires_at)
      """,
      logger: logger
    )
  }

  func remove(publicationURI: String, observedAt: Date) async throws {
    try await pool.query(
      "DELETE FROM wire_publications WHERE publication_uri = \(publicationURI) AND last_seen_at <= \(observedAt)",
      logger: logger
    )
  }
}
