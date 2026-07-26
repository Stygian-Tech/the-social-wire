import Foundation
@preconcurrency import GRDB
import Logging

public actor SQLiteOperationsStore: OperationsStore {
  public nonisolated let environment: String
  private let db: DatabasePool
  private let logger: Logger
  private let encoder = JSONEncoder()
  private let decoder = JSONDecoder()
  private let backfillFingerprintSecret: String?

  public init(
    path: String,
    environment: String,
    backfillFingerprintSecret: String? = nil,
    logger: Logger
  ) throws {
    self.environment = environment
    self.backfillFingerprintSecret = backfillFingerprintSecret
    self.logger = logger
    var configuration = Configuration()
    configuration.label = "com.thesocialwire.operations"
    db = try DatabasePool(path: path, configuration: configuration)
    try db.write { database in try Self.migrate(database) }
  }

  public func ping() async throws {
    _ = try await db.read { database in try Int.fetchOne(database, sql: "SELECT 1") }
  }

  public func upsertServiceState(_ state: OperationsServiceState) async throws {
    guard state.environment == environment else {
      throw OperationsStoreError.environmentMismatch(expected: environment, actual: state.environment)
    }
    let dependencies = try json(state.dependencyState)
    try await db.write { database in
      try database.execute(
        sql: """
          INSERT INTO operations_service_state
            (service, environment, instance_id, liveness, readiness, freshness, completeness,
             dependency_state, version, started_at, heartbeat_at)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          ON CONFLICT (service, environment, instance_id) DO UPDATE SET
            liveness = excluded.liveness, readiness = excluded.readiness,
            freshness = excluded.freshness, completeness = excluded.completeness,
            dependency_state = excluded.dependency_state, version = excluded.version,
            heartbeat_at = excluded.heartbeat_at
          """,
        arguments: [
          state.service, state.environment, state.instanceId, state.liveness.rawValue,
          state.readiness.rawValue, state.freshness.rawValue, state.completeness.rawValue,
          dependencies, state.version, Self.iso(state.startedAt), Self.iso(state.heartbeatAt),
        ]
      )
    }
  }

  public func listServiceStates() async throws -> [OperationsServiceState] {
    return try await db.read { database in
      try Row.fetchAll(
        database,
        sql: """
          SELECT * FROM operations_service_state
          WHERE environment = ? AND heartbeat_at > ?
          ORDER BY service, heartbeat_at DESC
          """,
        arguments: [environment, Self.iso(Date().addingTimeInterval(-120))]
      ).compactMap { row in
        guard
          let liveness = OperationsHealthState(rawValue: row["liveness"]),
          let readiness = OperationsHealthState(rawValue: row["readiness"]),
          let freshness = OperationsHealthState(rawValue: row["freshness"]),
          let completeness = OperationsHealthState(rawValue: row["completeness"]),
          let startedAt = Self.date(row["started_at"]),
          let heartbeatAt = Self.date(row["heartbeat_at"])
        else { return nil }
        let dependencyJSON: String = row["dependency_state"]
        return OperationsServiceState(
          service: row["service"],
          environment: row["environment"],
          instanceId: row["instance_id"],
          liveness: liveness,
          readiness: readiness,
          freshness: freshness,
          completeness: completeness,
          dependencyState: Self.decode([String: String].self, dependencyJSON) ?? [:],
          version: row["version"],
          startedAt: startedAt,
          heartbeatAt: heartbeatAt
        )
      }
    }
  }

  public func fetchStreamState(source: String) async throws -> IngestionStreamState? {
    return try await db.read { database in
      guard
        let row = try Row.fetchOne(
          database,
          sql: "SELECT * FROM appview_ingestion_stream_state WHERE environment = ? AND source = ? LIMIT 1",
          arguments: [environment, source]
        )
      else { return nil }
      return Self.streamState(row)
    }
  }

  public func listStreamStates() async throws -> [IngestionStreamState] {
    try await db.read { database in
      try Row.fetchAll(
        database,
        sql: "SELECT * FROM appview_ingestion_stream_state WHERE environment = ? ORDER BY source",
        arguments: [environment]
      ).compactMap(Self.streamState)
    }
  }

  public func markStreamConnected(source: String, at: Date) async throws {
    try await db.write { database in
      try database.execute(
        sql: """
          INSERT INTO appview_ingestion_stream_state
            (environment, source, connection_state, connected_at, transport_heartbeat_at,
             heartbeat_at, version)
          VALUES (?, ?, 'connected', ?, ?, ?, 1)
          ON CONFLICT (environment, source) DO UPDATE SET
            connection_state = 'connected', connected_at = excluded.connected_at,
            transport_heartbeat_at = excluded.transport_heartbeat_at,
            heartbeat_at = excluded.heartbeat_at, version = version + 1
          """,
        arguments: [environment, source, Self.iso(at), Self.iso(at), Self.iso(at)]
      )
    }
  }

  public func markStreamTransportHeartbeat(source: String, at: Date) async throws {
    try await db.write { database in
      try database.execute(
        sql: """
          INSERT INTO appview_ingestion_stream_state
            (environment, source, connection_state, connected_at, transport_heartbeat_at,
             heartbeat_at, version)
          VALUES (?, ?, 'connected', ?, ?, ?, 1)
          ON CONFLICT (environment, source) DO UPDATE SET
            connection_state = 'connected',
            transport_heartbeat_at = excluded.transport_heartbeat_at,
            heartbeat_at = excluded.heartbeat_at,
            version = version + 1
          """,
        arguments: [environment, source, Self.iso(at), Self.iso(at), Self.iso(at)]
      )
    }
  }

  public func markStreamDisconnected(source: String, reason: String, at: Date) async throws {
    try await db.write { database in
      try database.execute(
        sql: """
          INSERT INTO appview_ingestion_stream_state
            (environment, source, connection_state, last_disconnect_at, last_disconnect_reason, heartbeat_at, version)
          VALUES (?, ?, 'disconnected', ?, ?, ?, 1)
          ON CONFLICT (environment, source) DO UPDATE SET
            connection_state = 'disconnected', last_disconnect_at = excluded.last_disconnect_at,
            last_disconnect_reason = excluded.last_disconnect_reason, heartbeat_at = excluded.heartbeat_at,
            version = version + 1
          """,
        arguments: [environment, source, Self.iso(at), String(reason.prefix(256)), Self.iso(at)]
      )
    }
  }

  public func recordStreamQueueObservation(
    source: String,
    depth: Int,
    capacity: Int,
    overflowTotal: Int64,
    observedAt: Date
  ) async throws {
    try await db.write { database in
      try database.execute(
        sql: """
          INSERT INTO appview_ingestion_stream_state
            (environment, source, queue_depth, queue_capacity, queue_overflow_total,
             queue_observed_at, heartbeat_at, version)
          VALUES (?, ?, ?, ?, ?, ?, ?, 1)
          ON CONFLICT (environment, source) DO UPDATE SET
            queue_depth = excluded.queue_depth,
            queue_capacity = excluded.queue_capacity,
            queue_overflow_total = MAX(COALESCE(queue_overflow_total, 0), excluded.queue_overflow_total),
            queue_observed_at = excluded.queue_observed_at,
            heartbeat_at = excluded.heartbeat_at,
            version = version + 1
          """,
        arguments: [
          environment, source, max(0, depth), max(1, capacity), max(0, overflowTotal),
          Self.iso(observedAt), Self.iso(observedAt),
        ]
      )
    }
  }

  public func markStreamIndexedMutation(source: String, at: Date) async throws {
    try await updateStreamProgress(
      source: source,
      column: "last_indexed_mutation_at",
      value: Self.iso(at),
      at: at
    )
  }

  public func markStreamProjectionWatermark(
    source: String,
    watermark: String,
    at: Date
  ) async throws {
    try await updateStreamProgress(
      source: source,
      column: "projection_watermark",
      value: String(watermark.prefix(512)),
      at: at
    )
  }

  public func markStreamValidationWatermark(
    source: String,
    watermark: String,
    at: Date
  ) async throws {
    try await updateStreamProgress(
      source: source,
      column: "validation_watermark",
      value: String(watermark.prefix(512)),
      at: at
    )
  }

  private func updateStreamProgress(
    source: String,
    column: String,
    value: String,
    at: Date
  ) async throws {
    try await db.write { database in
      try database.execute(
        sql: """
          INSERT INTO appview_ingestion_stream_state
            (environment, source, \(column), heartbeat_at, version)
          VALUES (?, ?, ?, ?, 1)
          ON CONFLICT (environment, source) DO UPDATE SET
            \(column) = excluded.\(column),
            heartbeat_at = excluded.heartbeat_at,
            version = version + 1
          """,
        arguments: [environment, source, value, Self.iso(at)]
      )
    }
  }

  public func upsertJetstreamEndpoint(_ state: JetstreamEndpointState) async throws {
    try await db.write { database in
      try database.execute(
        sql: """
          INSERT INTO appview_jetstream_endpoints
            (environment, id, display_name, host, role, connection_state, last_connected_at,
             last_disconnected_at, last_error, connection_attempts, failover_count, updated_at)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          ON CONFLICT (environment, id) DO UPDATE SET
            display_name = excluded.display_name, host = excluded.host, role = excluded.role,
            connection_state = excluded.connection_state,
            last_connected_at = excluded.last_connected_at,
            last_disconnected_at = excluded.last_disconnected_at,
            last_error = excluded.last_error,
            connection_attempts = excluded.connection_attempts,
            failover_count = excluded.failover_count, updated_at = excluded.updated_at,
            version = version + 1
          """,
        arguments: [
          environment, state.id, state.displayName, state.host, state.role.rawValue,
          state.connectionState.rawValue, state.lastConnectedAt.map(Self.iso),
          state.lastDisconnectedAt.map(Self.iso), state.lastError,
          state.connectionAttempts, state.failoverCount, Self.iso(state.updatedAt),
        ]
      )
    }
  }

  public func listJetstreamEndpoints() async throws -> [JetstreamEndpointState] {
    try await listJetstreamEndpoints(limit: 250, before: nil).items
  }

  public func listJetstreamEndpoints(limit: Int, before: String?) async throws
    -> OperationsPage<JetstreamEndpointState>
  {
    let limit = max(1, min(limit, 250))
    return try await db.read { database in
      var arguments: StatementArguments = [environment]
      var cursorPredicate = ""
      if let decoded = try Self.decodeCursor(before) {
        cursorPredicate = " AND (updated_at < ? OR (updated_at = ? AND id < ?))"
        let date = Self.iso(decoded.date)
        arguments += [date, date, decoded.id]
      }
      arguments += [limit + 1]
      let rows = try Row.fetchAll(
        database,
        sql: """
          SELECT * FROM appview_jetstream_endpoints
          WHERE environment = ?\(cursorPredicate)
          ORDER BY updated_at DESC, id DESC LIMIT ?
          """,
        arguments: arguments
      ).compactMap(Self.jetstreamEndpoint)
      let total = try Int.fetchOne(
        database,
        sql: "SELECT COUNT(*) FROM appview_jetstream_endpoints WHERE environment = ?",
        arguments: [environment]) ?? 0
      let items = Array(rows.prefix(limit))
      let next = rows.count > limit
        ? items.last.map { OperationsPaginationCursor.encode(date: $0.updatedAt, id: $0.id) } : nil
      return OperationsPage(items: items, nextCursor: next, totalCount: total)
    }
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
      id: UUID().uuidString.lowercased(),
      environment: environment,
      action: action,
      status: .queued,
      requestedByDid: operatorDid,
      auditNote: auditNote.map { String($0.prefix(280)) },
      createdAt: at,
      updatedAt: at
    )
    return try await db.write { database -> OperationsWorkerCommand in
      if let existing = try Self.existingIdempotency(
        database: database, environment: environment, key: idempotencyKey,
        action: actionName, targetType: "command", targetId: nil,
        requestFingerprint: requestFingerprint)
      {
        let replay = try Self.replayIdempotencyResult(existing, as: OperationsWorkerCommand.self)
        try Self.insertAudit(
          database: database, environment: environment, operatorDid: operatorDid,
          action: actionName, targetType: "command", targetId: replay.id,
          idempotencyKey: idempotencyKey, requestId: requestId,
          expectedVersion: expectedStreamVersion, note: auditNote, before: [:],
          after: [
            "status": replay.status.rawValue, "version": String(replay.version),
            "targetId": replay.id,
          ], outcome: "idempotent_replay", at: at)
        return replay
      }
      let actualVersion = try Int.fetchOne(
        database,
        sql: "SELECT version FROM appview_ingestion_stream_state WHERE environment = ? AND source = 'jetstream'",
        arguments: [environment]) ?? 0
      guard actualVersion == expectedStreamVersion else {
        throw OperationsStoreError.versionConflict(expected: expectedStreamVersion, actual: actualVersion)
      }
      try database.execute(
        sql: """
          INSERT INTO operations_commands
            (environment, id, action, status, requested_by_did, audit_note, created_at, updated_at,
             expires_at, version)
          VALUES (?, ?, ?, 'queued', ?, ?, ?, ?, ?, 0)
          """,
        arguments: [
          environment, command.id, action.rawValue, operatorDid, command.auditNote ?? "",
          Self.iso(at), Self.iso(at),
          Self.iso(at.addingTimeInterval(365 * 86_400)),
        ]
      )
      try Self.insertIdempotency(
        database: database, environment: environment, key: idempotencyKey,
        action: actionName, targetType: "command", targetId: command.id,
        outcome: "queued", requestFingerprint: requestFingerprint,
        resultPayload: try Self.encodeIdempotencyResult(command), at: at)
      try Self.insertAudit(
        database: database, environment: environment, operatorDid: operatorDid,
        action: "jetstream.reconnect_requested", targetType: "command", targetId: command.id,
        idempotencyKey: idempotencyKey, requestId: requestId,
        expectedVersion: expectedStreamVersion, note: auditNote,
        before: ["streamVersion": String(actualVersion)],
        after: [
          "status": OperationsCommandStatus.queued.rawValue, "version": "0",
          "targetId": command.id,
        ], outcome: "queued", at: at)
      return command
    }
  }

  public func listCommands(limit: Int) async throws -> [OperationsWorkerCommand] {
    try await listCommands(limit: limit, before: nil).items
  }

  private func fetchCommand(id: String) async throws -> OperationsWorkerCommand? {
    try await db.read { database in
      try Row.fetchOne(
        database,
        sql: "SELECT * FROM operations_commands WHERE environment = ? AND id = ? LIMIT 1",
        arguments: [environment, id]
      ).flatMap(Self.command)
    }
  }

  public func listCommands(limit: Int, before: String?) async throws
    -> OperationsPage<OperationsWorkerCommand>
  {
    let limit = max(1, min(limit, 250))
    return try await db.read { database in
      var arguments: StatementArguments = [environment]
      var cursorPredicate = ""
      if let decoded = try Self.decodeCursor(before) {
        cursorPredicate = " AND (created_at < ? OR (created_at = ? AND id < ?))"
        let date = Self.iso(decoded.date)
        arguments += [date, date, decoded.id]
      }
      arguments += [limit + 1]
      let rows = try Row.fetchAll(
        database,
        sql: """
          SELECT * FROM operations_commands
          WHERE environment = ?\(cursorPredicate)
          ORDER BY created_at DESC, id DESC LIMIT ?
          """,
        arguments: arguments
      ).compactMap(Self.command)
      let total = try Int.fetchOne(
        database, sql: "SELECT COUNT(*) FROM operations_commands WHERE environment = ?",
        arguments: [environment]) ?? 0
      let items = Array(rows.prefix(limit))
      let next = rows.count > limit
        ? items.last.map { OperationsPaginationCursor.encode(date: $0.createdAt, id: $0.id) } : nil
      return OperationsPage(items: items, nextCursor: next, totalCount: total)
    }
  }

  public func claimNextCommand(
    action: OperationsCommandAction,
    workerId: String,
    at: Date
  ) async throws -> OperationsWorkerCommand? {
    let leaseUntil = at.addingTimeInterval(300)
    return try await db.write { database -> OperationsWorkerCommand? in
      guard let id = try String.fetchOne(
        database,
        sql: """
          SELECT id FROM operations_commands
          WHERE environment = ? AND action = ?
            AND (status = 'queued' OR (status = 'running' AND lease_expires_at < ?))
          ORDER BY created_at LIMIT 1
          """,
        arguments: [environment, action.rawValue, Self.iso(at)]
      ) else { return nil }
      try database.execute(
        sql: """
          UPDATE operations_commands SET status = 'running', claimed_by = ?, lease_expires_at = ?,
            updated_at = ?, version = version + 1
          WHERE environment = ? AND id = ?
            AND (status = 'queued' OR (status = 'running' AND lease_expires_at < ?))
          """,
        arguments: [workerId, Self.iso(leaseUntil), Self.iso(at), environment, id, Self.iso(at)]
      )
      guard database.changesCount == 1,
        let row = try Row.fetchOne(database, sql: "SELECT * FROM operations_commands WHERE environment = ? AND id = ?", arguments: [environment, id])
      else { return nil }
      return Self.command(row)
    }
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
    return try await db.write { database in
      guard let currentRow = try Row.fetchOne(
        database,
        sql: "SELECT * FROM operations_commands WHERE environment = ? AND id = ?",
        arguments: [environment, id]),
        let current = Self.command(currentRow)
      else { throw OperationsStoreError.notFound }
      guard current.status == .running, current.claimedBy == workerId,
        current.version == expectedVersion,
        current.leaseExpiresAt.map({ $0 >= at }) == true
      else { throw OperationsStoreError.leaseConflict }
      let boundedFailure = failureReason.map { String($0.prefix(160)) }
      try database.execute(
        sql: """
          UPDATE operations_commands
          SET status = ?, failure_reason = ?, updated_at = ?, completed_at = ?,
            expires_at = ?, lease_expires_at = NULL, version = version + 1
          WHERE environment = ? AND id = ? AND status = 'running' AND claimed_by = ?
            AND lease_expires_at >= ? AND version = ?
          """,
        arguments: [
          status.rawValue, boundedFailure, Self.iso(at), Self.iso(at),
          Self.iso(at.addingTimeInterval(365 * 86_400)), environment, id, workerId,
          Self.iso(at), expectedVersion,
        ]
      )
      guard database.changesCount == 1 else { throw OperationsStoreError.leaseConflict }
      try Self.extendLifecycleRetention(
        database: database, environment: environment, targetType: "command", targetId: id,
        terminalAt: at)
      try Self.insertAudit(
        database: database, environment: environment, operatorDid: "system:worker",
        action: "command.\(status.rawValue)", targetType: "command", targetId: id,
        idempotencyKey: nil, requestId: requestId, expectedVersion: expectedVersion,
        note: note,
        before: [
          "status": current.status.rawValue, "version": String(current.version),
          "leaseOwner": workerId,
        ],
        after: [
          "status": status.rawValue, "version": String(current.version + 1),
          "outcome": boundedFailure ?? "succeeded",
        ], outcome: status == .completed ? "succeeded" : "failed", at: at)
      guard let updatedRow = try Row.fetchOne(
        database,
        sql: "SELECT * FROM operations_commands WHERE environment = ? AND id = ?",
        arguments: [environment, id]),
        let updated = Self.command(updatedRow)
      else { throw OperationsStoreError.missingCreatedRecord }
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
    try await db.write { database in
      try database.execute(
        sql: """
          INSERT INTO appview_ingestion_stream_state
            (environment, source, connection_state, last_received_cursor, last_received_event_at,
             last_received_at, queue_depth, heartbeat_at, version)
          VALUES (?, ?, 'connected', ?, ?, ?, ?, ?, 1)
          ON CONFLICT (environment, source) DO UPDATE SET
            connection_state = 'connected',
            last_received_event_at = CASE WHEN excluded.last_received_cursor >= COALESCE(last_received_cursor, -1)
              THEN excluded.last_received_event_at ELSE last_received_event_at END,
            last_received_at = CASE WHEN excluded.last_received_cursor >= COALESCE(last_received_cursor, -1)
              THEN excluded.last_received_at ELSE last_received_at END,
            last_received_cursor = MAX(COALESCE(last_received_cursor, -1), excluded.last_received_cursor),
            queue_depth = excluded.queue_depth, heartbeat_at = excluded.heartbeat_at,
            version = version + 1
          """,
        arguments: [
          environment, source, cursor, eventAt.map(Self.iso), Self.iso(receivedAt), queueDepth,
          Self.iso(receivedAt),
        ]
      )
    }
  }

  public func markStreamCommitted(
    source: String,
    cursor: Int64,
    eventAt: Date?,
    committedAt: Date,
    queueDepth: Int
  ) async throws {
    try await db.write { database in
      try database.execute(
        sql: """
          INSERT INTO appview_ingestion_stream_state
            (environment, source, last_committed_cursor, last_committed_event_at, last_committed_at,
             queue_depth, heartbeat_at, version)
          VALUES (?, ?, ?, ?, ?, ?, ?, 1)
          ON CONFLICT (environment, source) DO UPDATE SET
            last_committed_event_at = CASE WHEN excluded.last_committed_cursor >= COALESCE(last_committed_cursor, -1)
              THEN excluded.last_committed_event_at ELSE last_committed_event_at END,
            last_committed_at = CASE WHEN excluded.last_committed_cursor >= COALESCE(last_committed_cursor, -1)
              THEN excluded.last_committed_at ELSE last_committed_at END,
            last_committed_cursor = MAX(COALESCE(last_committed_cursor, -1), excluded.last_committed_cursor),
            queue_depth = excluded.queue_depth, heartbeat_at = excluded.heartbeat_at,
            version = version + 1
          """,
        arguments: [
          environment, source, cursor, eventAt.map(Self.iso), Self.iso(committedAt), queueDepth,
          Self.iso(committedAt),
        ]
      )
    }
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
    try await db.write { database in
      try database.execute(
        sql: """
          INSERT INTO appview_recovery_failures
            (environment, id, job_id, source, record_identifier_hash, collection, operation, cursor, error_type,
             retry_count, first_failed_at, last_failed_at, expires_at)
          VALUES (?, ?, ?, 'jetstream', ?, ?, ?, ?, ?, 0, ?, ?, ?)
          """,
        arguments: [
          environment, UUID().uuidString.lowercased(), jobId, identityHash, String(collection.prefix(128)),
          String(operation.prefix(32)), cursor, String(errorCategory.prefix(64)), Self.iso(at),
          Self.iso(at), Self.iso(at.addingTimeInterval(30 * 86_400)),
        ]
      )
    }
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
    try await db.write { database in
      try database.execute(
        sql: """
          INSERT INTO appview_ingestion_gaps
            (environment, id, source, start_cursor, end_cursor, reason, status, collections,
             detected_at, updated_at, expires_at, version)
          VALUES (?, ?, ?, ?, ?, ?, 'suspected', ?, ?, ?, ?, 0)
          """,
        arguments: [
          environment, id, source, startCursor, endCursor, String(reason.prefix(128)), collectionJSON,
          Self.iso(detectedAt), Self.iso(detectedAt),
          Self.iso(detectedAt.addingTimeInterval(365 * 86_400)),
        ]
      )
    }
    guard let gap = try await fetchGap(id: id) else {
      throw OperationsStoreError.missingCreatedRecord
    }
    return gap
  }

  public func listGaps(limit: Int) async throws -> [IngestionGap] {
    try await listGaps(view: .all, limit: limit, before: nil).items
  }

  public func fetchGap(id: String) async throws -> IngestionGap? {
    try await db.read { database in
      try Row.fetchOne(
        database,
        sql: "SELECT * FROM appview_ingestion_gaps WHERE environment = ? AND id = ?",
        arguments: [environment, id]).flatMap(Self.gap)
    }
  }

  public func listGaps(
    view: GapListView,
    limit: Int,
    before: String?
  ) async throws -> OperationsPage<IngestionGap> {
    let limit = max(1, min(limit, 250))
    let predicate: String
    switch view {
    case .active:
      predicate = "status NOT IN ('resolved', 'ignored')"
    case .history:
      predicate = "status IN ('resolved', 'ignored')"
    case .all:
      predicate = "1 = 1"
    }
    return try await db.read { database in
      var arguments: StatementArguments = [environment]
      var cursorPredicate = ""
      if let decoded = try Self.decodeCursor(before) {
        cursorPredicate = " AND (detected_at < ? OR (detected_at = ? AND id < ?))"
        let date = Self.iso(decoded.date)
        arguments += [date, date, decoded.id]
      }
      arguments += [limit + 1]
      let rows = try Row.fetchAll(
        database,
        sql: """
          SELECT * FROM appview_ingestion_gaps
          WHERE environment = ? AND \(predicate)\(cursorPredicate)
          ORDER BY detected_at DESC, id DESC LIMIT ?
          """,
        arguments: arguments
      ).compactMap(Self.gap)
      let total = try Int.fetchOne(
        database,
        sql: "SELECT COUNT(*) FROM appview_ingestion_gaps WHERE environment = ? AND \(predicate)",
        arguments: [environment]
      ) ?? 0
      let items = Array(rows.prefix(limit))
      let next = rows.count > limit
        ? items.last.map { OperationsPaginationCursor.encode(date: $0.detectedAt, id: $0.id) } : nil
      return OperationsPage(items: items, nextCursor: next, totalCount: total)
    }
  }

  public func lifecycleCounts() async throws -> OperationsLifecycleCounts {
    try await db.read { database in
      let activeGaps = try Int.fetchOne(
        database,
        sql: "SELECT COUNT(*) FROM appview_ingestion_gaps WHERE environment = ? AND status NOT IN ('resolved', 'ignored')",
        arguments: [environment]) ?? 0
      let activeBackfills = try Int.fetchOne(
        database,
        sql: "SELECT COUNT(*) FROM appview_backfill_jobs WHERE environment = ? AND status IN ('queued', 'running', 'paused')",
        arguments: [environment]) ?? 0
      let attention = try Int.fetchOne(
        database,
        sql: "SELECT COUNT(*) FROM appview_backfill_jobs WHERE environment = ? AND status IN ('failed', 'cancelled')",
        arguments: [environment]) ?? 0
      let completed = try Int.fetchOne(
        database,
        sql: "SELECT COUNT(*) FROM appview_backfill_jobs WHERE environment = ? AND status = 'completed'",
        arguments: [environment]) ?? 0
      let alerts = try Int.fetchOne(
        database,
        sql: "SELECT COUNT(*) FROM operations_alerts WHERE environment = ? AND status != 'resolved'",
        arguments: [environment]) ?? 0
      return OperationsLifecycleCounts(
        activeGaps: activeGaps,
        activeBackfills: activeBackfills,
        attentionBackfills: attention,
        completedBackfills: completed,
        unresolvedAlerts: alerts)
    }
  }

  public func updateGap(id: String, status: IngestionGapStatus, operatorDid: String, at: Date)
    async throws
  {
    guard let current = try await fetchGap(id: id) else {
      throw OperationsStoreError.notFound
    }
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
    return try await db.write { database in
      if let existing = try Self.existingIdempotency(
        database: database, environment: environment, key: idempotencyKey,
        action: actionName, targetType: "gap", targetId: id,
        requestFingerprint: requestFingerprint)
      {
        let replay = try Self.replayIdempotencyResult(existing, as: IngestionGap.self)
        try Self.insertAudit(
          database: database, environment: environment, operatorDid: operatorDid,
          action: actionName, targetType: "gap", targetId: replay.id,
          idempotencyKey: idempotencyKey, requestId: requestId,
          expectedVersion: expectedVersion, note: note, before: [:],
          after: ["status": replay.status.rawValue, "version": String(replay.version)],
          outcome: "idempotent_replay", at: at)
        return replay
      }
      guard let row = try Row.fetchOne(
        database,
        sql: "SELECT * FROM appview_ingestion_gaps WHERE environment = ? AND id = ?",
        arguments: [environment, id]),
        let current = Self.gap(row)
      else { throw OperationsStoreError.notFound }
      guard current.version == expectedVersion else {
        throw OperationsStoreError.versionConflict(expected: expectedVersion, actual: current.version)
      }
      guard Self.canTransitionGap(from: current.status, to: status) else {
        throw OperationsStoreError.invalidTransition(from: current.status.rawValue, to: status.rawValue)
      }
      try database.execute(
        sql: """
          UPDATE appview_ingestion_gaps
          SET status = ?, updated_at = ?,
            expires_at = CASE WHEN ? IN ('resolved', 'ignored') THEN ? ELSE expires_at END,
            version = version + 1
          WHERE environment = ? AND id = ? AND version = ?
          """,
        arguments: [status.rawValue, Self.iso(at), status.rawValue,
          Self.iso(at.addingTimeInterval(365 * 86_400)), environment, id, expectedVersion])
      guard database.changesCount == 1 else {
        throw OperationsStoreError.versionConflict(expected: expectedVersion, actual: current.version + 1)
      }
      if [.resolved, .ignored].contains(status) {
        try Self.extendLifecycleRetention(
          database: database, environment: environment, targetType: "gap", targetId: id,
          terminalAt: at)
      }
      guard let updatedRow = try Row.fetchOne(
        database,
        sql: "SELECT * FROM appview_ingestion_gaps WHERE environment = ? AND id = ?",
        arguments: [environment, id]),
        let updated = Self.gap(updatedRow)
      else { throw OperationsStoreError.missingCreatedRecord }
      try Self.insertIdempotency(
        database: database, environment: environment, key: idempotencyKey,
        action: actionName, targetType: "gap", targetId: id,
        outcome: "succeeded", requestFingerprint: requestFingerprint,
        resultPayload: try Self.encodeIdempotencyResult(updated), at: at)
      try Self.insertAudit(
        database: database, environment: environment, operatorDid: operatorDid,
        action: "gap.\(status.rawValue)", targetType: "gap", targetId: id,
        idempotencyKey: idempotencyKey, requestId: requestId,
        expectedVersion: expectedVersion, note: note,
        before: ["status": current.status.rawValue, "version": String(current.version)],
        after: ["status": status.rawValue, "version": String(current.version + 1)],
        outcome: "succeeded", at: at)
      return updated
    }
  }

  public func resolveSuspectedGaps(
    source: String,
    through committedCursor: Int64,
    at: Date
  ) async throws -> [String] {
    try await db.write { database in
      let ids = try String.fetchAll(
        database,
        sql: """
          SELECT id
          FROM appview_ingestion_gaps
          WHERE environment = ? AND source = ? AND status = 'suspected'
            AND end_cursor IS NOT NULL AND end_cursor <= ?
          """,
        arguments: [environment, source, committedCursor]
      )
      guard !ids.isEmpty else { return [] }
      try database.execute(
        sql: """
          UPDATE appview_ingestion_gaps
          SET status = 'verification_required', updated_at = ?, version = version + 1
          WHERE environment = ? AND source = ? AND status = 'suspected'
            AND end_cursor IS NOT NULL AND end_cursor <= ?
          """,
        arguments: [Self.iso(at), environment, source, committedCursor]
      )
      return ids
    }
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
    let existingJobs = try await listBackfills(view: .active, limit: 250, before: nil).items
    let response = BackfillDryRunAssessment.build(
      request: request,
      gap: gap,
      existingJobs: existingJobs)
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
    let collectionsJSON = try json(dryRun.collections)
    let authorDidsJSON = try json(dryRun.authorDids)
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
    return try await db.write { database -> BackfillJob in
      var auditBefore: [String: String] = [:]
      if let existing = try Self.existingIdempotency(
        database: database, environment: environment, key: idempotencyKey,
        action: "backfill.queued", targetType: "backfill", targetId: nil,
        requestFingerprint: idempotencyRequestFingerprint)
      {
        let replay = try Self.replayIdempotencyResult(existing, as: BackfillJob.self)
        try Self.insertAudit(
          database: database, environment: environment, operatorDid: operatorDid,
          action: "backfill.queued", targetType: "backfill", targetId: replay.id,
          idempotencyKey: idempotencyKey, requestId: requestId,
          expectedVersion: request.expectedGapVersion, note: request.auditNote, before: [:],
          after: [
            "status": replay.status.rawValue, "version": String(replay.version),
            "targetId": replay.id,
          ], outcome: "idempotent_replay", at: at)
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

      if let gapId = dryRun.gapId {
        guard let gapRow = try Row.fetchOne(
          database,
          sql: "SELECT * FROM appview_ingestion_gaps WHERE environment = ? AND id = ?",
          arguments: [environment, gapId]),
          let gap = Self.gap(gapRow)
        else { throw OperationsStoreError.notFound }
        auditBefore = ["status": gap.status.rawValue, "version": String(gap.version)]
        if let expected = request.expectedGapVersion, expected != gap.version {
          throw OperationsStoreError.versionConflict(expected: expected, actual: gap.version)
        }
        guard gap.status == .confirmed || gap.status == .verificationRequired else {
          throw OperationsStoreError.invalidTransition(
            from: gap.status.rawValue, to: IngestionGapStatus.backfillQueued.rawValue)
        }
        if dryRun.sourceMode == .jetstreamReplay,
          gap.startCursor != dryRun.startCursor || gap.endCursor != dryRun.endCursor
        {
          throw OperationsStoreError.backfillScopeChanged(reason: "gap_range_changed")
        }
        if !gap.collections.isEmpty,
          Set(gap.collections).isDisjoint(with: dryRun.collections)
        {
          throw OperationsStoreError.backfillScopeChanged(reason: "gap_collections_changed")
        }
      }
      if dryRun.gapId == nil, dryRun.sourceMode == .jetstreamReplay,
        let endCursor = dryRun.endCursor,
        let committedCursor = try Int64.fetchOne(
          database,
          sql: """
            SELECT last_committed_cursor FROM appview_ingestion_stream_state
            WHERE environment = ? AND source = 'jetstream'
            """, arguments: [environment]),
        committedCursor >= endCursor
      {
        throw OperationsStoreError.backfillScopeChanged(reason: "range_already_committed")
      }
      let overlappingRows = try Row.fetchAll(
        database,
        sql: """
          SELECT * FROM appview_backfill_jobs
          WHERE environment = ? AND status IN ('queued', 'running', 'paused')
          """,
        arguments: [environment])
      if overlappingRows.compactMap(Self.backfill).contains(where: {
        BackfillDryRunAssessment.overlaps($0, request: dryRun)
      }) {
        throw OperationsStoreError.overlappingBackfill
      }
      try database.execute(
        sql: """
          INSERT INTO appview_backfill_jobs
            (environment, id, gap_id, source_mode, status, start_cursor, end_cursor, checkpoint_cursor,
             collections, author_dids, batch_size, rate_limit, max_concurrency, estimated_count,
             requested_by_did, audit_note, idempotency_key, verification_status,
             request_fingerprint, request_fingerprint_expires_at, normalized_request_hash,
             created_at, updated_at, expires_at, version)
          VALUES (?, ?, ?, ?, 'queued', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0)
          """,
        arguments: [
          environment, id, dryRun.gapId, dryRun.sourceMode.rawValue,
          dryRun.startCursor, dryRun.endCursor, dryRun.startCursor,
          collectionsJSON, authorDidsJSON,
          dryRun.batchSize, dryRun.rateLimit, dryRun.maxConcurrency,
          request.expectedEstimate, operatorDid, request.auditNote.map { String($0.prefix(280)) }, idempotencyKey,
          dryRun.sourceMode == .tapVerifiedResync ? BackfillVerificationStatus.pending.rawValue : BackfillVerificationStatus.required.rawValue,
          fingerprint, Self.iso(fingerprintExpiresAt), normalizedRequestHash,
          Self.iso(at), Self.iso(at), Self.iso(at.addingTimeInterval(365 * 86_400)),
        ]
      )
      if let gapId = dryRun.gapId {
        try database.execute(
          sql:
            "UPDATE appview_ingestion_gaps SET status = 'backfill_queued', backfill_job_id = ?, updated_at = ?, version = version + 1 WHERE environment = ? AND id = ?",
          arguments: [id, Self.iso(at), environment, gapId]
        )
      }
      guard let createdRow = try Row.fetchOne(
        database,
        sql: "SELECT * FROM appview_backfill_jobs WHERE environment = ? AND id = ?",
        arguments: [environment, id]),
        let created = Self.backfill(createdRow)
      else { throw OperationsStoreError.missingCreatedRecord }
      try Self.insertIdempotency(
        database: database, environment: environment, key: idempotencyKey,
        action: "backfill.queued", targetType: "backfill", targetId: id,
        outcome: "queued", requestFingerprint: idempotencyRequestFingerprint,
        resultPayload: try Self.encodeIdempotencyResult(created), at: at)
      try Self.insertAudit(
        database: database, environment: environment, operatorDid: operatorDid,
        action: "backfill.queued", targetType: "backfill", targetId: id,
        idempotencyKey: idempotencyKey, requestId: requestId,
        expectedVersion: request.expectedGapVersion, note: request.auditNote, before: auditBefore,
        after: [
          "status": BackfillJobStatus.queued.rawValue, "version": "0", "targetId": id,
        ],
        outcome: "succeeded", at: at)
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
    let predicate: String
    switch view {
    case .active: predicate = "status IN ('queued', 'running', 'paused')"
    case .attention: predicate = "status IN ('failed', 'cancelled')"
    case .history: predicate = "status = 'completed'"
    case .all: predicate = "1 = 1"
    }
    return try await db.read { database in
      var arguments: StatementArguments = [environment]
      var cursorPredicate = ""
      if let decoded = try Self.decodeCursor(before) {
        cursorPredicate = " AND (created_at < ? OR (created_at = ? AND id < ?))"
        let date = Self.iso(decoded.date)
        arguments += [date, date, decoded.id]
      }
      arguments += [limit + 1]
      let rows = try Row.fetchAll(
        database,
        sql: """
          SELECT * FROM appview_backfill_jobs
          WHERE environment = ? AND \(predicate)\(cursorPredicate)
          ORDER BY created_at DESC, id DESC LIMIT ?
          """,
        arguments: arguments
      ).compactMap(Self.backfill)
      let total = try Int.fetchOne(
        database,
        sql: "SELECT COUNT(*) FROM appview_backfill_jobs WHERE environment = ? AND \(predicate)",
        arguments: [environment]) ?? 0
      let items = Array(rows.prefix(limit))
      let next = rows.count > limit
        ? items.last.map { OperationsPaginationCursor.encode(date: $0.createdAt, id: $0.id) } : nil
      return OperationsPage(items: items, nextCursor: next, totalCount: total)
    }
  }

  public func fetchBackfill(id: String) async throws -> BackfillJob? {
    try await db.read { database in
      try Row.fetchOne(
        database,
        sql: "SELECT * FROM appview_backfill_jobs WHERE environment = ? AND id = ? LIMIT 1",
        arguments: [environment, id]
      ).flatMap(Self.backfill)
    }
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
    return try await db.write { database in
      if let existing = try Self.existingIdempotency(
        database: database, environment: environment, key: idempotencyKey,
        action: actionName, targetType: "backfill", targetId: id,
        requestFingerprint: requestFingerprint)
      {
        let replay = try Self.replayIdempotencyResult(existing, as: BackfillJob.self)
        try Self.insertAudit(
          database: database, environment: environment, operatorDid: operatorDid,
          action: actionName, targetType: "backfill", targetId: replay.id,
          idempotencyKey: idempotencyKey, requestId: requestId,
          expectedVersion: expectedVersion, note: note, before: [:],
          after: ["status": replay.status.rawValue, "version": String(replay.version)],
          outcome: "idempotent_replay", at: at)
        return replay
      }
      guard let row = try Row.fetchOne(
        database, sql: "SELECT * FROM appview_backfill_jobs WHERE environment = ? AND id = ?",
        arguments: [environment, id]),
        let current = Self.backfill(row)
      else { throw OperationsStoreError.notFound }
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
        guard let gapRow = try Row.fetchOne(
          database,
          sql: "SELECT * FROM appview_ingestion_gaps WHERE environment = ? AND id = ?",
          arguments: [environment, gapId]),
          let gap = Self.gap(gapRow)
        else { throw OperationsStoreError.notFound }
        guard gap.backfillJobId == current.id, transition.allowedFrom.contains(gap.status) else {
          throw OperationsStoreError.invalidTransition(
            from: gap.status.rawValue, to: transition.next.rawValue)
        }
        linkedGapUpdate = (gapId, gap.version, gap.status, transition.next)
      }
      let completed = [BackfillJobStatus.completed, .failed, .cancelled].contains(status) ? Self.iso(at) : nil
      try database.execute(
        sql: """
          UPDATE appview_backfill_jobs SET status = ?, updated_at = ?, version = version + 1,
            completed_at = ?, failure_reason = CASE WHEN ? = 'failed' THEN ? ELSE failure_reason END,
            expires_at = CASE WHEN ? IN ('completed', 'failed', 'cancelled') THEN ? ELSE expires_at END,
            lease_owner = NULL, lease_expires_at = NULL
          WHERE environment = ? AND id = ? AND version = ?
          """,
        arguments: [status.rawValue, Self.iso(at), completed, status.rawValue,
          failureReason.map { String($0.prefix(160)) }, status.rawValue,
          Self.iso(at.addingTimeInterval(365 * 86_400)), environment, id, expectedVersion])
      guard database.changesCount == 1 else {
        throw OperationsStoreError.versionConflict(expected: expectedVersion, actual: current.version + 1)
      }
      if var linkedGapUpdate {
        if status == .completed {
          let isVerifiedTap = current.sourceMode == .tapVerifiedResync
            && current.verificationStatus == .verified
            && !current.scopeTruncated
            && current.failedCount == 0
            && current.validationWatermark != nil
          linkedGapUpdate.to = isVerifiedTap ? .resolved : .verificationRequired
        }
        try database.execute(
          sql: """
            UPDATE appview_ingestion_gaps
            SET status = ?, updated_at = ?,
              expires_at = CASE WHEN ? IN ('resolved', 'ignored') THEN ? ELSE expires_at END,
              version = version + 1
            WHERE environment = ? AND id = ? AND version = ? AND status = ?
            """,
          arguments: [
            linkedGapUpdate.to.rawValue, Self.iso(at), linkedGapUpdate.to.rawValue,
            Self.iso(at.addingTimeInterval(365 * 86_400)), environment, linkedGapUpdate.id,
            linkedGapUpdate.version, linkedGapUpdate.from.rawValue,
          ])
        guard database.changesCount == 1 else {
          throw OperationsStoreError.invalidTransition(
            from: linkedGapUpdate.from.rawValue, to: linkedGapUpdate.to.rawValue)
        }
        if [.resolved, .ignored].contains(linkedGapUpdate.to) {
          try Self.extendLifecycleRetention(
            database: database, environment: environment, targetType: "gap",
            targetId: linkedGapUpdate.id, terminalAt: at)
        }
      }
      if [.completed, .failed, .cancelled].contains(status) {
        try Self.extendLifecycleRetention(
          database: database, environment: environment, targetType: "backfill", targetId: id,
          terminalAt: at)
      }
      guard let updatedRow = try Row.fetchOne(database, sql: "SELECT * FROM appview_backfill_jobs WHERE environment = ? AND id = ?", arguments: [environment, id]),
        let updated = Self.backfill(updatedRow)
      else { throw OperationsStoreError.missingCreatedRecord }
      try Self.insertIdempotency(
        database: database, environment: environment, key: idempotencyKey,
        action: actionName, targetType: "backfill", targetId: id,
        outcome: "succeeded", requestFingerprint: requestFingerprint,
        resultPayload: try Self.encodeIdempotencyResult(updated), at: at)
      try Self.insertAudit(
        database: database, environment: environment, operatorDid: operatorDid,
        action: "backfill.\(status.rawValue)", targetType: "backfill", targetId: id,
        idempotencyKey: idempotencyKey, requestId: requestId,
        expectedVersion: expectedVersion, note: note,
        before: ["status": current.status.rawValue, "version": String(current.version)],
        after: ["status": status.rawValue, "version": String(current.version + 1)],
        outcome: "succeeded", at: at)
      return updated
    }
  }

  public func claimNextBackfill(workerId: String, leaseUntil: Date, at: Date) async throws
    -> BackfillJob?
  {
    try await db.write { database in
      guard
        let id = try String.fetchOne(
          database,
          sql: """
            SELECT id FROM appview_backfill_jobs
            WHERE environment = ? AND status IN ('queued', 'running')
              AND (lease_expires_at IS NULL OR lease_expires_at < ?)
            ORDER BY created_at LIMIT 1
            """,
          arguments: [environment, Self.iso(at)]
        )
      else { return nil }
      try database.execute(
        sql: """
          UPDATE appview_backfill_jobs SET status = 'running', lease_owner = ?, lease_expires_at = ?,
            updated_at = ?, version = version + 1
          WHERE environment = ? AND id = ? AND (lease_expires_at IS NULL OR lease_expires_at < ?)
          """,
        arguments: [workerId, Self.iso(leaseUntil), Self.iso(at), environment, id, Self.iso(at)]
      )
      guard database.changesCount == 1,
        let row = try Row.fetchOne(
        database,
        sql: "SELECT * FROM appview_backfill_jobs WHERE environment = ? AND id = ?",
        arguments: [environment, id]),
        let job = Self.backfill(row)
      else { return nil }
      if let gapId = job.gapId {
        try database.execute(
          sql: "UPDATE appview_ingestion_gaps SET status = 'backfilling', updated_at = ?, version = version + 1 WHERE environment = ? AND id = ? AND status = 'backfill_queued'",
          arguments: [Self.iso(at), environment, gapId])
      }
      return job
    }
  }

  public func renewBackfillLease(
    id: String,
    workerId: String,
    expectedVersion: Int,
    leaseUntil: Date,
    at: Date
  ) async throws -> BackfillJob {
    try await mutateOwnedBackfill(
      id: id, workerId: workerId, expectedVersion: expectedVersion, leaseUntil: leaseUntil, at: at,
      update: "version = version + 1")
  }

  public func recordBackfillVerification(
    id: String,
    workerId: String,
    expectedVersion: Int,
    exactScope: Bool,
    truncated: Bool,
    failedCount: Int,
    validationWatermark: String?,
    at: Date
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
      leaseUntil: at.addingTimeInterval(60), at: at,
      update: "verification_status = ?, verification_reason = ?, scope_truncated = ?, validation_watermark = ?, failed_count = ?, version = version + 1",
      additionalArguments: [
        status.rawValue, reason, truncated, validationWatermark, effectiveFailedCount,
      ])
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
    return try await db.write { database in
      try database.execute(
        sql: """
          UPDATE appview_backfill_jobs
          SET author_results = ?, updated_at = ?, version = version + 1
          WHERE environment = ? AND id = ? AND status = 'running' AND lease_owner = ?
            AND lease_expires_at >= ? AND version = ?
          """,
        arguments: [
          encodedResults, Self.iso(at), environment, id, workerId, Self.iso(at), expectedVersion,
        ])
      guard database.changesCount == 1 else { throw OperationsStoreError.leaseConflict }
      guard let row = try Row.fetchOne(
        database, sql: "SELECT * FROM appview_backfill_jobs WHERE environment = ? AND id = ?",
        arguments: [environment, id]),
        let job = Self.backfill(row)
      else { throw OperationsStoreError.notFound }
      return job
    }
  }

  public func checkpointBackfill(
    id: String,
    workerId: String,
    expectedVersion: Int,
    cursor: Int64?,
    processed: Int,
    failed: Int,
    reconciled: Int,
    leaseUntil: Date,
    at: Date
  ) async throws -> BackfillJob {
    guard processed >= 0, failed >= 0, reconciled >= 0, failed <= processed,
      reconciled <= processed, leaseUntil > at
    else { throw OperationsStoreError.invalidProgress }
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
      id: id, workerId: workerId, expectedVersion: expectedVersion, leaseUntil: leaseUntil, at: at,
      update: "checkpoint_cursor = COALESCE(?, checkpoint_cursor), processed_count = ?, failed_count = ?, reconciled_count = ?, version = version + 1",
      additionalArguments: [cursor, processed, failed, reconciled])
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

  public func fetchAlert(id: String) async throws -> OperationsAlert? {
    try await db.read { database in
      try Row.fetchOne(
        database,
        sql: "SELECT * FROM operations_alerts WHERE environment = ? AND id = ?",
        arguments: [environment, id]).flatMap(Self.alert)
    }
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
    let predicate: String
    switch view {
    case .active: predicate = "status IN ('open', 'acknowledged')"
    case .history: predicate = "status = 'resolved'"
    case .all: predicate = "1 = 1"
    }
    return try await db.read { database in
      var arguments: StatementArguments = [environment]
      var cursorPredicate = ""
      if let decoded = try Self.decodeCursor(before) {
        cursorPredicate = " AND (opened_at < ? OR (opened_at = ? AND id < ?))"
        let date = Self.iso(decoded.date)
        arguments += [date, date, decoded.id]
      }
      arguments += [limit + 1]
      let rows = try Row.fetchAll(
        database,
        sql: """
          SELECT * FROM operations_alerts
          WHERE environment = ? AND \(predicate)\(cursorPredicate)
          ORDER BY opened_at DESC, id DESC LIMIT ?
          """,
        arguments: arguments
      ).compactMap(Self.alert)
      let total = try Int.fetchOne(
        database,
        sql: "SELECT COUNT(*) FROM operations_alerts WHERE environment = ? AND \(predicate)",
        arguments: [environment]) ?? 0
      let items = Array(rows.prefix(limit))
      let next = rows.count > limit
        ? items.last.map { OperationsPaginationCursor.encode(date: $0.openedAt, id: $0.id) } : nil
      return OperationsPage(items: items, nextCursor: next, totalCount: total)
    }
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
    let evidenceJSON = try json(OperationsRedactor.boundedAttributes(evidence))
    return try await db.write { database in
      if let row = try Row.fetchOne(
        database,
        sql: "SELECT * FROM operations_alerts WHERE environment = ? AND condition_key = ? AND status != 'resolved' LIMIT 1",
        arguments: [environment, conditionKey]),
        let existing = Self.alert(row)
      {
        try database.execute(
          sql: """
            UPDATE operations_alerts SET severity = ?, summary = ?, evidence = ?, runbook_slug = ?,
              updated_at = ?, version = version + 1
            WHERE environment = ? AND id = ?
            """,
          arguments: [String(severity.prefix(32)), String(summary.prefix(512)), evidenceJSON,
            String(runbookSlug.prefix(128)), Self.iso(at), environment, existing.id])
        guard let updatedRow = try Row.fetchOne(database, sql: "SELECT * FROM operations_alerts WHERE environment = ? AND id = ?", arguments: [environment, existing.id]),
          let updated = Self.alert(updatedRow)
        else { throw OperationsStoreError.missingCreatedRecord }
        return updated
      }
      let id = UUID().uuidString.lowercased()
      try database.execute(
        sql: """
          INSERT INTO operations_alerts
            (environment, id, rule, condition_key, severity, status, summary, evidence, runbook_slug,
             opened_at, updated_at, next_delivery_at, expires_at, version)
          VALUES (?, ?, ?, ?, ?, 'open', ?, ?, ?, ?, ?, ?, ?, 0)
          """,
        arguments: [
          environment, id, String(rule.prefix(128)), String(conditionKey.prefix(192)),
          String(severity.prefix(32)), String(summary.prefix(512)),
          evidenceJSON, String(runbookSlug.prefix(128)),
          Self.iso(at), Self.iso(at), Self.iso(at), Self.iso(at.addingTimeInterval(365 * 86_400)),
        ]
      )
      guard let row = try Row.fetchOne(database, sql: "SELECT * FROM operations_alerts WHERE environment = ? AND id = ?", arguments: [environment, id]),
        let created = Self.alert(row)
      else { throw OperationsStoreError.missingCreatedRecord }
      return created
    }
  }

  public func resolveAlert(conditionKey: String, at: Date) async throws {
    try await db.write { database in
      let ids = try String.fetchAll(
        database,
        sql: """
          SELECT id FROM operations_alerts
          WHERE environment = ? AND condition_key = ? AND status != 'resolved'
          """, arguments: [environment, conditionKey])
      try database.execute(
        sql: """
          UPDATE operations_alerts SET status = 'resolved', resolved_by_did = 'system:evaluator',
            updated_at = ?, expires_at = ?, version = version + 1
          WHERE environment = ? AND condition_key = ? AND status != 'resolved'
          """,
        arguments: [Self.iso(at), Self.iso(at.addingTimeInterval(365 * 86_400)),
          environment, conditionKey])
      for id in ids {
        try Self.extendLifecycleRetention(
          database: database, environment: environment, targetType: "alert", targetId: id,
          terminalAt: at)
      }
    }
  }

  public func listAlertsPendingDelivery(limit: Int, at: Date) async throws -> [OperationsAlert] {
    try await db.read { database in
      try Row.fetchAll(
        database,
        sql: """
          SELECT * FROM operations_alerts
          WHERE environment = ? AND status != 'resolved' AND delivery_dead_lettered_at IS NULL
            AND next_delivery_at IS NOT NULL AND next_delivery_at <= ?
          ORDER BY next_delivery_at, opened_at LIMIT ?
          """,
        arguments: [environment, Self.iso(at), max(1, min(limit, 100))]
      ).compactMap(Self.alert)
    }
  }

  public func updateAlertStatus(
    id: String,
    status: OperationsAlertStatus,
    operatorDid: String,
    at: Date
  ) async throws {
    guard let current = try await fetchAlert(id: id) else {
      throw OperationsStoreError.notFound
    }
    _ = try await transitionAlert(
      id: id, to: status, expectedVersion: current.version, operatorDid: operatorDid,
      idempotencyKey: UUID().uuidString.lowercased(), requestId: nil, note: nil, at: at)
  }

  public func transitionAlert(
    id: String,
    to status: OperationsAlertStatus,
    expectedVersion: Int,
    operatorDid: String,
    idempotencyKey: String,
    requestId: String? = nil,
    note: String?,
    at: Date
  ) async throws -> OperationsAlert {
    let actionName = "alert.\(status.rawValue)"
    let requestFingerprint = OperationsIdempotencyFingerprint.make(
      action: actionName, targetType: "alert", targetId: id, expectedVersion: expectedVersion,
      fields: ["operatorDid": operatorDid, "note": note, "status": status.rawValue])
    return try await db.write { database in
      if let existing = try Self.existingIdempotency(
        database: database, environment: environment, key: idempotencyKey,
        action: actionName, targetType: "alert", targetId: id,
        requestFingerprint: requestFingerprint)
      {
        let replay = try Self.replayIdempotencyResult(existing, as: OperationsAlert.self)
        try Self.insertAudit(
          database: database, environment: environment, operatorDid: operatorDid,
          action: actionName, targetType: "alert", targetId: replay.id,
          idempotencyKey: idempotencyKey, requestId: requestId,
          expectedVersion: expectedVersion, note: note, before: [:],
          after: ["status": replay.status.rawValue, "version": String(replay.version)],
          outcome: "idempotent_replay", at: at)
        return replay
      }
      guard let row = try Row.fetchOne(database, sql: "SELECT * FROM operations_alerts WHERE environment = ? AND id = ?", arguments: [environment, id]),
        let current = Self.alert(row)
      else { throw OperationsStoreError.notFound }
      guard current.version == expectedVersion else {
        throw OperationsStoreError.versionConflict(expected: expectedVersion, actual: current.version)
      }
      guard Self.canTransitionAlert(from: current.status, to: status) else {
        throw OperationsStoreError.invalidTransition(from: current.status.rawValue, to: status.rawValue)
      }
      try database.execute(
        sql: """
          UPDATE operations_alerts SET status = ?, updated_at = ?, version = version + 1,
            acknowledged_by_did = CASE WHEN ? = 'acknowledged' THEN ? ELSE acknowledged_by_did END,
            resolved_by_did = CASE WHEN ? = 'resolved' THEN ? ELSE resolved_by_did END,
            expires_at = CASE WHEN ? = 'resolved' THEN ? ELSE expires_at END
          WHERE environment = ? AND id = ? AND version = ?
          """,
        arguments: [status.rawValue, Self.iso(at), status.rawValue, operatorDid,
          status.rawValue, operatorDid, status.rawValue,
          Self.iso(at.addingTimeInterval(365 * 86_400)), environment, id, expectedVersion])
      guard database.changesCount == 1 else { throw OperationsStoreError.versionConflict(expected: expectedVersion, actual: current.version + 1) }
      if status == .resolved {
        try Self.extendLifecycleRetention(
          database: database, environment: environment, targetType: "alert", targetId: id,
          terminalAt: at)
      }
      guard let updatedRow = try Row.fetchOne(database, sql: "SELECT * FROM operations_alerts WHERE environment = ? AND id = ?", arguments: [environment, id]),
        let updated = Self.alert(updatedRow)
      else { throw OperationsStoreError.missingCreatedRecord }
      try Self.insertIdempotency(
        database: database, environment: environment, key: idempotencyKey,
        action: actionName, targetType: "alert", targetId: id,
        outcome: "succeeded", requestFingerprint: requestFingerprint,
        resultPayload: try Self.encodeIdempotencyResult(updated), at: at)
      try Self.insertAudit(
        database: database, environment: environment, operatorDid: operatorDid,
        action: "alert.\(status.rawValue)", targetType: "alert", targetId: id,
        idempotencyKey: idempotencyKey, requestId: requestId,
        expectedVersion: expectedVersion, note: note,
        before: ["status": current.status.rawValue, "version": String(current.version)],
        after: ["status": status.rawValue, "version": String(current.version + 1)],
        outcome: "succeeded", at: at)
      return updated
    }
  }

  public func retryAlertDelivery(
    id: String,
    expectedVersion: Int,
    operatorDid: String,
    idempotencyKey: String,
    requestId: String? = nil,
    note: String?,
    at: Date
  ) async throws -> OperationsAlert {
    let actionName = "alert.delivery_retry"
    let requestFingerprint = OperationsIdempotencyFingerprint.make(
      action: actionName, targetType: "alert", targetId: id, expectedVersion: expectedVersion,
      fields: ["operatorDid": operatorDid, "note": note])
    return try await db.write { database in
      if let existing = try Self.existingIdempotency(
        database: database, environment: environment, key: idempotencyKey,
        action: actionName, targetType: "alert", targetId: id,
        requestFingerprint: requestFingerprint)
      {
        let replay = try Self.replayIdempotencyResult(existing, as: OperationsAlert.self)
        try Self.insertAudit(
          database: database, environment: environment, operatorDid: operatorDid,
          action: actionName, targetType: "alert", targetId: replay.id,
          idempotencyKey: idempotencyKey, requestId: requestId,
          expectedVersion: expectedVersion, note: note, before: [:],
          after: ["status": replay.status.rawValue, "version": String(replay.version)],
          outcome: "idempotent_replay", at: at)
        return replay
      }
      guard let row = try Row.fetchOne(
        database, sql: "SELECT * FROM operations_alerts WHERE environment = ? AND id = ?",
        arguments: [environment, id]), let current = Self.alert(row)
      else { throw OperationsStoreError.notFound }
      guard current.version == expectedVersion else {
        throw OperationsStoreError.versionConflict(expected: expectedVersion, actual: current.version)
      }
      guard current.status != .resolved else {
        throw OperationsStoreError.invalidTransition(from: current.status.rawValue, to: "delivery_retry")
      }
      try database.execute(
        sql: """
          UPDATE operations_alerts SET next_delivery_at = ?, delivery_dead_lettered_at = NULL,
            delivery_attempts = 0, last_delivery_error = NULL, updated_at = ?, version = version + 1
          WHERE environment = ? AND id = ? AND version = ?
          """,
        arguments: [Self.iso(at), Self.iso(at), environment, id, expectedVersion])
      guard database.changesCount == 1 else {
        throw OperationsStoreError.versionConflict(expected: expectedVersion, actual: current.version + 1)
      }
      guard let updatedRow = try Row.fetchOne(database, sql: "SELECT * FROM operations_alerts WHERE environment = ? AND id = ?", arguments: [environment, id]),
        let updated = Self.alert(updatedRow)
      else { throw OperationsStoreError.notFound }
      try Self.insertIdempotency(
        database: database, environment: environment, key: idempotencyKey,
        action: actionName, targetType: "alert", targetId: id,
        outcome: "queued", requestFingerprint: requestFingerprint,
        resultPayload: try Self.encodeIdempotencyResult(updated), at: at)
      try Self.insertAudit(
        database: database, environment: environment, operatorDid: operatorDid,
        action: "alert.delivery_retry", targetType: "alert", targetId: id,
        idempotencyKey: idempotencyKey, requestId: requestId,
        expectedVersion: expectedVersion, note: note,
        before: [
          "status": current.status.rawValue, "version": String(current.version),
          "deliveryAttempts": String(current.deliveryAttempts),
        ],
        after: [
          "delivery": "queued", "deliveryAttempts": "0",
          "version": String(current.version + 1),
        ],
        outcome: "queued", at: at)
      return updated
    }
  }

  public func recordAlertDelivery(id: String, error: String?, at: Date) async throws {
    try await db.write { database in
      guard let attemptsBefore = try Int.fetchOne(
        database,
        sql: "SELECT delivery_attempts FROM operations_alerts WHERE environment = ? AND id = ? AND status != 'resolved'",
        arguments: [environment, id])
      else { return }
      let attempts = attemptsBefore + 1
      let deadLetteredAt = error != nil
        && attempts >= OperationsAlertDeliveryRetryPolicy.maximumAttempts ? Self.iso(at) : nil
      let nextDeliveryAt = error != nil
        && attempts < OperationsAlertDeliveryRetryPolicy.maximumAttempts
        ? Self.iso(at.addingTimeInterval(
          OperationsAlertDeliveryRetryPolicy.delaySeconds(alertId: id, attempt: attempts))) : nil
      try database.execute(
        sql: """
          UPDATE operations_alerts SET delivery_attempts = delivery_attempts + 1,
            last_delivery_error = ?, next_delivery_at = ?, delivery_dead_lettered_at = ?,
            updated_at = ?, version = version + 1
          WHERE environment = ? AND id = ? AND status != 'resolved'
          """,
        arguments: [error.map { String($0.prefix(256)) }, nextDeliveryAt, deadLetteredAt,
          Self.iso(at), environment, id]
      )
    }
  }

  public func listTraceSpans(limit: Int, traceId: String?) async throws -> [TraceSpan] {
    let limit = max(1, min(limit, 500))
    return try await db.read { database in
      let rows: [Row]
      if let traceId {
        rows = try Row.fetchAll(
          database,
          sql:
            "SELECT * FROM operations_trace_spans WHERE environment = ? AND trace_id = ? ORDER BY started_at DESC LIMIT ?",
          arguments: [environment, traceId, limit]
        )
      } else {
        rows = try Row.fetchAll(
          database,
          sql: "SELECT * FROM operations_trace_spans WHERE environment = ? ORDER BY started_at DESC LIMIT ?",
          arguments: [environment, limit]
        )
      }
      return rows.compactMap(Self.span)
    }
  }

  public func listTraceSpans(startAt: Date, endAt: Date, limit: Int) async throws -> [TraceSpan] {
    let limit = max(1, min(limit, 500))
    return try await db.read { database in
      try Row.fetchAll(
        database,
        sql: """
          SELECT * FROM operations_trace_spans
          WHERE environment = ? AND started_at >= ? AND started_at <= ?
          ORDER BY started_at ASC
          LIMIT ?
          """,
        arguments: [environment, Self.iso(startAt), Self.iso(endAt), limit]
      ).compactMap(Self.span)
    }
  }

  public func listTraceSpans(
    startAt: Date,
    endAt: Date,
    limit: Int,
    before: String?
  ) async throws -> OperationsPage<TraceSpan> {
    let limit = max(1, min(limit, 500))
    return try await db.read { database in
      var arguments: StatementArguments = [environment, Self.iso(startAt), Self.iso(endAt)]
      var cursorPredicate = ""
      if let decoded = try Self.decodeCursor(before) {
        cursorPredicate = " AND (started_at < ? OR (started_at = ? AND id < ?))"
        let date = Self.iso(decoded.date)
        arguments += [date, date, decoded.id]
      }
      arguments += [limit + 1]
      let rows = try Row.fetchAll(
        database,
        sql: """
          SELECT * FROM operations_trace_spans
          WHERE environment = ? AND started_at >= ? AND started_at <= ?\(cursorPredicate)
          ORDER BY started_at DESC, id DESC LIMIT ?
          """,
        arguments: arguments).compactMap(Self.span)
      let total = try Int.fetchOne(
        database,
        sql: """
          SELECT COUNT(*) FROM operations_trace_spans
          WHERE environment = ? AND started_at >= ? AND started_at <= ?
          """,
        arguments: [environment, Self.iso(startAt), Self.iso(endAt)]) ?? 0
      let items = Array(rows.prefix(limit))
      let next = rows.count > limit
        ? items.last.map { OperationsPaginationCursor.encode(date: $0.startedAt, id: $0.id) } : nil
      return OperationsPage(items: items, nextCursor: next, totalCount: total)
    }
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
    return try await db.read { database in
      try Row.fetchAll(
        database,
        sql: """
          SELECT environment, bucket_start, metric_name, dimensions, sample_count, value_sum, value_min, value_max
          FROM operations_metric_rollups
          WHERE environment = ? AND bucket_start >= ? AND bucket_start <= ?
          ORDER BY bucket_start ASC, metric_name ASC, dimensions_hash ASC
          LIMIT ?
          """,
        arguments: [environment, Self.iso(startAt), Self.iso(endAt), limit]
      ).compactMap { row in
        guard let bucketStart = Self.date(row["bucket_start"]) else { return nil }
        let dimensionsJSON: String = row["dimensions"]
        return OperationsMetricRollup(
          environment: row["environment"],
          bucketStart: bucketStart,
          metricName: row["metric_name"],
          dimensions: Self.decode([String: String].self, dimensionsJSON) ?? [:],
          sampleCount: row["sample_count"],
          valueSum: row["value_sum"],
          valueMin: row["value_min"],
          valueMax: row["value_max"]
        )
      }
    }
  }

  public func listMetricRollups(
    startAt: Date,
    endAt: Date,
    metricName: String?,
    collection: String?,
    limit: Int
  ) async throws -> [OperationsMetricRollup] {
    let limit = max(1, min(limit, 10_000))
    return try await db.read { database in
      try Row.fetchAll(
        database,
        sql: """
          SELECT environment, bucket_start, metric_name, dimensions, sample_count, value_sum,
            value_min, value_max
          FROM operations_metric_rollups
          WHERE environment = ? AND bucket_start >= ? AND bucket_start <= ?
            AND (? IS NULL OR metric_name = ?)
            AND (? IS NULL OR json_extract(dimensions, '$.collection') = ?)
          ORDER BY bucket_start ASC, metric_name ASC, dimensions_hash ASC LIMIT ?
          """,
        arguments: [environment, Self.iso(startAt), Self.iso(endAt), metricName, metricName,
          collection, collection, limit]
      ).compactMap { row in
        guard let bucketStart = Self.date(row["bucket_start"]) else { return nil }
        let dimensionsJSON: String = row["dimensions"]
        return OperationsMetricRollup(
          environment: row["environment"], bucketStart: bucketStart,
          metricName: row["metric_name"],
          dimensions: Self.decode([String: String].self, dimensionsJSON) ?? [:],
          sampleCount: row["sample_count"], valueSum: row["value_sum"],
          valueMin: row["value_min"], valueMax: row["value_max"])
      }
    }
  }

  public func listGapInvestigationEvents(startAt: Date, endAt: Date, limit: Int) async throws
    -> [OperationsEvent]
  {
    let limit = max(1, min(limit, 500))
    return try await db.read { database in
      try Row.fetchAll(
        database,
        sql: """
          SELECT * FROM operations_events
          WHERE environment = ? AND occurred_at >= ? AND occurred_at <= ?
            AND event_name IN ('jetstream.disconnected', 'jetstream.connected', 'commit.failed')
          ORDER BY occurred_at ASC
          LIMIT ?
          """,
        arguments: [environment, Self.iso(startAt), Self.iso(endAt), limit]
      ).compactMap(Self.event)
    }
  }

  public func recordEvent(_ event: OperationsEvent) async throws {
    try await recordTelemetryBatch([.event(event)])
  }

  public func recordTelemetryBatch(_ signals: [OperationsTelemetrySignal]) async throws {
    guard !signals.isEmpty else { return }
    try await db.write { database in
      for signal in signals {
        try Self.insertTelemetry(signal, environment: environment, database: database)
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
    return try await db.write { database in
      try database.execute(
        sql: """
          INSERT OR IGNORE INTO operations_change_event_watermarks
            (environment, latest_cursor, earliest_available_cursor, updated_at)
          VALUES (?, 0, 1, ?)
          """, arguments: [environment, Self.iso(at)])
      try database.execute(
        sql: """
          UPDATE operations_change_event_watermarks
          SET latest_cursor = latest_cursor + 1, updated_at = ?
          WHERE environment = ?
          """, arguments: [Self.iso(at), environment])
      guard let cursor = try Int64.fetchOne(
        database,
        sql: "SELECT latest_cursor FROM operations_change_event_watermarks WHERE environment = ?",
        arguments: [environment])
      else { throw OperationsStoreError.missingCreatedRecord }
      try database.execute(
        sql: """
          INSERT INTO operations_change_events
            (environment, cursor, event_type, entity_type, entity_id, payload, occurred_at, expires_at)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?)
          """,
        arguments: [
          environment, cursor, String(eventType.prefix(160)), String(entityType.prefix(64)),
          entityId, payloadJSON, Self.iso(at), Self.iso(at.addingTimeInterval(30 * 86_400)),
        ])
      return OperationsChangeEvent(
        environment: environment, cursor: cursor, eventType: String(eventType.prefix(160)),
        entityType: String(entityType.prefix(64)), entityId: entityId, payload: payload,
        occurredAt: at)
    }
  }

  public func listChangeEvents(after cursor: Int64, limit: Int) async throws
    -> [OperationsChangeEvent]
  {
    try await db.read { database in
      try Row.fetchAll(
        database,
        sql: """
          SELECT cursor, event_type, entity_type, entity_id, payload, occurred_at
          FROM operations_change_events
          WHERE environment = ? AND cursor > ?
          ORDER BY cursor ASC LIMIT ?
          """,
        arguments: [environment, max(0, cursor), max(1, min(limit, 500))]
      ).compactMap { row in
        guard let occurredAt = Self.date(row["occurred_at"]) else { return nil }
        let payloadJSON: String = row["payload"]
        return OperationsChangeEvent(
          environment: environment, cursor: row["cursor"], eventType: row["event_type"],
          entityType: row["entity_type"], entityId: row["entity_id"],
          payload: Self.decode([String: String].self, payloadJSON) ?? [:],
          occurredAt: occurredAt)
      }
    }
  }

  public func changeEventCursorBounds() async throws -> OperationsChangeEventCursorBounds {
    try await db.read { database in
      guard let row = try Row.fetchOne(
        database,
        sql: """
          SELECT earliest_available_cursor, latest_cursor
          FROM operations_change_event_watermarks WHERE environment = ?
          """, arguments: [environment])
      else { return OperationsChangeEventCursorBounds(earliestAvailable: 1, latest: 0) }
      return OperationsChangeEventCursorBounds(
        earliestAvailable: row["earliest_available_cursor"], latest: row["latest_cursor"])
    }
  }

  public func recordAudit(
    operatorDid: String,
    action: String,
    targetType: String,
    targetId: String?,
    note: String?,
    at: Date
  ) async throws {
    try await db.write { database in
      try Self.insertAudit(
        database: database, environment: environment, operatorDid: operatorDid,
        action: action, targetType: targetType, targetId: targetId,
        idempotencyKey: nil, note: note, before: [:], after: [:], outcome: "recorded", at: at)
    }
  }

  public func recordAudit(_ audit: OperationsMutationAudit) async throws {
    try await db.write { database in
      let before = audit.before.merging(
        audit.expectedVersion.map { ["expectedVersion": String($0)] } ?? [:],
        uniquingKeysWith: { current, _ in current })
      try Self.insertAudit(
        database: database, environment: environment, operatorDid: audit.operatorDid,
        action: audit.action, targetType: audit.targetType, targetId: audit.targetId,
        idempotencyKey: audit.idempotencyKey, requestId: audit.requestId,
        expectedVersion: audit.expectedVersion, note: audit.note, before: before,
        after: audit.after, outcome: audit.outcome, at: audit.occurredAt)
    }
  }

  struct StoredMutationAudit: Sendable, Equatable {
    let requestId: String?
    let expectedVersion: Int?
    let before: [String: String]
    let after: [String: String]
    let outcome: String
  }

  func mutationAudits(idempotencyKey: String) async throws -> [StoredMutationAudit] {
    try await db.read { database in
      try Row.fetchAll(
        database,
        sql: """
          SELECT request_id, expected_version, before_state, after_state, outcome
          FROM operations_audit_events
          WHERE environment = ? AND idempotency_key = ? ORDER BY occurred_at, id
          """,
        arguments: [environment, idempotencyKey]
      ).map { row in
        let beforeJSON: String = row["before_state"]
        let afterJSON: String = row["after_state"]
        return StoredMutationAudit(
          requestId: row["request_id"], expectedVersion: row["expected_version"],
          before: Self.decode([String: String].self, beforeJSON) ?? [:],
          after: Self.decode([String: String].self, afterJSON) ?? [:],
          outcome: row["outcome"])
      }
    }
  }

  func lifecycleExpiry(table: String, id: String) async throws -> Date? {
    let allowedTable: String
    switch table {
    case "operations_commands", "appview_ingestion_gaps", "appview_backfill_jobs",
      "operations_alerts": allowedTable = table
    default: throw OperationsStoreError.notFound
    }
    return try await db.read { database in
      let value = try String.fetchOne(
        database,
        sql: "SELECT expires_at FROM \(allowedTable) WHERE environment = ? AND id = ?",
        arguments: [environment, id])
      return value.flatMap(Self.date)
    }
  }

  func latestAuditExpiry(targetId: String) async throws -> Date? {
    try await db.read { database in
      let value = try String.fetchOne(
        database,
        sql: """
          SELECT expires_at FROM operations_audit_events
          WHERE environment = ? AND target_id = ? ORDER BY occurred_at DESC, id DESC LIMIT 1
          """, arguments: [environment, targetId])
      return value.flatMap(Self.date)
    }
  }

  public func cleanupExpired(at: Date, batchSize: Int) async throws -> Int {
    let batchSize = max(1, min(batchSize, 10_000))
    return try await db.write { database in
      var deleted = 0
      let expiredChangeCursor = try Int64.fetchOne(
        database,
        sql: """
          SELECT MAX(cursor) FROM (
            SELECT cursor FROM operations_change_events
            WHERE environment = ? AND expires_at <= ? ORDER BY cursor LIMIT ?
          )
          """,
        arguments: [environment, Self.iso(at), batchSize])
      try database.execute(
        sql: """
          DELETE FROM operations_change_events
          WHERE rowid IN (
            SELECT rowid FROM operations_change_events
            WHERE environment = ? AND expires_at <= ? ORDER BY cursor LIMIT ?
          )
          """,
        arguments: [environment, Self.iso(at), batchSize])
      deleted += database.changesCount
      if let expiredChangeCursor {
        try database.execute(
          sql: """
            UPDATE operations_change_event_watermarks
            SET earliest_available_cursor = MAX(earliest_available_cursor, ?), updated_at = ?
            WHERE environment = ?
            """,
          arguments: [expiredChangeCursor + 1, Self.iso(at), environment])
      }
      for table in [
        "operations_metric_rollups", "operations_trace_spans", "operations_events",
        "operations_audit_events", "operations_idempotency_records", "appview_recovery_failures",
      ] {
        try database.execute(
          sql: "DELETE FROM \(table) WHERE rowid IN (SELECT rowid FROM \(table) WHERE environment = ? AND expires_at <= ? LIMIT ?)",
          arguments: [environment, Self.iso(at), batchSize])
        deleted += database.changesCount
      }
      try database.execute(
        sql: """
          DELETE FROM operations_service_state WHERE rowid IN (
            SELECT rowid FROM operations_service_state
            WHERE environment = ? AND heartbeat_at <= ? LIMIT ?
          )
          """,
        arguments: [environment, Self.iso(at.addingTimeInterval(-86_400)), batchSize])
      deleted += database.changesCount
      for (table, terminalPredicate) in [
        ("operations_commands", "status IN ('completed', 'failed')"),
        ("operations_alerts", "status = 'resolved'"),
        ("appview_backfill_jobs", "status IN ('completed', 'failed', 'cancelled')"),
        ("appview_ingestion_gaps", "status IN ('resolved', 'ignored')"),
      ] {
        try database.execute(
          sql: "DELETE FROM \(table) WHERE rowid IN (SELECT rowid FROM \(table) WHERE environment = ? AND \(terminalPredicate) AND expires_at <= ? LIMIT ?)",
          arguments: [environment, Self.iso(at), batchSize])
        deleted += database.changesCount
      }
      return deleted
    }
  }

  private static func migrate(_ db: Database) throws {
    try db.execute(sql: Schema.sqlite)
    for table in [
      "operations_metric_rollups", "operations_trace_spans", "operations_audit_events",
      "appview_ingestion_stream_state", "appview_jetstream_endpoints", "operations_commands",
      "appview_ingestion_gaps", "appview_backfill_jobs", "appview_recovery_failures",
      "operations_alerts",
    ] {
      try addColumnIfMissing(
        db, table: table, column: "environment",
        definition: "TEXT NOT NULL DEFAULT '__legacy_unscoped__'")
    }
    try addColumnIfMissing(db, table: "appview_ingestion_stream_state", column: "version", definition: "INTEGER NOT NULL DEFAULT 0")
    try addColumnIfMissing(db, table: "appview_ingestion_stream_state", column: "queue_capacity", definition: "INTEGER")
    try addColumnIfMissing(db, table: "appview_ingestion_stream_state", column: "queue_overflow_total", definition: "INTEGER")
    try addColumnIfMissing(db, table: "appview_ingestion_stream_state", column: "queue_observed_at", definition: "TEXT")
    try addColumnIfMissing(db, table: "appview_ingestion_stream_state", column: "transport_heartbeat_at", definition: "TEXT")
    try addColumnIfMissing(db, table: "appview_ingestion_stream_state", column: "last_indexed_mutation_at", definition: "TEXT")
    try addColumnIfMissing(db, table: "appview_ingestion_stream_state", column: "projection_watermark", definition: "TEXT")
    try addColumnIfMissing(db, table: "appview_ingestion_stream_state", column: "validation_watermark", definition: "TEXT")
    try addColumnIfMissing(db, table: "appview_jetstream_endpoints", column: "version", definition: "INTEGER NOT NULL DEFAULT 0")
    try addColumnIfMissing(db, table: "operations_commands", column: "version", definition: "INTEGER NOT NULL DEFAULT 0")
    try addColumnIfMissing(db, table: "operations_commands", column: "expires_at", definition: "TEXT")
    try addColumnIfMissing(db, table: "operations_commands", column: "lease_expires_at", definition: "TEXT")
    try addColumnIfMissing(db, table: "appview_ingestion_gaps", column: "version", definition: "INTEGER NOT NULL DEFAULT 0")
    try addColumnIfMissing(db, table: "appview_ingestion_gaps", column: "expires_at", definition: "TEXT")
    try addColumnIfMissing(db, table: "appview_backfill_jobs", column: "version", definition: "INTEGER NOT NULL DEFAULT 0")
    try addColumnIfMissing(db, table: "appview_backfill_jobs", column: "failure_reason", definition: "TEXT")
    try addColumnIfMissing(db, table: "appview_backfill_jobs", column: "idempotency_key", definition: "TEXT")
    try addColumnIfMissing(db, table: "appview_backfill_jobs", column: "verification_status", definition: "TEXT NOT NULL DEFAULT 'required'")
    try addColumnIfMissing(db, table: "appview_backfill_jobs", column: "verification_reason", definition: "TEXT")
    try addColumnIfMissing(db, table: "appview_backfill_jobs", column: "scope_truncated", definition: "INTEGER NOT NULL DEFAULT 0")
    try addColumnIfMissing(db, table: "appview_backfill_jobs", column: "validation_watermark", definition: "TEXT")
    try addColumnIfMissing(db, table: "appview_backfill_jobs", column: "request_fingerprint", definition: "TEXT")
    try addColumnIfMissing(db, table: "appview_backfill_jobs", column: "request_fingerprint_expires_at", definition: "TEXT")
    try addColumnIfMissing(db, table: "appview_backfill_jobs", column: "normalized_request_hash", definition: "TEXT")
    try addColumnIfMissing(
      db, table: "appview_backfill_jobs", column: "author_results",
      definition: "TEXT NOT NULL DEFAULT '[]'")
    try addColumnIfMissing(db, table: "appview_backfill_jobs", column: "expires_at", definition: "TEXT")
    try addColumnIfMissing(db, table: "operations_alerts", column: "version", definition: "INTEGER NOT NULL DEFAULT 0")
    try addColumnIfMissing(db, table: "operations_alerts", column: "condition_key", definition: "TEXT NOT NULL DEFAULT '__legacy__'")
    try addColumnIfMissing(db, table: "operations_alerts", column: "next_delivery_at", definition: "TEXT")
    try addColumnIfMissing(db, table: "operations_alerts", column: "delivery_dead_lettered_at", definition: "TEXT")
    try addColumnIfMissing(db, table: "operations_alerts", column: "expires_at", definition: "TEXT")
    try addColumnIfMissing(db, table: "operations_audit_events", column: "idempotency_key", definition: "TEXT")
    try addColumnIfMissing(db, table: "operations_audit_events", column: "request_id", definition: "TEXT")
    try addColumnIfMissing(db, table: "operations_audit_events", column: "expected_version", definition: "INTEGER")
    try addColumnIfMissing(db, table: "operations_audit_events", column: "before_state", definition: "TEXT NOT NULL DEFAULT '{}'")
    try addColumnIfMissing(db, table: "operations_audit_events", column: "after_state", definition: "TEXT NOT NULL DEFAULT '{}'")
    try addColumnIfMissing(db, table: "operations_audit_events", column: "outcome", definition: "TEXT NOT NULL DEFAULT 'recorded'")
    try addColumnIfMissing(db, table: "operations_idempotency_records", column: "request_fingerprint", definition: "TEXT")
    try addColumnIfMissing(db, table: "operations_idempotency_records", column: "result_payload", definition: "TEXT NOT NULL DEFAULT '{}'")
    try db.execute(sql: """
      UPDATE operations_commands
      SET status = 'queued', claimed_by = NULL, lease_expires_at = NULL,
          updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now'), version = version + 1
      WHERE status = 'running' AND (claimed_by IS NULL OR lease_expires_at IS NULL);
      UPDATE operations_commands
      SET expires_at = strftime('%Y-%m-%dT%H:%M:%fZ', COALESCE(completed_at, updated_at), '+365 days')
      WHERE status IN ('completed', 'failed');
      UPDATE appview_ingestion_gaps
      SET expires_at = strftime('%Y-%m-%dT%H:%M:%fZ', updated_at, '+365 days')
      WHERE status IN ('resolved', 'ignored');
      UPDATE appview_backfill_jobs
      SET expires_at = strftime('%Y-%m-%dT%H:%M:%fZ', COALESCE(completed_at, updated_at), '+365 days')
      WHERE status IN ('completed', 'failed', 'cancelled');
      UPDATE operations_alerts
      SET expires_at = strftime('%Y-%m-%dT%H:%M:%fZ', updated_at, '+365 days')
      WHERE status = 'resolved';
      UPDATE operations_audit_events
      SET expires_at = strftime('%Y-%m-%dT%H:%M:%fZ', occurred_at, '+365 days');
      """)
    try db.execute(sql: Schema.indexes)
    try installChangeEventTriggers(db)
  }

  private static func addColumnIfMissing(
    _ db: Database,
    table: String,
    column: String,
    definition: String
  ) throws {
    let columns = try Row.fetchAll(db, sql: "PRAGMA table_info(\(table))")
      .map { row -> String in row["name"] }
    if !columns.contains(column) {
      try db.execute(sql: "ALTER TABLE \(table) ADD COLUMN \(column) \(definition)")
    }
  }

  private static func installChangeEventTriggers(_ db: Database) throws {
    for table in ["operations_service_state", "appview_ingestion_stream_state"] {
      for operation in ["insert", "update"] {
        try db.execute(sql: "DROP TRIGGER IF EXISTS operations_change_\(table)_\(operation)")
      }
    }
    let targets: [(table: String, entity: String, id: String)] = [
      ("appview_jetstream_endpoints", "endpoint", "id"),
      ("operations_commands", "command", "id"),
      ("appview_ingestion_gaps", "gap", "id"),
      ("appview_backfill_jobs", "job", "id"),
      ("operations_alerts", "alert", "id"),
    ]
    for target in targets {
      for operation in ["INSERT", "UPDATE"] {
        let trigger = "operations_change_\(target.table)_\(operation.lowercased())"
        try db.execute(sql: """
          CREATE TRIGGER IF NOT EXISTS \(trigger)
          AFTER \(operation) ON \(target.table)
          FOR EACH ROW WHEN NEW.environment != '__legacy_unscoped__'
          BEGIN
            INSERT OR IGNORE INTO operations_change_event_watermarks
              (environment, latest_cursor, earliest_available_cursor, updated_at)
            VALUES (NEW.environment, 0, 1, strftime('%Y-%m-%dT%H:%M:%fZ', 'now'));
            UPDATE operations_change_event_watermarks
            SET latest_cursor = latest_cursor + 1,
                updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
            WHERE environment = NEW.environment;
            INSERT INTO operations_change_events
              (environment, cursor, event_type, entity_type, entity_id, payload,
               occurred_at, expires_at)
            VALUES (
              NEW.environment,
              (SELECT latest_cursor FROM operations_change_event_watermarks
               WHERE environment = NEW.environment),
              '\(target.entity).\(operation.lowercased())',
              '\(target.entity)',
              NEW.\(target.id),
              '{}',
              strftime('%Y-%m-%dT%H:%M:%fZ', 'now'),
              strftime('%Y-%m-%dT%H:%M:%fZ', 'now', '+30 days'));
          END;
          """)
      }
    }
  }

  private func mutateOwnedBackfill(
    id: String,
    workerId: String,
    expectedVersion: Int,
    leaseUntil: Date,
    at: Date,
    update: String,
    additionalArguments: StatementArguments = []
  ) async throws -> BackfillJob {
    try await db.write { database in
      var arguments = additionalArguments
      arguments += [Self.iso(leaseUntil), Self.iso(at), environment, id, workerId, Self.iso(at), expectedVersion]
      try database.execute(
        sql: """
          UPDATE appview_backfill_jobs SET \(update), lease_expires_at = ?, updated_at = ?
          WHERE environment = ? AND id = ? AND status = 'running' AND lease_owner = ?
            AND lease_expires_at >= ? AND version = ?
          """,
        arguments: arguments)
      guard database.changesCount == 1 else { throw OperationsStoreError.leaseConflict }
      guard let row = try Row.fetchOne(
        database, sql: "SELECT * FROM appview_backfill_jobs WHERE environment = ? AND id = ?",
        arguments: [environment, id]),
        let job = Self.backfill(row)
      else { throw OperationsStoreError.notFound }
      return job
    }
  }

  private static func canTransitionGap(
    from: IngestionGapStatus,
    to: IngestionGapStatus
  ) -> Bool {
    switch (from, to) {
    case (.suspected, .confirmed), (.suspected, .resolved),
      (.confirmed, .backfillQueued), (.confirmed, .ignored),
      (.backfillQueued, .backfilling), (.backfillQueued, .confirmed),
      (.backfilling, .resolved), (.backfilling, .verificationRequired),
      (.backfilling, .confirmed), (.verificationRequired, .resolved),
      (.verificationRequired, .confirmed), (.verificationRequired, .backfillQueued):
      return true
    default:
      return false
    }
  }

  private static func canTransitionBackfill(
    from: BackfillJobStatus,
    to: BackfillJobStatus
  ) -> Bool {
    switch (from, to) {
    case (.queued, .running), (.queued, .cancelled),
      (.running, .paused), (.running, .completed), (.running, .failed),
      (.running, .cancelled), (.paused, .queued), (.paused, .cancelled):
      return true
    default:
      return false
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

  private static func canTransitionAlert(
    from: OperationsAlertStatus,
    to: OperationsAlertStatus
  ) -> Bool {
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

  private struct StoredIdempotencyResult {
    let targetId: String
    let resultPayload: String
  }

  private static func existingIdempotency(
    database: Database,
    environment: String,
    key: String,
    action: String,
    targetType: String,
    targetId: String?,
    requestFingerprint: String
  ) throws -> StoredIdempotencyResult? {
    guard let row = try Row.fetchOne(
      database,
      sql: """
        SELECT action, target_type, target_id, request_fingerprint, result_payload
        FROM operations_idempotency_records
        WHERE environment = ? AND idempotency_key = ? LIMIT 1
        """,
      arguments: [environment, key])
    else { return nil }
    let recordedAction: String = row["action"]
    let recordedTargetType: String = row["target_type"]
    let recordedTargetId: String? = row["target_id"]
    let recordedFingerprint: String? = row["request_fingerprint"]
    let resultPayload: String = row["result_payload"]
    guard recordedAction == action, recordedTargetType == targetType,
      targetId == nil || recordedTargetId == targetId,
      recordedFingerprint == requestFingerprint,
      !resultPayload.isEmpty
    else { throw OperationsStoreError.idempotencyConflict }
    guard let recordedTargetId else { throw OperationsStoreError.idempotencyConflict }
    return StoredIdempotencyResult(targetId: recordedTargetId, resultPayload: resultPayload)
  }

  private static func insertIdempotency(
    database: Database,
    environment: String,
    key: String,
    action: String,
    targetType: String,
    targetId: String,
    outcome: String,
    requestFingerprint: String,
    resultPayload: String,
    at: Date
  ) throws {
    try database.execute(
      sql: """
        INSERT INTO operations_idempotency_records
          (environment, idempotency_key, action, target_type, target_id, outcome,
           request_fingerprint, result_payload, created_at, expires_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
      arguments: [
        environment, key, String(action.prefix(128)), String(targetType.prefix(64)), targetId,
        outcome, requestFingerprint, resultPayload, iso(at), iso(at.addingTimeInterval(365 * 86_400)),
      ])
  }

  private static func encodeIdempotencyResult<T: Encodable>(_ result: T) throws -> String {
    let data = try JSONEncoder().encode(result)
    guard let payload = String(data: data, encoding: .utf8) else {
      throw OperationsStoreError.jsonEncoding
    }
    return payload
  }

  private static func replayIdempotencyResult<T: Decodable>(
    _ stored: StoredIdempotencyResult,
    as type: T.Type
  ) throws -> T {
    guard let data = stored.resultPayload.data(using: .utf8),
      let result = try? JSONDecoder().decode(type, from: data)
    else { throw OperationsStoreError.idempotencyConflict }
    return result
  }

  private static func insertAudit(
    database: Database,
    environment: String,
    operatorDid: String,
    action: String,
    targetType: String,
    targetId: String?,
    idempotencyKey: String?,
    requestId: String? = nil,
    expectedVersion: Int? = nil,
    note: String?,
    before: [String: String],
    after: [String: String],
    outcome: String,
    at: Date
  ) throws {
    let beforeJSON = String(data: try JSONEncoder().encode(before), encoding: .utf8) ?? "{}"
    let afterJSON = String(data: try JSONEncoder().encode(after), encoding: .utf8) ?? "{}"
    try database.execute(
      sql: """
        INSERT INTO operations_audit_events
          (environment, id, operator_did, action, target_type, target_id, idempotency_key,
           request_id, expected_version, note, before_state, after_state, outcome, occurred_at, expires_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
      arguments: [
        environment, UUID().uuidString.lowercased(), operatorDid, String(action.prefix(128)),
        String(targetType.prefix(64)), targetId, idempotencyKey,
        requestId.map { String($0.prefix(128)) }, expectedVersion,
        note.map { String($0.prefix(280)) }, beforeJSON, afterJSON, String(outcome.prefix(32)),
        iso(at), iso(at.addingTimeInterval(365 * 86_400)),
      ])
  }

  private static func extendLifecycleRetention(
    database: Database,
    environment: String,
    targetType: String,
    targetId: String,
    terminalAt: Date
  ) throws {
    let expiry = iso(terminalAt.addingTimeInterval(365 * 86_400))
    try database.execute(
      sql: """
        UPDATE operations_audit_events SET expires_at = ?
        WHERE environment = ? AND target_type = ? AND target_id = ?
        """, arguments: [expiry, environment, targetType, targetId])
    try database.execute(
      sql: """
        UPDATE operations_idempotency_records SET expires_at = ?
        WHERE environment = ? AND target_type = ? AND target_id = ?
        """, arguments: [expiry, environment, targetType, targetId])
  }

  private static func insertTelemetry(
    _ signal: OperationsTelemetrySignal,
    environment: String,
    database: Database
  ) throws {
    switch signal {
    case .metric(let sample):
      if let sampleEnvironment = sample.dimensions["environment"], sampleEnvironment != environment {
        throw OperationsStoreError.environmentMismatch(
          expected: environment, actual: sampleEnvironment)
      }
      let dimensions = OperationsRedactor.boundedAttributes(sample.dimensions)
      let dimensionsJSON = try jsonString(dimensions)
      let dimensionsKey = dimensions.sorted { $0.key < $1.key }
        .map { "\($0.key)=\($0.value)" }.joined(separator: "&")
      let dimensionsHash = OperationsRedactor.hashIdentity(dimensionsKey)
      let bucket = Date(
        timeIntervalSince1970: floor(sample.recordedAt.timeIntervalSince1970 / 60) * 60)
      try database.execute(
        sql: """
          INSERT INTO operations_metric_rollups
            (environment, bucket_start, metric_name, dimensions_hash, dimensions, sample_count,
             value_sum, value_min, value_max, histogram_buckets, expires_at)
          VALUES (?, ?, ?, ?, ?, 1, ?, ?, ?, '{}', ?)
          ON CONFLICT (environment, bucket_start, metric_name, dimensions_hash) DO UPDATE SET
            sample_count = sample_count + 1, value_sum = value_sum + excluded.value_sum,
            value_min = MIN(value_min, excluded.value_min), value_max = MAX(value_max, excluded.value_max)
          """,
        arguments: [
          environment, iso(bucket), String(sample.name.prefix(160)), dimensionsHash,
          dimensionsJSON, sample.value, sample.value, sample.value,
          iso(bucket.addingTimeInterval(90 * 86_400)),
        ])
    case .event(let event):
      guard event.environment == environment else {
        throw OperationsStoreError.environmentMismatch(expected: environment, actual: event.environment)
      }
      let attributes = try jsonString(OperationsRedactor.boundedAttributes(event.attributes))
      try database.execute(
        sql: """
          INSERT OR IGNORE INTO operations_events
            (id, service, environment, instance_id, event_name, occurred_at, request_id,
             trace_id, attributes, expires_at)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          """,
        arguments: [
          event.id, event.service, event.environment, event.instanceId,
          String(event.name.prefix(160)), iso(event.occurredAt), event.requestId, event.traceId,
          attributes, iso(event.occurredAt.addingTimeInterval(30 * 86_400)),
        ])
    case .span(let span):
      guard span.environment == environment else {
        throw OperationsStoreError.environmentMismatch(expected: environment, actual: span.environment)
      }
      let attributes = try jsonString(OperationsRedactor.boundedAttributes(span.attributes))
      try database.execute(
        sql: """
          INSERT OR IGNORE INTO operations_trace_spans
            (environment, id, trace_id, parent_span_id, service, name, started_at, duration_ms,
             status, attributes, expires_at)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          """,
        arguments: [
          environment, span.id, span.traceId, span.parentSpanId, span.service, span.name,
          iso(span.startedAt), span.durationMs, span.status, attributes, iso(span.expiresAt),
        ])
    }
  }

  private static func jsonString(_ value: [String: String]) throws -> String {
    String(data: try JSONEncoder().encode(value), encoding: .utf8) ?? "{}"
  }

  private func json<T: Encodable>(_ value: T) throws -> String {
    let data = try encoder.encode(value)
    guard let string = String(data: data, encoding: .utf8) else {
      throw OperationsStoreError.jsonEncoding
    }
    return string
  }

  private static func decode<T: Decodable>(_ type: T.Type, _ string: String) -> T? {
    guard let data = string.data(using: .utf8) else { return nil }
    return try? JSONDecoder().decode(type, from: data)
  }

  private static func iso(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
  }

  private static func date(_ value: String?) -> Date? {
    guard let value else { return nil }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
  }

  private static func streamState(_ row: Row) -> IngestionStreamState? {
    guard
      let state = IngestionConnectionState(rawValue: row["connection_state"]),
      let heartbeatAt = date(row["heartbeat_at"])
    else { return nil }
    let source: String = row["source"]
    let queueObservedAt = date(row["queue_observed_at"])
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
      environment: row["environment"],
      source: source,
      connectionState: state,
      connectedAt: date(row["connected_at"]),
      lastDisconnectAt: date(row["last_disconnect_at"]),
      lastDisconnectReason: row["last_disconnect_reason"],
      lastReceivedCursor: row["last_received_cursor"],
      lastReceivedEventAt: date(row["last_received_event_at"]),
      lastReceivedAt: date(row["last_received_at"]),
      lastCommittedCursor: row["last_committed_cursor"],
      lastCommittedEventAt: date(row["last_committed_event_at"]),
      lastCommittedAt: date(row["last_committed_at"]),
      queueDepth: row["queue_depth"],
      queueCapacity: row["queue_capacity"],
      queueOverflowTotal: row["queue_overflow_total"],
      queueEvidence: queueEvidence,
      transportHeartbeatAt: date(row["transport_heartbeat_at"]),
      lastIndexedMutationAt: date(row["last_indexed_mutation_at"]),
      projectionWatermark: row["projection_watermark"],
      validationWatermark: row["validation_watermark"],
      heartbeatAt: heartbeatAt,
      version: row["version"]
    )
  }

  private static func jetstreamEndpoint(_ row: Row) -> JetstreamEndpointState? {
    guard
      let role = JetstreamEndpointRole(rawValue: row["role"]),
      let state = IngestionConnectionState(rawValue: row["connection_state"]),
      let updatedAt = date(row["updated_at"])
    else { return nil }
    return JetstreamEndpointState(
      id: row["id"], environment: row["environment"], displayName: row["display_name"], host: row["host"], role: role,
      connectionState: state, lastConnectedAt: date(row["last_connected_at"]),
      lastDisconnectedAt: date(row["last_disconnected_at"]), lastError: row["last_error"],
      connectionAttempts: row["connection_attempts"], failoverCount: row["failover_count"],
      updatedAt: updatedAt, version: row["version"]
    )
  }

  private static func command(_ row: Row) -> OperationsWorkerCommand? {
    guard
      let action = OperationsCommandAction(rawValue: row["action"]),
      let status = OperationsCommandStatus(rawValue: row["status"]),
      let createdAt = date(row["created_at"]),
      let updatedAt = date(row["updated_at"])
    else { return nil }
    return OperationsWorkerCommand(
      id: row["id"], environment: row["environment"], action: action, status: status,
      requestedByDid: row["requested_by_did"],
      auditNote: (row["audit_note"] as String?).flatMap { $0.isEmpty ? nil : $0 },
      claimedBy: row["claimed_by"], leaseExpiresAt: date(row["lease_expires_at"]),
      failureReason: row["failure_reason"],
      createdAt: createdAt, updatedAt: updatedAt, completedAt: date(row["completed_at"]),
      version: row["version"]
    )
  }

  private static func gap(_ row: Row) -> IngestionGap? {
    guard
      let status = IngestionGapStatus(rawValue: row["status"]),
      let detectedAt = date(row["detected_at"]),
      let updatedAt = date(row["updated_at"])
    else { return nil }
    let collections: String = row["collections"]
    return IngestionGap(
      id: row["id"], environment: row["environment"], source: row["source"], startCursor: row["start_cursor"],
      endCursor: row["end_cursor"], startTime: date(row["start_time"]),
      endTime: date(row["end_time"]),
      reason: row["reason"], status: status, collections: decode([String].self, collections) ?? [],
      detectedAt: detectedAt, updatedAt: updatedAt, backfillJobId: row["backfill_job_id"],
      discoveredCount: row["discovered_count"], processedCount: row["processed_count"],
      failedCount: row["failed_count"], reconciledCount: row["reconciled_count"],
      version: row["version"]
    )
  }

  private static func backfill(_ row: Row) -> BackfillJob? {
    guard
      let sourceMode = BackfillSourceMode(rawValue: row["source_mode"]),
      let status = BackfillJobStatus(rawValue: row["status"]),
      let createdAt = date(row["created_at"]),
      let updatedAt = date(row["updated_at"])
    else { return nil }
    let collections: String = row["collections"]
    let authorDids: String = row["author_dids"]
    let authorResults: String = row["author_results"]
    return BackfillJob(
      id: row["id"], environment: row["environment"], gapId: row["gap_id"], sourceMode: sourceMode, status: status,
      startCursor: row["start_cursor"], endCursor: row["end_cursor"],
      checkpointCursor: row["checkpoint_cursor"],
      collections: decode([String].self, collections) ?? [],
      authorDids: decode([String].self, authorDids) ?? [],
      authorResults: DefaultEmptyArray(
        wrappedValue: decode([BackfillAuthorResult].self, authorResults) ?? []),
      batchSize: row["batch_size"], rateLimit: row["rate_limit"],
      maxConcurrency: row["max_concurrency"],
      estimatedCount: row["estimated_count"], processedCount: row["processed_count"],
      failedCount: row["failed_count"], reconciledCount: row["reconciled_count"],
      requestedByDid: row["requested_by_did"], auditNote: row["audit_note"],
      failureReason: row["failure_reason"], leaseOwner: row["lease_owner"],
      leaseExpiresAt: date(row["lease_expires_at"]), createdAt: createdAt, updatedAt: updatedAt,
      completedAt: date(row["completed_at"]), version: row["version"],
      verificationStatus: BackfillVerificationStatus(rawValue: row["verification_status"]) ?? .required,
      verificationReason: row["verification_reason"], scopeTruncated: row["scope_truncated"],
      validationWatermark: row["validation_watermark"]
    )
  }

  private static func alert(_ row: Row) -> OperationsAlert? {
    guard
      let status = OperationsAlertStatus(rawValue: row["status"]),
      let openedAt = date(row["opened_at"]),
      let updatedAt = date(row["updated_at"])
    else { return nil }
    let evidence: String = row["evidence"]
    return OperationsAlert(
      id: row["id"], environment: row["environment"], rule: row["rule"],
      conditionKey: row["condition_key"], severity: row["severity"], status: status,
      summary: row["summary"], evidence: decode([String: String].self, evidence) ?? [:],
      runbookSlug: row["runbook_slug"], openedAt: openedAt, updatedAt: updatedAt,
      acknowledgedByDid: row["acknowledged_by_did"], resolvedByDid: row["resolved_by_did"],
      deliveryAttempts: row["delivery_attempts"], lastDeliveryError: row["last_delivery_error"],
      nextDeliveryAt: date(row["next_delivery_at"]),
      deliveryDeadLetteredAt: date(row["delivery_dead_lettered_at"]), version: row["version"]
    )
  }

  private static func span(_ row: Row) -> TraceSpan? {
    guard let startedAt = date(row["started_at"]), let expiresAt = date(row["expires_at"]) else {
      return nil
    }
    let attributes: String = row["attributes"]
    return TraceSpan(
      id: row["id"], environment: row["environment"], traceId: row["trace_id"], parentSpanId: row["parent_span_id"],
      service: row["service"], name: row["name"], startedAt: startedAt,
      durationMs: row["duration_ms"], status: row["status"],
      attributes: decode([String: String].self, attributes) ?? [:], expiresAt: expiresAt
    )
  }

  private static func event(_ row: Row) -> OperationsEvent? {
    guard let occurredAt = date(row["occurred_at"]) else { return nil }
    let attributes: String = row["attributes"]
    return OperationsEvent(
      id: row["id"],
      service: row["service"],
      environment: row["environment"],
      instanceId: row["instance_id"],
      name: row["event_name"],
      occurredAt: occurredAt,
      requestId: row["request_id"],
      traceId: row["trace_id"],
      attributes: decode([String: String].self, attributes) ?? [:]
    )
  }
}

private enum Schema {
  static let sqlite = """
    CREATE TABLE IF NOT EXISTS operations_service_state (
      service TEXT NOT NULL, environment TEXT NOT NULL, instance_id TEXT NOT NULL,
      liveness TEXT NOT NULL CHECK (liveness IN ('healthy', 'degraded', 'unhealthy', 'unknown')),
      readiness TEXT NOT NULL CHECK (readiness IN ('healthy', 'degraded', 'unhealthy', 'unknown')),
      freshness TEXT NOT NULL CHECK (freshness IN ('healthy', 'degraded', 'unhealthy', 'unknown')),
      completeness TEXT NOT NULL CHECK (completeness IN ('healthy', 'degraded', 'unhealthy', 'unknown')),
      dependency_state TEXT NOT NULL DEFAULT '{}', version TEXT, started_at TEXT NOT NULL, heartbeat_at TEXT NOT NULL,
      PRIMARY KEY (service, environment, instance_id)
    );
    CREATE TABLE IF NOT EXISTS operations_trace_spans (
      environment TEXT NOT NULL, id TEXT NOT NULL, trace_id TEXT NOT NULL, parent_span_id TEXT, service TEXT NOT NULL,
      name TEXT NOT NULL, started_at TEXT NOT NULL, duration_ms REAL NOT NULL, status TEXT NOT NULL,
      attributes TEXT NOT NULL DEFAULT '{}', expires_at TEXT NOT NULL,
      PRIMARY KEY (environment, id)
    );
    CREATE TABLE IF NOT EXISTS operations_metric_rollups (
      environment TEXT NOT NULL, bucket_start TEXT NOT NULL, metric_name TEXT NOT NULL, dimensions_hash TEXT NOT NULL,
      dimensions TEXT NOT NULL DEFAULT '{}', sample_count INTEGER NOT NULL DEFAULT 0,
      value_sum REAL NOT NULL DEFAULT 0, value_min REAL, value_max REAL,
      histogram_buckets TEXT NOT NULL DEFAULT '{}', expires_at TEXT NOT NULL,
      PRIMARY KEY (environment, bucket_start, metric_name, dimensions_hash)
    );
    CREATE TABLE IF NOT EXISTS operations_events (
      id TEXT NOT NULL, service TEXT NOT NULL, environment TEXT NOT NULL, instance_id TEXT NOT NULL,
      event_name TEXT NOT NULL, occurred_at TEXT NOT NULL, request_id TEXT, trace_id TEXT,
      attributes TEXT NOT NULL DEFAULT '{}', expires_at TEXT NOT NULL,
      PRIMARY KEY (environment, id)
    );
    CREATE TABLE IF NOT EXISTS operations_audit_events (
      environment TEXT NOT NULL, id TEXT NOT NULL, operator_did TEXT NOT NULL, action TEXT NOT NULL,
      target_type TEXT NOT NULL, target_id TEXT, idempotency_key TEXT, request_id TEXT,
      expected_version INTEGER, note TEXT,
      before_state TEXT NOT NULL DEFAULT '{}', after_state TEXT NOT NULL DEFAULT '{}',
      outcome TEXT NOT NULL DEFAULT 'recorded', occurred_at TEXT NOT NULL, expires_at TEXT NOT NULL,
      PRIMARY KEY (environment, id)
    );
    CREATE TABLE IF NOT EXISTS operations_idempotency_records (
      environment TEXT NOT NULL, idempotency_key TEXT NOT NULL, action TEXT NOT NULL,
      target_type TEXT NOT NULL, target_id TEXT, outcome TEXT NOT NULL,
      request_fingerprint TEXT, result_payload TEXT NOT NULL DEFAULT '{}',
      created_at TEXT NOT NULL, expires_at TEXT NOT NULL,
      PRIMARY KEY (environment, idempotency_key)
    );
    CREATE TABLE IF NOT EXISTS operations_change_event_watermarks (
      environment TEXT PRIMARY KEY, latest_cursor INTEGER NOT NULL DEFAULT 0,
      earliest_available_cursor INTEGER NOT NULL DEFAULT 1, updated_at TEXT NOT NULL
    );
    CREATE TABLE IF NOT EXISTS operations_change_events (
      environment TEXT NOT NULL, cursor INTEGER NOT NULL, event_type TEXT NOT NULL,
      entity_type TEXT NOT NULL, entity_id TEXT, payload TEXT NOT NULL DEFAULT '{}',
      occurred_at TEXT NOT NULL, expires_at TEXT NOT NULL,
      PRIMARY KEY (environment, cursor)
    );
    CREATE TABLE IF NOT EXISTS appview_ingestion_stream_state (
      environment TEXT NOT NULL, source TEXT NOT NULL,
      connection_state TEXT NOT NULL DEFAULT 'unknown'
        CHECK (connection_state IN ('connected', 'disconnected', 'reconnecting', 'unknown')),
      connected_at TEXT,
      last_disconnect_at TEXT, last_disconnect_reason TEXT, last_received_cursor INTEGER,
      last_received_event_at TEXT, last_received_at TEXT, last_committed_cursor INTEGER,
      last_committed_event_at TEXT, last_committed_at TEXT, queue_depth INTEGER NOT NULL DEFAULT 0,
      queue_capacity INTEGER, queue_overflow_total INTEGER, queue_observed_at TEXT,
      transport_heartbeat_at TEXT, last_indexed_mutation_at TEXT,
      projection_watermark TEXT, validation_watermark TEXT,
      heartbeat_at TEXT NOT NULL, version INTEGER NOT NULL DEFAULT 0 CHECK (version >= 0),
      CHECK (queue_depth >= 0), CHECK (queue_capacity IS NULL OR queue_capacity > 0),
      CHECK (queue_overflow_total IS NULL OR queue_overflow_total >= 0),
      PRIMARY KEY (environment, source)
    );
    CREATE TABLE IF NOT EXISTS appview_jetstream_endpoints (
      environment TEXT NOT NULL, id TEXT NOT NULL, display_name TEXT NOT NULL, host TEXT NOT NULL,
      role TEXT NOT NULL CHECK (role IN ('active', 'standby')),
      connection_state TEXT NOT NULL DEFAULT 'unknown'
        CHECK (connection_state IN ('connected', 'disconnected', 'reconnecting', 'unknown')),
      last_connected_at TEXT,
      last_disconnected_at TEXT, last_error TEXT, connection_attempts INTEGER NOT NULL DEFAULT 0,
      failover_count INTEGER NOT NULL DEFAULT 0, updated_at TEXT NOT NULL,
      version INTEGER NOT NULL DEFAULT 0 CHECK (version >= 0),
      CHECK (connection_attempts >= 0), CHECK (failover_count >= 0),
      PRIMARY KEY (environment, id)
    );
    CREATE TABLE IF NOT EXISTS operations_commands (
      environment TEXT NOT NULL, id TEXT NOT NULL,
      action TEXT NOT NULL CHECK (action = 'reconnect_jetstream'),
      status TEXT NOT NULL CHECK (status IN ('queued', 'running', 'completed', 'failed')),
      requested_by_did TEXT NOT NULL, audit_note TEXT, claimed_by TEXT,
      lease_expires_at TEXT, failure_reason TEXT, created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL, completed_at TEXT,
      expires_at TEXT,
      version INTEGER NOT NULL DEFAULT 0 CHECK (version >= 0),
      CHECK (status != 'running' OR (claimed_by IS NOT NULL AND lease_expires_at IS NOT NULL)),
      PRIMARY KEY (environment, id)
    );
    CREATE TABLE IF NOT EXISTS appview_ingestion_gaps (
      environment TEXT NOT NULL, id TEXT NOT NULL, source TEXT NOT NULL, start_cursor INTEGER, end_cursor INTEGER,
      start_time TEXT, end_time TEXT, reason TEXT NOT NULL,
      status TEXT NOT NULL CHECK (status IN ('suspected', 'confirmed', 'backfill_queued',
        'backfilling', 'verification_required', 'resolved', 'ignored')),
      collections TEXT NOT NULL DEFAULT '[]', detected_at TEXT NOT NULL, updated_at TEXT NOT NULL,
      backfill_job_id TEXT, discovered_count INTEGER NOT NULL DEFAULT 0,
      processed_count INTEGER NOT NULL DEFAULT 0, failed_count INTEGER NOT NULL DEFAULT 0,
      reconciled_count INTEGER NOT NULL DEFAULT 0, expires_at TEXT,
      version INTEGER NOT NULL DEFAULT 0 CHECK (version >= 0),
      CHECK (start_cursor IS NULL OR end_cursor IS NULL OR start_cursor < end_cursor),
      CHECK (discovered_count >= 0 AND processed_count >= 0 AND failed_count >= 0
        AND reconciled_count >= 0 AND failed_count <= processed_count
        AND reconciled_count <= processed_count),
      PRIMARY KEY (environment, id)
    );
    CREATE TABLE IF NOT EXISTS appview_backfill_jobs (
      environment TEXT NOT NULL, id TEXT NOT NULL, gap_id TEXT,
      source_mode TEXT NOT NULL CHECK (source_mode IN
        ('tap_verified_resync', 'jetstream_replay', 'pds_reconciliation')),
      status TEXT NOT NULL CHECK (status IN ('queued', 'running', 'paused', 'completed', 'failed', 'cancelled')),
      start_cursor INTEGER, end_cursor INTEGER, checkpoint_cursor INTEGER,
      collections TEXT NOT NULL DEFAULT '[]', author_dids TEXT NOT NULL DEFAULT '[]',
      author_results TEXT NOT NULL DEFAULT '[]',
      batch_size INTEGER NOT NULL, rate_limit INTEGER NOT NULL, max_concurrency INTEGER NOT NULL,
      estimated_count INTEGER NOT NULL DEFAULT 0, processed_count INTEGER NOT NULL DEFAULT 0,
      failed_count INTEGER NOT NULL DEFAULT 0, reconciled_count INTEGER NOT NULL DEFAULT 0,
      requested_by_did TEXT NOT NULL, audit_note TEXT, failure_reason TEXT, idempotency_key TEXT,
      verification_status TEXT NOT NULL DEFAULT 'required'
        CHECK (verification_status IN ('pending', 'required', 'verified', 'failed')),
      verification_reason TEXT,
      scope_truncated INTEGER NOT NULL DEFAULT 0, validation_watermark TEXT,
      request_fingerprint TEXT, request_fingerprint_expires_at TEXT, normalized_request_hash TEXT,
      lease_owner TEXT, lease_expires_at TEXT,
      created_at TEXT NOT NULL, updated_at TEXT NOT NULL, completed_at TEXT, expires_at TEXT,
      version INTEGER NOT NULL DEFAULT 0 CHECK (version >= 0),
      CHECK (batch_size BETWEEN 1 AND 10000 AND rate_limit BETWEEN 1 AND 5000
        AND max_concurrency BETWEEN 1 AND 16),
      CHECK (source_mode = 'pds_reconciliation' OR max_concurrency = 1),
      CHECK (source_mode != 'jetstream_replay' OR
        (start_cursor IS NOT NULL AND end_cursor IS NOT NULL AND start_cursor < end_cursor)),
      CHECK (start_cursor IS NULL OR end_cursor IS NULL OR start_cursor < end_cursor),
      CHECK (checkpoint_cursor IS NULL OR
        ((start_cursor IS NULL OR checkpoint_cursor >= start_cursor)
          AND (end_cursor IS NULL OR checkpoint_cursor <= end_cursor))),
      CHECK (estimated_count >= 0 AND processed_count >= 0 AND failed_count >= 0
        AND reconciled_count >= 0 AND failed_count <= processed_count
        AND reconciled_count <= processed_count),
      PRIMARY KEY (environment, id)
    );
    CREATE TABLE IF NOT EXISTS appview_recovery_failures (
      environment TEXT NOT NULL, id TEXT NOT NULL, job_id TEXT, source TEXT NOT NULL, record_identifier_hash TEXT NOT NULL,
      collection TEXT, operation TEXT, cursor INTEGER, error_type TEXT NOT NULL,
      retry_count INTEGER NOT NULL DEFAULT 0, first_failed_at TEXT NOT NULL, last_failed_at TEXT NOT NULL,
      resolved_at TEXT, expires_at TEXT NOT NULL, CHECK (retry_count >= 0),
      PRIMARY KEY (environment, id)
    );
    CREATE TABLE IF NOT EXISTS operations_alerts (
      environment TEXT NOT NULL, id TEXT NOT NULL, rule TEXT NOT NULL, condition_key TEXT NOT NULL,
      severity TEXT NOT NULL,
      status TEXT NOT NULL CHECK (status IN ('open', 'acknowledged', 'resolved')),
      summary TEXT NOT NULL, evidence TEXT NOT NULL DEFAULT '{}', runbook_slug TEXT NOT NULL,
      opened_at TEXT NOT NULL, updated_at TEXT NOT NULL, acknowledged_by_did TEXT,
      resolved_by_did TEXT, delivery_attempts INTEGER NOT NULL DEFAULT 0, last_delivery_error TEXT,
      next_delivery_at TEXT, delivery_dead_lettered_at TEXT, expires_at TEXT,
      version INTEGER NOT NULL DEFAULT 0 CHECK (version >= 0),
      CHECK (delivery_attempts >= 0), PRIMARY KEY (environment, id)
    );
    """

  static let indexes = """
    CREATE UNIQUE INDEX IF NOT EXISTS idx_ingestion_stream_environment_source
      ON appview_ingestion_stream_state (environment, source);
    CREATE UNIQUE INDEX IF NOT EXISTS idx_jetstream_endpoint_environment_id
      ON appview_jetstream_endpoints (environment, id);
    CREATE UNIQUE INDEX IF NOT EXISTS idx_metric_rollup_environment_key
      ON operations_metric_rollups (environment, bucket_start, metric_name, dimensions_hash);
    CREATE INDEX IF NOT EXISTS idx_operations_trace_spans_trace
      ON operations_trace_spans (environment, trace_id, started_at);
    CREATE INDEX IF NOT EXISTS idx_operations_commands_claim
      ON operations_commands (environment, action, status, created_at);
    DROP INDEX IF EXISTS idx_operations_commands_one_active_action;
    CREATE UNIQUE INDEX IF NOT EXISTS idx_operations_commands_one_active_action_env
      ON operations_commands (environment, action) WHERE status IN ('queued', 'running');
    CREATE INDEX IF NOT EXISTS idx_operations_active_gaps
      ON appview_ingestion_gaps (environment, detected_at DESC, id DESC)
      WHERE status NOT IN ('resolved', 'ignored');
    CREATE INDEX IF NOT EXISTS idx_operations_active_backfills
      ON appview_backfill_jobs (environment, created_at DESC, id DESC)
      WHERE status IN ('queued', 'running', 'paused');
    DROP INDEX IF EXISTS idx_operations_audit_idempotency;
    CREATE INDEX IF NOT EXISTS idx_operations_idempotency_expiry
      ON operations_idempotency_records (environment, expires_at);
    CREATE INDEX IF NOT EXISTS idx_operations_change_events_replay
      ON operations_change_events (environment, cursor);
    CREATE INDEX IF NOT EXISTS idx_operations_change_events_expiry
      ON operations_change_events (environment, expires_at, cursor);
    DROP INDEX IF EXISTS idx_operations_alert_open_rule;
    CREATE UNIQUE INDEX IF NOT EXISTS idx_operations_alert_open_condition
      ON operations_alerts (environment, condition_key) WHERE status != 'resolved';
    """
}
