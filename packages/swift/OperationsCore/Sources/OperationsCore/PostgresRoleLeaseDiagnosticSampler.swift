import Foundation
import Logging
import PostgresNIO

/// Failure-only diagnostics use a caller-owned, separate min-zero/max-one pool. They never
/// compete for Coordinator control connections or expose query text, parameters or raw errors.
public actor PostgresRoleLeaseDiagnosticSampler {
  private let environment: String
  private let logger: Logger
  private let load: @Sendable (String) async throws -> RoleLeaseDiagnosticSnapshot
  private let monotonicNow: @Sendable () -> ContinuousClock.Instant
  private let processNow: @Sendable () -> Date
  private var lastCaptures: [String: ContinuousClock.Instant] = [:]
  private var isRunning = false

  public init(pool: PostgresClient, environment: String, logger: Logger) {
    let queryLogger = Logger(label: "lease-diagnostic-sql", factory: { _ in SwiftLogNoOpLogHandler() })
    self.init(
      environment: environment, logger: logger,
      load: { role in
        try await Self.readSnapshot(pool: pool, environment: environment, role: role, logger: queryLogger)
      })
  }

  init(
    environment: String,
    logger: Logger,
    monotonicNow: @escaping @Sendable () -> ContinuousClock.Instant = { .now },
    processNow: @escaping @Sendable () -> Date = { Date() },
    load: @escaping @Sendable (String) async throws -> RoleLeaseDiagnosticSnapshot
  ) {
    self.environment = environment
    self.logger = logger
    self.monotonicNow = monotonicNow
    self.processNow = processNow
    self.load = load
  }

  public func capture(role: String) async {
    guard !Task.isCancelled, !isRunning,
      Self.validScope(environment, limit: 32), Self.validScope(role, limit: 128)
    else { return }
    let start = monotonicNow()
    lastCaptures = lastCaptures.filter { $0.value.duration(to: start) < .seconds(60) }
    // Bound state even if an erroneous caller supplies unbounded distinct role names.
    guard lastCaptures[role] == nil, lastCaptures.count < 64 else { return }
    lastCaptures[role] = start
    isRunning = true
    defer { isRunning = false }
    var metadata: Logger.Metadata = ["environment": .string(environment), "role": .string(role)]
    do {
      let snapshot = try await load(role)
      metadata.merge(snapshot.metadata) { _, value in value }
      metadata["availability"] = "available"
    } catch {
      // Classification is a closed enum; server detail, SQL and bound values never reach logs.
      metadata["availability"] = "unavailable"
      metadata["failure"] = .string(RoleLeaseFailure.classify(error).rawValue)
    }
    metadata["process_time"] = .string(processNow().ISO8601Format())
    metadata["capture_ms"] = .stringConvertible(start.duration(to: monotonicNow()) / .milliseconds(1))
    logger.warning("Coordinator lease failure diagnostic", metadata: metadata)
  }

  private static func validScope(_ value: String, limit: Int) -> Bool {
    !value.isEmpty && value.utf8.count <= limit && RoleLeaseDiagnosticSnapshot.safeLabel(value, limit: limit) == value
  }

  static func readSnapshot(
    pool: PostgresClient, environment: String, role: String, logger: Logger
  ) async throws -> RoleLeaseDiagnosticSnapshot {
    try await PostgresRoleLeaseBudget.withTransaction(pool: pool, logger: logger) { connection in
      _ = try await PostgresRoleLeaseBudget.query("SET TRANSACTION READ ONLY", connection: connection, logger: logger)
      let rows = try await PostgresRoleLeaseBudget.query(
        """
        WITH activity AS MATERIALIZED (
          SELECT pid, state, wait_event_type, wait_event FROM pg_stat_activity
          WHERE datname = current_database() AND backend_type = 'client backend'
            AND pid <> pg_backend_pid()
        ), sampled AS MATERIALIZED (
          SELECT pid, wait_event_type, wait_event, pg_blocking_pids(pid) AS blockers
          FROM activity WHERE wait_event_type IS NOT NULL OR state = 'active'
          ORDER BY (wait_event_type = 'Lock') DESC NULLS LAST, (state = 'active') DESC, pid LIMIT 16
        ), lease AS (
          SELECT owner_id, fencing_token, lease_expires_at FROM operations_role_leases
          WHERE environment = \(environment) AND role = \(role)
        )
        SELECT clock_timestamp(), lease.owner_id, lease.fencing_token, lease.lease_expires_at,
          (SELECT COUNT(*)::bigint FROM activity),
          (SELECT COUNT(*)::bigint FROM activity WHERE state = 'active'),
          (SELECT COUNT(*)::bigint FROM activity WHERE state = 'idle'),
          (SELECT COUNT(*)::bigint FROM activity WHERE wait_event_type IS NOT NULL),
          COALESCE((SELECT jsonb_agg(jsonb_build_object(
            'pid', pid, 'waitEventType', wait_event_type, 'waitEvent', wait_event,
            'blockingPIDs', blockers[1:16], 'blockersTruncated', cardinality(blockers) > 16
          )) FROM sampled), '[]'::jsonb)::text,
          (SELECT COUNT(*)::bigint FROM activity WHERE wait_event_type IS NOT NULL OR state = 'active')
        FROM (SELECT 1) AS present LEFT JOIN lease ON TRUE
        """, connection: connection, logger: logger)
      for row in rows {
        let value = try row.decode((Date, String?, Int64?, Date?, Int64, Int64, Int64, Int64, String, Int64).self)
        return RoleLeaseDiagnosticSnapshot(
          databaseTime: value.0, ownerID: value.1, fencingToken: value.2, expiresAt: value.3,
          totalConnections: value.4, activeConnections: value.5, idleConnections: value.6,
          waitingConnections: value.7,
          backends: try JSONDecoder().decode([RoleLeaseDiagnosticSnapshot.Backend].self, from: Data(value.8.utf8)),
          sampledBackendCandidates: value.9)
      }
      throw RoleLeaseFailure.unknown
    }
  }
}
