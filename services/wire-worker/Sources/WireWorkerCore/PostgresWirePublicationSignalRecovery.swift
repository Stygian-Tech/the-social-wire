import Foundation
import Logging
import PostgresNIO
import WireCore

/// Recreates only activity whose original transport and event time survived in
/// logged version fences. Completing this job never means archive replay ended.
struct PostgresWirePublicationSignalRecovery: Sendable {
  let pool: PostgresClient
  let logger: Logger
  let actorHasher: WireActorHasher
  let scope: WireInboxSourceScope

  init(pool: PostgresClient, logger: Logger, actorSecret: String, scope: WireInboxSourceScope) throws {
    self.pool = pool
    self.logger = logger
    self.actorHasher = try WireActorHasher(secret: Data(actorSecret.utf8))
    self.scope = scope
  }

  /// The cursor and inserted signals commit together; failures retry the same
  /// bounded page. Account/source locks match the ingestion lock order.
  func runBatch(asOf: Date, limit: Int = 100) async throws -> Int {
    try await pool.withTransaction(logger: logger) { connection in
      try await connection.query(
        """
        UPDATE wire_publication_signal_recovery_jobs job SET replay_completed_at = \(asOf)
        FROM appview_jetstream_checkpoints checkpoint, wire_ingestion_inbox_epochs epoch
        WHERE job.environment = \(scope.environment) AND job.source_generation = ANY(\(scope.sourceGenerations))
          AND job.completed_at IS NOT NULL AND job.replay_completed_at IS NULL
          AND checkpoint.environment = job.environment AND checkpoint.source_generation = job.source_generation
          AND checkpoint.replay_state = 'live'
          AND checkpoint.last_staged_seq >= checkpoint.replay_sealed_seq
          AND epoch.environment = job.environment AND epoch.source_generation = job.source_generation
          AND epoch.initialized_at = job.inbox_initialized_at
          AND NOT EXISTS (
            SELECT 1 FROM wire_ingestion_inbox inbox
            WHERE inbox.environment = job.environment AND inbox.source_generation = job.source_generation
              AND inbox.status IN ('pending', 'leased', 'retry', 'deferred', 'dead_letter')
          )
        """, logger: logger)
      let jobs = try await connection.query(
        """
        SELECT job.source_generation, job.inbox_initialized_at, job.maximum_source_seq,
               job.after_event_time, job.after_source_uri
        FROM wire_publication_signal_recovery_jobs job
        JOIN wire_ingestion_inbox_epochs epoch
          ON epoch.environment = job.environment AND epoch.source_generation = job.source_generation
          AND epoch.initialized_at = job.inbox_initialized_at
        WHERE job.environment = \(scope.environment)
          AND job.source_generation = ANY(\(scope.sourceGenerations)) AND job.completed_at IS NULL
        ORDER BY job.inbox_initialized_at
        LIMIT 1 FOR UPDATE OF job SKIP LOCKED
        """, logger: logger)
      var job: (String, Date, Int64, Date, String)?
      for try await row in jobs { job = try row.decode((String, Date, Int64, Date, String).self) }
      guard let job else { return 0 }
      let cutoff = asOf.addingTimeInterval(-WireDataPolicy.signalRetention)
      let rows = try await connection.query(
        """
        SELECT event_time, source_uri
        FROM wire_standard_record_fences
        WHERE environment = \(scope.environment) AND source_generation = \(job.0)
          AND activity_recorded AND operation <> 'delete' AND event_time > \(cutoff)
          AND updated_at < \(job.1) AND seq <= \(job.2) AND event_kind = 'commit'
          AND (event_time, source_uri) > (\(job.3), \(job.4))
        ORDER BY event_time, source_uri LIMIT \(max(1, min(limit, 500)))
        """, logger: logger)
      var page: [(Date, String)] = []
      for try await row in rows { page.append(try row.decode((Date, String).self)) }
      for (_, uri) in page {
        let parts = uri.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count == 4, parts[0] == "at:",
          ["site.standard.document", "site.standard.entry"].contains(String(parts[2])) else { continue }
        let repo = String(parts[1])
        let accountLock = "wire-recommendation-account:\(scope.environment):\(repo)"
        try await connection.query(
          "SELECT pg_advisory_xact_lock(hashtextextended(\(accountLock), 0))", logger: logger)
        try await connection.query(
          "SELECT pg_advisory_xact_lock(hashtextextended(\(uri), 0))", logger: logger)
        let current = try await connection.query(
          """
          SELECT fence.seq, fence.source_host, fence.cursor_kind, fence.event_time,
                 alias.canonical_key
          FROM wire_standard_record_fences fence
          JOIN appview_jetstream_checkpoints checkpoint
            ON checkpoint.environment = fence.environment
            AND checkpoint.source_generation = fence.source_generation
            AND checkpoint.source_host = fence.source_host AND checkpoint.cursor_kind = fence.cursor_kind
          JOIN wire_item_aliases alias ON alias.alias_key = fence.source_uri AND alias.expires_at > \(asOf)
          JOIN wire_items item ON item.canonical_key = alias.canonical_key AND item.expires_at > \(asOf)
          WHERE fence.environment = \(scope.environment) AND fence.source_generation = \(job.0)
            AND fence.source_uri = \(uri) AND fence.seq <= \(job.2)
            AND fence.updated_at < \(job.1) AND fence.event_kind = 'commit'
            AND fence.activity_recorded AND fence.operation <> 'delete'
            AND fence.event_time > \(cutoff) AND fence.event_time <= \(asOf)
            AND NOT EXISTS (
              SELECT 1 FROM wire_recommendation_account_fences account
              WHERE account.environment = fence.environment AND account.repo_did = \(repo)
                AND (NOT account.active OR account.inactive_through >= fence.event_time)
            )
          """, logger: logger)
        for try await row in current {
          let value = try row.decode((Int64, String, String, Date, String).self)
          let actorHash = try actorHasher.hash(repo)
          let eventKey = "\(scope.environment):\(job.0):\(value.0)"
          let transportKey = PostgresWireInboxProcessor.transportEventKey(
            environment: scope.environment, sourceHost: value.1, cursorKind: value.2, sequence: value.0)
          try await connection.query(
            "SELECT ensure_wire_signal_event_partition((\(value.3) AT TIME ZONE 'UTC')::date)", logger: logger)
          // Never replace any source signal. A concurrent replay/newer mutation
          // remains authoritative, including changes after the snapshot cutoff.
          try await connection.query(
            """
            INSERT INTO wire_signal_events
              (event_key, transport_event_key, canonical_key, signal_kind, actor_key_hash,
               source_uri, source_collection, source_action, occurred_at, expires_at)
            SELECT \(eventKey), \(transportKey), \(value.4), 'publication', \(actorHash),
                   \(uri), \(String(parts[2])), 'publication', \(value.3),
                   \(value.3.addingTimeInterval(WireDataPolicy.signalRetention))
            WHERE NOT EXISTS (SELECT 1 FROM wire_signal_events WHERE source_uri = \(uri))
            ON CONFLICT DO NOTHING
            """, logger: logger)
        }
      }
      if let last = page.last {
        try await connection.query(
          """
          UPDATE wire_publication_signal_recovery_jobs
          SET after_event_time = \(last.0), after_source_uri = \(last.1)
          WHERE environment = \(scope.environment) AND source_generation = \(job.0)
            AND inbox_initialized_at = \(job.1)
          """, logger: logger)
      } else {
        try await connection.query(
          """
          UPDATE wire_publication_signal_recovery_jobs SET completed_at = \(asOf)
          WHERE environment = \(scope.environment) AND source_generation = \(job.0)
            AND inbox_initialized_at = \(job.1)
          """, logger: logger)
      }
      return page.count
    }
  }
}
