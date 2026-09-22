import Foundation
import PostgresNIO
import Testing

@testable import ThinAppViewCore

extension PostgresJetstreamInboxIntegrationTests {
  @Test("latest boundary selection matches full history with exact overrides and scope and position exclusions")
  func latestPDSBoundarySelectionParity() async throws {
    try await PostgresInboxFixture.withFixture { fixture in
      let viewer = fixture.sourceGeneration + "-boundary-viewer"
      let author = fixture.sourceGeneration + "-boundary-author"
      let at = Date(timeIntervalSince1970: 1_789_000_000)
      func execute(_ query: PostgresQuery) async throws {
        for try await _ in try await fixture.pool.query(query, logger: fixture.logger) {}
      }
      func cleanup() async throws {
        try await execute("DELETE FROM appview_pds_read_state_exact WHERE viewer_did = \(viewer)")
        try await execute("DELETE FROM appview_pds_read_state_boundaries WHERE viewer_did = \(viewer)")
        try await execute("DELETE FROM appview_pds_read_state_authority WHERE viewer_did = \(viewer)")
      }
      do {
        try await execute("""
          INSERT INTO appview_pds_read_state_authority (viewer_did, manifest, manifest_cid)
          VALUES (\(viewer), '{}'::jsonb, 'verified')
          """)
        try await execute("""
          INSERT INTO appview_pds_read_state_boundaries
            (viewer_did, rule_key, sequence, is_read, acted_at, publication_id,
             author_did, scope_keys, boundary_at, boundary_uri)
          SELECT \(viewer), n::text, n, n % 2 = 0, \(at), 'publication', \(author),
            CASE WHEN n % 3 = 0 THEN '[]'::jsonb ELSE '["site"]'::jsonb END,
            \(at), 'b'
          FROM generate_series(1, 2000) n
          """)
        // Newer rules that do not match must not hide an older applicable rule.
        try await execute("""
          INSERT INTO appview_pds_read_state_boundaries
            (viewer_did, rule_key, sequence, is_read, acted_at, publication_id,
             author_did, scope_keys, boundary_at, boundary_uri)
          VALUES
            (\(viewer), 'other-site', 2100, FALSE, \(at), 'publication', \(author), '["other"]', \(at), NULL),
            (\(viewer), 'other-author', 2200, FALSE, \(at), 'publication', 'other-author', '[]', \(at), NULL),
            (\(viewer), 'older-position', 2300, FALSE, \(at), 'publication', \(author), '[]', \(at.addingTimeInterval(-10)), NULL)
          """)
        try await execute("""
          INSERT INTO appview_pds_read_state_exact (viewer_did, subject_uri, sequence, is_read, acted_at)
          VALUES (\(viewer), 'a', 2500, FALSE, \(at)), (\(viewer), 'b', 1, FALSE, \(at)),
            (\(viewer), 'z', 2600, TRUE, \(at))
          """)
        let rows = try await fixture.pool.query("""
          WITH candidates AS (
            SELECT subject, site, position_at, author FROM
              unnest(ARRAY['a','b','c','z']) subject
              CROSS JOIN unnest(ARRAY['site','other','absent']) site
              CROSS JOIN unnest(ARRAY[\(at.addingTimeInterval(-20)), \(at), \(at.addingTimeInterval(0.000001))]) position_at
              CROSS JOIN unnest(ARRAY[\(author), 'absent-author']) author
          )
          SELECT appview_pds_entry_is_read(\(viewer), candidate.subject, candidate.author, candidate.site, candidate.position_at),
            COALESCE((SELECT is_read FROM (
              SELECT sequence, is_read FROM appview_pds_read_state_exact
              WHERE viewer_did = \(viewer) AND subject_uri = candidate.subject
              UNION ALL
              SELECT sequence, is_read FROM appview_pds_read_state_boundaries
              WHERE viewer_did = \(viewer) AND author_did = candidate.author
                AND (scope_keys = '[]'::jsonb OR scope_keys ? candidate.site)
                AND (candidate.position_at < boundary_at OR (candidate.position_at = boundary_at
                  AND (boundary_uri IS NULL OR candidate.subject COLLATE "C" <= boundary_uri COLLATE "C")))
            ) actions ORDER BY sequence DESC LIMIT 1), FALSE)
          FROM candidates candidate
          """, logger: fixture.logger)
        var count = 0
        for try await row in rows {
          let (actual, expected) = try row.decode((Bool, Bool).self)
          #expect(actual == expected)
          count += 1
        }
        #expect(count == 72)
        try await execute("UPDATE appview_pds_read_state_authority SET projection_ready = FALSE WHERE viewer_did = \(viewer)")
        do {
          try await execute("SELECT appview_pds_entry_is_read(\(viewer), 'a', \(author), 'site', \(at))")
          Issue.record("Unavailable PDS projection returned a read state")
        } catch let error as PSQLError {
          #expect(error.serverInfo?[.sqlState] == "55000")
        }
        try await execute("UPDATE appview_pds_read_state_authority SET manifest = NULL, manifest_cid = NULL WHERE viewer_did = \(viewer)")
        let legacy = try await fixture.pool.query("SELECT appview_pds_entry_is_read(\(viewer), 'a', \(author), 'site', \(at)) IS NULL", logger: fixture.logger)
        for try await row in legacy { #expect(try row.decode(Bool.self)) }
      } catch {
        try? await cleanup()
        throw error
      }
      try await cleanup()
    }
  }
}
