import Foundation
import PostgresNIO
import Testing

@testable import WireWorkerCore

extension WirePostgresIntegrationTests {
  @Test("malformed publication metadata is retained terminally after rollback without repeated retries",
    arguments: [false, true])
  func malformedPublicationTransactionIsTerminal(snapshot: Bool) async throws {
    try await WireSourceVersionFixture.run(collection: "site.standard.publication") { fixture in
      let base = fixture.base
      try await fixture.insert(sequence: 1, revision: WireSourceVersionFixture.olderRevision,
        snapshot: snapshot)
      // The envelope is valid; failure occurs inside the projection transaction.
      let path = snapshot ? "{snapshot,record,url}" : "{commit,record,url}"
      try await base.pool.query(
        """
        UPDATE wire_ingestion_inbox SET payload = payload #- \(path)::text[]
        WHERE environment = \(base.environment) AND seq = 1
        """, logger: base.logger)
      #expect(try await fixture.apply(sequence: 1) == .terminal)
      #expect(try await base.scalar(
        """
        SELECT count(*)::bigint FROM wire_ingestion_inbox
        WHERE environment = \(base.environment) AND seq = 1
          AND status = 'dead_letter' AND failure_category = 'malformed_event'
          AND attempt_count = 1 AND applied_at IS NULL AND payload IS NOT NULL
        """) == 1)
      #expect(try await base.scalar(
        "SELECT count(*)::bigint FROM wire_standard_record_fences WHERE environment = \(base.environment)") == 0)
      #expect(try await fixture.projectionExists() == false)
      // The malformed predecessor must not block the next valid repository event.
      try await fixture.insert(sequence: 2, revision: WireSourceVersionFixture.newerRevision,
        snapshot: snapshot)
      #expect(try await fixture.apply(sequence: 2) == .applied)
      #expect(try await fixture.projectionExists())
    }
  }
}
