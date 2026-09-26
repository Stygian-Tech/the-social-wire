import Foundation
import PostgresNIO
import ReadStateCore

extension PostgresThinAppViewStore {
  func persistPDSProjection(viewerDid: String, operations: [ReadStateOperation],
                           incremental: Bool, on connection: PostgresConnection) async throws {
    // These identifiers are fixed constants, never supplied by a viewer.
    let exactTable = incremental ? "appview_pds_read_state_exact" : "tsw_pds_exact_stage"
    let boundaryTable = incremental ? "appview_pds_read_state_boundaries" : "tsw_pds_boundary_stage"
    if !incremental {
      try await connection.query("CREATE TEMP TABLE tsw_pds_exact_stage (LIKE appview_pds_read_state_exact INCLUDING ALL) ON COMMIT DROP", logger: logger)
      try await connection.query("CREATE TEMP TABLE tsw_pds_boundary_stage (LIKE appview_pds_read_state_boundaries INCLUDING ALL) ON COMMIT DROP", logger: logger)
    }
    for start in stride(from: 0, to: operations.count, by: 250) {
      try Task.checkCancellation()
      let batch = Array(operations[start..<min(start + 250, operations.count)])
      let json = String(decoding: try JSONEncoder().encode(batch), as: UTF8.self)
      try await connection.query(
        """
        INSERT INTO \(unescaped: exactTable) AS target (viewer_did, subject_uri, sequence, is_read, acted_at)
        SELECT DISTINCT ON (subject.uri) \(viewerDid), subject.uri,
          (operation->>'sequence')::bigint, operation->>'state' = 'read', (operation->>'actedAt')::timestamptz
        FROM jsonb_array_elements(\(json)::jsonb) operation
        CROSS JOIN LATERAL jsonb_array_elements_text(operation->'subjectUris') subject(uri)
        ORDER BY subject.uri, (operation->>'sequence')::bigint DESC
        ON CONFLICT (viewer_did, subject_uri) DO UPDATE SET
          sequence = EXCLUDED.sequence, is_read = EXCLUDED.is_read, acted_at = EXCLUDED.acted_at
        WHERE EXCLUDED.sequence > target.sequence
        """, logger: logger)
      try await connection.query(
        """
        INSERT INTO \(unescaped: boundaryTable)
          (viewer_did, rule_key, sequence, is_read, acted_at,
           publication_id, author_did, scope_keys, boundary_at, boundary_uri)
        SELECT DISTINCT \(viewerDid), encode(sha256(convert_to(boundary.value::text, 'UTF8')), 'hex'),
          (item.operation->>'sequence')::bigint, item.operation->>'state' = 'read',
          (item.operation->>'actedAt')::timestamptz,
          boundary.value #>> '{scope,publicationId}', boundary.value #>> '{scope,authorDid}',
          boundary.value #> '{scope,publicationSiteKeys}',
          (boundary.value->>'createdAt')::timestamptz, boundary.value->>'entryId'
        FROM jsonb_array_elements(\(json)::jsonb) item(operation)
        CROSS JOIN LATERAL jsonb_array_elements(item.operation->'boundaries') boundary(value)
        ON CONFLICT (viewer_did, sequence, rule_key) DO NOTHING
        """, logger: logger)
    }
    guard !incremental else { return }
    // All replacement statements share the authority lock and transaction.
    // Readers see the previous complete state until the entire diff commits.
    try await connection.query(
      """
      INSERT INTO appview_pds_read_state_exact AS target SELECT * FROM tsw_pds_exact_stage
      ON CONFLICT (viewer_did, subject_uri) DO UPDATE SET
        sequence = EXCLUDED.sequence, is_read = EXCLUDED.is_read, acted_at = EXCLUDED.acted_at
      WHERE (target.sequence, target.is_read, target.acted_at)
        IS DISTINCT FROM (EXCLUDED.sequence, EXCLUDED.is_read, EXCLUDED.acted_at)
      """, logger: logger)
    try await connection.query(
      """
      INSERT INTO appview_pds_read_state_boundaries AS target SELECT * FROM tsw_pds_boundary_stage
      ON CONFLICT (viewer_did, sequence, rule_key) DO UPDATE SET
        is_read = EXCLUDED.is_read, acted_at = EXCLUDED.acted_at
      WHERE (target.is_read, target.acted_at) IS DISTINCT FROM (EXCLUDED.is_read, EXCLUDED.acted_at)
      """, logger: logger)
    try await connection.query(
      """
      DELETE FROM appview_pds_read_state_exact target WHERE viewer_did = \(viewerDid)
        AND NOT EXISTS (SELECT 1 FROM tsw_pds_exact_stage incoming
          WHERE incoming.viewer_did = target.viewer_did AND incoming.subject_uri = target.subject_uri)
      """, logger: logger)
    try await connection.query(
      """
      DELETE FROM appview_pds_read_state_boundaries target WHERE viewer_did = \(viewerDid)
        AND NOT EXISTS (SELECT 1 FROM tsw_pds_boundary_stage incoming
          WHERE incoming.viewer_did = target.viewer_did AND incoming.sequence = target.sequence
            AND incoming.rule_key = target.rule_key)
      """, logger: logger)
  }
}
