import Foundation
import Logging
import OperationsCore

/// Consumes Jetstream commits in receive order and advances the durable cursor only after indexing succeeds.
actor FirehoseSubscriber {
  private static let reconnectProgressTimeout: TimeInterval = 30

  private var endpointPool: JetstreamEndpointPool
  private var endpointStates: [String: JetstreamEndpointState]
  private let indexer: ThinAppViewIndexer
  private let operationsStore: (any OperationsStore)?
  private let telemetry: OperationsTelemetryBuffer?
  private let environment: String
  private let instanceId: String
  private let replayRewindMicroseconds: Int64
  private let logger: Logger
  private var suspectedGapEndCursor: Int64?
  private var pendingReconnectCommand: OperationsWorkerCommand?
  private var pendingReconnectProgress: JetstreamReconnectProgressGate?
  private var pendingReconnectTimeoutTask: Task<Void, Never>?
  private var pendingReconnectFailures = 0
  private var queueDepth = 0
  private var queueCapacity = 4_096
  private var queueDropped: Int64 = 0
  private var lastQueueMetricAt = Date.distantPast

  init(
    relayURLs: [String],
    indexer: ThinAppViewIndexer,
    operationsStore: (any OperationsStore)?,
    telemetry: OperationsTelemetryBuffer?,
    environment: String,
    instanceId: String,
    replayRewindMicroseconds: Int64,
    logger: Logger
  ) {
    let pool = JetstreamEndpointPool(urls: relayURLs)
    self.endpointPool = pool
    self.endpointStates = Dictionary(
      uniqueKeysWithValues: pool.endpoints.enumerated().map { index, endpoint in
        (
          endpoint.id,
          JetstreamEndpointState(
            id: endpoint.id,
            environment: environment,
            displayName: endpoint.displayName,
            host: endpoint.host,
            role: index == 0 ? .active : .standby,
            connectionState: .unknown,
            updatedAt: Date()
          )
        )
      }
    )
    self.indexer = indexer
    self.operationsStore = operationsStore
    self.telemetry = telemetry
    self.environment = environment
    self.instanceId = instanceId
    self.replayRewindMicroseconds = replayRewindMicroseconds
    self.logger = logger
  }

  func runForever() async {
    while !Task.isCancelled {
      do {
        try await consumeOnce()
      } catch let request as ManualJetstreamReconnectRequest {
        await beginPendingReconnect(request.command, at: Date())
      } catch {
        let now = Date()
        await markActiveEndpointDisconnected(error: error, at: now)
        await failReconnectCommandIfAllEndpointsFailed(error: error, at: now)
        try? await operationsStore?.markStreamDisconnected(
          source: "jetstream",
          reason: OperationsRedactor.errorCategory(error),
          at: now
        )
        await emitEvent("jetstream.disconnected", attributes: ["error_type": OperationsRedactor.errorCategory(error)])
        await recordDisconnectGap(reason: error, at: now)
        logger.warning(
          "Firehose disconnected; failing over from durable cursor",
          metadata: [
            "error_type": .string(OperationsRedactor.errorCategory(error)),
            "next_endpoint": .string(endpointPool.active.host),
          ]
        )
        try? await Task.sleep(for: .seconds(3))
      }
    }
  }

  private func consumeOnce() async throws {
    let endpoint = endpointPool.active
    await beginConnectionAttempt(endpoint: endpoint, at: Date())
    let streamState = try await operationsStore?.fetchStreamState(source: "jetstream")
    if let gaps = try await operationsStore?.listGaps(limit: 250) {
      suspectedGapEndCursor = gaps
        .filter { $0.source == "jetstream" && $0.status == .suspected }
        .compactMap(\.endCursor)
        .max()
    }
    let cursor = JetstreamCursor.resumeCursor(
      committed: streamState?.lastCommittedCursor,
      seededReceived: streamState?.lastReceivedCursor,
      rewindMicroseconds: replayRewindMicroseconds
    )
    let url = try JetstreamCursor.url(endpoint.url, cursor: cursor)

    let logger = self.logger
    let workerId = instanceId
    let result = try await withThrowingTaskGroup(of: FirehoseCycleResult.self) { group in
      group.addTask {
        #if canImport(WebSocketKit)
        try await FirehoseLinuxWebSocket.consume(
          relayURL: url,
          logger: logger,
          onConnected: { await self.didConnect(endpointId: endpoint.id, at: Date()) },
          onHeartbeat: { await self.didReceiveTransportHeartbeat(at: Date()) },
          onQueueObservation: { await self.observeQueue($0) }
        ) { text in
          try await self.handleMessage(text)
        }
        #else
        try await FirehoseSubscriberURLSessionTransport.consume(
          relayURL: url,
          logger: logger,
          isCancelled: { Task.isCancelled },
          onConnected: { await self.didConnect(endpointId: endpoint.id, at: Date()) },
          onHeartbeat: { await self.didReceiveTransportHeartbeat(at: Date()) },
          onQueueObservation: { await self.observeQueue($0) }
        ) { text in
          try await self.handleMessage(text)
        }
        #endif
        return .streamEnded
      }
      if let operationsStore, pendingReconnectCommand == nil {
        group.addTask {
          while !Task.isCancelled {
            if let command = try await operationsStore.claimNextCommand(
              action: .reconnectJetstream,
              workerId: workerId,
              at: Date()
            ) {
              return .reconnect(command)
            }
            try await Task.sleep(for: .seconds(1))
          }
          return .streamEnded
        }
      }
      guard let first = try await group.next() else { return FirehoseCycleResult.streamEnded }
      group.cancelAll()
      return first
    }

    switch result {
    case .streamEnded:
      throw FirehoseConnectionClosedError()
    case .reconnect(let command):
      throw ManualJetstreamReconnectRequest(command: command)
    }
  }

  private func beginConnectionAttempt(endpoint: JetstreamEndpoint, at: Date) async {
    pendingReconnectTimeoutTask?.cancel()
    pendingReconnectTimeoutTask = nil
    pendingReconnectProgress?.beginConnectionAttempt()
    for configured in endpointPool.endpoints {
      let previous = endpointStates[configured.id]
      endpointStates[configured.id] = JetstreamEndpointState(
        id: configured.id,
        environment: environment,
        displayName: configured.displayName,
        host: configured.host,
        role: configured.id == endpoint.id ? .active : .standby,
        connectionState: configured.id == endpoint.id ? .reconnecting : (previous?.connectionState ?? .unknown),
        lastConnectedAt: previous?.lastConnectedAt,
        lastDisconnectedAt: previous?.lastDisconnectedAt,
        lastError: previous?.lastError,
        connectionAttempts: (previous?.connectionAttempts ?? 0) + (configured.id == endpoint.id ? 1 : 0),
        failoverCount: previous?.failoverCount ?? 0,
        updatedAt: at
      )
    }
    await persistEndpointStates()
  }

  private func didConnect(endpointId: String, at: Date) async {
    guard endpointPool.active.id == endpointId, let previous = endpointStates[endpointId] else { return }
    endpointStates[endpointId] = JetstreamEndpointState(
      id: previous.id, environment: environment,
      displayName: previous.displayName, host: previous.host, role: .active,
      connectionState: .connected, lastConnectedAt: at,
      lastDisconnectedAt: previous.lastDisconnectedAt, lastError: nil,
      connectionAttempts: previous.connectionAttempts, failoverCount: previous.failoverCount,
      updatedAt: at
    )
    try? await operationsStore?.markStreamConnected(source: "jetstream", at: at)
    await persistEndpointStates()
    await emitEvent("jetstream.connected", attributes: ["endpoint": previous.host])
    pendingReconnectProgress?.didConnect(at: at)
    schedulePendingReconnectProgressTimeout(connectedAt: at)
  }

  private func didReceiveTransportHeartbeat(at: Date) async {
    try? await operationsStore?.markStreamTransportHeartbeat(source: "jetstream", at: at)
  }

  private func markActiveEndpointDisconnected(error: Error, at: Date) async {
    let endpoint = endpointPool.active
    let previous = endpointStates[endpoint.id]
    endpointStates[endpoint.id] = JetstreamEndpointState(
      id: endpoint.id, environment: environment,
      displayName: endpoint.displayName, host: endpoint.host, role: .standby,
      connectionState: .disconnected, lastConnectedAt: previous?.lastConnectedAt,
      lastDisconnectedAt: at, lastError: OperationsRedactor.errorCategory(error),
      connectionAttempts: previous?.connectionAttempts ?? 0,
      failoverCount: (previous?.failoverCount ?? 0) + (endpointPool.endpoints.count > 1 ? 1 : 0),
      updatedAt: at
    )
    _ = endpointPool.rotateAfterFailure()
    await persistEndpointStates()
  }

  private func failReconnectCommandIfAllEndpointsFailed(error: Error, at: Date) async {
    guard let command = pendingReconnectCommand else { return }
    pendingReconnectFailures += 1
    guard pendingReconnectFailures >= endpointPool.endpoints.count else { return }
    let failure = "all_jetstream_endpoints_unavailable"
    if let operationsStore {
      do {
        _ = try await operationsStore.completeCommand(
          id: command.id, status: .failed, failureReason: failure, workerId: instanceId,
          expectedVersion: command.version, requestId: reconnectRequestId(command),
          note: "Reconnect failed after every configured Jetstream endpoint returned \(OperationsRedactor.errorCategory(error)).",
          at: at)
      } catch {
        logger.warning("Rejected stale reconnect failure completion", metadata: [
          "command_id": .string(command.id),
          "error_type": .string(OperationsRedactor.errorCategory(error)),
        ])
      }
    }
    pendingReconnectCommand = nil
    pendingReconnectProgress = nil
    pendingReconnectTimeoutTask?.cancel()
    pendingReconnectTimeoutTask = nil
    pendingReconnectFailures = 0
  }

  private func persistEndpointStates() async {
    guard let operationsStore else { return }
    for state in endpointStates.values {
      try? await operationsStore.upsertJetstreamEndpoint(state)
    }
  }

  private func beginPendingReconnect(_ command: OperationsWorkerCommand, at: Date) async {
    guard let operationsStore else { return }
    do {
      let state = try await operationsStore.fetchStreamState(source: "jetstream")
      pendingReconnectCommand = command
      pendingReconnectProgress = JetstreamReconnectProgressGate(state: state)
      pendingReconnectTimeoutTask?.cancel()
      pendingReconnectTimeoutTask = nil
      pendingReconnectFailures = 0
      logger.notice(
        "Operator requested Jetstream reconnect",
        metadata: ["command_id": .string(command.id)]
      )
    } catch {
      let failure = "reconnect_baseline_unavailable"
      do {
        _ = try await operationsStore.completeCommand(
          id: command.id, status: .failed, failureReason: failure, workerId: instanceId,
          expectedVersion: command.version, requestId: reconnectRequestId(command),
          note: "Reconnect could not capture a durable pre-connection cursor baseline.", at: at)
      } catch {
        logger.warning("Rejected stale reconnect baseline failure completion", metadata: [
          "command_id": .string(command.id),
          "error_type": .string(OperationsRedactor.errorCategory(error)),
        ])
      }
    }
  }

  private func completePendingReconnectAfterProgress(cursor: Int64, at: Date) async {
    guard let command = pendingReconnectCommand,
      let progress = pendingReconnectProgress,
      progress.permitsCompletion(receivedCursor: cursor, committedCursor: cursor),
      let operationsStore
    else { return }

    do {
      try await assessPostReconnectGap(at: at, store: operationsStore)
      _ = try await operationsStore.completeCommand(
        id: command.id, status: .completed, failureReason: nil, workerId: instanceId,
        expectedVersion: command.version, requestId: reconnectRequestId(command),
        note: "Jetstream reconnected, committed a post-handshake cursor, and completed gap assessment.",
        at: at)
      pendingReconnectCommand = nil
      pendingReconnectProgress = nil
      pendingReconnectTimeoutTask?.cancel()
      pendingReconnectTimeoutTask = nil
      pendingReconnectFailures = 0
    } catch {
      logger.error(
        "Reconnect made cursor progress but could not complete gap assessment",
        metadata: [
          "command_id": .string(command.id),
          "error_type": .string(OperationsRedactor.errorCategory(error)),
        ]
      )
      await emitEvent(
        "jetstream.reconnect_assessment_failed",
        attributes: ["error_type": OperationsRedactor.errorCategory(error)]
      )
    }
  }

  private func schedulePendingReconnectProgressTimeout(connectedAt: Date) {
    guard let command = pendingReconnectCommand else { return }
    pendingReconnectTimeoutTask?.cancel()
    pendingReconnectTimeoutTask = Task { [weak self] in
      do {
        try await Task.sleep(for: .seconds(Self.reconnectProgressTimeout))
      } catch {
        return
      }
      await self?.failPendingReconnectForNoProgress(
        commandId: command.id,
        connectedAt: connectedAt,
        at: Date()
      )
    }
  }

  private func failPendingReconnectForNoProgress(
    commandId: String,
    connectedAt: Date,
    at: Date
  ) async {
    guard let command = pendingReconnectCommand, command.id == commandId,
      pendingReconnectProgress?.connectedAt == connectedAt,
      let operationsStore
    else { return }
    let failure = "post_reconnect_cursor_progress_timeout"
    do {
      _ = try await operationsStore.completeCommand(
        id: commandId,
        status: .failed,
        failureReason: failure,
        workerId: instanceId,
        expectedVersion: command.version,
        requestId: reconnectRequestId(command),
        note: "Reconnect established transport but observed no durable cursor progress within the bounded window.",
        at: at)
    } catch {
      logger.warning("Rejected stale reconnect timeout completion", metadata: [
        "command_id": .string(command.id),
        "error_type": .string(OperationsRedactor.errorCategory(error)),
      ])
    }
    await emitEvent("jetstream.reconnect_progress_timeout")
    pendingReconnectCommand = nil
    pendingReconnectProgress = nil
    pendingReconnectTimeoutTask?.cancel()
    pendingReconnectTimeoutTask = nil
    pendingReconnectFailures = 0
  }

  private func reconnectRequestId(_ command: OperationsWorkerCommand) -> String {
    "reconnect:\(command.id):\(command.version)"
  }

  private func assessPostReconnectGap(
    at: Date,
    store: any OperationsStore
  ) async throws {
    guard let state = try await store.fetchStreamState(source: "jetstream") else {
      throw JetstreamReconnectAssessmentError.streamStateUnavailable
    }
    guard let candidate = JetstreamGapDetector.postReconnectCandidate(state: state) else { return }
    let existingGaps = try await store.listGaps(limit: 250)
    guard !existingGaps.contains(where: { candidate.isCovered(by: $0) }) else { return }
    let gap = try await store.createGap(
      source: "jetstream",
      startCursor: candidate.startCursor,
      endCursor: candidate.endCursor,
      reason: candidate.reason,
      collections: [],
      detectedAt: at
    )
    suspectedGapEndCursor = max(suspectedGapEndCursor ?? gap.endCursor ?? 0, gap.endCursor ?? 0)
  }

  func handleMessage(_ text: String) async throws {
    guard
      let data = text.data(using: .utf8),
      let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      (json["kind"] as? String) == "commit",
      let cursor = JetstreamCursor.parse(json["time_us"]),
      let did = json["did"] as? String,
      let commit = json["commit"] as? [String: Any],
      let collection = commit["collection"] as? String,
      let rkey = commit["rkey"] as? String,
      let operation = commit["operation"] as? String
    else { return }

    let now = Date()
    let startedAt = now
    let eventTime = Date(timeIntervalSince1970: Double(cursor) / 1_000_000)
    try await operationsStore?.markStreamReceived(
      source: "jetstream",
      cursor: cursor,
      eventAt: eventTime,
      receivedAt: now,
      queueDepth: queueDepth
    )

    let cid = (commit["cid"] as? String) ?? ""
    let recordObject = commit["record"] ?? [:]
    let recordJSON = (try? JSONSerialization.data(withJSONObject: recordObject)) ?? Data("{}".utf8)

    do {
      let indexingOutcome = try await indexer.handleCommitWithOutcome(
        repoDid: did,
        collection: collection,
        rkey: rkey,
        cid: cid,
        recordJSON: recordJSON,
        operation: operation,
        ingestionSource: "jetstream",
        cursor: String(cursor),
        eventTime: eventTime
      )
      try await operationsStore?.markStreamCommitted(
        source: "jetstream",
        cursor: cursor,
        eventAt: eventTime,
        committedAt: Date(),
        queueDepth: queueDepth
      )
      if indexingOutcome.didMutateProjection {
        try? await operationsStore?.markStreamIndexedMutation(source: "jetstream", at: Date())
        try? await operationsStore?.markStreamProjectionWatermark(
          source: "jetstream",
          watermark: "cursor:\(cursor)",
          at: Date()
        )
      }
      await confirmSuspectedGapsAfterProgress(through: cursor, at: Date())
      await completePendingReconnectAfterProgress(cursor: cursor, at: Date())
      let duration = Date().timeIntervalSince(startedAt)
      let indexingResult = indexingOutcome.didMutateProjection ? "indexed" : "skipped"
      if indexingOutcome.didMutateProjection {
        await emitMetric("socialwire.ingestion.events_total", value: 1, dimensions: ["collection": collection, "operation": operation, "ingestion_mode": "live"])
        await emitMetric("socialwire.ingestion.db_write_duration_seconds", value: duration, dimensions: ["collection": collection, "operation": operation, "ingestion_mode": "live"])
      }
      await emitMetric("socialwire.ingestion.processed_events_total", value: 1, dimensions: ["collection": collection, "operation": operation, "ingestion_mode": "live", "indexing_result": indexingResult])
      await emitMetric("socialwire.ingestion.results_total", value: 1, dimensions: ["collection": collection, "operation": operation, "result": "success", "ingestion_mode": "live", "indexing_result": indexingResult])
      await emitMetric("socialwire.ingestion.commit_lag_seconds", value: Date().timeIntervalSince(eventTime), dimensions: ["collection": collection, "ingestion_mode": "live"])
      await emitEvent("commit.committed", attributes: ["collection": collection, "operation": operation, "indexing_result": indexingResult])
      if Int.random(in: 0..<100) < 5 { await emitSpan(startedAt: startedAt, duration: duration, status: "ok", collection: collection, operation: operation) }
    } catch {
      try? await operationsStore?.recordRecoveryFailure(
        jobId: nil,
        identityHash: OperationsRedactor.hashIdentity("(did)/(collection)/(rkey)"),
        collection: collection,
        operation: operation,
        cursor: cursor,
        errorCategory: OperationsRedactor.errorCategory(error),
        at: Date()
      )
      let duration = Date().timeIntervalSince(startedAt)
      await emitMetric("socialwire.ingestion.results_total", value: 1, dimensions: ["collection": collection, "operation": operation, "result": "error", "error_type": OperationsRedactor.errorCategory(error), "ingestion_mode": "live"])
      await emitEvent("commit.failed", attributes: ["collection": collection, "operation": operation, "error_type": OperationsRedactor.errorCategory(error)])
      await emitSpan(startedAt: startedAt, duration: duration, status: "error", collection: collection, operation: operation)
      await recordCommitFailureGap(collection: collection, cursor: cursor, at: Date())
      throw error
    }
  }

  private func emitMetric(_ name: String, value: Double, dimensions: [String: String]) async {
    var bounded = dimensions
    if let collection = bounded["collection"] { bounded["collection"] = Self.collectionDimension(collection) }
    _ = await telemetry?.enqueue(.metric(.init(name: name, value: value, dimensions: bounded)))
  }

  private func observeQueue(_ observation: BoundedQueueObservation) async {
    let previousDropped = queueDropped
    queueDepth = observation.depth
    queueCapacity = observation.capacity
    queueDropped = observation.dropped
    let now = Date()
    guard
      queueDropped > previousDropped
        || now.timeIntervalSince(lastQueueMetricAt) >= 1
    else { return }
    lastQueueMetricAt = now
    try? await operationsStore?.recordStreamQueueObservation(
      source: "jetstream",
      depth: queueDepth,
      capacity: queueCapacity,
      overflowTotal: queueDropped,
      observedAt: now
    )
    await emitMetric(
      "socialwire.ingestion.queue_depth",
      value: Double(queueDepth),
      dimensions: ["ingestion_source": "jetstream"]
    )
    await emitMetric(
      "socialwire.ingestion.queue_capacity",
      value: Double(queueCapacity),
      dimensions: ["ingestion_source": "jetstream"]
    )
    if queueDropped > previousDropped {
      await emitMetric(
        "socialwire.ingestion.queue_dropped_total",
        value: Double(queueDropped - previousDropped),
        dimensions: ["ingestion_source": "jetstream"]
      )
    }
  }

  private func emitEvent(_ name: String, attributes: [String: String] = [:]) async {
    var bounded = attributes
    if let collection = bounded["collection"] { bounded["collection"] = Self.collectionDimension(collection) }
    _ = await telemetry?.enqueue(.event(.init(service: "appview-worker", environment: environment, instanceId: instanceId, name: name, attributes: bounded)))
  }

  private func emitSpan(startedAt: Date, duration: TimeInterval, status: String, collection: String, operation: String) async {
    let trace = TraceContext(sampled: true)
    _ = await telemetry?.enqueue(.span(.init(
      environment: environment,
      traceId: trace.traceId,
      service: "appview-worker",
      name: "worker.index.commit",
      startedAt: startedAt,
      durationMs: duration * 1_000,
      status: status,
      attributes: ["collection": Self.collectionDimension(collection), "operation": operation, "ingestion_mode": "live"],
      expiresAt: startedAt.addingTimeInterval(status == "error" ? 30 * 86_400 : 7 * 86_400)
    )))
  }

  private static func collectionDimension(_ value: String) -> String {
    let allowlist: Set<String> = [
      "site.standard.document", "site.standard.entry", "site.standard.publication",
      "app.skyreader.feed.subscription", "app.thesocialwire.entryReadState",
    ]
    return allowlist.contains(value) ? value : "other"
  }

  private func recordDisconnectGap(reason: Error, at: Date) async {
    guard let operationsStore else { return }
    guard let state = try? await operationsStore.fetchStreamState(source: "jetstream") else { return }
    guard let candidate = JetstreamGapDetector.candidate(state: state, reason: reason) else { return }
    await recordGap(candidate, collections: [], at: at)
  }

  private func recordCommitFailureGap(collection: String, cursor: Int64, at: Date) async {
    guard let operationsStore,
      let state = try? await operationsStore.fetchStreamState(source: "jetstream"),
      let committed = state.lastCommittedCursor,
      cursor > committed
    else { return }
    await recordGap(
      JetstreamGapCandidate(
        startCursor: committed,
        endCursor: cursor,
        reason: "commit_indexing_failure"
      ),
      collections: [collection],
      at: at
    )
  }

  private func recordGap(
    _ candidate: JetstreamGapCandidate,
    collections: [String],
    at: Date
  ) async {
    guard let operationsStore else { return }
    let existingGaps = (try? await operationsStore.listGaps(limit: 250)) ?? []
    guard !existingGaps.contains(where: { candidate.isCovered(by: $0) }) else { return }
    guard let gap = try? await operationsStore.createGap(
      source: "jetstream",
      startCursor: candidate.startCursor,
      endCursor: candidate.endCursor,
      reason: candidate.reason,
      collections: collections,
      detectedAt: at
    ) else { return }
    suspectedGapEndCursor = max(suspectedGapEndCursor ?? gap.endCursor ?? 0, gap.endCursor ?? 0)
  }

  private func confirmSuspectedGapsAfterProgress(through cursor: Int64, at: Date) async {
    guard let target = suspectedGapEndCursor, cursor >= target, let operationsStore else { return }
    await JetstreamGapProgressAssessment.confirmSuspectedGaps(
      store: operationsStore,
      through: cursor,
      at: at
    )
    suspectedGapEndCursor = nil
  }
}

enum JetstreamGapProgressAssessment {
  /// Transport progress proves that the connection advanced, not that every repository mutation
  /// (especially deletes) was recovered. It may confirm a suspected gap but can never resolve it.
  static func confirmSuspectedGaps(
    store: any OperationsStore,
    through cursor: Int64,
    at: Date
  ) async {
    guard
      let page = try? await store.listGaps(view: .active, limit: 250, before: nil)
    else { return }
    for gap in page.items where
      gap.source == "jetstream"
        && gap.status == .suspected
        && gap.endCursor.map({ $0 <= cursor }) == true
    {
      _ = try? await store.transitionGap(
        id: gap.id,
        to: .confirmed,
        expectedVersion: gap.version,
        operatorDid: "system:worker",
        idempotencyKey: "jetstream-progress:\(gap.id):\(gap.version):confirmed",
        requestId: nil,
        note: "Transport progressed through the suspected range; mutation completeness remains unverified.",
        at: at
      )
    }
  }
}

struct JetstreamGapCandidate: Equatable, Sendable {
  let startCursor: Int64
  let endCursor: Int64
  let reason: String

  func isCovered(by gap: IngestionGap) -> Bool {
    guard gap.source == "jetstream",
      [.suspected, .confirmed, .backfillQueued, .backfilling, .verificationRequired]
        .contains(gap.status),
      let existingStart = gap.startCursor,
      let existingEnd = gap.endCursor
    else { return false }
    return existingStart <= startCursor && existingEnd >= endCursor
  }
}

enum JetstreamGapDetector {
  static func candidate(state: IngestionStreamState, reason: Error) -> JetstreamGapCandidate? {
    guard let committed = state.lastCommittedCursor,
      let received = state.lastReceivedCursor,
      received > committed
    else { return nil }
    return JetstreamGapCandidate(
      startCursor: committed,
      endCursor: received,
      reason: reason is FirehoseQueueOverflowError ? "message_pump_overflow" : "receive_commit_backlog"
    )
  }

  static func postReconnectCandidate(state: IngestionStreamState) -> JetstreamGapCandidate? {
    guard let committed = state.lastCommittedCursor,
      let received = state.lastReceivedCursor,
      received > committed
    else { return nil }
    return JetstreamGapCandidate(
      startCursor: committed,
      endCursor: received,
      reason: "operator_reconnect_receive_commit_backlog"
    )
  }
}

public enum JetstreamCursor {
  public static func parse(_ value: Any?) -> Int64? {
    switch value {
    case let raw as Int64: return raw
    case let raw as Int: return Int64(raw)
    case let raw as NSNumber: return raw.int64Value
    case let raw as String: return Int64(raw)
    default: return nil
    }
  }

  public static func resumeCursor(
    committed: Int64?,
    seededReceived: Int64?,
    rewindMicroseconds: Int64
  ) -> Int64? {
    if let committed { return max(0, committed - rewindMicroseconds) }
    if let seededReceived { return max(0, seededReceived - 30_000_000) }
    return nil
  }

  public static func url(_ raw: String, cursor: Int64?) throws -> String {
    guard var components = URLComponents(string: raw) else { throw FirehoseSubscriberError.invalidURL }
    if let cursor {
      var items = components.queryItems ?? []
      items.removeAll { $0.name == "cursor" }
      items.append(URLQueryItem(name: "cursor", value: String(cursor)))
      components.queryItems = items
    }
    guard let url = components.url?.absoluteString else { throw FirehoseSubscriberError.invalidURL }
    return url
  }
}

enum FirehoseSubscriberError: Error, CustomStringConvertible {
  case invalidURL

  var description: String { "Invalid firehose WebSocket URL" }
}

struct FirehoseQueueOverflowError: Error {}
struct FirehoseConnectionClosedError: Error {}
private enum JetstreamReconnectAssessmentError: Error {
  case streamStateUnavailable
}

private enum FirehoseCycleResult: Sendable {
  case streamEnded
  case reconnect(OperationsWorkerCommand)
}

private struct ManualJetstreamReconnectRequest: Error, Sendable {
  let command: OperationsWorkerCommand
}
