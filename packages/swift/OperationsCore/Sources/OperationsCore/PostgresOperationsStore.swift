import Foundation
import Logging
import PostgresNIO

public actor PostgresOperationsStore: OperationsStore {
  public nonisolated let environment: String
  private let pool: PostgresClient
  private let logger: Logger
  private let encoder = JSONEncoder()
  private let decoder = JSONDecoder()
  private let backfillFingerprintSecret: String?
  private var lastDatabaseObservation: (transactions: Int64, statsResetAt: Date?, at: Date)?

  private enum PreparedTelemetry: Sendable {
    case metric(OperationsMetricSample, dimensionsJSON: String, dimensionsHash: String, bucket: Date)
    case event(OperationsEvent, attributesJSON: String)
    case span(TraceSpan, attributesJSON: String)
  }

  public init(
    pool: PostgresClient,
    environment: String,
    backfillFingerprintSecret: String? = nil,
    logger: Logger
  ) {
    self.pool = pool
    self.environment = environment
    self.backfillFingerprintSecret = backfillFingerprintSecret
    self.logger = logger
  }

  public func ping() async throws {
    let rows = try await pool.query("SELECT 1", logger: logger)
    for try await _ in rows { return }
  }

  public func fetchDatabaseObservability() async throws -> DatabaseObservabilitySnapshot? {
    let observedAt = Date()
    let summaryRows = try await pool.query(
      """
      SELECT
        pg_database_size(current_database())::bigint,
        numbackends::bigint,
        current_setting('max_connections')::bigint,
        (xact_commit + xact_rollback)::bigint,
        CASE
          WHEN (blks_hit + blks_read) = 0 THEN NULL::double precision
          ELSE blks_hit::double precision / (blks_hit + blks_read)::double precision
        END,
        stats_reset
      FROM pg_stat_database
      WHERE datname = current_database()
      """,
      logger: logger
    )
    var summary: (Int64, Int64, Int64, Int64, Double?, Date?)?
    for try await row in summaryRows {
      summary = try row.decode((Int64, Int64, Int64, Int64, Double?, Date?).self)
      break
    }
    guard let summary else { return nil }

    let activeQueryRows = try await pool.query(
      """
      SELECT COUNT(*)::bigint FROM pg_stat_activity
      WHERE datname = current_database() AND state = 'active' AND pid <> pg_backend_pid()
      """, logger: logger)
    var activeQueries: Int64 = 0
    for try await row in activeQueryRows { activeQueries = try row.decode(Int64.self); break }
    let transactionRate: Double?
    if let previous = lastDatabaseObservation,
      observedAt.timeIntervalSince(previous.at) > 0,
      previous.statsResetAt == summary.5,
      summary.3 >= previous.transactions
    {
      transactionRate = Double(summary.3 - previous.transactions)
        / observedAt.timeIntervalSince(previous.at)
    } else {
      transactionRate = nil
    }
    lastDatabaseObservation = (summary.3, summary.5, observedAt)

    let recordCountRows = try await pool.query(
      "SELECT COALESCE(SUM(n_live_tup), 0)::bigint FROM pg_stat_user_tables",
      logger: logger
    )
    var estimatedRecords: Int64 = 0
    for try await row in recordCountRows {
      estimatedRecords = try row.decode(Int64.self)
      break
    }

    let tableRows = try await pool.query(
      """
      SELECT schemaname, relname, n_live_tup::bigint
      FROM pg_stat_user_tables
      ORDER BY n_live_tup DESC, schemaname, relname
      LIMIT 10
      """,
      logger: logger
    )
    var topTables: [DatabaseTableRecordCount] = []
    for try await row in tableRows {
      let value = try row.decode((String, String, Int64).self)
      topTables.append(
        DatabaseTableRecordCount(schema: value.0, table: value.1, estimatedRecords: value.2))
    }

    return DatabaseObservabilitySnapshot(
      databaseSizeBytes: summary.0,
      activeConnections: summary.1,
      maxConnections: summary.2,
      transactionsTotal: summary.3,
      estimatedRecords: estimatedRecords,
      cacheHitRatio: summary.4,
      statsResetAt: summary.5,
      topTables: topTables,
      connectedBackends: summary.1,
      activeQueries: activeQueries,
      transactionRatePerSecond: transactionRate,
      observedAt: observedAt,
      evidenceAgeSeconds: 0
    )
  }

  public func upsertServiceState(_ state: OperationsServiceState) async throws {
    guard state.environment == environment else {
      throw OperationsStoreError.environmentMismatch(expected: environment, actual: state.environment)
    }
    let dependencies = try json(state.dependencyState)
    try await pool.query(
      """
      INSERT INTO operations_service_state
        (service, environment, instance_id, liveness, readiness, freshness, completeness,
         dependency_state, version, started_at, heartbeat_at)
      VALUES
        (\(state.service), \(state.environment), \(state.instanceId), \(state.liveness.rawValue),
         \(state.readiness.rawValue), \(state.freshness.rawValue), \(state.completeness.rawValue),
         \(dependencies)::jsonb, \(state.version), \(state.startedAt), \(state.heartbeatAt))
      ON CONFLICT (service, environment, instance_id) DO UPDATE SET
        liveness = EXCLUDED.liveness,
        readiness = EXCLUDED.readiness,
        freshness = EXCLUDED.freshness,
        completeness = EXCLUDED.completeness,
        dependency_state = EXCLUDED.dependency_state,
        version = EXCLUDED.version,
        heartbeat_at = EXCLUDED.heartbeat_at
      """,
      logger: logger
    )
  }

  public func listServiceStates() async throws -> [OperationsServiceState] {
    let rows = try await pool.query(
      """
      SELECT service, environment, instance_id, liveness, readiness, freshness, completeness,
             dependency_state::text, version, started_at, heartbeat_at
      FROM operations_service_state
      WHERE environment = \(environment) AND heartbeat_at > NOW() - INTERVAL '2 minutes'
      ORDER BY service, heartbeat_at DESC
      """,
      logger: logger
    )
    var result: [OperationsServiceState] = []
    for try await row in rows {
      let decoded = try row.decode(
        (String, String, String, String, String, String, String, String, String?, Date, Date).self
      )
      result.append(
        OperationsServiceState(
          service: decoded.0,
          environment: decoded.1,
          instanceId: decoded.2,
          liveness: OperationsHealthState(rawValue: decoded.3) ?? .unknown,
          readiness: OperationsHealthState(rawValue: decoded.4) ?? .unknown,
          freshness: OperationsHealthState(rawValue: decoded.5) ?? .unknown,
          completeness: OperationsHealthState(rawValue: decoded.6) ?? .unknown,
          dependencyState: decodeJSON([String: String].self, from: decoded.7) ?? [:],
          version: decoded.8,
          startedAt: decoded.9,
          heartbeatAt: decoded.10
        )
      )
    }
    return result
  }

  public func fetchStreamState(source: String) async throws -> IngestionStreamState? {
    let rows = try await pool.query(
      """
      SELECT *
      FROM appview_ingestion_stream_state
      WHERE environment = \(environment) AND source = \(source)
      LIMIT 1
      """,
      logger: logger
    )
    for try await row in rows {
      return try Self.streamState(row)
    }
    return nil
  }

  public func listStreamStates() async throws -> [IngestionStreamState] {
    let rows = try await pool.query(
      """
      SELECT *
      FROM appview_ingestion_stream_state WHERE environment = \(environment) ORDER BY source
      """, logger: logger)
    var result: [IngestionStreamState] = []
    for try await row in rows {
      result.append(try Self.streamState(row))
    }
    return result
  }

  public func markStreamConnected(source: String, at: Date) async throws {
    try await pool.query(
      """
      INSERT INTO appview_ingestion_stream_state
        (environment, source, connection_state, connected_at, transport_heartbeat_at,
         heartbeat_at, version)
      VALUES (\(environment), \(source), 'connected', \(at), \(at), \(at), 1)
      ON CONFLICT (environment, source) DO UPDATE SET
        connection_state = 'connected', connected_at = EXCLUDED.connected_at,
        transport_heartbeat_at = EXCLUDED.transport_heartbeat_at,
        heartbeat_at = EXCLUDED.heartbeat_at, version = appview_ingestion_stream_state.version + 1
      """,
      logger: logger
    )
  }

  public func markStreamTransportHeartbeat(source: String, at: Date) async throws {
    try await pool.query(
      """
      INSERT INTO appview_ingestion_stream_state
        (environment, source, connection_state, connected_at, transport_heartbeat_at,
         heartbeat_at, version)
      VALUES (\(environment), \(source), 'connected', \(at), \(at), \(at), 1)
      ON CONFLICT (environment, source) DO UPDATE SET
        connection_state = 'connected',
        transport_heartbeat_at = EXCLUDED.transport_heartbeat_at,
        heartbeat_at = EXCLUDED.heartbeat_at,
        version = appview_ingestion_stream_state.version + 1
      """,
      logger: logger
    )
  }

  public func markStreamDisconnected(source: String, reason: String, at: Date) async throws {
    try await pool.query(
      """
      INSERT INTO appview_ingestion_stream_state
        (environment, source, connection_state, last_disconnect_at, last_disconnect_reason, heartbeat_at, version)
      VALUES (\(environment), \(source), 'disconnected', \(at), \(String(reason.prefix(256))), \(at), 1)
      ON CONFLICT (environment, source) DO UPDATE SET
        connection_state = 'disconnected',
        last_disconnect_at = EXCLUDED.last_disconnect_at,
        last_disconnect_reason = EXCLUDED.last_disconnect_reason,
        heartbeat_at = EXCLUDED.heartbeat_at,
        version = appview_ingestion_stream_state.version + 1
      """,
      logger: logger
    )
  }

  public func recordStreamQueueObservation(
    source: String,
    depth: Int,
    capacity: Int,
    overflowTotal: Int64,
    observedAt: Date
  ) async throws {
    try await pool.query(
      """
      INSERT INTO appview_ingestion_stream_state
        (environment, source, queue_depth, queue_capacity, queue_overflow_total,
         queue_observed_at, heartbeat_at, version)
      VALUES (\(environment), \(source), \(max(0, depth)), \(max(1, capacity)),
              \(max(0, overflowTotal)), \(observedAt), \(observedAt), 1)
      ON CONFLICT (environment, source) DO UPDATE SET
        queue_depth = EXCLUDED.queue_depth,
        queue_capacity = EXCLUDED.queue_capacity,
        queue_overflow_total = GREATEST(
          appview_ingestion_stream_state.queue_overflow_total,
          EXCLUDED.queue_overflow_total
        ),
        queue_observed_at = EXCLUDED.queue_observed_at,
        heartbeat_at = EXCLUDED.heartbeat_at,
        version = appview_ingestion_stream_state.version + 1
      """,
      logger: logger
    )
  }

  public func markStreamIndexedMutation(source: String, at: Date) async throws {
    try await pool.query(
      """
      INSERT INTO appview_ingestion_stream_state
        (environment, source, last_indexed_mutation_at, heartbeat_at, version)
      VALUES (\(environment), \(source), \(at), \(at), 1)
      ON CONFLICT (environment, source) DO UPDATE SET
        last_indexed_mutation_at = EXCLUDED.last_indexed_mutation_at,
        heartbeat_at = EXCLUDED.heartbeat_at,
        version = appview_ingestion_stream_state.version + 1
      """,
      logger: logger
    )
  }

  public func markStreamProjectionWatermark(
    source: String,
    watermark: String,
    at: Date
  ) async throws {
    try await pool.query(
      """
      INSERT INTO appview_ingestion_stream_state
        (environment, source, projection_watermark, heartbeat_at, version)
      VALUES (\(environment), \(source), \(String(watermark.prefix(512))), \(at), 1)
      ON CONFLICT (environment, source) DO UPDATE SET
        projection_watermark = EXCLUDED.projection_watermark,
        heartbeat_at = EXCLUDED.heartbeat_at,
        version = appview_ingestion_stream_state.version + 1
      """,
      logger: logger
    )
  }

  public func markStreamValidationWatermark(
    source: String,
    watermark: String,
    at: Date
  ) async throws {
    try await pool.query(
      """
      INSERT INTO appview_ingestion_stream_state
        (environment, source, validation_watermark, heartbeat_at, version)
      VALUES (\(environment), \(source), \(String(watermark.prefix(512))), \(at), 1)
      ON CONFLICT (environment, source) DO UPDATE SET
        validation_watermark = EXCLUDED.validation_watermark,
        heartbeat_at = EXCLUDED.heartbeat_at,
        version = appview_ingestion_stream_state.version + 1
      """,
      logger: logger
    )
  }

  public func upsertJetstreamEndpoint(_ state: JetstreamEndpointState) async throws {
    try await pool.query(
      """
      INSERT INTO appview_jetstream_endpoints
        (environment, id, display_name, host, role, connection_state, last_connected_at,
         last_disconnected_at, last_error, connection_attempts, failover_count, updated_at)
      VALUES
        (\(environment), \(state.id), \(state.displayName), \(state.host), \(state.role.rawValue),
         \(state.connectionState.rawValue), \(state.lastConnectedAt), \(state.lastDisconnectedAt),
         \(state.lastError), \(state.connectionAttempts), \(state.failoverCount), \(state.updatedAt))
      ON CONFLICT (environment, id) DO UPDATE SET
        display_name = EXCLUDED.display_name,
        host = EXCLUDED.host,
        role = EXCLUDED.role,
        connection_state = EXCLUDED.connection_state,
        last_connected_at = EXCLUDED.last_connected_at,
        last_disconnected_at = EXCLUDED.last_disconnected_at,
        last_error = EXCLUDED.last_error,
        connection_attempts = EXCLUDED.connection_attempts,
        failover_count = EXCLUDED.failover_count,
        updated_at = EXCLUDED.updated_at,
        version = appview_jetstream_endpoints.version + 1
      """,
      logger: logger
    )
  }

  public func listJetstreamEndpoints() async throws -> [JetstreamEndpointState] {
    try await listJetstreamEndpoints(limit: 250, before: nil).items
  }

  public func listJetstreamEndpoints(limit: Int, before: String?) async throws
    -> OperationsPage<JetstreamEndpointState>
  {
    let limit = max(1, min(limit, 250))
    let beforeCursor = try Self.decodeCursor(before)
    let beforeDate = beforeCursor?.date
    let beforeId = beforeCursor?.id
    let rows = try await pool.query(
      """
      SELECT id, display_name, host, role, connection_state, last_connected_at,
             last_disconnected_at, last_error, connection_attempts, failover_count, updated_at, version
      FROM appview_jetstream_endpoints
      WHERE environment = \(environment)
        AND (\(beforeDate)::timestamptz IS NULL OR updated_at < \(beforeDate)::timestamptz
          OR (updated_at = \(beforeDate)::timestamptz AND id < \(beforeId)::text))
      ORDER BY updated_at DESC, id DESC
      LIMIT \(limit + 1)
      """,
      logger: logger
    )
    var result: [JetstreamEndpointState] = []
    for try await row in rows {
      let value = try row.decode(
        (String, String, String, String, String, Date?, Date?, String?, Int, Int, Date, Int).self
      )
      result.append(
        JetstreamEndpointState(
          id: value.0, environment: environment, displayName: value.1, host: value.2,
          role: JetstreamEndpointRole(rawValue: value.3) ?? .standby,
          connectionState: IngestionConnectionState(rawValue: value.4) ?? .unknown,
          lastConnectedAt: value.5, lastDisconnectedAt: value.6, lastError: value.7,
          connectionAttempts: value.8, failoverCount: value.9, updatedAt: value.10,
          version: value.11
        )
      )
    }
    let countRows = try await pool.query(
      "SELECT COUNT(*)::bigint FROM appview_jetstream_endpoints WHERE environment = \(environment)",
      logger: logger)
    var total = 0
    for try await row in countRows { total = Int(try row.decode(Int64.self)); break }
    let items = Array(result.prefix(limit))
    let next = result.count > limit
      ? items.last.map { OperationsPaginationCursor.encode(date: $0.updatedAt, id: $0.id) } : nil
    return OperationsPage(items: items, nextCursor: next, totalCount: total)
  }

  public func createCommand(
    action: OperationsCommandAction,
    operatorDid: String,
    auditNote: String,
    at: Date
  ) async throws -> OperationsWorkerCommand {
    let streamVersion = try await fetchStreamState(source: "jetstream")?.version ?? 0
    return try await createCommand(
      action: action, operatorDid: operatorDid, auditNote: auditNote,
      expectedStreamVersion: streamVersion, idempotencyKey: UUID().uuidString.lowercased(),
      requestId: nil, at: at)
  }

  public func createCommand(
    action: OperationsCommandAction,
    operatorDid: String,
    auditNote: String?,
    expectedStreamVersion: Int,
    idempotencyKey: String,
    requestId: String? = nil,
    at: Date
  ) async throws -> OperationsWorkerCommand {
    let actionName = "jetstream.reconnect_requested"
    let requestFingerprint = OperationsIdempotencyFingerprint.make(
      action: actionName, targetType: "command", targetId: nil,
      expectedVersion: expectedStreamVersion,
      fields: ["operatorDid": operatorDid, "auditNote": auditNote])
    let command = OperationsWorkerCommand(
      id: UUID().uuidString.lowercased(), environment: environment, action: action, status: .queued,
      requestedByDid: operatorDid, auditNote: auditNote.map { String($0.prefix(280)) },
      createdAt: at, updatedAt: at
    )
    return try await pool.withTransaction(logger: logger) { connection -> OperationsWorkerCommand in
      if let existing = try await existingIdempotency(
        connection: connection, key: idempotencyKey, action: actionName,
        targetType: "command", targetId: nil, requestFingerprint: requestFingerprint)
      {
        let replay = try replayIdempotencyResult(existing, as: OperationsWorkerCommand.self)
        let afterJSON = try json([
          "status": replay.status.rawValue, "version": String(replay.version),
          "targetId": replay.id,
        ])
        try await connection.query(
          Self.auditInsert(
            environment: environment, operatorDid: operatorDid, action: actionName,
            targetType: "command", targetId: replay.id, idempotencyKey: idempotencyKey,
            requestId: requestId, expectedVersion: expectedStreamVersion, note: auditNote,
            beforeJSON: "{}", afterJSON: afterJSON, outcome: "idempotent_replay", at: at),
          logger: logger)
        return replay
      }
      let versionRows = try await connection.query(
        "SELECT version FROM appview_ingestion_stream_state WHERE environment = \(environment) AND source = 'jetstream' FOR UPDATE",
        logger: logger)
      var actualVersion = 0
      for try await row in versionRows { actualVersion = try row.decode(Int.self); break }
      guard actualVersion == expectedStreamVersion else {
        throw OperationsStoreError.versionConflict(expected: expectedStreamVersion, actual: actualVersion)
      }
      try await connection.query(
        """
        INSERT INTO operations_commands
          (environment, id, action, status, requested_by_did, audit_note, created_at, updated_at,
           expires_at, version)
        VALUES (\(environment), \(command.id), \(action.rawValue), 'queued', \(operatorDid),
          \(command.auditNote), \(at), \(at), \(at.addingTimeInterval(365 * 86_400)), 0)
        """, logger: logger)
      try await insertIdempotency(
        connection: connection, key: idempotencyKey, action: actionName,
        targetType: "command", targetId: command.id, outcome: "queued",
        requestFingerprint: requestFingerprint,
        resultPayload: try json(command), at: at)
      try await connection.query(
        """
        INSERT INTO operations_audit_events
          (environment, id, operator_did, action, target_type, target_id, idempotency_key,
           request_id, expected_version, note, before_state, after_state, outcome,
           occurred_at, expires_at)
        VALUES (\(environment), \(UUID().uuidString.lowercased()), \(operatorDid),
          'jetstream.reconnect_requested', 'command', \(command.id), \(idempotencyKey),
          \(requestId), \(expectedStreamVersion), \(auditNote),
          \("{\"streamVersion\":\"\(actualVersion)\"}")::jsonb,
          \("{\"status\":\"queued\",\"version\":\"0\",\"targetId\":\"\(command.id)\"}")::jsonb,
          'queued', \(at), \(at.addingTimeInterval(365 * 86_400)))
        """, logger: logger)
      return command
    }
  }

  public func listCommands(limit: Int) async throws -> [OperationsWorkerCommand] {
    try await listCommands(limit: limit, before: nil).items
  }

  private func fetchCommand(id: String) async throws -> OperationsWorkerCommand? {
    let rows = try await pool.query(
      """
      SELECT id, action, status, requested_by_did, audit_note, claimed_by, lease_expires_at, failure_reason,
             created_at, updated_at, completed_at, version
      FROM operations_commands
      WHERE environment = \(environment) AND id = \(id)
      LIMIT 1
      """,
      logger: logger)
    return try await decodeCommands(rows).first
  }

  public func listCommands(limit: Int, before: String?) async throws
    -> OperationsPage<OperationsWorkerCommand>
  {
    let boundedLimit = max(1, min(limit, 250))
    let beforeCursor = try Self.decodeCursor(before)
    let beforeDate = beforeCursor?.date
    let beforeId = beforeCursor?.id
    let rows = try await pool.query(
      """
      SELECT id, action, status, requested_by_did, audit_note, claimed_by, lease_expires_at, failure_reason,
             created_at, updated_at, completed_at, version
      FROM operations_commands
      WHERE environment = \(environment)
        AND (\(beforeDate)::timestamptz IS NULL OR created_at < \(beforeDate)::timestamptz
          OR (created_at = \(beforeDate)::timestamptz AND id < \(beforeId)::text))
      ORDER BY created_at DESC, id DESC
      LIMIT \(boundedLimit + 1)
      """,
      logger: logger
    )
    let commands = try await decodeCommands(rows)
    let countRows = try await pool.query(
      "SELECT COUNT(*)::bigint FROM operations_commands WHERE environment = \(environment)",
      logger: logger)
    var total = 0
    for try await row in countRows { total = Int(try row.decode(Int64.self)); break }
    let items = Array(commands.prefix(boundedLimit))
    let next = commands.count > boundedLimit
      ? items.last.map { OperationsPaginationCursor.encode(date: $0.createdAt, id: $0.id) } : nil
    return OperationsPage(items: items, nextCursor: next, totalCount: total)
  }

  public func claimNextCommand(
    action: OperationsCommandAction,
    workerId: String,
    at: Date
  ) async throws -> OperationsWorkerCommand? {
    let leaseUntil = at.addingTimeInterval(300)
    let rows = try await pool.query(
      """
      WITH next_command AS (
        SELECT id FROM operations_commands
        WHERE environment = \(environment) AND action = \(action.rawValue)
          AND (status = 'queued' OR (status = 'running' AND lease_expires_at < \(at)))
        ORDER BY created_at
        FOR UPDATE SKIP LOCKED
        LIMIT 1
      )
      UPDATE operations_commands AS command
      SET status = 'running', claimed_by = \(workerId), lease_expires_at = \(leaseUntil),
          updated_at = \(at), version = command.version + 1
      FROM next_command
      WHERE command.environment = \(environment) AND command.id = next_command.id
      RETURNING command.id, command.action, command.status, command.requested_by_did,
                command.audit_note, command.claimed_by, command.lease_expires_at,
                command.failure_reason,
                command.created_at, command.updated_at, command.completed_at, command.version
      """,
      logger: logger
    )
    return try await decodeCommands(rows).first
  }

  public func completeCommand(
    id: String,
    status: OperationsCommandStatus,
    failureReason: String?,
    workerId: String,
    expectedVersion: Int,
    requestId: String?,
    note: String?,
    at: Date
  ) async throws -> OperationsWorkerCommand {
    precondition(status == .completed || status == .failed)
    return try await pool.withTransaction(logger: logger) { connection in
      let boundedFailure = failureReason.map { String($0.prefix(160)) }
      let rows = try await connection.query(
        """
        UPDATE operations_commands
        SET status = \(status.rawValue), failure_reason = \(boundedFailure),
            updated_at = \(at), completed_at = \(at),
            expires_at = \(at.addingTimeInterval(365 * 86_400)),
            lease_expires_at = NULL, version = version + 1
        WHERE environment = \(environment) AND id = \(id) AND status = 'running'
          AND claimed_by = \(workerId) AND lease_expires_at >= \(at)
          AND version = \(expectedVersion)
        RETURNING id, action, status, requested_by_did, audit_note, claimed_by,
          lease_expires_at, failure_reason, created_at, updated_at, completed_at, version
        """, logger: logger)
      guard let updated = try await decodeCommands(rows).first else {
        throw OperationsStoreError.leaseConflict
      }
      try await extendLifecycleRetention(
        connection: connection, targetType: "command", targetId: id, terminalAt: at)
      let beforeJSON = try json([
        "status": OperationsCommandStatus.running.rawValue,
        "version": String(expectedVersion), "leaseOwner": workerId,
      ])
      let afterJSON = try json([
        "status": status.rawValue, "version": String(updated.version),
        "outcome": boundedFailure ?? "succeeded",
      ])
      try await connection.query(
        """
        INSERT INTO operations_audit_events
          (environment, id, operator_did, action, target_type, target_id, request_id,
           expected_version, note, before_state, after_state, outcome, occurred_at, expires_at)
        VALUES (\(environment), \(UUID().uuidString.lowercased()), 'system:worker',
          \("command.\(status.rawValue)"), 'command', \(id), \(requestId),
          \(expectedVersion), \(note), \(beforeJSON)::jsonb, \(afterJSON)::jsonb,
          \(status == .completed ? "succeeded" : "failed"), \(at),
          \(at.addingTimeInterval(365 * 86_400)))
        """, logger: logger)
      return updated
    }
  }

  public func markStreamReceived(
    source: String,
    cursor: Int64,
    eventAt: Date?,
    receivedAt: Date,
    queueDepth: Int
  ) async throws {
    try await pool.query(
      """
      INSERT INTO appview_ingestion_stream_state
        (environment, source, connection_state, last_received_cursor, last_received_event_at, last_received_at, queue_depth, heartbeat_at, version)
      VALUES (\(environment), \(source), 'connected', \(cursor), \(eventAt), \(receivedAt), \(queueDepth), \(receivedAt), 1)
      ON CONFLICT (environment, source) DO UPDATE SET
        connection_state = 'connected',
        last_received_cursor = GREATEST(COALESCE(appview_ingestion_stream_state.last_received_cursor, -1), EXCLUDED.last_received_cursor),
        last_received_event_at = CASE
          WHEN appview_ingestion_stream_state.last_received_cursor IS NULL
            OR EXCLUDED.last_received_cursor >= appview_ingestion_stream_state.last_received_cursor
          THEN EXCLUDED.last_received_event_at ELSE appview_ingestion_stream_state.last_received_event_at END,
        last_received_at = CASE
          WHEN appview_ingestion_stream_state.last_received_cursor IS NULL
            OR EXCLUDED.last_received_cursor >= appview_ingestion_stream_state.last_received_cursor
          THEN EXCLUDED.last_received_at ELSE appview_ingestion_stream_state.last_received_at END,
        queue_depth = EXCLUDED.queue_depth,
        heartbeat_at = EXCLUDED.heartbeat_at,
        version = appview_ingestion_stream_state.version + 1
      """,
      logger: logger
    )
  }

  public func markStreamCommitted(
    source: String,
    cursor: Int64,
    eventAt: Date?,
    committedAt: Date,
    queueDepth: Int
  ) async throws {
    try await pool.query(
      """
      INSERT INTO appview_ingestion_stream_state
        (environment, source, last_committed_cursor, last_committed_event_at, last_committed_at, queue_depth, heartbeat_at, version)
      VALUES (\(environment), \(source), \(cursor), \(eventAt), \(committedAt), \(queueDepth), \(committedAt), 1)
      ON CONFLICT (environment, source) DO UPDATE SET
        last_committed_cursor = GREATEST(COALESCE(appview_ingestion_stream_state.last_committed_cursor, -1), EXCLUDED.last_committed_cursor),
        last_committed_event_at = CASE
          WHEN appview_ingestion_stream_state.last_committed_cursor IS NULL
            OR EXCLUDED.last_committed_cursor >= appview_ingestion_stream_state.last_committed_cursor
          THEN EXCLUDED.last_committed_event_at ELSE appview_ingestion_stream_state.last_committed_event_at END,
        last_committed_at = CASE
          WHEN appview_ingestion_stream_state.last_committed_cursor IS NULL
            OR EXCLUDED.last_committed_cursor >= appview_ingestion_stream_state.last_committed_cursor
          THEN EXCLUDED.last_committed_at ELSE appview_ingestion_stream_state.last_committed_at END,
        queue_depth = EXCLUDED.queue_depth,
        heartbeat_at = EXCLUDED.heartbeat_at,
        version = appview_ingestion_stream_state.version + 1
      """,
      logger: logger
    )
  }

  public func recordRecoveryFailure(
    jobId: String?,
    identityHash: String,
    collection: String,
    operation: String,
    cursor: Int64?,
    errorCategory: String,
    at: Date
  ) async throws {
    let id = UUID().uuidString.lowercased()
    let expiresAt = at.addingTimeInterval(30 * 86_400)
    try await pool.query(
      """
      INSERT INTO appview_recovery_failures
        (environment, id, job_id, source, record_identifier_hash, collection, operation, cursor, error_type,
         retry_count, first_failed_at, last_failed_at, expires_at)
      VALUES
        (\(environment), \(id), \(jobId), 'jetstream', \(identityHash), \(String(collection.prefix(128))),
         \(String(operation.prefix(32))), \(cursor), \(String(errorCategory.prefix(64))), 0, \(at), \(at), \(expiresAt))
      """,
      logger: logger
    )
  }

  public func createGap(
    source: String,
    startCursor: Int64?,
    endCursor: Int64?,
    reason: String,
    collections: [String],
    detectedAt: Date
  ) async throws -> IngestionGap {
    let id = UUID().uuidString.lowercased()
    let collectionJSON = try json(collections)
    try await pool.query(
      """
      INSERT INTO appview_ingestion_gaps
        (environment, id, source, start_cursor, end_cursor, reason, status, collections, detected_at, updated_at, version)
      VALUES
        (\(environment), \(id), \(source), \(startCursor), \(endCursor), \(String(reason.prefix(128))), 'suspected',
         \(collectionJSON)::jsonb, \(detectedAt), \(detectedAt), 0)
      """,
      logger: logger
    )
    guard let created = try await fetchGap(id: id) else {
      throw OperationsStoreError.missingCreatedRecord
    }
    return created
  }

  public func listGaps(limit: Int) async throws -> [IngestionGap] {
    try await listGaps(view: .all, limit: limit, before: nil).items
  }

  public func listGaps(
    view: GapListView,
    limit: Int,
    before: String?
  ) async throws -> OperationsPage<IngestionGap> {
    let limit = max(1, min(limit, 250))
    let beforeCursor = try Self.decodeCursor(before)
    let beforeDate = beforeCursor?.date
    let beforeId = beforeCursor?.id
    let rows = try await pool.query(
      """
      SELECT id, source, start_cursor, end_cursor, start_time, end_time, reason, status,
             collections::text, detected_at, updated_at, backfill_job_id,
             discovered_count, processed_count, failed_count, reconciled_count, version
      FROM appview_ingestion_gaps
      WHERE environment = \(environment)
        AND (\(view.rawValue) = 'all'
          OR (\(view.rawValue) = 'active' AND status NOT IN ('resolved', 'ignored'))
          OR (\(view.rawValue) = 'history' AND status IN ('resolved', 'ignored')))
        AND (\(beforeDate)::timestamptz IS NULL OR detected_at < \(beforeDate)::timestamptz
          OR (detected_at = \(beforeDate)::timestamptz AND id < \(beforeId)::text))
      ORDER BY detected_at DESC, id DESC
      LIMIT \(limit + 1)
      """,
      logger: logger
    )
    let decoded = try await decodeGaps(rows)
    let countRows = try await pool.query(
      """
      SELECT COUNT(*)::bigint FROM appview_ingestion_gaps
      WHERE environment = \(environment)
        AND (\(view.rawValue) = 'all'
          OR (\(view.rawValue) = 'active' AND status NOT IN ('resolved', 'ignored'))
          OR (\(view.rawValue) = 'history' AND status IN ('resolved', 'ignored')))
      """,
      logger: logger)
    var total = 0
    for try await row in countRows { total = Int(try row.decode(Int64.self)) }
    let items = Array(decoded.prefix(limit))
    let next = decoded.count > limit
      ? items.last.map { OperationsPaginationCursor.encode(date: $0.detectedAt, id: $0.id) } : nil
    return OperationsPage(items: items, nextCursor: next, totalCount: total)
  }

  public func lifecycleCounts() async throws -> OperationsLifecycleCounts {
    let rows = try await pool.query(
      """
      SELECT
        (SELECT COUNT(*) FROM appview_ingestion_gaps WHERE environment = \(environment) AND status NOT IN ('resolved', 'ignored'))::bigint,
        (SELECT COUNT(*) FROM appview_backfill_jobs WHERE environment = \(environment) AND status IN ('queued', 'running', 'paused'))::bigint,
        (SELECT COUNT(*) FROM appview_backfill_jobs WHERE environment = \(environment) AND status IN ('failed', 'cancelled'))::bigint,
        (SELECT COUNT(*) FROM appview_backfill_jobs WHERE environment = \(environment) AND status = 'completed')::bigint,
        (SELECT COUNT(*) FROM operations_alerts WHERE environment = \(environment) AND status != 'resolved')::bigint
      """, logger: logger)
    for try await row in rows {
      let value = try row.decode((Int64, Int64, Int64, Int64, Int64).self)
      return OperationsLifecycleCounts(
        activeGaps: Int(value.0), activeBackfills: Int(value.1), attentionBackfills: Int(value.2),
        completedBackfills: Int(value.3), unresolvedAlerts: Int(value.4))
    }
    return OperationsLifecycleCounts()
  }

  public func updateGap(id: String, status: IngestionGapStatus, operatorDid: String, at: Date)
    async throws
  {
    guard let current = try await fetchGap(id: id) else { throw OperationsStoreError.notFound }
    _ = try await transitionGap(
      id: id, to: status, expectedVersion: current.version, operatorDid: operatorDid,
      idempotencyKey: UUID().uuidString.lowercased(), requestId: nil, note: nil, at: at)
  }

  public func transitionGap(
    id: String,
    to status: IngestionGapStatus,
    expectedVersion: Int,
    operatorDid: String,
    idempotencyKey: String,
    requestId: String? = nil,
    note: String?,
    at: Date
  ) async throws -> IngestionGap {
    let actionName = "gap.\(status.rawValue)"
    let requestFingerprint = OperationsIdempotencyFingerprint.make(
      action: actionName, targetType: "gap", targetId: id, expectedVersion: expectedVersion,
      fields: ["operatorDid": operatorDid, "note": note, "status": status.rawValue])
    return try await pool.withTransaction(logger: logger) { connection in
      if let existing = try await existingIdempotency(
        connection: connection, key: idempotencyKey, action: actionName,
        targetType: "gap", targetId: id, requestFingerprint: requestFingerprint)
      {
        let replay = try replayIdempotencyResult(existing, as: IngestionGap.self)
        let afterJSON = try json([
          "status": replay.status.rawValue, "version": String(replay.version),
        ])
        try await connection.query(
          Self.auditInsert(
            environment: environment, operatorDid: operatorDid, action: actionName,
            targetType: "gap", targetId: replay.id, idempotencyKey: idempotencyKey,
            requestId: requestId, expectedVersion: expectedVersion, note: note,
            beforeJSON: "{}", afterJSON: afterJSON, outcome: "idempotent_replay", at: at),
          logger: logger)
        return replay
      }
      let currentRows = try await connection.query(Self.gapSelect(environment: environment, id: id), logger: logger)
      var current: IngestionGap?
      for try await row in currentRows { current = try decodeGap(row); break }
      guard let current else { throw OperationsStoreError.notFound }
      guard current.version == expectedVersion else {
        throw OperationsStoreError.versionConflict(expected: expectedVersion, actual: current.version)
      }
      guard Self.canTransitionGap(from: current.status, to: status) else {
        throw OperationsStoreError.invalidTransition(from: current.status.rawValue, to: status.rawValue)
      }
      let rows = try await connection.query(
        """
        UPDATE appview_ingestion_gaps SET status = \(status.rawValue), updated_at = \(at),
          expires_at = CASE WHEN \(status.rawValue) IN ('resolved', 'ignored')
            THEN \(at.addingTimeInterval(365 * 86_400)) ELSE expires_at END,
          version = version + 1
        WHERE environment = \(environment) AND id = \(id) AND version = \(expectedVersion)
        RETURNING id, source, start_cursor, end_cursor, start_time, end_time, reason, status,
          collections::text, detected_at, updated_at, backfill_job_id,
          discovered_count, processed_count, failed_count, reconciled_count, version
        """, logger: logger)
      var updated: IngestionGap?
      for try await row in rows { updated = try decodeGap(row); break }
      guard let updated else {
        throw OperationsStoreError.versionConflict(expected: expectedVersion, actual: current.version + 1)
      }
      if [.resolved, .ignored].contains(status) {
        try await extendLifecycleRetention(
          connection: connection, targetType: "gap", targetId: id, terminalAt: at)
      }
      try await insertIdempotency(
        connection: connection, key: idempotencyKey, action: actionName,
        targetType: "gap", targetId: id, outcome: "succeeded",
        requestFingerprint: requestFingerprint,
        resultPayload: try json(updated), at: at)
      let beforeJSON = try json(["status": current.status.rawValue, "version": String(current.version)])
      let afterJSON = try json(["status": status.rawValue, "version": String(updated.version)])
      try await connection.query(
        """
        INSERT INTO operations_audit_events
          (environment, id, operator_did, action, target_type, target_id, idempotency_key,
           request_id, expected_version, note, before_state, after_state, outcome,
           occurred_at, expires_at)
        VALUES (\(environment), \(UUID().uuidString.lowercased()), \(operatorDid),
          \("gap.\(status.rawValue)"), 'gap', \(id), \(idempotencyKey), \(requestId),
          \(expectedVersion), \(note),
          \(beforeJSON)::jsonb, \(afterJSON)::jsonb, 'succeeded', \(at), \(at.addingTimeInterval(365 * 86_400)))
        """, logger: logger)
      return updated
    }
  }

  public func resolveSuspectedGaps(
    source: String,
    through committedCursor: Int64,
    at: Date
  ) async throws -> [String] {
    let rows = try await pool.query(
      """
      UPDATE appview_ingestion_gaps
      SET status = 'verification_required', updated_at = \(at), version = version + 1
      WHERE environment = \(environment) AND source = \(source) AND status = 'suspected'
        AND end_cursor IS NOT NULL AND end_cursor <= \(committedCursor)
      RETURNING id
      """,
      logger: logger
    )
    var ids: [String] = []
    for try await row in rows {
      ids.append(try row.decode(String.self))
    }
    return ids
  }

  public func estimateBackfill(_ request: BackfillDryRunRequest) async throws
    -> BackfillDryRunResponse
  {
    let request = try BackfillScopePolicy.normalized(request)
    let gap: IngestionGap?
    if let gapId = request.gapId {
      gap = try await fetchGap(id: gapId)
    } else {
      gap = nil
    }
    async let existingJobs = listBackfills(view: .active, limit: 250, before: nil)
    let resolvedExistingJobs = try await existingJobs
    let response = BackfillDryRunAssessment.build(
      request: request,
      gap: gap,
      existingJobs: resolvedExistingJobs.items)
    guard let secret = backfillFingerprintSecret else {
      throw OperationsStoreError.invalidBackfillFingerprint
    }
    return response.replacingRequestFingerprint(BackfillRequestFingerprint.make(
      canonicalRequest: response.requestFingerprint, estimatedCount: response.estimatedCount,
      validUntil: response.validUntil, environment: environment, secret: secret))
  }

  public func createBackfill(
    _ request: CreateBackfillRequest,
    operatorDid: String,
    requestId: String? = nil,
    at: Date
  ) async throws -> BackfillJob {
    let dryRun = try BackfillScopePolicy.normalized(request.dryRun)
    let id = UUID().uuidString.lowercased()
    let idempotencyKey = request.idempotencyKey
    let collections = try json(dryRun.collections)
    let authorDids = try json(dryRun.authorDids)
    let canonicalRequest = BackfillRequestFingerprint.canonicalRequest(dryRun)
    let normalizedRequestHash = OperationsRedactor.hashIdentity(canonicalRequest)
    let idempotencyRequestFingerprint = OperationsIdempotencyFingerprint.make(
      action: "backfill.queued", targetType: "backfill", targetId: nil,
      expectedVersion: request.expectedGapVersion,
      fields: [
        "operatorDid": operatorDid, "canonicalRequest": canonicalRequest,
        "expectedEstimate": String(request.expectedEstimate), "auditNote": request.auditNote,
        "environmentConfirmation": request.environmentConfirmation,
        "signedRequestFingerprint": request.requestFingerprint,
      ])
    return try await pool.withTransaction(logger: logger) { connection -> BackfillJob in
      var auditBefore: [String: String] = [:]
      if let existing = try await existingIdempotency(
        connection: connection, key: idempotencyKey, action: "backfill.queued",
        targetType: "backfill", targetId: nil,
        requestFingerprint: idempotencyRequestFingerprint)
      {
        let replay = try replayIdempotencyResult(existing, as: BackfillJob.self)
        let afterJSON = try json([
          "status": replay.status.rawValue, "version": String(replay.version),
          "targetId": replay.id,
        ])
        try await connection.query(
          Self.auditInsert(
            environment: environment, operatorDid: operatorDid, action: "backfill.queued",
            targetType: "backfill", targetId: replay.id, idempotencyKey: idempotencyKey,
            requestId: requestId, expectedVersion: request.expectedGapVersion,
            note: request.auditNote, beforeJSON: "{}", afterJSON: afterJSON,
            outcome: "idempotent_replay", at: at), logger: logger)
        return replay
      }
      let fingerprint = request.requestFingerprint
      guard let fingerprintSecret = backfillFingerprintSecret,
        BackfillRequestFingerprint.validate(
          fingerprint, canonicalRequest: canonicalRequest,
          estimatedCount: request.expectedEstimate, environment: environment,
          secret: fingerprintSecret, at: at),
        let fingerprintExpiresAt = BackfillRequestFingerprint.validUntil(fingerprint)
      else { throw OperationsStoreError.invalidBackfillFingerprint }

      // Recovery creation is rare; a short environment-scoped advisory lock prevents two
      // empty-scope reads from concurrently queuing overlapping work.
      _ = try await connection.query(
        "SELECT pg_advisory_xact_lock(hashtextextended(\(environment) || '|operations_backfill_scope', 0))",
        logger: logger)

      if let gapId = dryRun.gapId {
        let gapRows = try await connection.query(
          """
          SELECT status, version, start_cursor, end_cursor, collections::text
          FROM appview_ingestion_gaps
          WHERE environment = \(environment) AND id = \(gapId) FOR UPDATE
          """,
          logger: logger)
        var current: (String, Int, Int64?, Int64?, String)?
        for try await row in gapRows {
          current = try row.decode((String, Int, Int64?, Int64?, String).self); break
        }
        guard let current else { throw OperationsStoreError.notFound }
        auditBefore = ["status": current.0, "version": String(current.1)]
        if let expected = request.expectedGapVersion, expected != current.1 {
          throw OperationsStoreError.versionConflict(expected: expected, actual: current.1)
        }
        guard current.0 == IngestionGapStatus.confirmed.rawValue
          || current.0 == IngestionGapStatus.verificationRequired.rawValue
        else {
          throw OperationsStoreError.invalidTransition(
            from: current.0, to: IngestionGapStatus.backfillQueued.rawValue)
        }
        if dryRun.sourceMode == .jetstreamReplay,
          current.2 != dryRun.startCursor || current.3 != dryRun.endCursor
        {
          throw OperationsStoreError.backfillScopeChanged(reason: "gap_range_changed")
        }
        if let gapCollections = try? JSONDecoder().decode(
          [String].self, from: Data(current.4.utf8)),
          !gapCollections.isEmpty, Set(gapCollections).isDisjoint(with: dryRun.collections)
        {
          throw OperationsStoreError.backfillScopeChanged(reason: "gap_collections_changed")
        }
      }
      if dryRun.gapId == nil, dryRun.sourceMode == .jetstreamReplay,
        let endCursor = dryRun.endCursor
      {
        let cursorRows = try await connection.query(
          """
          SELECT last_committed_cursor FROM appview_ingestion_stream_state
          WHERE environment = \(environment) AND source = 'jetstream' FOR SHARE
          """, logger: logger)
        for try await row in cursorRows {
          if let committed = try row.decode(Int64?.self), committed >= endCursor {
            throw OperationsStoreError.backfillScopeChanged(reason: "range_already_committed")
          }
          break
        }
      }
      let scopeRows = try await connection.query(
        """
        SELECT gap_id, source_mode, start_cursor, end_cursor, collections::text, author_dids::text
        FROM appview_backfill_jobs
        WHERE environment = \(environment) AND status IN ('queued', 'running', 'paused')
        FOR UPDATE
        """, logger: logger)
      for try await row in scopeRows {
        let value = try row.decode((String?, String, Int64?, Int64?, String, String).self)
        guard value.1 == dryRun.sourceMode.rawValue,
          let existingCollections = try? JSONDecoder().decode(
            [String].self, from: Data(value.4.utf8)),
          !Set(existingCollections).isDisjoint(with: dryRun.collections)
        else { continue }
        if let gapId = dryRun.gapId, value.0 == gapId {
          throw OperationsStoreError.overlappingBackfill
        }
        switch dryRun.sourceMode {
        case .jetstreamReplay:
          if let requestStart = dryRun.startCursor, let requestEnd = dryRun.endCursor,
            let existingStart = value.2, let existingEnd = value.3,
            requestStart < existingEnd, existingStart < requestEnd
          {
            throw OperationsStoreError.overlappingBackfill
          }
        case .tapVerifiedResync, .pdsReconciliation:
          if let existingAuthors = try? JSONDecoder().decode(
            [String].self, from: Data(value.5.utf8)),
            !Set(existingAuthors).isDisjoint(with: dryRun.authorDids)
          {
            throw OperationsStoreError.overlappingBackfill
          }
        }
      }
      let verification = dryRun.sourceMode == .tapVerifiedResync
        ? BackfillVerificationStatus.pending.rawValue : BackfillVerificationStatus.required.rawValue
      try await connection.query(
        """
        INSERT INTO appview_backfill_jobs
          (environment, id, gap_id, source_mode, status, start_cursor, end_cursor, checkpoint_cursor,
           collections, author_dids, batch_size, rate_limit, max_concurrency, estimated_count,
           requested_by_did, audit_note, idempotency_key, verification_status,
           request_fingerprint, request_fingerprint_expires_at, normalized_request_hash,
           created_at, updated_at, version)
        VALUES (\(environment), \(id), \(dryRun.gapId), \(dryRun.sourceMode.rawValue), 'queued',
          \(dryRun.startCursor), \(dryRun.endCursor), \(dryRun.startCursor),
          \(collections)::jsonb, \(authorDids)::jsonb, \(dryRun.batchSize),
          \(dryRun.rateLimit), \(dryRun.maxConcurrency), \(request.expectedEstimate),
          \(operatorDid), \(request.auditNote.map { String($0.prefix(280)) }), \(idempotencyKey),
          \(verification), \(fingerprint), \(fingerprintExpiresAt), \(normalizedRequestHash),
          \(at), \(at), 0)
        """, logger: logger)
      if let gapId = dryRun.gapId {
        try await connection.query(
          "UPDATE appview_ingestion_gaps SET status = 'backfill_queued', backfill_job_id = \(id), updated_at = \(at), version = version + 1 WHERE environment = \(environment) AND id = \(gapId)",
          logger: logger)
      }
      let createdRows = try await connection.query(
        Self.backfillSelect(environment: environment, id: id), logger: logger)
      var created: BackfillJob?
      for try await row in createdRows { created = try decodeBackfill(row); break }
      guard let created else { throw OperationsStoreError.missingCreatedRecord }
      try await insertIdempotency(
        connection: connection, key: idempotencyKey, action: "backfill.queued",
        targetType: "backfill", targetId: id, outcome: "queued",
        requestFingerprint: idempotencyRequestFingerprint,
        resultPayload: try json(created), at: at)
      let auditBeforeJSON = try json(auditBefore)
      let auditAfterJSON = try json([
        "status": BackfillJobStatus.queued.rawValue, "version": "0", "targetId": id,
      ])
      try await connection.query(
        """
        INSERT INTO operations_audit_events
          (environment, id, operator_did, action, target_type, target_id, idempotency_key,
           request_id, expected_version, note, before_state, after_state, outcome,
           occurred_at, expires_at)
        VALUES (\(environment), \(UUID().uuidString.lowercased()), \(operatorDid), 'backfill.queued',
          'backfill', \(id), \(idempotencyKey), \(requestId), \(request.expectedGapVersion),
          \(request.auditNote), \(auditBeforeJSON)::jsonb,
          \(auditAfterJSON)::jsonb, 'succeeded', \(at),
          \(at.addingTimeInterval(365 * 86_400)))
        """, logger: logger)
      return created
    }
  }

  public func listBackfills(limit: Int) async throws -> [BackfillJob] {
    try await listBackfills(view: .all, limit: limit, before: nil).items
  }

  public func listBackfills(
    view: BackfillListView,
    limit: Int,
    before: String?
  ) async throws -> OperationsPage<BackfillJob> {
    let limit = max(1, min(limit, 250))
    let beforeCursor = try Self.decodeCursor(before)
    let beforeDate = beforeCursor?.date
    let beforeId = beforeCursor?.id
    let rows = try await pool.query(
      """
      SELECT id, gap_id, source_mode, status, start_cursor, end_cursor, checkpoint_cursor,
             collections::text, author_dids::text, batch_size, rate_limit, max_concurrency,
             estimated_count, processed_count, failed_count, reconciled_count,
             requested_by_did, audit_note, failure_reason, lease_owner, lease_expires_at,
             created_at, updated_at, completed_at, version, verification_status,
             verification_reason, scope_truncated, validation_watermark, author_results::text
      FROM appview_backfill_jobs
      WHERE environment = \(environment)
        AND (\(view.rawValue) = 'all'
          OR (\(view.rawValue) = 'active' AND status IN ('queued', 'running', 'paused'))
          OR (\(view.rawValue) = 'attention' AND status IN ('failed', 'cancelled'))
          OR (\(view.rawValue) = 'history' AND status = 'completed'))
        AND (\(beforeDate)::timestamptz IS NULL OR created_at < \(beforeDate)::timestamptz
          OR (created_at = \(beforeDate)::timestamptz AND id < \(beforeId)::text))
      ORDER BY created_at DESC, id DESC
      LIMIT \(limit + 1)
      """,
      logger: logger
    )
    let decoded = try await decodeBackfills(rows)
    let countRows = try await pool.query(
      """
      SELECT COUNT(*)::bigint FROM appview_backfill_jobs
      WHERE environment = \(environment)
        AND (\(view.rawValue) = 'all'
          OR (\(view.rawValue) = 'active' AND status IN ('queued', 'running', 'paused'))
          OR (\(view.rawValue) = 'attention' AND status IN ('failed', 'cancelled'))
          OR (\(view.rawValue) = 'history' AND status = 'completed'))
      """, logger: logger)
    var total = 0
    for try await row in countRows { total = Int(try row.decode(Int64.self)) }
    let items = Array(decoded.prefix(limit))
    let next = decoded.count > limit
      ? items.last.map { OperationsPaginationCursor.encode(date: $0.createdAt, id: $0.id) } : nil
    return OperationsPage(items: items, nextCursor: next, totalCount: total)
  }

  public func fetchBackfill(id: String) async throws -> BackfillJob? {
    let rows = try await pool.query(
      """
      SELECT id, gap_id, source_mode, status, start_cursor, end_cursor, checkpoint_cursor,
             collections::text, author_dids::text, batch_size, rate_limit, max_concurrency,
             estimated_count, processed_count, failed_count, reconciled_count,
             requested_by_did, audit_note, failure_reason, lease_owner, lease_expires_at,
             created_at, updated_at, completed_at, version, verification_status,
             verification_reason, scope_truncated, validation_watermark, author_results::text
      FROM appview_backfill_jobs
      WHERE environment = \(environment) AND id = \(id)
      LIMIT 1
      """,
      logger: logger
    )
    return try await decodeBackfills(rows).first
  }

  public func updateBackfillStatus(
    id: String,
    status: BackfillJobStatus,
    operatorDid: String,
    failureReason: String?,
    at: Date
  ) async throws {
    guard let current = try await fetchBackfill(id: id) else { throw OperationsStoreError.notFound }
    _ = try await transitionBackfill(
      id: id, to: status, expectedVersion: current.version, operatorDid: operatorDid,
      idempotencyKey: UUID().uuidString.lowercased(), requestId: nil, note: nil,
      failureReason: failureReason, at: at)
  }

  public func transitionBackfill(
    id: String,
    to status: BackfillJobStatus,
    expectedVersion: Int,
    operatorDid: String,
    idempotencyKey: String,
    requestId: String? = nil,
    note: String?,
    failureReason: String?,
    at: Date
  ) async throws -> BackfillJob {
    let actionName = "backfill.\(status.rawValue)"
    let requestFingerprint = OperationsIdempotencyFingerprint.make(
      action: actionName, targetType: "backfill", targetId: id,
      expectedVersion: expectedVersion,
      fields: [
        "operatorDid": operatorDid, "note": note, "failureReason": failureReason,
        "status": status.rawValue,
      ])
    return try await pool.withTransaction(logger: logger) { connection in
      if let existing = try await existingIdempotency(
        connection: connection, key: idempotencyKey, action: actionName,
        targetType: "backfill", targetId: id, requestFingerprint: requestFingerprint)
      {
        let replay = try replayIdempotencyResult(existing, as: BackfillJob.self)
        let afterJSON = try json([
          "status": replay.status.rawValue, "version": String(replay.version),
        ])
        try await connection.query(
          Self.auditInsert(
            environment: environment, operatorDid: operatorDid, action: actionName,
            targetType: "backfill", targetId: replay.id, idempotencyKey: idempotencyKey,
            requestId: requestId, expectedVersion: expectedVersion, note: note,
            beforeJSON: "{}", afterJSON: afterJSON, outcome: "idempotent_replay", at: at),
          logger: logger)
        return replay
      }
      let currentRows = try await connection.query(Self.backfillSelect(environment: environment, id: id), logger: logger)
      var current: BackfillJob?
      for try await row in currentRows { current = try decodeBackfill(row); break }
      guard let current else { throw OperationsStoreError.notFound }
      guard current.version == expectedVersion else {
        throw OperationsStoreError.versionConflict(expected: expectedVersion, actual: current.version)
      }
      guard Self.canTransitionBackfill(from: current.status, to: status) else {
        throw OperationsStoreError.invalidTransition(from: current.status.rawValue, to: status.rawValue)
      }
      if operatorDid == "system:worker", current.status == .running,
        [.completed, .failed].contains(status)
      {
        guard current.leaseOwner != nil,
          current.leaseExpiresAt.map({ $0 >= at }) == true
        else { throw OperationsStoreError.leaseConflict }
      }
      var linkedGapUpdate: (id: String, version: Int, from: IngestionGapStatus, to: IngestionGapStatus)?
      if let gapId = current.gapId,
        let transition = Self.linkedGapTransition(from: current.status, to: status)
      {
        let gapRows = try await connection.query(
          Self.gapSelect(environment: environment, id: gapId, forUpdate: true), logger: logger)
        var linkedGap: IngestionGap?
        for try await row in gapRows { linkedGap = try decodeGap(row); break }
        guard let gap = linkedGap else { throw OperationsStoreError.notFound }
        guard gap.backfillJobId == current.id, transition.allowedFrom.contains(gap.status) else {
          throw OperationsStoreError.invalidTransition(
            from: gap.status.rawValue, to: transition.next.rawValue)
        }
        linkedGapUpdate = (gapId, gap.version, gap.status, transition.next)
      }
      let completedAt: Date? = [.completed, .failed, .cancelled].contains(status) ? at : nil
      let rows = try await connection.query(
        """
        UPDATE appview_backfill_jobs SET status = \(status.rawValue), updated_at = \(at),
          completed_at = \(completedAt), version = version + 1,
          expires_at = CASE WHEN \(status.rawValue) IN ('completed', 'failed', 'cancelled')
            THEN \(at.addingTimeInterval(365 * 86_400)) ELSE expires_at END,
          failure_reason = CASE WHEN \(status.rawValue) = 'failed'
            THEN \(failureReason.map { String($0.prefix(160)) }) ELSE failure_reason END,
          lease_owner = NULL, lease_expires_at = NULL
        WHERE environment = \(environment) AND id = \(id) AND version = \(expectedVersion)
        RETURNING id, gap_id, source_mode, status, start_cursor, end_cursor, checkpoint_cursor,
          collections::text, author_dids::text, batch_size, rate_limit, max_concurrency,
          estimated_count, processed_count, failed_count, reconciled_count, requested_by_did,
          audit_note, failure_reason, lease_owner, lease_expires_at, created_at, updated_at,
          completed_at, version, verification_status, verification_reason, scope_truncated,
          validation_watermark, author_results::text
        """, logger: logger)
      var updated: BackfillJob?
      for try await row in rows { updated = try decodeBackfill(row); break }
      guard let updated else {
        throw OperationsStoreError.versionConflict(expected: expectedVersion, actual: current.version + 1)
      }
      if var linkedGapUpdate {
        if status == .completed {
          let isVerifiedTap = updated.sourceMode == .tapVerifiedResync
            && updated.verificationStatus == .verified && !updated.scopeTruncated
            && updated.failedCount == 0 && updated.validationWatermark != nil
          linkedGapUpdate.to = isVerifiedTap ? .resolved : .verificationRequired
        }
        let gapRows = try await connection.query(
          """
          UPDATE appview_ingestion_gaps
          SET status = \(linkedGapUpdate.to.rawValue), updated_at = \(at),
            expires_at = CASE WHEN \(linkedGapUpdate.to.rawValue) IN ('resolved', 'ignored')
              THEN \(at.addingTimeInterval(365 * 86_400)) ELSE expires_at END,
            version = version + 1
          WHERE environment = \(environment) AND id = \(linkedGapUpdate.id)
            AND version = \(linkedGapUpdate.version) AND status = \(linkedGapUpdate.from.rawValue)
          RETURNING id
          """, logger: logger)
        var changedGap = false
        for try await _ in gapRows { changedGap = true; break }
        guard changedGap else {
          throw OperationsStoreError.invalidTransition(
            from: linkedGapUpdate.from.rawValue, to: linkedGapUpdate.to.rawValue)
        }
        if [.resolved, .ignored].contains(linkedGapUpdate.to) {
          try await extendLifecycleRetention(
            connection: connection, targetType: "gap", targetId: linkedGapUpdate.id,
            terminalAt: at)
        }
      }
      if [.completed, .failed, .cancelled].contains(status) {
        try await extendLifecycleRetention(
          connection: connection, targetType: "backfill", targetId: id, terminalAt: at)
      }
      try await insertIdempotency(
        connection: connection, key: idempotencyKey, action: actionName,
        targetType: "backfill", targetId: id, outcome: "succeeded",
        requestFingerprint: requestFingerprint,
        resultPayload: try json(updated), at: at)
      let beforeJSON = try json(["status": current.status.rawValue, "version": String(current.version)])
      let afterJSON = try json(["status": updated.status.rawValue, "version": String(updated.version)])
      try await connection.query(
        """
        INSERT INTO operations_audit_events
          (environment, id, operator_did, action, target_type, target_id, idempotency_key,
           request_id, expected_version, note, before_state, after_state, outcome,
           occurred_at, expires_at)
        VALUES (\(environment), \(UUID().uuidString.lowercased()), \(operatorDid),
          \("backfill.\(status.rawValue)"), 'backfill', \(id), \(idempotencyKey),
          \(requestId), \(expectedVersion), \(note),
          \(beforeJSON)::jsonb, \(afterJSON)::jsonb, 'succeeded', \(at),
          \(at.addingTimeInterval(365 * 86_400)))
        """, logger: logger)
      return updated
    }
  }

  public func claimNextBackfill(workerId: String, leaseUntil: Date, at: Date) async throws
    -> BackfillJob?
  {
    return try await pool.withTransaction(logger: logger) { connection in
      let rows = try await connection.query(
        """
        UPDATE appview_backfill_jobs
        SET status = 'running', lease_owner = \(workerId), lease_expires_at = \(leaseUntil),
          updated_at = \(at), version = version + 1
        WHERE environment = \(environment) AND id = (
          SELECT id FROM appview_backfill_jobs
          WHERE environment = \(environment) AND status IN ('queued', 'running')
            AND (lease_expires_at IS NULL OR lease_expires_at < \(at))
          ORDER BY created_at FOR UPDATE SKIP LOCKED LIMIT 1)
        RETURNING id, gap_id, source_mode, status, start_cursor, end_cursor, checkpoint_cursor,
          collections::text, author_dids::text, batch_size, rate_limit, max_concurrency,
          estimated_count, processed_count, failed_count, reconciled_count, requested_by_did,
          audit_note, failure_reason, lease_owner, lease_expires_at, created_at, updated_at,
          completed_at, version, verification_status, verification_reason, scope_truncated,
          validation_watermark, author_results::text
        """, logger: logger)
      var job: BackfillJob?
      for try await row in rows { job = try decodeBackfill(row); break }
      if let gapId = job?.gapId {
        try await connection.query(
          "UPDATE appview_ingestion_gaps SET status = 'backfilling', updated_at = \(at), version = version + 1 WHERE environment = \(environment) AND id = \(gapId) AND status = 'backfill_queued'",
          logger: logger)
      }
      return job
    }
  }

  public func renewBackfillLease(
    id: String, workerId: String, expectedVersion: Int, leaseUntil: Date, at: Date
  ) async throws -> BackfillJob {
    try await mutateOwnedBackfill(
      id: id, workerId: workerId, expectedVersion: expectedVersion, leaseUntil: leaseUntil,
      at: at, checkpoint: nil, processed: nil, failed: nil, reconciled: nil,
      verification: nil)
  }

  public func recordBackfillVerification(
    id: String, workerId: String, expectedVersion: Int, exactScope: Bool, truncated: Bool,
    failedCount: Int, validationWatermark: String?, at: Date
  ) async throws -> BackfillJob {
    guard failedCount >= 0 else { throw OperationsStoreError.invalidProgress }
    guard let current = try await fetchBackfill(id: id) else {
      throw OperationsStoreError.notFound
    }
    guard current.version == expectedVersion else {
      throw OperationsStoreError.versionConflict(expected: expectedVersion, actual: current.version)
    }
    let effectiveFailedCount = max(current.failedCount, failedCount)
    let isAuthoritativeTap = current.sourceMode == .tapVerifiedResync
    let verified = isAuthoritativeTap && exactScope && !truncated
      && effectiveFailedCount == 0 && validationWatermark != nil
    let status: BackfillVerificationStatus
    if verified { status = .verified }
    else if isAuthoritativeTap && exactScope && (truncated || effectiveFailedCount > 0) {
      status = .failed
    }
    else { status = .required }
    let reason: String?
    if !exactScope { reason = "scope_not_exact" }
    else if !isAuthoritativeTap { reason = "source_not_authoritative" }
    else if truncated { reason = "scope_truncated" }
    else if effectiveFailedCount > 0 { reason = "recovery_failures" }
    else if validationWatermark == nil { reason = "missing_validation_watermark" }
    else { reason = nil }
    return try await mutateOwnedBackfill(
      id: id, workerId: workerId, expectedVersion: expectedVersion,
      leaseUntil: at.addingTimeInterval(60), at: at, checkpoint: nil, processed: nil,
      failed: effectiveFailedCount, reconciled: nil,
      verification: (status, reason, truncated, validationWatermark))
  }

  public func recordBackfillAuthorResults(
    id: String,
    workerId: String,
    expectedVersion: Int,
    results: [BackfillAuthorResult],
    at: Date
  ) async throws -> BackfillJob {
    try Self.validateAuthorResults(results)
    let encodedResults = try json(results)
    let rows = try await pool.query(
      """
      UPDATE appview_backfill_jobs
      SET author_results = \(encodedResults)::jsonb, updated_at = \(at), version = version + 1
      WHERE environment = \(environment) AND id = \(id) AND status = 'running'
        AND lease_owner = \(workerId) AND lease_expires_at >= \(at)
        AND version = \(expectedVersion)
      RETURNING id, gap_id, source_mode, status, start_cursor, end_cursor, checkpoint_cursor,
        collections::text, author_dids::text, batch_size, rate_limit, max_concurrency,
        estimated_count, processed_count, failed_count, reconciled_count, requested_by_did,
        audit_note, failure_reason, lease_owner, lease_expires_at, created_at, updated_at,
        completed_at, version, verification_status, verification_reason, scope_truncated,
        validation_watermark, author_results::text
      """, logger: logger)
    for try await row in rows { return try decodeBackfill(row) }
    throw OperationsStoreError.leaseConflict
  }

  public func checkpointBackfill(
    id: String, workerId: String, expectedVersion: Int, cursor: Int64?, processed: Int,
    failed: Int, reconciled: Int, leaseUntil: Date, at: Date
  ) async throws -> BackfillJob {
    guard processed >= 0, failed >= 0, reconciled >= 0, failed <= processed,
      reconciled <= processed, leaseUntil > at else {
      throw OperationsStoreError.invalidProgress
    }
    guard let current = try await fetchBackfill(id: id) else {
      throw OperationsStoreError.notFound
    }
    guard current.version == expectedVersion else {
      throw OperationsStoreError.versionConflict(expected: expectedVersion, actual: current.version)
    }
    guard processed >= current.processedCount, failed >= current.failedCount,
      reconciled >= current.reconciledCount
    else { throw OperationsStoreError.invalidProgress }
    if let cursor {
      guard current.checkpointCursor.map({ cursor >= $0 }) ?? true,
        current.startCursor.map({ cursor >= $0 }) ?? true,
        current.endCursor.map({ cursor <= $0 }) ?? true
      else { throw OperationsStoreError.invalidProgress }
    }
    return try await mutateOwnedBackfill(
      id: id, workerId: workerId, expectedVersion: expectedVersion, leaseUntil: leaseUntil,
      at: at, checkpoint: cursor, processed: processed, failed: failed, reconciled: reconciled,
      verification: nil)
  }

  public func checkpointBackfill(
    id: String,
    cursor: Int64?,
    processed: Int,
    failed: Int,
    reconciled: Int,
    leaseUntil: Date,
    at: Date
  ) async throws {
    guard let current = try await fetchBackfill(id: id), let workerId = current.leaseOwner else {
      throw OperationsStoreError.leaseConflict
    }
    _ = try await checkpointBackfill(
      id: id, workerId: workerId, expectedVersion: current.version, cursor: cursor,
      processed: processed, failed: failed, reconciled: reconciled,
      leaseUntil: leaseUntil, at: at)
  }

  public func listAlerts(limit: Int) async throws -> [OperationsAlert] {
    try await listAlerts(limit: limit, before: nil).items
  }

  public func listAlerts(limit: Int, before: String?) async throws
    -> OperationsPage<OperationsAlert>
  {
    try await listAlerts(view: .all, limit: limit, before: before)
  }

  public func listAlerts(view: AlertListView, limit: Int, before: String?) async throws
    -> OperationsPage<OperationsAlert>
  {
    let limit = max(1, min(limit, 250))
    let statuses: [String]
    switch view {
    case .active: statuses = ["open", "acknowledged"]
    case .history: statuses = ["resolved"]
    case .all: statuses = ["open", "acknowledged", "resolved"]
    }
    let beforeCursor = try Self.decodeCursor(before)
    let beforeDate = beforeCursor?.date
    let beforeId = beforeCursor?.id
    let rows = try await pool.query(
      """
      SELECT id, rule, condition_key, severity, status, summary, evidence::text, runbook_slug,
             opened_at, updated_at, acknowledged_by_did, resolved_by_did,
             delivery_attempts, last_delivery_error, next_delivery_at,
             delivery_dead_lettered_at, version
      FROM operations_alerts
      WHERE environment = \(environment)
        AND status = ANY(\(statuses))
        AND (\(beforeDate)::timestamptz IS NULL OR opened_at < \(beforeDate)::timestamptz
          OR (opened_at = \(beforeDate)::timestamptz AND id < \(beforeId)::text))
      ORDER BY opened_at DESC, id DESC
      LIMIT \(limit + 1)
      """,
      logger: logger
    )
    var result: [OperationsAlert] = []
    for try await row in rows {
      result.append(try decodeAlert(row))
    }
    let countRows = try await pool.query(
      "SELECT COUNT(*)::bigint FROM operations_alerts WHERE environment = \(environment) AND status = ANY(\(statuses))",
      logger: logger)
    var total = 0
    for try await row in countRows { total = Int(try row.decode(Int64.self)); break }
    let items = Array(result.prefix(limit))
    let next = result.count > limit
      ? items.last.map { OperationsPaginationCursor.encode(date: $0.openedAt, id: $0.id) } : nil
    return OperationsPage(items: items, nextCursor: next, totalCount: total)
  }

  public func openAlert(
    rule: String,
    conditionKey: String,
    severity: String,
    summary: String,
    evidence: [String: String],
    runbookSlug: String,
    at: Date
  ) async throws -> OperationsAlert {
    let id = UUID().uuidString.lowercased()
    let evidenceJSON = try json(OperationsRedactor.boundedAttributes(evidence))
    let rows = try await pool.query(
      """
      INSERT INTO operations_alerts
        (environment, id, rule, condition_key, severity, status, summary, evidence, runbook_slug,
         opened_at, updated_at, next_delivery_at, version)
      VALUES
        (\(environment), \(id), \(String(rule.prefix(128))), \(String(conditionKey.prefix(192))),
         \(String(severity.prefix(32))), 'open',
         \(String(summary.prefix(512))), \(evidenceJSON)::jsonb, \(String(runbookSlug.prefix(128))), \(at), \(at), \(at), 0)
      ON CONFLICT (environment, condition_key)
        WHERE environment <> '__legacy_unscoped__' AND status != 'resolved' DO UPDATE SET
        severity = EXCLUDED.severity, summary = EXCLUDED.summary, evidence = EXCLUDED.evidence,
        runbook_slug = EXCLUDED.runbook_slug, updated_at = EXCLUDED.updated_at,
        version = operations_alerts.version + 1
      RETURNING id, rule, condition_key, severity, status, summary, evidence::text, runbook_slug,
        opened_at, updated_at, acknowledged_by_did, resolved_by_did, delivery_attempts,
        last_delivery_error, next_delivery_at, delivery_dead_lettered_at, version
      """,
      logger: logger
    )
    for try await row in rows { return try decodeAlert(row) }
    throw OperationsStoreError.missingCreatedRecord
  }

  public func resolveAlert(conditionKey: String, at: Date) async throws {
    try await pool.withTransaction(logger: logger) { connection in
      let rows = try await connection.query(
        """
        UPDATE operations_alerts SET status = 'resolved', resolved_by_did = 'system:evaluator',
          updated_at = \(at), expires_at = \(at.addingTimeInterval(365 * 86_400)),
          version = version + 1
        WHERE environment = \(environment) AND condition_key = \(conditionKey) AND status != 'resolved'
        RETURNING id
        """, logger: logger)
      var ids: [String] = []
      for try await row in rows { ids.append(try row.decode(String.self)) }
      for id in ids {
        try await extendLifecycleRetention(
          connection: connection, targetType: "alert", targetId: id, terminalAt: at)
      }
    }
  }

  public func listAlertsPendingDelivery(limit: Int, at: Date) async throws -> [OperationsAlert] {
    let rows = try await pool.query(
      """
      SELECT id, rule, condition_key, severity, status, summary, evidence::text, runbook_slug,
        opened_at, updated_at, acknowledged_by_did, resolved_by_did, delivery_attempts,
        last_delivery_error, next_delivery_at, delivery_dead_lettered_at, version
      FROM operations_alerts
      WHERE environment = \(environment) AND status != 'resolved'
        AND delivery_dead_lettered_at IS NULL AND next_delivery_at <= \(at)
      ORDER BY next_delivery_at, opened_at LIMIT \(max(1, min(limit, 100)))
      """, logger: logger)
    var result: [OperationsAlert] = []
    for try await row in rows { result.append(try decodeAlert(row)) }
    return result
  }

  public func updateAlertStatus(
    id: String,
    status: OperationsAlertStatus,
    operatorDid: String,
    at: Date
  ) async throws {
    guard let current = try await fetchAlert(id: id) else { throw OperationsStoreError.notFound }
    _ = try await transitionAlert(
      id: id, to: status, expectedVersion: current.version, operatorDid: operatorDid,
      idempotencyKey: UUID().uuidString.lowercased(), requestId: nil, note: nil, at: at)
  }

  public func transitionAlert(
    id: String, to status: OperationsAlertStatus, expectedVersion: Int, operatorDid: String,
    idempotencyKey: String, requestId: String? = nil, note: String?, at: Date
  ) async throws -> OperationsAlert {
    let actionName = "alert.\(status.rawValue)"
    let requestFingerprint = OperationsIdempotencyFingerprint.make(
      action: actionName, targetType: "alert", targetId: id, expectedVersion: expectedVersion,
      fields: ["operatorDid": operatorDid, "note": note, "status": status.rawValue])
    return try await pool.withTransaction(logger: logger) { connection in
      if let existing = try await existingIdempotency(
        connection: connection, key: idempotencyKey, action: actionName,
        targetType: "alert", targetId: id, requestFingerprint: requestFingerprint)
      {
        let replay = try replayIdempotencyResult(existing, as: OperationsAlert.self)
        let afterJSON = try json([
          "status": replay.status.rawValue, "version": String(replay.version),
        ])
        try await connection.query(
          Self.auditInsert(
            environment: environment, operatorDid: operatorDid, action: actionName,
            targetType: "alert", targetId: replay.id, idempotencyKey: idempotencyKey,
            requestId: requestId, expectedVersion: expectedVersion, note: note,
            beforeJSON: "{}", afterJSON: afterJSON, outcome: "idempotent_replay", at: at),
          logger: logger)
        return replay
      }
      let currentRows = try await connection.query(
        Self.alertSelect(environment: environment, id: id, forUpdate: true), logger: logger)
      var current: OperationsAlert?
      for try await row in currentRows { current = try decodeAlert(row); break }
      guard let current else { throw OperationsStoreError.notFound }
      guard current.version == expectedVersion else {
        throw OperationsStoreError.versionConflict(expected: expectedVersion, actual: current.version)
      }
      guard Self.canTransitionAlert(from: current.status, to: status) else {
        throw OperationsStoreError.invalidTransition(from: current.status.rawValue, to: status.rawValue)
      }
      let acknowledged = status == .acknowledged ? operatorDid : nil
      let resolved = status == .resolved ? operatorDid : nil
      let rows = try await connection.query(
        """
        UPDATE operations_alerts SET status = \(status.rawValue), updated_at = \(at),
          acknowledged_by_did = COALESCE(\(acknowledged), acknowledged_by_did),
          resolved_by_did = COALESCE(\(resolved), resolved_by_did),
          expires_at = CASE WHEN \(status.rawValue) = 'resolved'
            THEN \(at.addingTimeInterval(365 * 86_400)) ELSE expires_at END,
          version = version + 1
        WHERE environment = \(environment) AND id = \(id) AND version = \(expectedVersion)
        RETURNING id, rule, condition_key, severity, status, summary, evidence::text, runbook_slug,
          opened_at, updated_at, acknowledged_by_did, resolved_by_did, delivery_attempts,
          last_delivery_error, next_delivery_at, delivery_dead_lettered_at, version
        """, logger: logger)
      var updated: OperationsAlert?
      for try await row in rows { updated = try decodeAlert(row); break }
      guard let updated else {
        throw OperationsStoreError.versionConflict(expected: expectedVersion, actual: current.version + 1)
      }
      if status == .resolved {
        try await extendLifecycleRetention(
          connection: connection, targetType: "alert", targetId: id, terminalAt: at)
      }
      try await insertIdempotency(
        connection: connection, key: idempotencyKey, action: actionName,
        targetType: "alert", targetId: id, outcome: "succeeded",
        requestFingerprint: requestFingerprint,
        resultPayload: try json(updated), at: at)
      let beforeJSON = try json(["status": current.status.rawValue, "version": String(current.version)])
      let afterJSON = try json(["status": updated.status.rawValue, "version": String(updated.version)])
      try await connection.query(
        Self.auditInsert(
          environment: environment, operatorDid: operatorDid, action: actionName,
          targetType: "alert", targetId: id, idempotencyKey: idempotencyKey,
          requestId: requestId, expectedVersion: expectedVersion, note: note,
          beforeJSON: beforeJSON, afterJSON: afterJSON, outcome: "succeeded", at: at),
        logger: logger)
      return updated
    }
  }

  public func retryAlertDelivery(
    id: String, expectedVersion: Int, operatorDid: String, idempotencyKey: String,
    requestId: String? = nil, note: String?, at: Date
  ) async throws -> OperationsAlert {
    let actionName = "alert.delivery_retry"
    let requestFingerprint = OperationsIdempotencyFingerprint.make(
      action: actionName, targetType: "alert", targetId: id, expectedVersion: expectedVersion,
      fields: ["operatorDid": operatorDid, "note": note])
    return try await pool.withTransaction(logger: logger) { connection in
      if let existing = try await existingIdempotency(
        connection: connection, key: idempotencyKey, action: actionName,
        targetType: "alert", targetId: id, requestFingerprint: requestFingerprint)
      {
        let replay = try replayIdempotencyResult(existing, as: OperationsAlert.self)
        let afterJSON = try json([
          "status": replay.status.rawValue, "version": String(replay.version),
        ])
        try await connection.query(
          Self.auditInsert(
            environment: environment, operatorDid: operatorDid, action: actionName,
            targetType: "alert", targetId: replay.id, idempotencyKey: idempotencyKey,
            requestId: requestId, expectedVersion: expectedVersion, note: note,
            beforeJSON: "{}", afterJSON: afterJSON, outcome: "idempotent_replay", at: at),
          logger: logger)
        return replay
      }
      let currentRows = try await connection.query(
        Self.alertSelect(environment: environment, id: id, forUpdate: true), logger: logger)
      var current: OperationsAlert?
      for try await row in currentRows { current = try decodeAlert(row); break }
      guard let current else { throw OperationsStoreError.notFound }
      guard current.version == expectedVersion else {
        throw OperationsStoreError.versionConflict(expected: expectedVersion, actual: current.version)
      }
      guard current.status != .resolved else {
        throw OperationsStoreError.invalidTransition(from: current.status.rawValue, to: "delivery_retry")
      }
      let rows = try await connection.query(
        """
        UPDATE operations_alerts SET next_delivery_at = \(at), delivery_dead_lettered_at = NULL,
          delivery_attempts = 0, last_delivery_error = NULL, updated_at = \(at),
          version = version + 1
        WHERE environment = \(environment) AND id = \(id) AND status != 'resolved'
          AND version = \(expectedVersion)
        RETURNING id, rule, condition_key, severity, status, summary, evidence::text, runbook_slug,
          opened_at, updated_at, acknowledged_by_did, resolved_by_did, delivery_attempts,
          last_delivery_error, next_delivery_at, delivery_dead_lettered_at, version
        """, logger: logger)
      var updated: OperationsAlert?
      for try await row in rows { updated = try decodeAlert(row); break }
      guard let updated else {
        throw OperationsStoreError.versionConflict(expected: expectedVersion, actual: current.version + 1)
      }
      try await insertIdempotency(
        connection: connection, key: idempotencyKey, action: actionName,
        targetType: "alert", targetId: id, outcome: "queued",
        requestFingerprint: requestFingerprint,
        resultPayload: try json(updated), at: at)
      let beforeJSON = try json([
        "status": current.status.rawValue, "version": String(current.version),
        "deliveryAttempts": String(current.deliveryAttempts),
      ])
      let afterJSON = try json([
        "delivery": "queued", "deliveryAttempts": "0", "version": String(updated.version),
      ])
      try await connection.query(
        Self.auditInsert(
          environment: environment, operatorDid: operatorDid, action: actionName,
          targetType: "alert", targetId: id, idempotencyKey: idempotencyKey,
          requestId: requestId, expectedVersion: expectedVersion, note: note,
          beforeJSON: beforeJSON, afterJSON: afterJSON, outcome: "queued", at: at),
        logger: logger)
      return updated
    }
  }

  public func recordAlertDelivery(id: String, error: String?, at: Date) async throws {
    try await pool.withTransaction(logger: logger) { connection in
      let rows = try await connection.query(
        """
        SELECT delivery_attempts FROM operations_alerts
        WHERE environment = \(environment) AND id = \(id) AND status != 'resolved'
        FOR UPDATE
        """, logger: logger)
      var attemptsBefore: Int?
      for try await row in rows { attemptsBefore = try row.decode(Int.self); break }
      guard let attemptsBefore else { return }
      let attempts = attemptsBefore + 1
      let deadLetteredAt: Date? = error != nil
        && attempts >= OperationsAlertDeliveryRetryPolicy.maximumAttempts ? at : nil
      let nextDeliveryAt: Date? = error != nil
        && attempts < OperationsAlertDeliveryRetryPolicy.maximumAttempts
        ? at.addingTimeInterval(
          OperationsAlertDeliveryRetryPolicy.delaySeconds(alertId: id, attempt: attempts)) : nil
      try await connection.query(
        """
        UPDATE operations_alerts SET delivery_attempts = delivery_attempts + 1,
          last_delivery_error = \(error.map { String($0.prefix(256)) }),
          next_delivery_at = \(nextDeliveryAt),
          delivery_dead_lettered_at = \(deadLetteredAt), updated_at = \(at),
          version = version + 1
        WHERE environment = \(environment) AND id = \(id) AND status != 'resolved'
        """, logger: logger)
    }
  }

  public func listTraceSpans(limit: Int, traceId: String?) async throws -> [TraceSpan] {
    let limit = max(1, min(limit, 500))
    let rows: PostgresRowSequence
    if let traceId {
      rows = try await pool.query(
        """
        SELECT id, trace_id, parent_span_id, service, name, started_at, duration_ms, status,
               attributes::text, expires_at
        FROM operations_trace_spans
        WHERE environment = \(environment) AND trace_id = \(traceId)
        ORDER BY started_at DESC
        LIMIT \(limit)
        """,
        logger: logger
      )
    } else {
      rows = try await pool.query(
        """
        SELECT id, trace_id, parent_span_id, service, name, started_at, duration_ms, status,
               attributes::text, expires_at
        FROM operations_trace_spans
        WHERE environment = \(environment)
        ORDER BY started_at DESC
        LIMIT \(limit)
        """,
        logger: logger
      )
    }
    var result: [TraceSpan] = []
    for try await row in rows {
      let value = try row.decode(
        (String, String, String?, String, String, Date, Double, String, String, Date).self)
      result.append(
        TraceSpan(
          id: value.0,
          environment: environment,
          traceId: value.1,
          parentSpanId: value.2,
          service: value.3,
          name: value.4,
          startedAt: value.5,
          durationMs: value.6,
          status: value.7,
          attributes: decodeJSON([String: String].self, from: value.8) ?? [:],
          expiresAt: value.9
        )
      )
    }
    return result
  }

  public func listTraceSpans(startAt: Date, endAt: Date, limit: Int) async throws -> [TraceSpan] {
    let limit = max(1, min(limit, 500))
    let rows = try await pool.query(
      """
      SELECT id, trace_id, parent_span_id, service, name, started_at, duration_ms, status,
             attributes::text, expires_at
      FROM operations_trace_spans
      WHERE environment = \(environment) AND started_at >= \(startAt) AND started_at <= \(endAt)
      ORDER BY started_at ASC
      LIMIT \(limit)
      """,
      logger: logger
    )
    var result: [TraceSpan] = []
    for try await row in rows {
      let value = try row.decode(
        (String, String, String?, String, String, Date, Double, String, String, Date).self)
      result.append(
        TraceSpan(
          id: value.0,
          environment: environment,
          traceId: value.1,
          parentSpanId: value.2,
          service: value.3,
          name: value.4,
          startedAt: value.5,
          durationMs: value.6,
          status: value.7,
          attributes: decodeJSON([String: String].self, from: value.8) ?? [:],
          expiresAt: value.9
        )
      )
    }
    return result
  }

  public func listTraceSpans(
    startAt: Date,
    endAt: Date,
    limit: Int,
    before: String?
  ) async throws -> OperationsPage<TraceSpan> {
    let limit = max(1, min(limit, 500))
    let decodedCursor = try Self.decodeCursor(before)
    let beforeDate = decodedCursor?.date
    let beforeId = decodedCursor?.id
    let rows = try await pool.query(
      """
      SELECT id, trace_id, parent_span_id, service, name, started_at, duration_ms, status,
             attributes::text, expires_at
      FROM operations_trace_spans
      WHERE environment = \(environment) AND started_at >= \(startAt) AND started_at <= \(endAt)
        AND (\(beforeDate)::timestamptz IS NULL OR started_at < \(beforeDate)::timestamptz
          OR (started_at = \(beforeDate)::timestamptz AND id < \(beforeId)::text))
      ORDER BY started_at DESC, id DESC LIMIT \(limit + 1)
      """, logger: logger)
    var decoded: [TraceSpan] = []
    for try await row in rows {
      let value = try row.decode(
        (String, String, String?, String, String, Date, Double, String, String, Date).self)
      decoded.append(TraceSpan(
        id: value.0, environment: environment, traceId: value.1, parentSpanId: value.2,
        service: value.3, name: value.4, startedAt: value.5, durationMs: value.6,
        status: value.7, attributes: decodeJSON([String: String].self, from: value.8) ?? [:],
        expiresAt: value.9))
    }
    let countRows = try await pool.query(
      """
      SELECT COUNT(*)::bigint FROM operations_trace_spans
      WHERE environment = \(environment) AND started_at >= \(startAt) AND started_at <= \(endAt)
      """, logger: logger)
    var total = 0
    for try await row in countRows { total = Int(try row.decode(Int64.self)); break }
    let items = Array(decoded.prefix(limit))
    let next = decoded.count > limit
      ? items.last.map { OperationsPaginationCursor.encode(date: $0.startedAt, id: $0.id) } : nil
    return OperationsPage(items: items, nextCursor: next, totalCount: total)
  }

  public func recordTraceSpan(_ span: TraceSpan) async throws {
    try await recordTelemetryBatch([.span(span)])
  }

  public func recordMetric(_ sample: OperationsMetricSample) async throws {
    try await recordTelemetryBatch([.metric(sample)])
  }

  public func listMetricRollups(startAt: Date, endAt: Date, limit: Int) async throws
    -> [OperationsMetricRollup]
  {
    let limit = max(1, min(limit, 10_000))
    let rows = try await pool.query(
      """
      SELECT bucket_start, metric_name, dimensions::text, sample_count, value_sum, value_min, value_max
      FROM operations_metric_rollups
      WHERE environment = \(environment) AND bucket_start >= \(startAt) AND bucket_start <= \(endAt)
      ORDER BY bucket_start ASC, metric_name ASC, dimensions_hash ASC
      LIMIT \(limit)
      """,
      logger: logger
    )
    var result: [OperationsMetricRollup] = []
    for try await row in rows {
      let value = try row.decode((Date, String, String, Int, Double, Double?, Double?).self)
      result.append(
        OperationsMetricRollup(
          environment: environment,
          bucketStart: value.0,
          metricName: value.1,
          dimensions: decodeJSON([String: String].self, from: value.2) ?? [:],
          sampleCount: value.3,
          valueSum: value.4,
          valueMin: value.5,
          valueMax: value.6
        )
      )
    }
    return result
  }

  public func listMetricRollups(
    startAt: Date,
    endAt: Date,
    metricName: String?,
    collection: String?,
    limit: Int
  ) async throws -> [OperationsMetricRollup] {
    let rows = try await pool.query(
      """
      SELECT bucket_start, metric_name, dimensions::text, sample_count, value_sum, value_min, value_max
      FROM operations_metric_rollups
      WHERE environment = \(environment) AND bucket_start >= \(startAt) AND bucket_start <= \(endAt)
        AND (\(metricName)::text IS NULL OR metric_name = \(metricName)::text)
        AND (\(collection)::text IS NULL OR dimensions->>'collection' = \(collection)::text)
      ORDER BY bucket_start ASC, metric_name ASC, dimensions_hash ASC
      LIMIT \(max(1, min(limit, 10_000)))
      """, logger: logger)
    var result: [OperationsMetricRollup] = []
    for try await row in rows {
      let value = try row.decode((Date, String, String, Int, Double, Double?, Double?).self)
      result.append(OperationsMetricRollup(
        environment: environment, bucketStart: value.0, metricName: value.1,
        dimensions: decodeJSON([String: String].self, from: value.2) ?? [:],
        sampleCount: value.3, valueSum: value.4, valueMin: value.5, valueMax: value.6))
    }
    return result
  }

  public func listGapInvestigationEvents(startAt: Date, endAt: Date, limit: Int) async throws
    -> [OperationsEvent]
  {
    let limit = max(1, min(limit, 500))
    let rows = try await pool.query(
      """
      SELECT id, service, environment, instance_id, event_name, occurred_at,
             request_id, trace_id, attributes::text
      FROM operations_events
      WHERE environment = \(environment) AND occurred_at >= \(startAt) AND occurred_at <= \(endAt)
        AND event_name IN ('jetstream.disconnected', 'jetstream.connected', 'commit.failed')
      ORDER BY occurred_at ASC
      LIMIT \(limit)
      """,
      logger: logger
    )
    var result: [OperationsEvent] = []
    for try await row in rows {
      let value = try row.decode(
        (String, String, String, String, String, Date, String?, String?, String).self)
      result.append(
        OperationsEvent(
          id: value.0,
          service: value.1,
          environment: value.2,
          instanceId: value.3,
          name: value.4,
          occurredAt: value.5,
          requestId: value.6,
          traceId: value.7,
          attributes: decodeJSON([String: String].self, from: value.8) ?? [:]
        )
      )
    }
    return result
  }

  public func recordEvent(_ event: OperationsEvent) async throws {
    try await recordTelemetryBatch([.event(event)])
  }

  public func recordTelemetryBatch(_ signals: [OperationsTelemetrySignal]) async throws {
    guard !signals.isEmpty else { return }
    var prepared: [PreparedTelemetry] = []
    prepared.reserveCapacity(signals.count)
    // Every writer must acquire rollup index keys in the same order. Without this ordering,
    // concurrent batches containing the same metrics in different sequences can deadlock while
    // PostgreSQL resolves their ON CONFLICT updates.
    for signal in OperationsTelemetrySignalOrder.sorted(signals) {
      switch signal {
      case .metric(let sample):
        if let sampleEnvironment = sample.dimensions["environment"], sampleEnvironment != environment {
          throw OperationsStoreError.environmentMismatch(
            expected: environment, actual: sampleEnvironment)
        }
        let dimensions = OperationsRedactor.boundedAttributes(sample.dimensions)
        let dimensionsJSON = try json(dimensions)
        let key = dimensions.sorted { $0.key < $1.key }
          .map { "\($0.key)=\($0.value)" }.joined(separator: "&")
        let bucket = Date(
          timeIntervalSince1970: floor(sample.recordedAt.timeIntervalSince1970 / 60) * 60)
        prepared.append(.metric(
          sample, dimensionsJSON: dimensionsJSON,
          dimensionsHash: OperationsRedactor.hashIdentity(key), bucket: bucket))
      case .event(let event):
        guard event.environment == environment else {
          throw OperationsStoreError.environmentMismatch(expected: environment, actual: event.environment)
        }
        prepared.append(.event(
          event, attributesJSON: try json(OperationsRedactor.boundedAttributes(event.attributes))))
      case .span(let span):
        guard span.environment == environment else {
          throw OperationsStoreError.environmentMismatch(expected: environment, actual: span.environment)
        }
        prepared.append(.span(
          span, attributesJSON: try json(OperationsRedactor.boundedAttributes(span.attributes))))
      }
    }
    try await pool.withTransaction(logger: logger) { connection in
      for item in prepared {
        switch item {
        case .metric(let sample, let dimensionsJSON, let dimensionsHash, let bucket):
          try await connection.query(
            """
            INSERT INTO operations_metric_rollups
              (environment, bucket_start, metric_name, dimensions_hash, dimensions, sample_count,
               value_sum, value_min, value_max, histogram_buckets, expires_at)
            VALUES (\(environment), \(bucket), \(String(sample.name.prefix(160))),
              \(dimensionsHash), \(dimensionsJSON)::jsonb, 1, \(sample.value), \(sample.value),
              \(sample.value), '{}'::jsonb, \(bucket.addingTimeInterval(90 * 86_400)))
            ON CONFLICT (environment, bucket_start, metric_name, dimensions_hash) DO UPDATE SET
              sample_count = operations_metric_rollups.sample_count + 1,
              value_sum = operations_metric_rollups.value_sum + EXCLUDED.value_sum,
              value_min = LEAST(operations_metric_rollups.value_min, EXCLUDED.value_min),
              value_max = GREATEST(operations_metric_rollups.value_max, EXCLUDED.value_max)
            """, logger: logger)
        case .event(let event, let attributesJSON):
          try await connection.query(
            """
            INSERT INTO operations_events
              (id, service, environment, instance_id, event_name, occurred_at, request_id,
               trace_id, attributes, expires_at)
            VALUES (\(event.id), \(event.service), \(event.environment), \(event.instanceId),
              \(String(event.name.prefix(160))), \(event.occurredAt), \(event.requestId),
              \(event.traceId), \(attributesJSON)::jsonb,
              \(event.occurredAt.addingTimeInterval(30 * 86_400)))
            ON CONFLICT (environment, id) DO NOTHING
            """, logger: logger)
        case .span(let span, let attributesJSON):
          try await connection.query(
            """
            INSERT INTO operations_trace_spans
              (environment, id, trace_id, parent_span_id, service, name, started_at, duration_ms,
               status, attributes, expires_at)
            VALUES (\(environment), \(span.id), \(span.traceId), \(span.parentSpanId),
              \(span.service), \(span.name), \(span.startedAt), \(span.durationMs),
              \(span.status), \(attributesJSON)::jsonb, \(span.expiresAt))
            ON CONFLICT (environment, id) DO NOTHING
            """, logger: logger)
        }
      }
    }
  }

  public func appendChangeEvent(
    eventType: String,
    entityType: String,
    entityId: String?,
    payload: [String: String],
    at: Date
  ) async throws -> OperationsChangeEvent {
    let payloadJSON = try json(payload)
    let rows = try await pool.query(
      """
      SELECT operations_append_change_event(
        \(environment), \(String(eventType.prefix(160))), \(String(entityType.prefix(64))),
        \(entityId), \(payloadJSON)::jsonb, \(at))
      """, logger: logger)
    for try await row in rows {
      let cursor = try row.decode(Int64.self)
      return OperationsChangeEvent(
        environment: environment, cursor: cursor, eventType: String(eventType.prefix(160)),
        entityType: String(entityType.prefix(64)), entityId: entityId, payload: payload,
        occurredAt: at)
    }
    throw OperationsStoreError.missingCreatedRecord
  }

  public func listChangeEvents(after cursor: Int64, limit: Int) async throws
    -> [OperationsChangeEvent]
  {
    let rows = try await pool.query(
      """
      SELECT cursor, event_type, entity_type, entity_id, payload::text, occurred_at
      FROM operations_change_events
      WHERE environment = \(environment) AND cursor > \(max(0, cursor))
      ORDER BY cursor ASC LIMIT \(max(1, min(limit, 500)))
      """, logger: logger)
    var events: [OperationsChangeEvent] = []
    for try await row in rows {
      let value = try row.decode((Int64, String, String, String?, String, Date).self)
      events.append(OperationsChangeEvent(
        environment: environment, cursor: value.0, eventType: value.1,
        entityType: value.2, entityId: value.3,
        payload: decodeJSON([String: String].self, from: value.4) ?? [:],
        occurredAt: value.5))
    }
    return events
  }

  public func changeEventCursorBounds() async throws -> OperationsChangeEventCursorBounds {
    let rows = try await pool.query(
      """
      SELECT earliest_available_cursor, latest_cursor
      FROM operations_change_event_watermarks WHERE environment = \(environment)
      """, logger: logger)
    for try await row in rows {
      let value = try row.decode((Int64, Int64).self)
      return OperationsChangeEventCursorBounds(earliestAvailable: value.0, latest: value.1)
    }
    return OperationsChangeEventCursorBounds(earliestAvailable: 1, latest: 0)
  }

  public func recordAudit(
    operatorDid: String,
    action: String,
    targetType: String,
    targetId: String?,
    note: String?,
    at: Date
  ) async throws {
    let id = UUID().uuidString.lowercased()
    let expiresAt =
      Calendar.current.date(byAdding: .day, value: 365, to: at)
      ?? at.addingTimeInterval(365 * 86_400)
    try await pool.query(
      """
      INSERT INTO operations_audit_events
        (environment, id, operator_did, action, target_type, target_id, note,
         before_state, after_state, outcome, occurred_at, expires_at)
      VALUES
        (\(environment), \(id), \(operatorDid), \(String(action.prefix(128))), \(String(targetType.prefix(64))),
         \(targetId), \(note.map { String($0.prefix(280)) }), '{}'::jsonb, '{}'::jsonb,
         'recorded', \(at), \(expiresAt))
      """,
      logger: logger
    )
  }

  public func recordAudit(_ audit: OperationsMutationAudit) async throws {
    let id = UUID().uuidString.lowercased()
    let before = audit.before.merging(
      audit.expectedVersion.map { ["expectedVersion": String($0)] } ?? [:],
      uniquingKeysWith: { current, _ in current })
    let beforeJSON = try json(before)
    let afterJSON = try json(audit.after)
    let expiresAt = audit.occurredAt.addingTimeInterval(365 * 86_400)
    try await pool.query(
      """
      INSERT INTO operations_audit_events
        (environment, id, operator_did, action, target_type, target_id, idempotency_key,
         request_id, expected_version, note, before_state, after_state, outcome, occurred_at, expires_at)
      VALUES (\(environment), \(id), \(audit.operatorDid), \(String(audit.action.prefix(128))),
        \(String(audit.targetType.prefix(64))), \(audit.targetId), \(audit.idempotencyKey),
        \(String(audit.requestId.prefix(128))), \(audit.expectedVersion),
        \(audit.note.map { String($0.prefix(280)) }), \(beforeJSON)::jsonb, \(afterJSON)::jsonb,
        \(String(audit.outcome.prefix(32))), \(audit.occurredAt), \(expiresAt))
      """, logger: logger)
  }

  public func cleanupExpired(at: Date, batchSize: Int) async throws -> Int {
    let rows = try await pool.query(
      "SELECT operations_cleanup_expired(\(environment), \(at), \(max(1, min(batchSize, 10_000)))::integer)::bigint",
      logger: logger)
    for try await row in rows { return Int(try row.decode(Int64.self)) }
    return 0
  }

  private func decodeBackfills(_ rows: PostgresRowSequence) async throws -> [BackfillJob] {
    var result: [BackfillJob] = []
    for try await row in rows {
      result.append(try decodeBackfill(row))
    }
    return result
  }

  private func decodeCommands(_ rows: PostgresRowSequence) async throws -> [OperationsWorkerCommand] {
    var result: [OperationsWorkerCommand] = []
    for try await row in rows {
      let value = try row.decode(
        (String, String, String, String, String?, String?, Date?, String?, Date, Date, Date?, Int).self
      )
      guard
        let action = OperationsCommandAction(rawValue: value.1),
        let status = OperationsCommandStatus(rawValue: value.2)
      else { continue }
      result.append(
        OperationsWorkerCommand(
          id: value.0, environment: environment, action: action, status: status, requestedByDid: value.3,
          auditNote: value.4, claimedBy: value.5, leaseExpiresAt: value.6,
          failureReason: value.7, createdAt: value.8, updatedAt: value.9,
          completedAt: value.10, version: value.11
        )
      )
    }
    return result
  }

  private func decodeGaps(_ rows: PostgresRowSequence) async throws -> [IngestionGap] {
    var result: [IngestionGap] = []
    for try await row in rows { result.append(try decodeGap(row)) }
    return result
  }

  private func decodeGap(_ row: PostgresRow) throws -> IngestionGap {
    let value = try row.decode(
      (
        String, String, Int64?, Int64?, Date?, Date?, String, String, String, Date, Date, String?,
        Int, Int, Int, Int, Int
      ).self)
    return IngestionGap(
      id: value.0, environment: environment, source: value.1, startCursor: value.2,
      endCursor: value.3, startTime: value.4, endTime: value.5, reason: value.6,
      status: IngestionGapStatus(rawValue: value.7) ?? .suspected,
      collections: decodeJSON([String].self, from: value.8) ?? [], detectedAt: value.9,
      updatedAt: value.10, backfillJobId: value.11, discoveredCount: value.12,
      processedCount: value.13, failedCount: value.14, reconciledCount: value.15,
      version: value.16)
  }

  private func decodeBackfill(_ row: PostgresRow) throws -> BackfillJob {
    let value = try row.decode(
      (
        String, String?, String, String, Int64?, Int64?, Int64?, String, String, Int, Int, Int,
        Int, Int, Int, Int, String, String?, String?, String?, Date?, Date, Date, Date?, Int,
        String, String?, Bool, String?, String
      ).self)
    return BackfillJob(
      id: value.0, environment: environment, gapId: value.1,
      sourceMode: BackfillSourceMode(rawValue: value.2) ?? .jetstreamReplay,
      status: BackfillJobStatus(rawValue: value.3) ?? .queued,
      startCursor: value.4, endCursor: value.5, checkpointCursor: value.6,
      collections: decodeJSON([String].self, from: value.7) ?? [],
      authorDids: decodeJSON([String].self, from: value.8) ?? [],
      authorResults: DefaultEmptyArray(
        wrappedValue: decodeJSON([BackfillAuthorResult].self, from: value.29) ?? []),
      batchSize: value.9,
      rateLimit: value.10, maxConcurrency: value.11, estimatedCount: value.12,
      processedCount: value.13, failedCount: value.14, reconciledCount: value.15,
      requestedByDid: value.16, auditNote: value.17, failureReason: value.18,
      leaseOwner: value.19, leaseExpiresAt: value.20, createdAt: value.21,
      updatedAt: value.22, completedAt: value.23, version: value.24,
      verificationStatus: BackfillVerificationStatus(rawValue: value.25) ?? .required,
      verificationReason: value.26, scopeTruncated: value.27, validationWatermark: value.28)
  }

  private func decodeAlert(_ row: PostgresRow) throws -> OperationsAlert {
    let value = try row.decode(
      (String, String, String, String, String, String, String, String, Date, Date, String?, String?,
       Int, String?, Date?, Date?, Int).self)
    return OperationsAlert(
      id: value.0, environment: environment, rule: value.1, conditionKey: value.2,
      severity: value.3, status: OperationsAlertStatus(rawValue: value.4) ?? .open,
      summary: value.5, evidence: decodeJSON([String: String].self, from: value.6) ?? [:],
      runbookSlug: value.7, openedAt: value.8, updatedAt: value.9,
      acknowledgedByDid: value.10, resolvedByDid: value.11, deliveryAttempts: value.12,
      lastDeliveryError: value.13, nextDeliveryAt: value.14,
      deliveryDeadLetteredAt: value.15, version: value.16)
  }

  public func fetchGap(id: String) async throws -> IngestionGap? {
    let rows = try await pool.query(Self.gapSelect(environment: environment, id: id), logger: logger)
    for try await row in rows { return try decodeGap(row) }
    return nil
  }

  public func fetchAlert(id: String) async throws -> OperationsAlert? {
    let rows = try await pool.query(
      """
      SELECT id, rule, condition_key, severity, status, summary, evidence::text, runbook_slug,
        opened_at, updated_at, acknowledged_by_did, resolved_by_did, delivery_attempts,
        last_delivery_error, next_delivery_at, delivery_dead_lettered_at, version
      FROM operations_alerts WHERE environment = \(environment) AND id = \(id) LIMIT 1
      """, logger: logger)
    for try await row in rows { return try decodeAlert(row) }
    return nil
  }

  private struct StoredIdempotencyResult {
    let targetId: String
    let resultPayload: String
  }

  private func existingIdempotency(
    connection: PostgresConnection,
    key: String,
    action: String,
    targetType: String,
    targetId: String?,
    requestFingerprint: String
  ) async throws -> StoredIdempotencyResult? {
    _ = try await connection.query(
      "SELECT pg_advisory_xact_lock(hashtextextended(\(environment) || '|' || \(key), 0))",
      logger: logger)
    let rows = try await connection.query(
      """
      SELECT action, target_type, target_id, request_fingerprint, result_payload::text
      FROM operations_idempotency_records
      WHERE environment = \(environment) AND idempotency_key = \(key) LIMIT 1
      """, logger: logger)
    for try await row in rows {
      let recorded = try row.decode((String, String, String?, String?, String).self)
      guard recorded.0 == action, recorded.1 == targetType,
        targetId == nil || recorded.2 == targetId,
        recorded.3 == requestFingerprint,
        !recorded.4.isEmpty,
        let recordedTargetId = recorded.2
      else { throw OperationsStoreError.idempotencyConflict }
      return StoredIdempotencyResult(targetId: recordedTargetId, resultPayload: recorded.4)
    }
    return nil
  }

  private func insertIdempotency(
    connection: PostgresConnection,
    key: String,
    action: String,
    targetType: String,
    targetId: String,
    outcome: String,
    requestFingerprint: String,
    resultPayload: String,
    at: Date
  ) async throws {
    try await connection.query(
      """
      INSERT INTO operations_idempotency_records
        (environment, idempotency_key, action, target_type, target_id, outcome,
         request_fingerprint, result_payload, created_at, expires_at)
      VALUES (\(environment), \(key), \(String(action.prefix(128))),
        \(String(targetType.prefix(64))), \(targetId), \(outcome), \(requestFingerprint),
        \(resultPayload)::jsonb, \(at),
        \(at.addingTimeInterval(365 * 86_400)))
      """, logger: logger)
  }

  private func extendLifecycleRetention(
    connection: PostgresConnection,
    targetType: String,
    targetId: String,
    terminalAt: Date
  ) async throws {
    let expiry = terminalAt.addingTimeInterval(365 * 86_400)
    try await connection.query(
      """
      UPDATE operations_audit_events SET expires_at = \(expiry)
      WHERE environment = \(environment) AND target_type = \(targetType)
        AND target_id = \(targetId)
      """, logger: logger)
    try await connection.query(
      """
      UPDATE operations_idempotency_records SET expires_at = \(expiry)
      WHERE environment = \(environment) AND target_type = \(targetType)
        AND target_id = \(targetId)
      """, logger: logger)
  }

  private func replayIdempotencyResult<T: Decodable>(
    _ stored: StoredIdempotencyResult,
    as type: T.Type
  ) throws -> T {
    guard let result = decodeJSON(type, from: stored.resultPayload) else {
      throw OperationsStoreError.idempotencyConflict
    }
    return result
  }

  private func recordRichAudit(
    operatorDid: String, action: String, targetType: String, targetId: String,
    idempotencyKey: String, note: String?, before: [String: String], after: [String: String],
    at: Date
  ) async throws {
    let beforeJSON = try json(before)
    let afterJSON = try json(after)
    try await pool.query(
      """
      INSERT INTO operations_audit_events
        (environment, id, operator_did, action, target_type, target_id, idempotency_key,
         note, before_state, after_state, outcome, occurred_at, expires_at)
      VALUES (\(environment), \(UUID().uuidString.lowercased()), \(operatorDid), \(action),
        \(targetType), \(targetId), \(idempotencyKey), \(note), \(beforeJSON)::jsonb,
        \(afterJSON)::jsonb, 'succeeded', \(at), \(at.addingTimeInterval(365 * 86_400)))
      """, logger: logger)
  }

  private func mutateOwnedBackfill(
    id: String, workerId: String, expectedVersion: Int, leaseUntil: Date, at: Date,
    checkpoint: Int64?, processed: Int?, failed: Int?, reconciled: Int?,
    verification: (BackfillVerificationStatus, String?, Bool, String?)?
  ) async throws -> BackfillJob {
    let verificationStatus = verification?.0.rawValue
    let verificationReason = verification?.1
    let scopeTruncated = verification?.2
    let validationWatermark = verification?.3
    let rows = try await pool.query(
      """
      UPDATE appview_backfill_jobs SET
        checkpoint_cursor = COALESCE(\(checkpoint), checkpoint_cursor),
        processed_count = COALESCE(\(processed), processed_count),
        failed_count = COALESCE(\(failed), failed_count),
        reconciled_count = COALESCE(\(reconciled), reconciled_count),
        verification_status = COALESCE(\(verificationStatus), verification_status),
        verification_reason = CASE WHEN \(verificationStatus)::text IS NULL THEN verification_reason ELSE \(verificationReason) END,
        scope_truncated = COALESCE(\(scopeTruncated), scope_truncated),
        validation_watermark = COALESCE(\(validationWatermark), validation_watermark),
        lease_expires_at = \(leaseUntil), updated_at = \(at), version = version + 1
      WHERE environment = \(environment) AND id = \(id) AND status = 'running'
        AND lease_owner = \(workerId) AND lease_expires_at >= \(at) AND version = \(expectedVersion)
      RETURNING id, gap_id, source_mode, status, start_cursor, end_cursor, checkpoint_cursor,
        collections::text, author_dids::text, batch_size, rate_limit, max_concurrency,
        estimated_count, processed_count, failed_count, reconciled_count, requested_by_did,
        audit_note, failure_reason, lease_owner, lease_expires_at, created_at, updated_at,
        completed_at, version, verification_status, verification_reason, scope_truncated,
        validation_watermark, author_results::text
      """, logger: logger)
    for try await row in rows { return try decodeBackfill(row) }
    throw OperationsStoreError.leaseConflict
  }

  private static func streamState(_ row: PostgresRow) throws -> IngestionStreamState {
    let values = row.makeRandomAccess()
    let environment = try values["environment"].decode(String.self)
    let source = try values["source"].decode(String.self)
    let connection = try values["connection_state"].decode(String.self)
    let queueObservedAt = try values["queue_observed_at"].decode(Date?.self)
    let queueEvidence = queueObservedAt.map {
      OperationsEvidenceMetadata(
        source: "\(source)_transport_queue",
        accuracy: .exact,
        generatedAt: $0,
        indexedThrough: $0,
        ageSeconds: Date().timeIntervalSince($0),
        validUntil: $0.addingTimeInterval(15),
        coverage: 1,
        lastSuccessfulAt: $0
      )
    }
    return IngestionStreamState(
      environment: environment,
      source: source,
      connectionState: IngestionConnectionState(rawValue: connection) ?? .unknown,
      connectedAt: try values["connected_at"].decode(Date?.self),
      lastDisconnectAt: try values["last_disconnect_at"].decode(Date?.self),
      lastDisconnectReason: try values["last_disconnect_reason"].decode(String?.self),
      lastReceivedCursor: try values["last_received_cursor"].decode(Int64?.self),
      lastReceivedEventAt: try values["last_received_event_at"].decode(Date?.self),
      lastReceivedAt: try values["last_received_at"].decode(Date?.self),
      lastCommittedCursor: try values["last_committed_cursor"].decode(Int64?.self),
      lastCommittedEventAt: try values["last_committed_event_at"].decode(Date?.self),
      lastCommittedAt: try values["last_committed_at"].decode(Date?.self),
      queueDepth: try values["queue_depth"].decode(Int.self),
      queueCapacity: try values["queue_capacity"].decode(Int?.self),
      queueOverflowTotal: try values["queue_overflow_total"].decode(Int64?.self),
      queueEvidence: queueEvidence,
      transportHeartbeatAt: try values["transport_heartbeat_at"].decode(Date?.self),
      lastIndexedMutationAt: try values["last_indexed_mutation_at"].decode(Date?.self),
      projectionWatermark: try values["projection_watermark"].decode(String?.self),
      validationWatermark: try values["validation_watermark"].decode(String?.self),
      heartbeatAt: try values["heartbeat_at"].decode(Date.self),
      version: try values["version"].decode(Int.self)
    )
  }

  private static func canTransitionGap(from: IngestionGapStatus, to: IngestionGapStatus) -> Bool {
    switch (from, to) {
    case (.suspected, .confirmed), (.suspected, .resolved),
      (.confirmed, .backfillQueued), (.confirmed, .ignored),
      (.backfillQueued, .backfilling), (.backfillQueued, .confirmed),
      (.backfilling, .resolved), (.backfilling, .verificationRequired),
      (.backfilling, .confirmed), (.verificationRequired, .resolved),
      (.verificationRequired, .confirmed), (.verificationRequired, .backfillQueued): return true
    default: return false
    }
  }

  private static func canTransitionBackfill(from: BackfillJobStatus, to: BackfillJobStatus) -> Bool {
    switch (from, to) {
    case (.queued, .running), (.queued, .cancelled), (.running, .paused),
      (.running, .completed), (.running, .failed), (.running, .cancelled),
      (.paused, .queued), (.paused, .cancelled): return true
    default: return false
    }
  }

  private static func linkedGapTransition(
    from jobStatus: BackfillJobStatus,
    to nextJobStatus: BackfillJobStatus
  ) -> (allowedFrom: [IngestionGapStatus], next: IngestionGapStatus)? {
    switch (jobStatus, nextJobStatus) {
    case (.queued, .cancelled):
      return ([.backfillQueued], .confirmed)
    case (.running, .completed):
      return ([.backfilling], .verificationRequired)
    case (.running, .failed), (.running, .cancelled), (.paused, .cancelled):
      return ([.backfilling], .confirmed)
    default:
      return nil
    }
  }

  private static func canTransitionAlert(from: OperationsAlertStatus, to: OperationsAlertStatus) -> Bool {
    switch (from, to) {
    case (.open, .acknowledged), (.open, .resolved), (.acknowledged, .resolved): return true
    default: return false
    }
  }

  private static func validateAuthorResults(_ results: [BackfillAuthorResult]) throws {
    guard results.count <= 5_000 else { throw OperationsStoreError.invalidProgress }
    let safeErrorCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789_,-")
    for result in results {
      guard ATProtoRepositoryDIDValidator.isValid(result.did),
        !result.collection.isEmpty, result.collection.count <= 200,
        result.discoveredCount >= 0, result.processedCount >= 0, result.failedCount >= 0,
        result.processedCount <= result.discoveredCount,
        result.failedCount == result.discoveredCount - result.processedCount
      else { throw OperationsStoreError.invalidProgress }
      if let error = result.error {
        guard error.count <= 240,
          error.unicodeScalars.allSatisfy({ safeErrorCharacters.contains($0) })
        else { throw OperationsStoreError.invalidProgress }
      }
    }
  }

  private static func decodeCursor(_ cursor: String?) throws -> OperationsPaginationCursor? {
    guard let cursor else { return nil }
    guard let decoded = OperationsPaginationCursor.decode(cursor) else {
      throw OperationsStoreError.invalidPaginationCursor
    }
    return decoded
  }

  private static func gapSelect(
    environment: String,
    id: String,
    forUpdate: Bool = false
  ) -> PostgresQuery {
    let lock = forUpdate ? "FOR UPDATE" : ""
    return """
      SELECT id, source, start_cursor, end_cursor, start_time, end_time, reason, status,
        collections::text, detected_at, updated_at, backfill_job_id, discovered_count,
        processed_count, failed_count, reconciled_count, version
      FROM appview_ingestion_gaps WHERE environment = \(environment) AND id = \(id)
      LIMIT 1 \(unescaped: lock)
      """
  }

  private static func backfillSelect(environment: String, id: String) -> PostgresQuery {
    """
    SELECT id, gap_id, source_mode, status, start_cursor, end_cursor, checkpoint_cursor,
      collections::text, author_dids::text, batch_size, rate_limit, max_concurrency,
      estimated_count, processed_count, failed_count, reconciled_count, requested_by_did,
      audit_note, failure_reason, lease_owner, lease_expires_at, created_at, updated_at,
      completed_at, version, verification_status, verification_reason, scope_truncated,
      validation_watermark, author_results::text
    FROM appview_backfill_jobs WHERE environment = \(environment) AND id = \(id) LIMIT 1
    """
  }

  private static func alertSelect(
    environment: String,
    id: String,
    forUpdate: Bool = false
  ) -> PostgresQuery {
    let lock = forUpdate ? "FOR UPDATE" : ""
    return """
      SELECT id, rule, condition_key, severity, status, summary, evidence::text, runbook_slug,
        opened_at, updated_at, acknowledged_by_did, resolved_by_did, delivery_attempts,
        last_delivery_error, next_delivery_at, delivery_dead_lettered_at, version
      FROM operations_alerts WHERE environment = \(environment) AND id = \(id)
      LIMIT 1 \(unescaped: lock)
      """
  }

  private static func auditInsert(
    environment: String,
    operatorDid: String,
    action: String,
    targetType: String,
    targetId: String,
    idempotencyKey: String,
    requestId: String?,
    expectedVersion: Int?,
    note: String?,
    beforeJSON: String,
    afterJSON: String,
    outcome: String,
    at: Date
  ) -> PostgresQuery {
    """
    INSERT INTO operations_audit_events
      (environment, id, operator_did, action, target_type, target_id, idempotency_key,
       request_id, expected_version, note, before_state, after_state, outcome,
       occurred_at, expires_at)
    VALUES (\(environment), \(UUID().uuidString.lowercased()), \(operatorDid),
      \(String(action.prefix(128))), \(String(targetType.prefix(64))), \(targetId),
      \(idempotencyKey), \(requestId.map { String($0.prefix(128)) }), \(expectedVersion),
      \(note.map { String($0.prefix(280)) }), \(beforeJSON)::jsonb,
      \(afterJSON)::jsonb, \(String(outcome.prefix(32))), \(at),
      \(at.addingTimeInterval(365 * 86_400)))
    """
  }

  private func json<T: Encodable>(_ value: T) throws -> String {
    let data = try encoder.encode(value)
    guard let string = String(data: data, encoding: .utf8) else {
      throw OperationsStoreError.jsonEncoding
    }
    return string
  }

  private func decodeJSON<T: Decodable>(_ type: T.Type, from string: String) -> T? {
    guard let data = string.data(using: .utf8) else { return nil }
    return try? decoder.decode(type, from: data)
  }
}

public enum OperationsStoreError: Error, Sendable, Equatable {
  case missingCreatedRecord
  case jsonEncoding
  case notFound
  case environmentMismatch(expected: String, actual: String)
  case versionConflict(expected: Int, actual: Int)
  case invalidTransition(from: String, to: String)
  case leaseConflict
  case invalidProgress
  case invalidBackfillFingerprint
  case idempotencyConflict
  case overlappingBackfill
  case backfillScopeChanged(reason: String)
  case invalidPaginationCursor
}
