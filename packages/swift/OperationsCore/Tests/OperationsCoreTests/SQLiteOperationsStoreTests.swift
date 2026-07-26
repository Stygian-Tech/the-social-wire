import Foundation
import Logging
import Testing

@testable import OperationsCore

@Suite("SQLiteOperationsStore")
struct SQLiteOperationsStoreTests {
  @Test("Jetstream endpoint state and reconnect commands are durable")
  func jetstreamRecoveryControlLifecycle() async throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("operations-\(UUID().uuidString).sqlite")
    defer { try? FileManager.default.removeItem(at: url) }
    let store = try SQLiteOperationsStore(
      path: url.path, environment: "dev", logger: Logger(label: "operations.test"))
    let now = Date()

    try await store.upsertJetstreamEndpoint(
      JetstreamEndpointState(
        id: "jetstream1.us-east.bsky.network",
        environment: "dev",
        displayName: "Jetstream 1",
        host: "jetstream1.us-east.bsky.network",
        role: .active,
        connectionState: .connected,
        lastConnectedAt: now,
        connectionAttempts: 2,
        failoverCount: 1,
        updatedAt: now
      )
    )
    let endpoint = try #require(await store.listJetstreamEndpoints().first)
    #expect(endpoint.role == .active)
    #expect(endpoint.connectionAttempts == 2)

    let command = try await store.createCommand(
      action: .reconnectJetstream,
      operatorDid: "did:plc:operator",
      auditNote: "Reconnect stalled ingestion",
      at: now
    )
    let claimed = try #require(
      await store.claimNextCommand(
        action: .reconnectJetstream,
        workerId: "worker-1",
        at: now.addingTimeInterval(1)
      )
    )
    #expect(claimed.id == command.id)
    #expect(claimed.status == .running)
    #expect(claimed.claimedBy == "worker-1")

    _ = try await store.completeCommand(
      id: command.id,
      status: .completed,
      failureReason: nil,
      workerId: "worker-1",
      expectedVersion: claimed.version,
      requestId: "worker-complete-1",
      note: "Reconnect progress and gap assessment completed.",
      at: now.addingTimeInterval(2)
    )
    let completed = try #require(await store.listCommands(limit: 10).first)
    #expect(completed.status == .completed)
    #expect(completed.completedAt != nil)
  }

  @Test("command completion rejects stale owners, versions, and leases")
  func commandCompletionRequiresCurrentLease() async throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("operations-\(UUID().uuidString).sqlite")
    defer { try? FileManager.default.removeItem(at: url) }
    let store = try SQLiteOperationsStore(
      path: url.path, environment: "dev", logger: Logger(label: "operations.test"))
    let now = Date()
    let command = try await store.createCommand(
      action: .reconnectJetstream, operatorDid: "did:plc:operator", auditNote: nil,
      expectedStreamVersion: 0, idempotencyKey: "leased-command", requestId: "request-lease",
      at: now)
    let claimed = try #require(await store.claimNextCommand(
      action: .reconnectJetstream, workerId: "worker-1", at: now.addingTimeInterval(1)))

    await #expect(throws: OperationsStoreError.leaseConflict) {
      _ = try await store.completeCommand(
        id: command.id, status: .completed, failureReason: nil, workerId: "worker-2",
        expectedVersion: claimed.version, requestId: "wrong-owner", note: nil,
        at: now.addingTimeInterval(2))
    }
    await #expect(throws: OperationsStoreError.leaseConflict) {
      _ = try await store.completeCommand(
        id: command.id, status: .completed, failureReason: nil, workerId: "worker-1",
        expectedVersion: claimed.version + 1, requestId: "wrong-version", note: nil,
        at: now.addingTimeInterval(2))
    }
    let leaseExpiry = try #require(claimed.leaseExpiresAt)
    await #expect(throws: OperationsStoreError.leaseConflict) {
      _ = try await store.completeCommand(
        id: command.id, status: .completed, failureReason: nil, workerId: "worker-1",
        expectedVersion: claimed.version, requestId: "expired-lease", note: nil,
        at: leaseExpiry.addingTimeInterval(1))
    }
  }

  @Test("operator mutation and success audit commit exactly once")
  func mutationAuditIsAtomicAndComplete() async throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("operations-\(UUID().uuidString).sqlite")
    defer { try? FileManager.default.removeItem(at: url) }
    let store = try SQLiteOperationsStore(
      path: url.path, environment: "dev", logger: Logger(label: "operations.test"))
    let idempotencyKey = "reconnect-audit-once"

    let command = try await store.createCommand(
      action: .reconnectJetstream,
      operatorDid: "did:plc:operator",
      auditNote: nil,
      expectedStreamVersion: 0,
      idempotencyKey: idempotencyKey,
      requestId: "request-123",
      at: Date())
    let audits = try await store.mutationAudits(idempotencyKey: idempotencyKey)

    #expect(audits.count == 1)
    #expect(audits.first?.requestId == "request-123")
    #expect(audits.first?.expectedVersion == 0)
    #expect(audits.first?.before == ["streamVersion": "0"])
    #expect(audits.first?.after["targetId"] == command.id)
    #expect(audits.first?.after["status"] == "queued")
    #expect(audits.first?.after["version"] == "0")
    #expect(audits.first?.outcome == "queued")
  }

  @Test("Received and committed cursors advance independently and never regress")
  func checkpointsDoNotRegress() async throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("operations-\(UUID().uuidString).sqlite")
    defer { try? FileManager.default.removeItem(at: url) }
    let store = try SQLiteOperationsStore(
      path: url.path, environment: "dev", logger: Logger(label: "operations.test"))
    let now = Date()

    try await store.markStreamReceived(
      source: "jetstream", cursor: 2_000, eventAt: now, receivedAt: now, queueDepth: 1
    )
    try await store.markStreamCommitted(
      source: "jetstream", cursor: 1_900, eventAt: now, committedAt: now, queueDepth: 0
    )
    try await store.markStreamReceived(
      source: "jetstream", cursor: 1_500, eventAt: now, receivedAt: now, queueDepth: 0
    )

    let state = try #require(await store.fetchStreamState(source: "jetstream"))
    #expect(state.lastReceivedCursor == 2_000)
    #expect(state.lastCommittedCursor == 1_900)
    let overview = try await store.overview(at: now.addingTimeInterval(10))
    #expect(overview.evidence["ingestion"]?.accuracy == .unavailable)
    #expect(overview.evidence["ingestion"]?.indexedThrough == nil)
  }

  @Test("transport, queue, mutation, projection, and validation evidence remain distinct")
  func sourceEvidenceIsNotConflated() async throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("operations-\(UUID().uuidString).sqlite")
    defer { try? FileManager.default.removeItem(at: url) }
    let store = try SQLiteOperationsStore(
      path: url.path, environment: "dev", logger: Logger(label: "operations.test"))
    let connectedAt = Date()
    let receivedAt = connectedAt.addingTimeInterval(1)
    let queueObservedAt = connectedAt.addingTimeInterval(2)
    let indexedAt = connectedAt.addingTimeInterval(3)

    try await store.markStreamConnected(source: "tap", at: connectedAt)
    try await store.markStreamReceived(
      source: "tap",
      cursor: 42,
      eventAt: receivedAt,
      receivedAt: receivedAt,
      queueDepth: 2
    )
    try await store.recordStreamQueueObservation(
      source: "tap",
      depth: 3,
      capacity: 256,
      overflowTotal: 7,
      observedAt: queueObservedAt
    )
    try await store.recordStreamQueueObservation(
      source: "tap",
      depth: 1,
      capacity: 256,
      overflowTotal: 2,
      observedAt: queueObservedAt.addingTimeInterval(0.1)
    )
    try await store.markStreamIndexedMutation(source: "tap", at: indexedAt)
    try await store.markStreamProjectionWatermark(
      source: "tap",
      watermark: "projection:42",
      at: indexedAt.addingTimeInterval(1)
    )
    try await store.markStreamValidationWatermark(
      source: "tap",
      watermark: "validation:42",
      at: indexedAt.addingTimeInterval(2)
    )

    let state = try #require(await store.fetchStreamState(source: "tap"))
    #expect(abs((state.transportHeartbeatAt ?? .distantPast).timeIntervalSince(connectedAt)) < 0.002)
    #expect(abs((state.lastReceivedAt ?? .distantPast).timeIntervalSince(receivedAt)) < 0.002)
    #expect(abs((state.lastIndexedMutationAt ?? .distantPast).timeIntervalSince(indexedAt)) < 0.002)
    #expect(state.projectionWatermark == "projection:42")
    #expect(state.validationWatermark == "validation:42")
    #expect(state.queueDepth == 1)
    #expect(state.queueCapacity == 256)
    #expect(state.queueOverflowTotal == 7)
    #expect(state.queueEvidence?.source == "tap_transport_queue")
    #expect(state.queueEvidence?.accuracy.rawValue == "exact")
    #expect(try await store.fetchStreamState(source: "jetstream") == nil)
  }

  @Test("overview ingestion evidence follows only the fresh advertised authority")
  func overviewUsesAuthoritativeTransportEvidence() async throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("operations-\(UUID().uuidString).sqlite")
    defer { try? FileManager.default.removeItem(at: url) }
    let store = try SQLiteOperationsStore(
      path: url.path, environment: "dev", logger: Logger(label: "operations.test"))
    let now = Date()
    try await store.markStreamTransportHeartbeat(source: "jetstream", at: now)
    try await store.markStreamTransportHeartbeat(source: "tap", at: now.addingTimeInterval(-1))
    try await store.upsertServiceState(OperationsServiceState(
      service: "appview-worker", environment: "dev", instanceId: "worker-1",
      liveness: .healthy, readiness: .healthy, freshness: .healthy, completeness: .unknown,
      dependencyState: ["ingestion_authority": "tap"], startedAt: now, heartbeatAt: now))

    let overview = try await store.overview(at: now)
    #expect(overview.ingestion?.source == "tap")
    #expect(overview.ingestionSources.map(\.source).sorted() == ["jetstream", "tap"])
    #expect(overview.evidence["ingestion"]?.accuracy == .exact)
    #expect(abs((overview.evidence["ingestion"]?.indexedThrough ?? .distantPast)
      .timeIntervalSince(now.addingTimeInterval(-1))) < 0.002)

    let expired = try await store.overview(at: now.addingTimeInterval(60))
    #expect(expired.evidence["ingestion"]?.accuracy == .unavailable)
    #expect(expired.evidence["ingestion"]?.degradedReason?.contains("authority") == true)
  }

  @Test("overview service evidence requires every logical service")
  func overviewServiceEvidenceUsesRequiredServiceCoverage() async throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("operations-\(UUID().uuidString).sqlite")
    defer { try? FileManager.default.removeItem(at: url) }
    let store = try SQLiteOperationsStore(
      path: url.path, environment: "dev", logger: Logger(label: "operations.test"))
    let now = Date()
    for (offset, service) in ["gateway", "appview", "appview-worker", "operations"].enumerated() {
      try await store.upsertServiceState(OperationsServiceState(
        service: service, environment: "dev", instanceId: "\(service)-1",
        liveness: .healthy, readiness: .healthy, freshness: .healthy, completeness: .healthy,
        dependencyState: service == "appview-worker" ? ["ingestion_authority": "jetstream"] : [:],
        startedAt: now, heartbeatAt: now.addingTimeInterval(-Double(offset))))
    }
    let complete = try await store.overview(at: now)
    #expect(complete.evidence["services"]?.accuracy == .exact)
    #expect(complete.evidence["services"]?.coverage == 1)
    #expect(abs((complete.evidence["services"]?.indexedThrough ?? .distantPast)
      .timeIntervalSince(now.addingTimeInterval(-3))) < 0.002)

    let partiallyExpired = try await store.overview(at: now.addingTimeInterval(43.5))
    #expect(partiallyExpired.evidence["services"]?.accuracy == .sampled)
    #expect(partiallyExpired.evidence["services"]?.coverage == 0.5)
    #expect(partiallyExpired.evidence["services"]?.degradedReason?.contains("operations") == true)
  }

  @Test("Backfill jobs are dry-run first, leaseable, resumable, and auditable")
  func backfillLifecycle() async throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("operations-\(UUID().uuidString).sqlite")
    defer { try? FileManager.default.removeItem(at: url) }
    let store = try SQLiteOperationsStore(
      path: url.path, environment: "dev", backfillFingerprintSecret: "test-secret",
      logger: Logger(label: "operations.test"))
    let request = BackfillDryRunRequest(
      sourceMode: .jetstreamReplay,
      startCursor: 1_000_000,
      endCursor: 6_000_000,
      collections: ["site.standard.document"],
      batchSize: 100,
      rateLimit: 50,
      maxConcurrency: 1
    )
    let estimate = try await store.estimateBackfill(request)
    #expect(estimate.estimatedCount > 0)

    let job = try await store.createBackfill(
      CreateBackfillRequest(
        dryRun: request,
        expectedEstimate: estimate.estimatedCount,
        auditNote: "Repair test gap",
        environmentConfirmation: nil,
        idempotencyKey: "backfill-lifecycle",
        requestFingerprint: estimate.requestFingerprint
      ),
      operatorDid: "did:plc:operator",
      at: Date()
    )
    let claimed = try #require(
      await store.claimNextBackfill(
        workerId: "worker-1", leaseUntil: Date().addingTimeInterval(60), at: Date()
      )
    )
    #expect(claimed.id == job.id)
    #expect(claimed.status == .running)

    try await store.checkpointBackfill(
      id: job.id,
      cursor: 3_000_000,
      processed: 20,
      failed: 1,
      reconciled: 19,
      leaseUntil: Date().addingTimeInterval(60),
      at: Date()
    )
    let fetchedUpdated = try await store.fetchBackfill(id: job.id)
    let updated = try #require(fetchedUpdated)
    #expect(updated.checkpointCursor == 3_000_000)
    #expect(updated.processedCount == 20)
    #expect(updated.failedCount == 1)
    #expect(updated.reconciledCount == 19)
    await #expect(throws: OperationsStoreError.invalidProgress) {
      _ = try await store.checkpointBackfill(
        id: job.id, workerId: "worker-1", expectedVersion: updated.version,
        cursor: 2_000_000, processed: 20, failed: 1, reconciled: 19,
        leaseUntil: Date().addingTimeInterval(60), at: Date())
    }

    try await store.updateBackfillStatus(
      id: job.id,
      status: .failed,
      operatorDid: "system:worker",
      failureReason: "database_timeout",
      at: Date()
    )
    let fetchedFailed = try await store.fetchBackfill(id: job.id)
    let failed = try #require(fetchedFailed)
    #expect(failed.failureReason == "database_timeout")

    let tapRequest = BackfillDryRunRequest(
      sourceMode: .tapVerifiedResync,
      collections: ["site.standard.document"],
      authorDids: ["did:plc:aaaaaaaaaaaaaaaaaaaaaaaa"],
      batchSize: 100,
      rateLimit: 50,
      maxConcurrency: 1)
    let tapEstimate = try await store.estimateBackfill(tapRequest)
    let tapJob = try await store.createBackfill(
      CreateBackfillRequest(
        dryRun: tapRequest,
        expectedEstimate: tapEstimate.estimatedCount,
        auditNote: nil,
        environmentConfirmation: nil,
        idempotencyKey: "tap-verification-pending",
        requestFingerprint: tapEstimate.requestFingerprint),
      operatorDid: "did:plc:operator",
      at: Date())
    #expect(tapJob.verificationStatus == .pending)
    let tapRunning = try #require(await store.claimNextBackfill(
      workerId: "tap-worker", leaseUntil: Date().addingTimeInterval(60), at: Date()))
    #expect(tapRunning.id == tapJob.id)
    let tapVerified = try await store.recordBackfillVerification(
      id: tapRunning.id, workerId: "tap-worker", expectedVersion: tapRunning.version,
      exactScope: true, truncated: false, failedCount: 0,
      validationWatermark: "tap:event:100", at: Date())
    #expect(tapVerified.verificationStatus == .verified)
    let expiredLeaseAt = try #require(tapRunning.leaseExpiresAt).addingTimeInterval(1)
    await #expect(throws: OperationsStoreError.leaseConflict) {
      _ = try await store.transitionBackfill(
        id: tapVerified.id, to: .completed, expectedVersion: tapVerified.version,
        operatorDid: "system:worker", idempotencyKey: "tap-stale-completion",
        requestId: nil, note: nil, failureReason: nil, at: expiredLeaseAt)
    }
  }

  @Test("later committed cursors do not falsely resolve an explicit gap range")
  func committedCursorBeyondGapStillAllowsReplay() async throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("operations-\(UUID().uuidString).sqlite")
    defer { try? FileManager.default.removeItem(at: url) }
    let store = try SQLiteOperationsStore(
      path: url.path, environment: "dev", backfillFingerprintSecret: "test-secret",
      logger: Logger(label: "operations.test"))
    let now = Date()
    let gap = try await store.createGap(
      source: "jetstream",
      startCursor: 1_000_000,
      endCursor: 2_000_000,
      reason: "receive_commit_backlog",
      collections: [],
      detectedAt: now
    )
    let confirmed = try await store.transitionGap(
      id: gap.id, to: .confirmed, expectedVersion: gap.version,
      operatorDid: "did:plc:operator", idempotencyKey: "confirm-gap",
      requestId: "request-confirm-gap", note: nil, at: now)
    try await store.markStreamCommitted(
      source: "jetstream",
      cursor: 2_000_000,
      eventAt: now,
      committedAt: now,
      queueDepth: 0
    )

    let estimate = try await store.estimateBackfill(
      BackfillDryRunRequest(
        gapId: gap.id,
        sourceMode: .jetstreamReplay,
        startCursor: 1_000_000,
        endCursor: 2_000_000,
        collections: ["site.standard.document"],
        batchSize: 100,
        rateLimit: 50,
        maxConcurrency: 1
      )
    )
    #expect(estimate.estimatedCount > 0)
    #expect(!estimate.conflicts.contains { $0.contains("already committed") })
    let job = try await store.createBackfill(
      CreateBackfillRequest(
        dryRun: BackfillDryRunRequest(
          gapId: gap.id,
          sourceMode: .jetstreamReplay,
          startCursor: 1_000_000,
          endCursor: 2_000_000,
          collections: ["site.standard.document"],
          batchSize: 100,
          rateLimit: 50,
          maxConcurrency: 1),
        expectedEstimate: estimate.estimatedCount,
        auditNote: nil,
        environmentConfirmation: nil,
        idempotencyKey: "explicit-gap-replay",
        expectedGapVersion: confirmed.version,
        requestFingerprint: estimate.requestFingerprint),
      operatorDid: "did:plc:operator", requestId: "request-replay-gap", at: now)
    #expect(job.gapId == gap.id)
  }

  @Test("Dry run rejects an overlapping active backfill")
  func duplicateBackfillIsRejected() async throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("operations-\(UUID().uuidString).sqlite")
    defer { try? FileManager.default.removeItem(at: url) }
    let store = try SQLiteOperationsStore(
      path: url.path, environment: "dev", backfillFingerprintSecret: "test-secret",
      logger: Logger(label: "operations.test"))
    let request = BackfillDryRunRequest(
      sourceMode: .jetstreamReplay,
      startCursor: 1_000_000,
      endCursor: 6_000_000,
      collections: ["site.standard.document"],
      batchSize: 100,
      rateLimit: 50,
      maxConcurrency: 1
    )
    let firstEstimate = try await store.estimateBackfill(request)
    _ = try await store.createBackfill(
      CreateBackfillRequest(
        dryRun: request,
        expectedEstimate: firstEstimate.estimatedCount,
        auditNote: nil,
        environmentConfirmation: nil,
        idempotencyKey: "overlap-first",
        requestFingerprint: firstEstimate.requestFingerprint
      ),
      operatorDid: "did:plc:operator",
      at: Date()
    )

    let duplicateEstimate = try await store.estimateBackfill(request)
    #expect(duplicateEstimate.conflicts.contains { $0.contains("active backfill") })
  }

  @Test("Metric rollups retain real bucket values and dimensions")
  func metricRollups() async throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("operations-\(UUID().uuidString).sqlite")
    defer { try? FileManager.default.removeItem(at: url) }
    let store = try SQLiteOperationsStore(
      path: url.path, environment: "dev", logger: Logger(label: "operations.test"))
    let now = Date()

    try await store.recordMetric(
      OperationsMetricSample(
        name: "socialwire.ingestion.events_total",
        value: 1,
        dimensions: ["collection": "site.standard.document", "operation": "create"],
        recordedAt: now
      )
    )

    let rollups = try await store.listMetricRollups(
      startAt: now.addingTimeInterval(-60),
      endAt: now.addingTimeInterval(60),
      limit: 100
    )
    let rollup = try #require(rollups.first)
    #expect(rollup.metricName == "socialwire.ingestion.events_total")
    #expect(rollup.dimensions["collection"] == "site.standard.document")
    #expect(rollup.sampleCount == 1)
    #expect(rollup.valueSum == 1)
  }

  @Test("telemetry batches reject cross-environment signals atomically")
  func telemetryEnvironmentIsolation() async throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("operations-\(UUID().uuidString).sqlite")
    defer { try? FileManager.default.removeItem(at: url) }
    let store = try SQLiteOperationsStore(
      path: url.path, environment: "dev", logger: Logger(label: "operations.test"))
    let now = Date()
    await #expect(throws: OperationsStoreError.environmentMismatch(
      expected: "dev", actual: "prod")
    ) {
      try await store.recordTelemetryBatch([
        .metric(OperationsMetricSample(
          name: "socialwire.test.total", value: 1, dimensions: ["environment": "dev"],
          recordedAt: now)),
        .event(OperationsEvent(
          service: "appview", environment: "prod", instanceId: "appview-1",
          name: "test", occurredAt: now)),
      ])
    }
    #expect(try await store.listMetricRollups(
      startAt: now.addingTimeInterval(-60), endAt: now.addingTimeInterval(60), limit: 10
    ).isEmpty)
  }

  @Test("alert delivery retries are durable, bounded, dead-lettered, and manually retryable")
  func alertDeliveryRetryLifecycle() async throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("operations-\(UUID().uuidString).sqlite")
    defer { try? FileManager.default.removeItem(at: url) }
    let store = try SQLiteOperationsStore(
      path: url.path, environment: "dev", logger: Logger(label: "operations.test"))
    let openedAt = Date()
    let opened = try await store.openAlert(
      rule: "test", conditionKey: "test:delivery", severity: "warning", summary: "Test",
      evidence: [:], runbookSlug: "test", at: openedAt)

    for attempt in 1...OperationsAlertDeliveryRetryPolicy.maximumAttempts {
      let failedAt = openedAt.addingTimeInterval(Double(attempt))
      try await store.recordAlertDelivery(
        id: opened.id, error: "webhook_delivery_failed", at: failedAt)
      let alert = try #require(await store.fetchAlert(id: opened.id))
      #expect(alert.deliveryAttempts == attempt)
      if attempt < OperationsAlertDeliveryRetryPolicy.maximumAttempts {
        #expect(alert.deliveryDeadLetteredAt == nil)
        #expect((alert.nextDeliveryAt ?? .distantPast) > failedAt)
        #expect((alert.nextDeliveryAt ?? .distantFuture) <= failedAt.addingTimeInterval(3_600))
      } else {
        #expect(alert.deliveryDeadLetteredAt != nil)
        #expect(alert.nextDeliveryAt == nil)
      }
    }
    #expect(try await store.listAlertsPendingDelivery(
      limit: 10, at: openedAt.addingTimeInterval(10_000)).isEmpty)

    let deadLettered = try #require(await store.fetchAlert(id: opened.id))
    let retriedAt = openedAt.addingTimeInterval(20_000)
    let retried = try await store.retryAlertDelivery(
      id: opened.id, expectedVersion: deadLettered.version,
      operatorDid: "did:plc:aaaaaaaaaaaaaaaaaaaaaaaa", idempotencyKey: "retry-alert",
      requestId: "request-retry-alert", note: nil, at: retriedAt)
    #expect(retried.deliveryAttempts == 0)
    #expect(retried.deliveryDeadLetteredAt == nil)
    #expect(retried.lastDeliveryError == nil)
    #expect(try await store.listAlertsPendingDelivery(limit: 10, at: retriedAt)
      .contains { $0.id == opened.id })
  }

  @Test("active gap filtering happens before limits despite hundreds of newer terminal rows")
  func activeGapPredicatePrecedesLimit() async throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("operations-\(UUID().uuidString).sqlite")
    defer { try? FileManager.default.removeItem(at: url) }
    let store = try SQLiteOperationsStore(
      path: url.path, environment: "dev", logger: Logger(label: "operations.test"))
    let startedAt = Date().addingTimeInterval(-1_000)
    let active = try await store.createGap(
      source: "jetstream", startCursor: 1, endCursor: 2, reason: "transport_disconnect",
      collections: [], detectedAt: startedAt)
    for index in 0...250 {
      let gap = try await store.createGap(
        source: "jetstream", startCursor: Int64(index + 10), endCursor: Int64(index + 11),
        reason: "transport_disconnect", collections: [],
        detectedAt: startedAt.addingTimeInterval(Double(index + 1)))
      _ = try await store.transitionGap(
        id: gap.id, to: .resolved, expectedVersion: gap.version,
        operatorDid: "system:test", idempotencyKey: "resolve-terminal-\(index)",
        requestId: nil, note: nil, at: startedAt.addingTimeInterval(Double(index + 1)))
    }

    let page = try await store.listGaps(view: .active, limit: 1, before: nil)
    #expect(page.totalCount == 1)
    #expect(page.items.map(\.id) == [active.id])
    #expect(try await store.lifecycleCounts().activeGaps == 1)
  }

  @Test("active backfill filtering happens before limits despite hundreds of newer terminal rows")
  func activeBackfillPredicatePrecedesLimit() async throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("operations-\(UUID().uuidString).sqlite")
    defer { try? FileManager.default.removeItem(at: url) }
    let store = try SQLiteOperationsStore(
      path: url.path, environment: "dev", backfillFingerprintSecret: "test-secret",
      logger: Logger(label: "operations.test"))
    let startedAt = Date().addingTimeInterval(-1_000)
    let activeRequest = BackfillDryRunRequest(
      sourceMode: .jetstreamReplay, startCursor: 1_000, endCursor: 2_000,
      collections: ["site.standard.document"], batchSize: 100, rateLimit: 50,
      maxConcurrency: 1)
    let activeEstimate = try await store.estimateBackfill(activeRequest)
    let queued = try await store.createBackfill(
      CreateBackfillRequest(
        dryRun: activeRequest, expectedEstimate: activeEstimate.estimatedCount, auditNote: nil,
        environmentConfirmation: nil, idempotencyKey: "old-active-backfill",
        requestFingerprint: activeEstimate.requestFingerprint),
      operatorDid: "did:plc:aaaaaaaaaaaaaaaaaaaaaaaa", requestId: nil, at: startedAt)
    let running = try #require(await store.claimNextBackfill(
      workerId: "worker-active", leaseUntil: startedAt.addingTimeInterval(60), at: startedAt))
    #expect(running.id == queued.id)
    let paused = try await store.transitionBackfill(
      id: running.id, to: .paused, expectedVersion: running.version,
      operatorDid: "did:plc:aaaaaaaaaaaaaaaaaaaaaaaa", idempotencyKey: "pause-old-backfill",
      requestId: nil, note: nil, failureReason: nil, at: startedAt)

    for index in 0...250 {
      let start = Int64(10_000 + index * 10)
      let request = BackfillDryRunRequest(
        sourceMode: .jetstreamReplay, startCursor: start, endCursor: start + 5,
        collections: ["site.standard.document"], batchSize: 100, rateLimit: 50,
        maxConcurrency: 1)
      let estimate = try await store.estimateBackfill(request)
      let job = try await store.createBackfill(
        CreateBackfillRequest(
          dryRun: request, expectedEstimate: estimate.estimatedCount, auditNote: nil,
          environmentConfirmation: nil, idempotencyKey: "terminal-backfill-\(index)",
          requestFingerprint: estimate.requestFingerprint),
        operatorDid: "did:plc:aaaaaaaaaaaaaaaaaaaaaaaa", requestId: nil,
        at: startedAt.addingTimeInterval(Double(index + 1)))
      let claimed = try #require(await store.claimNextBackfill(
        workerId: "worker-\(index)",
        leaseUntil: startedAt.addingTimeInterval(Double(index + 1) + 60),
        at: startedAt.addingTimeInterval(Double(index + 1))))
      #expect(claimed.id == job.id)
      _ = try await store.transitionBackfill(
        id: job.id, to: .completed, expectedVersion: claimed.version,
        operatorDid: "system:worker", idempotencyKey: "complete-backfill-\(index)",
        requestId: nil, note: nil, failureReason: nil,
        at: startedAt.addingTimeInterval(Double(index + 1) + 0.5))
    }

    let page = try await store.listBackfills(view: .active, limit: 1, before: nil)
    #expect(page.totalCount == 1)
    #expect(page.items.map(\.id) == [paused.id])
    let counts = try await store.lifecycleCounts()
    #expect(counts.activeBackfills == 1)
    #expect(counts.completedBackfills == 251)
  }

  @Test("malformed pagination cursors are never treated as first-page requests")
  func malformedPaginationCursorsAreRejected() async throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("operations-\(UUID().uuidString).sqlite")
    defer { try? FileManager.default.removeItem(at: url) }
    let store = try SQLiteOperationsStore(
      path: url.path, environment: "dev", logger: Logger(label: "operations.test"))
    let malformed = "not-a-valid-operations-cursor"

    await #expect(throws: OperationsStoreError.invalidPaginationCursor) {
      _ = try await store.listJetstreamEndpoints(limit: 10, before: malformed)
    }
    await #expect(throws: OperationsStoreError.invalidPaginationCursor) {
      _ = try await store.listCommands(limit: 10, before: malformed)
    }
    await #expect(throws: OperationsStoreError.invalidPaginationCursor) {
      _ = try await store.listGaps(view: .active, limit: 10, before: malformed)
    }
    await #expect(throws: OperationsStoreError.invalidPaginationCursor) {
      _ = try await store.listBackfills(view: .active, limit: 10, before: malformed)
    }
    await #expect(throws: OperationsStoreError.invalidPaginationCursor) {
      _ = try await store.listAlerts(view: .active, limit: 10, before: malformed)
    }
    await #expect(throws: OperationsStoreError.invalidPaginationCursor) {
      _ = try await store.listTraceSpans(
        startAt: Date().addingTimeInterval(-60), endAt: Date(), limit: 10, before: malformed)
    }
  }

  @Test("idempotent command replay resolves records older than the list page cap")
  func commandReplayUsesExactLookup() async throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("operations-\(UUID().uuidString).sqlite")
    defer { try? FileManager.default.removeItem(at: url) }
    let store = try SQLiteOperationsStore(
      path: url.path, environment: "dev", logger: Logger(label: "operations.test"))
    let startedAt = Date().addingTimeInterval(-1_000)
    let original = try await store.createCommand(
      action: .reconnectJetstream, operatorDid: "did:plc:operator", auditNote: nil,
      expectedStreamVersion: 0, idempotencyKey: "old-command", requestId: "request-old",
      at: startedAt)
    let originalClaim = try #require(await store.claimNextCommand(
      action: .reconnectJetstream, workerId: "worker-old",
      at: startedAt.addingTimeInterval(0.1)))
    _ = try await store.completeCommand(
      id: original.id, status: .completed, failureReason: nil,
      workerId: "worker-old", expectedVersion: originalClaim.version,
      requestId: "complete-old", note: nil,
      at: startedAt.addingTimeInterval(0.2))

    for index in 0...250 {
      let command = try await store.createCommand(
        action: .reconnectJetstream, operatorDid: "did:plc:operator", auditNote: nil,
        expectedStreamVersion: 0, idempotencyKey: "new-command-\(index)", requestId: nil,
        at: startedAt.addingTimeInterval(Double(index + 1)))
      let claim = try #require(await store.claimNextCommand(
        action: .reconnectJetstream, workerId: "worker-\(index)",
        at: startedAt.addingTimeInterval(Double(index + 1) + 0.1)))
      _ = try await store.completeCommand(
        id: command.id, status: .completed, failureReason: nil,
        workerId: "worker-\(index)", expectedVersion: claim.version,
        requestId: "complete-\(index)", note: nil,
        at: startedAt.addingTimeInterval(Double(index + 1) + 0.2))
    }

    let replay = try await store.createCommand(
      action: .reconnectJetstream, operatorDid: "did:plc:operator", auditNote: nil,
      expectedStreamVersion: 0, idempotencyKey: "old-command", requestId: "request-replay",
      at: Date())
    #expect(replay.id == original.id)
    #expect(replay.status == .queued)
    #expect(replay.version == 0)
    #expect(replay.completedAt == nil)
    let replayAudits = try await store.mutationAudits(idempotencyKey: "old-command")
    #expect(replayAudits.map(\.outcome) == ["queued", "idempotent_replay"])
  }

  @Test("idempotency keys conflict when the canonical request changes")
  func commandIdempotencyBindsRequest() async throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("operations-\(UUID().uuidString).sqlite")
    defer { try? FileManager.default.removeItem(at: url) }
    let store = try SQLiteOperationsStore(
      path: url.path, environment: "dev", logger: Logger(label: "operations.test"))
    _ = try await store.createCommand(
      action: .reconnectJetstream, operatorDid: "did:plc:operator", auditNote: "first scope",
      expectedStreamVersion: 0, idempotencyKey: "bound-command", requestId: "first", at: Date())

    await #expect(throws: OperationsStoreError.idempotencyConflict) {
      _ = try await store.createCommand(
        action: .reconnectJetstream, operatorDid: "did:plc:operator",
        auditNote: "different scope", expectedStreamVersion: 0,
        idempotencyKey: "bound-command", requestId: "second", at: Date())
    }
  }

  @Test("backfill creation idempotency binds the exact signed scope")
  func backfillIdempotencyBindsScope() async throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("operations-\(UUID().uuidString).sqlite")
    defer { try? FileManager.default.removeItem(at: url) }
    let store = try SQLiteOperationsStore(
      path: url.path, environment: "dev", backfillFingerprintSecret: "test-secret",
      logger: Logger(label: "operations.test"))
    let firstRequest = BackfillDryRunRequest(
      sourceMode: .pdsReconciliation, collections: ["site.standard.document"],
      authorDids: ["did:plc:aaaaaaaaaaaaaaaaaaaaaaaa"], batchSize: 50, rateLimit: 10,
      maxConcurrency: 1)
    let firstEstimate = try await store.estimateBackfill(firstRequest)
    _ = try await store.createBackfill(
      CreateBackfillRequest(
        dryRun: firstRequest, expectedEstimate: firstEstimate.estimatedCount, auditNote: nil,
        environmentConfirmation: nil, idempotencyKey: "bound-backfill",
        requestFingerprint: firstEstimate.requestFingerprint),
      operatorDid: "did:plc:operator", requestId: "first", at: Date())

    let changedRequest = BackfillDryRunRequest(
      sourceMode: .pdsReconciliation, collections: ["site.standard.document"],
      authorDids: ["did:plc:aaaaaaaaaaaaaaaaaaaaaaaa"], batchSize: 50, rateLimit: 20,
      maxConcurrency: 1)
    let changedEstimate = try await store.estimateBackfill(changedRequest)
    await #expect(throws: OperationsStoreError.idempotencyConflict) {
      _ = try await store.createBackfill(
        CreateBackfillRequest(
          dryRun: changedRequest, expectedEstimate: changedEstimate.estimatedCount,
          auditNote: nil, environmentConfirmation: nil, idempotencyKey: "bound-backfill",
          requestFingerprint: changedEstimate.requestFingerprint),
        operatorDid: "did:plc:operator", requestId: "second", at: Date())
    }
  }

  @Test("terminal transitions restart recovery and audit retention from terminal time")
  func terminalTransitionsResetRetention() async throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("operations-\(UUID().uuidString).sqlite")
    defer { try? FileManager.default.removeItem(at: url) }
    let store = try SQLiteOperationsStore(
      path: url.path, environment: "dev", backfillFingerprintSecret: "test-secret",
      logger: Logger(label: "operations.test"))
    let createdAt = Date()
    let terminalAt = createdAt.addingTimeInterval(100 * 86_400)
    let expectedExpiry = terminalAt.addingTimeInterval(365 * 86_400)

    let command = try await store.createCommand(
      action: .reconnectJetstream, operatorDid: "did:plc:operator", auditNote: nil,
      expectedStreamVersion: 0, idempotencyKey: "retention-command", requestId: "create",
      at: createdAt)
    let commandClaim = try #require(await store.claimNextCommand(
      action: .reconnectJetstream, workerId: "worker-retention", at: terminalAt))
    _ = try await store.completeCommand(
      id: command.id, status: .completed, failureReason: nil, workerId: "worker-retention",
      expectedVersion: commandClaim.version, requestId: "complete", note: nil,
      at: terminalAt)

    let gap = try await store.createGap(
      source: "jetstream", startCursor: 10, endCursor: 20, reason: "retention",
      collections: [], detectedAt: createdAt)
    let confirmed = try await store.transitionGap(
      id: gap.id, to: .confirmed, expectedVersion: gap.version,
      operatorDid: "did:plc:operator", idempotencyKey: "retention-gap-confirm",
      requestId: nil, note: nil, at: createdAt.addingTimeInterval(1))
    _ = try await store.transitionGap(
      id: gap.id, to: .ignored, expectedVersion: confirmed.version,
      operatorDid: "did:plc:operator", idempotencyKey: "retention-gap-terminal",
      requestId: nil, note: nil, at: terminalAt)

    let recoveryRequest = BackfillDryRunRequest(
      sourceMode: .pdsReconciliation, collections: ["site.standard.document"],
      authorDids: ["did:plc:bbbbbbbbbbbbbbbbbbbbbbbb"], batchSize: 50, rateLimit: 10,
      maxConcurrency: 1)
    let recoveryEstimate = try await store.estimateBackfill(recoveryRequest)
    let backfill = try await store.createBackfill(
      CreateBackfillRequest(
        dryRun: recoveryRequest, expectedEstimate: recoveryEstimate.estimatedCount,
        auditNote: nil, environmentConfirmation: nil, idempotencyKey: "retention-backfill",
        requestFingerprint: recoveryEstimate.requestFingerprint),
      operatorDid: "did:plc:operator", at: createdAt)
    _ = try await store.transitionBackfill(
      id: backfill.id, to: .cancelled, expectedVersion: backfill.version,
      operatorDid: "did:plc:operator", idempotencyKey: "retention-backfill-terminal",
      requestId: nil, note: nil, failureReason: nil, at: terminalAt)

    let alert = try await store.openAlert(
      rule: "retention", conditionKey: "retention", severity: "warning",
      summary: "Retention test", evidence: [:], runbookSlug: "retention", at: createdAt)
    _ = try await store.transitionAlert(
      id: alert.id, to: .resolved, expectedVersion: alert.version,
      operatorDid: "did:plc:operator", idempotencyKey: "retention-alert-terminal",
      requestId: nil, note: nil, at: terminalAt)

    for (table, id) in [
      ("operations_commands", command.id), ("appview_ingestion_gaps", gap.id),
      ("appview_backfill_jobs", backfill.id), ("operations_alerts", alert.id),
    ] {
      let expiry = try #require(await store.lifecycleExpiry(table: table, id: id))
      #expect(abs(expiry.timeIntervalSince(expectedExpiry)) < 1)
    }
    let auditExpiry = try #require(await store.latestAuditExpiry(targetId: alert.id))
    #expect(abs(auditExpiry.timeIntervalSince(expectedExpiry)) < 1)
  }

  @Test("an exact linked gap remains recoverable behind more than 250 newer gaps")
  func linkedGapDryRunUsesExactLookup() async throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("operations-\(UUID().uuidString).sqlite")
    defer { try? FileManager.default.removeItem(at: url) }
    let store = try SQLiteOperationsStore(
      path: url.path, environment: "dev", backfillFingerprintSecret: "test-secret",
      logger: Logger(label: "operations.test"))
    let startedAt = Date().addingTimeInterval(-1_000)
    let gap = try await store.createGap(
      source: "jetstream", startCursor: 100, endCursor: 200, reason: "transport_disconnect",
      collections: ["site.standard.document"], detectedAt: startedAt)
    _ = try await store.transitionGap(
      id: gap.id, to: .confirmed, expectedVersion: gap.version,
      operatorDid: "did:plc:operator", idempotencyKey: "confirm-old-gap", requestId: nil,
      note: nil, at: startedAt)
    for index in 0...250 {
      _ = try await store.createGap(
        source: "jetstream", startCursor: Int64(1_000 + index),
        endCursor: Int64(1_001 + index), reason: "transport_disconnect", collections: [],
        detectedAt: startedAt.addingTimeInterval(Double(index + 1)))
    }

    let estimate = try await store.estimateBackfill(BackfillDryRunRequest(
      gapId: gap.id, sourceMode: .jetstreamReplay, startCursor: 100, endCursor: 200,
      collections: ["site.standard.document"], batchSize: 100, rateLimit: 50,
      maxConcurrency: 1))
    #expect(estimate.conflicts.isEmpty)
  }

  @Test("linked gap terminal updates are state-checked and queued cancellation is actionable")
  func linkedGapTerminalTransitionsAreGuarded() async throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("operations-\(UUID().uuidString).sqlite")
    defer { try? FileManager.default.removeItem(at: url) }
    let store = try SQLiteOperationsStore(
      path: url.path, environment: "dev", backfillFingerprintSecret: "test-secret",
      logger: Logger(label: "operations.test"))
    let now = Date()
    let gap = try await store.createGap(
      source: "jetstream", startCursor: 100, endCursor: 200, reason: "transport_disconnect",
      collections: ["site.standard.document"], detectedAt: now)
    let confirmed = try await store.transitionGap(
      id: gap.id, to: .confirmed, expectedVersion: gap.version,
      operatorDid: "did:plc:operator", idempotencyKey: "guard-confirm", requestId: nil,
      note: nil, at: now)
    let request = BackfillDryRunRequest(
      gapId: gap.id, sourceMode: .jetstreamReplay, startCursor: 100, endCursor: 200,
      collections: ["site.standard.document"], batchSize: 100, rateLimit: 50,
      maxConcurrency: 1)
    let firstEstimate = try await store.estimateBackfill(request)
    let queued = try await store.createBackfill(
      CreateBackfillRequest(
        dryRun: request, expectedEstimate: firstEstimate.estimatedCount, auditNote: nil,
        environmentConfirmation: nil, idempotencyKey: "guard-first-job",
        expectedGapVersion: confirmed.version, requestFingerprint: firstEstimate.requestFingerprint),
      operatorDid: "did:plc:operator", requestId: nil, at: now)
    _ = try await store.transitionBackfill(
      id: queued.id, to: .cancelled, expectedVersion: queued.version,
      operatorDid: "did:plc:operator", idempotencyKey: "guard-cancel-queued",
      requestId: nil, note: nil, failureReason: nil, at: now)
    let actionable = try #require(await store.fetchGap(id: gap.id))
    #expect(actionable.status == .confirmed)

    let secondEstimate = try await store.estimateBackfill(request)
    let second = try await store.createBackfill(
      CreateBackfillRequest(
        dryRun: request, expectedEstimate: secondEstimate.estimatedCount, auditNote: nil,
        environmentConfirmation: nil, idempotencyKey: "guard-second-job",
        expectedGapVersion: actionable.version,
        requestFingerprint: secondEstimate.requestFingerprint),
      operatorDid: "did:plc:operator", requestId: nil, at: now)
    let running = try #require(await store.claimNextBackfill(
      workerId: "worker-1", leaseUntil: now.addingTimeInterval(60), at: now))
    #expect(running.id == second.id)
    let backfillingGap = try #require(await store.fetchGap(id: gap.id))
    let manuallyResolved = try await store.transitionGap(
      id: gap.id, to: .resolved, expectedVersion: backfillingGap.version,
      operatorDid: "did:plc:operator", idempotencyKey: "guard-resolve-gap", requestId: nil,
      note: nil, at: now)

    await #expect(throws: OperationsStoreError.invalidTransition(
      from: IngestionGapStatus.resolved.rawValue,
      to: IngestionGapStatus.confirmed.rawValue)
    ) {
      _ = try await store.transitionBackfill(
        id: running.id, to: .failed, expectedVersion: running.version,
        operatorDid: "system:worker", idempotencyKey: "guard-fail-after-resolve",
        requestId: nil, note: nil, failureReason: "recovery_failed", at: now)
    }
    #expect(try await store.fetchGap(id: gap.id)?.status == manuallyResolved.status)
    #expect(try await store.fetchBackfill(id: running.id)?.status == .running)
  }

  @Test("non-verifiable recovery remains verification required instead of failed")
  func nonExactVerificationIsRequired() async throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("operations-\(UUID().uuidString).sqlite")
    defer { try? FileManager.default.removeItem(at: url) }
    let store = try SQLiteOperationsStore(
      path: url.path, environment: "dev", backfillFingerprintSecret: "test-secret",
      logger: Logger(label: "operations.test"))
    let request = BackfillDryRunRequest(
      sourceMode: .jetstreamReplay, startCursor: 100, endCursor: 200,
      collections: ["site.standard.document"], batchSize: 100, rateLimit: 50,
      maxConcurrency: 1)
    let estimate = try await store.estimateBackfill(request)
    let queued = try await store.createBackfill(
      CreateBackfillRequest(
        dryRun: request, expectedEstimate: estimate.estimatedCount, auditNote: nil,
        environmentConfirmation: nil, idempotencyKey: "verification-required",
        requestFingerprint: estimate.requestFingerprint),
      operatorDid: "did:plc:operator", requestId: nil, at: Date())
    let running = try #require(await store.claimNextBackfill(
      workerId: "worker-1", leaseUntil: Date().addingTimeInterval(60), at: Date()))
    #expect(running.id == queued.id)
    let result = try await store.recordBackfillVerification(
      id: running.id, workerId: "worker-1", expectedVersion: running.version,
      exactScope: false, truncated: false, failedCount: 0, validationWatermark: nil,
      at: Date())
    #expect(result.verificationStatus == .required)
    #expect(result.verificationReason == "scope_not_exact")
    let exactJetstream = try await store.recordBackfillVerification(
      id: result.id, workerId: "worker-1", expectedVersion: result.version,
      exactScope: true, truncated: false, failedCount: 0,
      validationWatermark: "jetstream:cursor:200", at: Date())
    #expect(exactJetstream.verificationStatus == .required)
    #expect(exactJetstream.verificationReason == "source_not_authoritative")
  }
}
