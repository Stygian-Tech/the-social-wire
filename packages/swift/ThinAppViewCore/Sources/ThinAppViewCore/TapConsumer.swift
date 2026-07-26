import Foundation
import Logging
import OperationsCore

/// Consumes verified Tap events in acknowledgement mode.
///
/// Shadow mode records durable parity evidence without changing AppView rows. Authoritative mode
/// applies the same idempotent transformer used by the legacy worker and only acknowledges after
/// both the mutation and per-repository evidence have been persisted.
public actor TapConsumer {
  private let store: any ThinAppViewStore
  private let indexer: ThinAppViewIndexer
  private let configuration: TapConsumerConfiguration
  private let operationsStore: (any OperationsStore)?
  private let repositoryRestorer: (any TapRepositoryRestorer)?
  private let telemetry: OperationsTelemetryBuffer?
  private let instanceId: String
  private let logger: Logger
  private var queueDepth = 0
  private var queueCapacity: Int
  private var droppedMessages: Int64 = 0
  private var queueMetricGate = QueueMetricEmissionGate()

  public init(
    store: any ThinAppViewStore,
    indexer: ThinAppViewIndexer,
    configuration: TapConsumerConfiguration,
    repositoryRestorer: (any TapRepositoryRestorer)? = nil,
    operationsStore: (any OperationsStore)? = nil,
    telemetry: OperationsTelemetryBuffer? = nil,
    instanceId: String,
    logger: Logger
  ) {
    self.store = store
    self.indexer = indexer
    self.configuration = configuration
    self.repositoryRestorer = repositoryRestorer
    self.operationsStore = operationsStore
    self.telemetry = telemetry
    self.instanceId = instanceId
    self.logger = logger
    self.queueCapacity = configuration.queueCapacity
  }

  public func runForever() async {
    guard configuration.mode != .disabled else { return }
    var reconnectDelay: TimeInterval = 1
    while !Task.isCancelled {
      do {
        try await TapChannelTransport.consume(
          channelURL: configuration.channelURL.absoluteString,
          adminPassword: configuration.adminPassword,
          queueCapacity: configuration.queueCapacity,
          logger: logger,
          onConnected: {
            try? await self.operationsStore?.markStreamConnected(source: "tap", at: Date())
          },
          onHeartbeat: {
            try? await self.operationsStore?.markStreamTransportHeartbeat(
              source: "tap",
              at: Date()
            )
          },
          onQueueObservation: { observation in
            await self.observeQueue(observation)
          },
          handleMessage: { text, acknowledge in
            try await self.process(text, acknowledge: acknowledge)
          }
        )
        reconnectDelay = 1
      } catch {
        try? await operationsStore?.markStreamDisconnected(
          source: "tap",
          reason: OperationsRedactor.errorCategory(error),
          at: Date()
        )
        logger.warning(
          "Tap channel disconnected",
          metadata: [
            "error_type": .string(OperationsRedactor.errorCategory(error)),
            "retry_seconds": .stringConvertible(reconnectDelay),
          ]
        )
        try? await Task.sleep(for: .seconds(reconnectDelay))
        reconnectDelay = min(60, reconnectDelay * 2)
      }
    }
  }

  public func process(
    _ text: String,
    acknowledge: @Sendable (Int64) async throws -> Void
  ) async throws {
    let event = try TapEventParser.parse(text)
    let now = Date()
    try await operationsStore?.markStreamReceived(
      source: "tap",
      cursor: event.id,
      eventAt: now,
      receivedAt: now,
      queueDepth: queueDepth
    )

    if try await store.hasProcessedTapEvent(
      environment: configuration.environment,
      eventId: event.id
    ) {
      try await operationsStore?.markStreamCommitted(
        source: "tap",
        cursor: event.id,
        eventAt: now,
        committedAt: Date(),
        queueDepth: queueDepth
      )
      try await acknowledge(event.id)
      await emitAcknowledgedMetric(eventType: Self.eventType(event), redelivery: true)
      return
    }

    let previous = try await store.fetchTapRepositorySyncState(
      environment: configuration.environment,
      repoDid: event.repoDid
    )
    let state: TapRepositorySyncState
    let eventType: String
    let parityEvidence: TapParityEventEvidence?
    let indexedMutation: Bool
    let indexedMetricDimensions: [String: String]
    let validationObserved: Bool
    switch event {
    case .record(let record):
      let result = try await processRecord(record, previous: previous, at: now)
      state = result.state
      parityEvidence = result.parityEvidence
      eventType = "record"
      indexedMutation = result.indexingOutcome.didMutateProjection
      indexedMetricDimensions = [
        "collection": record.collection,
        "operation": record.action.rawValue,
      ]
      validationObserved = configuration.mode == .shadow
        && configuration.collections.contains(record.collection)
    case .identity(let identity):
      let result = try await processIdentity(identity, previous: previous, at: now)
      state = result.state
      parityEvidence = nil
      eventType = "identity"
      indexedMutation = result.indexingOutcome.didMutateProjection
      indexedMetricDimensions = [:]
      validationObserved = false
    }

    try await store.commitTapEvent(
      state: state,
      eventId: event.id,
      eventType: eventType,
      parityEvidence: parityEvidence,
      processedAt: now
    )
    try await operationsStore?.markStreamCommitted(
      source: "tap",
      cursor: event.id,
      eventAt: now,
      committedAt: Date(),
      queueDepth: queueDepth
    )
    if indexedMutation {
      try? await operationsStore?.markStreamIndexedMutation(source: "tap", at: now)
    }
    if validationObserved {
      try? await operationsStore?.markStreamValidationWatermark(
        source: "tap",
        watermark: "event:\(event.id)",
        at: now
      )
    }
    if indexedMutation {
      await emitMetric(
        "socialwire.ingestion.events_total",
        value: 1,
        dimensions: [
          "ingestion_source": "tap",
          "ingestion_mode": configuration.mode.rawValue,
          "event_type": eventType,
          "parity": state.parityStatus.rawValue,
        ].merging(indexedMetricDimensions) { _, measuredValue in measuredValue }
      )
    }
    try await acknowledge(event.id)
    await emitAcknowledgedMetric(eventType: eventType, redelivery: false)
  }

  private func processRecord(
    _ event: TapRecordEvent,
    previous: TapRepositorySyncState?,
    at now: Date
  ) async throws -> (
    state: TapRepositorySyncState,
    parityEvidence: TapParityEventEvidence?,
    indexingOutcome: ThinAppViewIndexingOutcome
  ) {
    let configured = configuration.collections.contains(event.collection)
    let parity: TapParityAssessment
    var indexedAt: Date?
    let indexingOutcome: ThinAppViewIndexingOutcome

    if configuration.mode == .authoritative, configured {
      indexingOutcome = try await indexer.handleCommitWithOutcome(
        repoDid: event.did,
        collection: event.collection,
        rkey: event.rkey,
        cid: event.cid ?? "",
        recordJSON: event.recordJSON ?? Data("{}".utf8),
        operation: event.action.rawValue,
        ingestionSource: "tap",
        ingestionEnvironment: configuration.environment,
        repoRev: event.rev,
        cursor: String(event.id),
        eventTime: now
      )
      parity = TapParityAssessment(
        status: .authoritative,
        mismatch: nil,
        counted: false,
        evidence: nil
      )
      indexedAt = indexingOutcome.didMutateProjection ? now : nil
    } else if !configured {
      indexingOutcome = .skipped
      parity = TapParityAssessment(
        status: .mismatch,
        mismatch: "unexpected_collection:\(event.collection)",
        counted: true,
        evidence: TapParityEventEvidence(
          uri: RenderFieldExtractor.buildEntryUri(
            did: event.did,
            collection: event.collection,
            rkey: event.rkey
          ),
          collection: event.collection,
          mismatchKind: "unexpected_collection",
          expectedCid: event.cid,
          observedCid: nil
        )
      )
    } else {
      indexingOutcome = .skipped
      parity = try await assessParity(event)
    }

    return (
      nextState(
        previous: previous,
        repoDid: event.did,
        repoRev: event.rev,
        eventId: event.id,
        eventLive: event.live,
        accountStatus: previous?.accountStatus ?? .active,
        parity: parity,
        indexedAt: indexedAt,
        at: now
      ),
      parity.evidence,
      indexingOutcome
    )
  }

  private func processIdentity(
    _ event: TapIdentityEvent,
    previous: TapRepositorySyncState?,
    at now: Date
  ) async throws -> (
    state: TapRepositorySyncState,
    indexingOutcome: ThinAppViewIndexingOutcome
  ) {
    var indexingOutcome = ThinAppViewIndexingOutcome.skipped
    if configuration.mode == .authoritative {
      indexingOutcome = try await indexer.handleIdentityWithOutcome(
        repoDid: event.did,
        status: event.status,
        isActive: event.isActive
      )
      if event.isActive && event.status.isActive {
        guard let repositoryRestorer else {
          throw TapRepositoryRestorationError.unavailable
        }
        _ = try await repositoryRestorer.restoreCurrentRepository(repoDid: event.did)
        indexingOutcome = .projectionMutation
      }
    }
    return (
      nextState(
        previous: previous,
        repoDid: event.did,
        repoRev: previous?.repoRev,
        eventId: event.id,
        eventLive: nil,
        accountStatus: event.status,
        parity: TapParityAssessment(
          status: configuration.mode == .authoritative ? .authoritative : .lifecycleObserved,
          mismatch: nil,
          counted: false,
          evidence: nil
        ),
        indexedAt: indexingOutcome.didMutateProjection ? now : previous?.lastIndexedAt,
        preservePdsBase: false,
        at: now
      ),
      indexingOutcome
    )
  }

  private func assessParity(_ event: TapRecordEvent) async throws -> TapParityAssessment {
    guard ThinAppViewConfig.canonicalContentCollections.contains(event.collection) else {
      return TapParityAssessment(status: .pending, mismatch: nil, counted: false, evidence: nil)
    }
    let uri = RenderFieldExtractor.buildEntryUri(
      did: event.did,
      collection: event.collection,
      rkey: event.rkey
    )
    let indexed = try await store.fetchContentIdentity(uri: uri)
    switch event.action {
    case .delete:
      if indexed == nil {
        return TapParityAssessment(
          status: .matched,
          mismatch: nil,
          counted: true,
          evidence: TapParityEventEvidence(
            uri: uri,
            collection: event.collection,
            mismatchKind: nil,
            expectedCid: nil,
            observedCid: nil
          )
        )
      }
      return TapParityAssessment(
        status: .mismatch,
        mismatch: "delete_still_indexed",
        counted: true,
        evidence: TapParityEventEvidence(
          uri: uri,
          collection: event.collection,
          mismatchKind: "delete_still_indexed",
          expectedCid: nil,
          observedCid: indexed?.cid
        )
      )
    case .create, .update:
      guard let expectedCid = event.cid else {
        return TapParityAssessment(
          status: .mismatch,
          mismatch: "missing_tap_cid",
          counted: true,
          evidence: TapParityEventEvidence(
            uri: uri,
            collection: event.collection,
            mismatchKind: "missing_tap_cid",
            expectedCid: nil,
            observedCid: indexed?.cid
          )
        )
      }
      guard let indexed else {
        return TapParityAssessment(
          status: .mismatch,
          mismatch: "record_not_indexed",
          counted: true,
          evidence: TapParityEventEvidence(
            uri: uri,
            collection: event.collection,
            mismatchKind: "record_not_indexed",
            expectedCid: expectedCid,
            observedCid: nil
          )
        )
      }
      if indexed.cid == expectedCid {
        return TapParityAssessment(
          status: .matched,
          mismatch: nil,
          counted: true,
          evidence: TapParityEventEvidence(
            uri: uri,
            collection: event.collection,
            mismatchKind: nil,
            expectedCid: expectedCid,
            observedCid: indexed.cid
          )
        )
      }
      return TapParityAssessment(
        status: .mismatch,
        mismatch: "cid_mismatch",
        counted: true,
        evidence: TapParityEventEvidence(
          uri: uri,
          collection: event.collection,
          mismatchKind: "cid_mismatch",
          expectedCid: expectedCid,
          observedCid: indexed.cid
        )
      )
    }
  }

  private func nextState(
    previous: TapRepositorySyncState?,
    repoDid: String,
    repoRev: String?,
    eventId: Int64,
    eventLive: Bool?,
    accountStatus: TapAccountStatus,
    parity: TapParityAssessment,
    indexedAt: Date?,
    preservePdsBase: Bool = true,
    at now: Date
  ) -> TapRepositorySyncState {
    let matchedIncrement: Int64 = parity.counted && parity.status == .matched ? 1 : 0
    let mismatchIncrement: Int64 = parity.counted && parity.status == .mismatch ? 1 : 0
    return TapRepositorySyncState(
      environment: configuration.environment,
      repoDid: repoDid,
      repoRev: repoRev,
      accountStatus: accountStatus,
      pdsBase: preservePdsBase ? previous?.pdsBase : nil,
      lastEventId: max(previous?.lastEventId ?? eventId, eventId),
      lastEventLive: eventLive ?? previous?.lastEventLive ?? false,
      parityStatus: parity.status,
      matchedEventCount: (previous?.matchedEventCount ?? 0) + matchedIncrement,
      mismatchedEventCount: (previous?.mismatchedEventCount ?? 0) + mismatchIncrement,
      lastMismatch: parity.mismatch ?? previous?.lastMismatch,
      lastIndexedAt: indexedAt ?? previous?.lastIndexedAt,
      lastValidatedAt: parity.counted ? now : previous?.lastValidatedAt,
      updatedAt: now
    )
  }

  private func observeQueue(_ observation: BoundedQueueObservation) async {
    let previousDroppedMessages = droppedMessages
    queueDepth = observation.depth
    queueCapacity = observation.capacity
    if observation.dropped > droppedMessages {
      let delta = observation.dropped - droppedMessages
      droppedMessages = observation.dropped
      await emitMetric(
        "socialwire.ingestion.queue_dropped_total",
        value: Double(delta),
        dimensions: ["ingestion_source": "tap"]
      )
    }
    let now = Date()
    let shouldEmit = queueMetricGate.shouldEmit(at: now)
    if shouldEmit || observation.dropped > previousDroppedMessages {
      try? await operationsStore?.recordStreamQueueObservation(
        source: "tap",
        depth: queueDepth,
        capacity: queueCapacity,
        overflowTotal: droppedMessages,
        observedAt: now
      )
    }
    guard shouldEmit else { return }
    await emitMetric(
      "socialwire.ingestion.queue_depth",
      value: Double(queueDepth),
      dimensions: ["ingestion_source": "tap"]
    )
    await emitMetric(
      "socialwire.ingestion.queue_capacity",
      value: Double(queueCapacity),
      dimensions: ["ingestion_source": "tap"]
    )
  }

  private func emitMetric(
    _ name: String,
    value: Double,
    dimensions: [String: String]
  ) async {
    _ = await telemetry?.enqueue(.metric(.init(name: name, value: value, dimensions: dimensions)))
  }

  private func emitAcknowledgedMetric(eventType: String, redelivery: Bool) async {
    await emitMetric(
      "socialwire.ingestion.acknowledged_events_total",
      value: 1,
      dimensions: [
        "ingestion_source": "tap",
        "ingestion_mode": configuration.mode.rawValue,
        "event_type": eventType,
        "redelivery": redelivery ? "true" : "false",
      ]
    )
  }

  private static func eventType(_ event: TapEvent) -> String {
    switch event {
    case .record: "record"
    case .identity: "identity"
    }
  }
}

struct QueueMetricEmissionGate: Sendable {
  private var lastEmissionAt = Date.distantPast

  mutating func shouldEmit(at now: Date, interval: TimeInterval = 1) -> Bool {
    guard now.timeIntervalSince(lastEmissionAt) >= interval else { return false }
    lastEmissionAt = now
    return true
  }
}

private struct TapParityAssessment: Sendable {
  let status: TapParityStatus
  let mismatch: String?
  let counted: Bool
  let evidence: TapParityEventEvidence?
}
