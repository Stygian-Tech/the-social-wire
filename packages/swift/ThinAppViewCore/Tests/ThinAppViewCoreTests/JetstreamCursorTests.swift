import Foundation
import Logging
import OperationsCore
import Testing
@testable import ThinAppViewCore

@Suite("Jetstream cursor")
struct JetstreamCursorTests {
  @Test func parsesOnlyMicrosecondCursorRepresentations() {
    #expect(JetstreamCursor.parse("1720000000000000") == 1_720_000_000_000_000)
    #expect(JetstreamCursor.parse(NSNumber(value: 42)) == 42)
    #expect(JetstreamCursor.parse(nil) == nil)
  }

  @Test func rewindsCommittedCursorFiveSeconds() {
    #expect(
      JetstreamCursor.resumeCursor(
        committed: 20_000_000,
        seededReceived: 19_000_000,
        rewindMicroseconds: 5_000_000
      ) == 15_000_000
    )
  }

  @Test func firstUpgradeRewindsSeedThirtySeconds() {
    #expect(
      JetstreamCursor.resumeCursor(
        committed: nil,
        seededReceived: 40_000_000,
        rewindMicroseconds: 5_000_000
      ) == 10_000_000
    )
  }

  @Test func replacesCursorWithoutDroppingCollectionFilters() throws {
    let url = try JetstreamCursor.url(
      "wss://jetstream.example/subscribe?wantedCollections=site.standard.document&cursor=1",
      cursor: 25
    )
    #expect(url.contains("wantedCollections=site.standard.document"))
    #expect(url.contains("cursor=25"))
    #expect(!url.contains("cursor=1&"))
  }

  @Test func gapDetectorRequiresObservedUncommittedCursors() {
    let caughtUp = IngestionStreamState(
      environment: "test",
      source: "jetstream",
      connectionState: .disconnected,
      lastReceivedCursor: 2_000,
      lastCommittedCursor: 2_000,
      heartbeatAt: Date()
    )
    #expect(JetstreamGapDetector.candidate(state: caughtUp, reason: FirehoseQueueOverflowError()) == nil)

    let backlog = IngestionStreamState(
      environment: "test",
      source: "jetstream",
      connectionState: .disconnected,
      lastReceivedCursor: 2_100,
      lastCommittedCursor: 2_000,
      heartbeatAt: Date()
    )
    #expect(
      JetstreamGapDetector.candidate(state: backlog, reason: FirehoseQueueOverflowError())
        == JetstreamGapCandidate(
          startCursor: 2_000,
          endCursor: 2_100,
          reason: "message_pump_overflow"
        )
    )
  }

  @Test func replayWindowUsesRewindOnlyForTransportCatchup() {
    let window = JetstreamReplayWindow(lowerBound: 20_000_000, upperBound: 30_000_000)
    #expect(window.connectionCursor == 15_000_000)
    #expect(!window.contains(19_999_999))
    #expect(!window.contains(20_000_000))
    #expect(window.contains(20_000_001))
    #expect(window.contains(30_000_000))
    #expect(window.isPastUpperBound(30_000_001))
  }

  @Test("replay checks every envelope cursor before filtering by kind")
  func replayBoundsAllEnvelopeKinds() {
    let policy = JetstreamReplayEnvelopePolicy(
      window: JetstreamReplayWindow(lowerBound: 20, upperBound: 30),
      authorDids: [],
      collections: ["site.standard.document"]
    )

    #expect(
      policy.classifyCursor(["kind": "identity", "time_us": 31])
        == .pastUpperBound(31)
    )
    #expect(
      policy.classifyCursor(["kind": "account", "time_us": 19])
        == .beforeWindow(19)
    )
    #expect(
      policy.classifyCursor(["kind": "commit", "time_us": 25])
        == .withinWindow(25)
    )
  }

  @Test("DID-scoped replay excludes every other author")
  func replayAuthorScope() {
    let scoped = JetstreamReplayEnvelopePolicy(
      window: JetstreamReplayWindow(lowerBound: 20, upperBound: 30),
      authorDids: ["did:plc:aaaaaaaaaaaaaaaaaaaaaaaa"],
      collections: ["site.standard.document"]
    )
    #expect(
      scoped.includes(
        did: "did:plc:aaaaaaaaaaaaaaaaaaaaaaaa",
        collection: "site.standard.document"
      )
    )
    #expect(
      !scoped.includes(
        did: "did:plc:bbbbbbbbbbbbbbbbbbbbbbbb",
        collection: "site.standard.document"
      )
    )
    #expect(
      !scoped.includes(
        did: "did:plc:aaaaaaaaaaaaaaaaaaaaaaaa",
        collection: "site.standard.publication"
      )
    )

    let unscoped = JetstreamReplayEnvelopePolicy(
      window: JetstreamReplayWindow(lowerBound: 20, upperBound: 30),
      authorDids: [],
      collections: ["site.standard.document"]
    )
    #expect(
      unscoped.includes(
        did: "did:plc:bbbbbbbbbbbbbbbbbbbbbbbb",
        collection: "site.standard.document"
      )
    )
  }

  @Test("repeated or out-of-order cursors do not postpone the replay deadline")
  func replayProgressRequiresCursorAdvance() {
    let startedAt = Date(timeIntervalSince1970: 1_000)
    var state = JetstreamReplayProgressMonitor.State(
      initialCursor: 10,
      startedAt: startedAt
    )
    state.observe(cursor: 20, at: startedAt.addingTimeInterval(1))
    state.observe(cursor: 20, at: startedAt.addingTimeInterval(5))
    state.observe(cursor: 19, at: startedAt.addingTimeInterval(6))

    #expect(state.greatestCursor == 20)
    #expect(state.lastAdvancedAt == startedAt.addingTimeInterval(1))
    #expect(state.hasStalled(at: startedAt.addingTimeInterval(4), timeout: 3))
  }

  @Test("quiet replay fails with bounded visible no-progress evidence")
  func quietReplayTimesOut() async {
    let monitor = JetstreamReplayProgressMonitor(
      initialCursor: 10,
      timeout: 0.03,
      pollInterval: 0.005
    )

    await #expect(throws: JetstreamReplayProgressMonitor.TimeoutError(lastObservedCursor: 10)) {
      try await monitor.waitForStall()
    }
  }

  @Test("reconnect handshake cannot complete before durable cursor progress")
  func reconnectRequiresPostHandshakeProgress() {
    let baseline = IngestionStreamState(
      environment: "test",
      source: "jetstream",
      connectionState: .disconnected,
      lastReceivedCursor: 100,
      lastCommittedCursor: 90,
      heartbeatAt: Date()
    )
    var gate = JetstreamReconnectProgressGate(state: baseline)

    #expect(!gate.permitsCompletion(receivedCursor: 101, committedCursor: 101))
    gate.didConnect(at: Date())
    #expect(!gate.permitsCompletion(receivedCursor: 100, committedCursor: 100))
    #expect(!gate.permitsCompletion(receivedCursor: 101, committedCursor: 90))
    #expect(gate.permitsCompletion(receivedCursor: 101, committedCursor: 101))

    gate.beginConnectionAttempt()
    #expect(!gate.permitsCompletion(receivedCursor: 102, committedCursor: 102))
  }

  @Test("Jetstream no-op commits advance the durable cursor without counting as indexed")
  func noOpCommitIsNotIndexedTelemetry() async throws {
    let appViewPath = NSTemporaryDirectory() + "jetstream-noop-appview-\(UUID().uuidString).sqlite"
    let operationsPath = NSTemporaryDirectory() + "jetstream-noop-operations-\(UUID().uuidString).sqlite"
    defer {
      try? FileManager.default.removeItem(atPath: appViewPath)
      try? FileManager.default.removeItem(atPath: operationsPath)
    }
    let logger = Logger(label: "jetstream-noop.test")
    let appViewStore = try SQLiteThinAppViewStore(path: appViewPath, logger: logger)
    let operationsStore = try SQLiteOperationsStore(
      path: operationsPath,
      environment: "test",
      logger: logger
    )
    let telemetryRecorder = JetstreamTelemetryRecorder()
    let telemetry = OperationsTelemetryBuffer(
      capacity: 100,
      batchSize: 100,
      logger: logger
    ) { signals in
      await telemetryRecorder.append(signals)
    }
    let subscriber = FirehoseSubscriber(
      relayURLs: ["wss://jetstream.example/subscribe"],
      indexer: ThinAppViewIndexer(
        store: appViewStore,
        config: ThinAppViewConfig.fromEnvironment(["ENABLE_THIN_APPVIEW": "true"]),
        logger: logger
      ),
      operationsStore: operationsStore,
      telemetry: telemetry,
      environment: "test",
      instanceId: "test-worker",
      replayRewindMicroseconds: 5_000_000,
      logger: logger
    )
    let cursor: Int64 = 1_720_000_000_000_000

    try await subscriber.handleMessage(
      #"{"did":"did:plc:aaaaaaaaaaaaaaaaaaaaaaaa","time_us":1720000000000000,"kind":"commit","commit":{"operation":"create","collection":"app.thesocialwire.entryReadState","rkey":"read-state","cid":"bafyno-op","record":{}}}"#
    )
    _ = await telemetry.flushOnce()

    let state = try #require(
      try await operationsStore.fetchStreamState(source: "jetstream")
    )
    #expect(state.lastReceivedCursor == cursor)
    #expect(state.lastCommittedCursor == cursor)
    #expect(
      await telemetryRecorder.metrics(named: "socialwire.ingestion.events_total").isEmpty
    )
    let processed = await telemetryRecorder.metrics(
      named: "socialwire.ingestion.processed_events_total"
    )
    #expect(processed.count == 1)
    #expect(processed.first?.dimensions["indexing_result"] == "skipped")
  }

  @Test("Jetstream progress confirms a gap but never resolves it")
  func jetstreamProgressLeavesGapActionable() async throws {
    let path = NSTemporaryDirectory() + "jetstream-gap-\(UUID().uuidString).sqlite"
    defer { try? FileManager.default.removeItem(atPath: path) }
    let store = try SQLiteOperationsStore(
      path: path,
      environment: "test",
      logger: Logger(label: "jetstream-gap.test")
    )
    let gap = try await store.createGap(
      source: "jetstream",
      startCursor: 1_000,
      endCursor: 2_000,
      reason: "transport_disconnect",
      collections: ["site.standard.document"],
      detectedAt: Date()
    )

    await JetstreamGapProgressAssessment.confirmSuspectedGaps(
      store: store,
      through: 2_500,
      at: Date()
    )

    let page = try await store.listGaps(view: .active, limit: 10, before: nil)
    #expect(page.items.first(where: { $0.id == gap.id })?.status == .confirmed)
    #expect(!page.items.contains(where: { $0.id == gap.id && $0.status == .resolved }))
  }

  @Test("verification-required ranges prevent duplicate Jetstream gaps")
  func verificationRequiredRangeIsCovered() async throws {
    let path = NSTemporaryDirectory() + "jetstream-covered-\(UUID().uuidString).sqlite"
    defer { try? FileManager.default.removeItem(atPath: path) }
    let store = try SQLiteOperationsStore(
      path: path,
      environment: "test",
      logger: Logger(label: "jetstream-covered.test")
    )
    let suspected = try await store.createGap(
      source: "jetstream",
      startCursor: 1_000,
      endCursor: 3_000,
      reason: "transport_disconnect",
      collections: [],
      detectedAt: Date()
    )
    let confirmed = try await store.transitionGap(
      id: suspected.id,
      to: .confirmed,
      expectedVersion: suspected.version,
      operatorDid: "system:test",
      idempotencyKey: "confirm-\(suspected.id)",
      requestId: nil,
      note: nil,
      at: Date()
    )
    let queued = try await store.transitionGap(
      id: confirmed.id,
      to: .backfillQueued,
      expectedVersion: confirmed.version,
      operatorDid: "system:test",
      idempotencyKey: "queue-\(confirmed.id)",
      requestId: nil,
      note: nil,
      at: Date()
    )
    let backfilling = try await store.transitionGap(
      id: queued.id,
      to: .backfilling,
      expectedVersion: queued.version,
      operatorDid: "system:test",
      idempotencyKey: "run-\(queued.id)",
      requestId: nil,
      note: nil,
      at: Date()
    )
    let verificationRequired = try await store.transitionGap(
      id: backfilling.id,
      to: .verificationRequired,
      expectedVersion: backfilling.version,
      operatorDid: "system:test",
      idempotencyKey: "verify-\(backfilling.id)",
      requestId: nil,
      note: nil,
      at: Date()
    )

    let candidate = JetstreamGapCandidate(
      startCursor: 1_500,
      endCursor: 2_500,
      reason: "operator_reconnect_receive_commit_backlog"
    )
    #expect(candidate.isCovered(by: verificationRequired))
  }
}

private actor OrderedValues {
  var values: [String] = []
  func append(_ value: String) { values.append(value) }
  func snapshot() -> [String] { values }
}

private actor JetstreamTelemetryRecorder {
  private var signals: [OperationsTelemetrySignal] = []

  func append(_ newSignals: [OperationsTelemetrySignal]) {
    signals.append(contentsOf: newSignals)
  }

  func metrics(named name: String) -> [OperationsMetricSample] {
    signals.compactMap { signal in
      guard case .metric(let sample) = signal, sample.name == name else { return nil }
      return sample
    }
  }
}

@Suite("Bounded sequential message pump")
struct BoundedSequentialMessagePumpTests {
  @Test func processesMessagesInReceiveOrder() async throws {
    let ordered = OrderedValues()
    let pump = BoundedSequentialMessagePump(capacity: 4, handleMessage: { value in
      if value == "first" { try await Task.sleep(for: .milliseconds(25)) }
      await ordered.append(value)
    }, onFailure: { _ in })
    #expect(pump.enqueue("first"))
    #expect(pump.enqueue("second"))
    try await Task.sleep(for: .milliseconds(100))
    #expect(await ordered.snapshot() == ["first", "second"])
  }

  @Test func rejectsMessagesWhenCapacityIsSaturated() async throws {
    let pump = BoundedSequentialMessagePump(capacity: 1, handleMessage: { _ in
      try await Task.sleep(for: .milliseconds(100))
    }, onFailure: { _ in })
    #expect(pump.enqueue("first"))
    #expect(!pump.enqueue("overflow"))
  }
}
