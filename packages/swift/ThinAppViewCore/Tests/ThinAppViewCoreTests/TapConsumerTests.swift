import Foundation
import Logging
import OperationsCore
import Testing

@testable import ThinAppViewCore

@Suite("Tap acknowledgement consumer")
struct TapConsumerTests {
  @Test("parses current nested Tap record and raw identity fixtures")
  func parsesCurrentWireFixtures() throws {
    let record = try TapEventParser.parse(
      #"{"id":12345,"type":"record","record":{"live":true,"rev":"3kb3fge5lm32x","did":"did:plc:aaaaaaaaaaaaaaaaaaaaaaaa","collection":"site.standard.document","rkey":"article","action":"create","cid":"bafyrecord","record":{"$type":"site.standard.document","title":"Hello"}}}"#
    )
    guard case .record(let recordEvent) = record else {
      Issue.record("Expected record event")
      return
    }
    #expect(recordEvent.id == 12_345)
    #expect(recordEvent.live)
    #expect(recordEvent.action == .create)
    #expect(recordEvent.cid == "bafyrecord")

    // Tap's raw envelope uses snake_case. @atproto/tap normalizes this to `isActive`.
    let identity = try TapEventParser.parse(
      #"{"id":12346,"type":"identity","identity":{"did":"did:plc:aaaaaaaaaaaaaaaaaaaaaaaa","handle":"alice.test","is_active":false,"status":"deactivated"}}"#
    )
    guard case .identity(let identityEvent) = identity else {
      Issue.record("Expected identity event")
      return
    }
    #expect(identityEvent.status == .deactivated)
    #expect(!identityEvent.isActive)
  }

  @Test("parser accepts real did:web repositories and rejects synthetic or unsupported DIDs")
  func parserEnforcesRepositoryDIDBoundary() throws {
    let web = try TapEventParser.parse(
      #"{"id":12347,"type":"identity","identity":{"did":"did:web:profiles.thesocialwire.app:authors:alice","handle":"alice.example","is_active":true,"status":"active"}}"#
    )
    guard case .identity(let identity) = web else {
      Issue.record("Expected identity event")
      return
    }
    #expect(identity.did == "did:web:profiles.thesocialwire.app:authors:alice")

    #expect(throws: TapEventParseError.self) {
      try TapEventParser.parse(
        #"{"id":12348,"type":"identity","identity":{"did":"did:web:skyreader.rss","handle":"rss.invalid","is_active":true,"status":"active"}}"#
      )
    }
    #expect(throws: TapEventParseError.self) {
      try TapEventParser.parse(
        #"{"id":12349,"type":"identity","identity":{"did":"did:key:z6Mkexample","handle":"key.invalid","is_active":true,"status":"active"}}"#
      )
    }
    #expect(throws: TapEventParseError.self) {
      try TapEventParser.parse(
        #"{"id":12350,"type":"identity","identity":{"did":"did:web:example.com:%2Fadmin","handle":"unsafe.invalid","is_active":true,"status":"active"}}"#
      )
    }
  }

  @Test("shadow consumer acknowledges only after durable parity state")
  func shadowAcknowledgesAfterParityCommit() async throws {
    let fixture = try makeFixture(mode: .shadow)
    let now = Date()
    try await fixture.store.upsertContentItem(
      IndexedContentItem(
        uri: "at://did:plc:aaaaaaaaaaaaaaaaaaaaaaaa/site.standard.document/article",
        cid: "bafyrecord",
        authorDid: "did:plc:aaaaaaaaaaaaaaaaaaaaaaaa",
        collection: "site.standard.document",
        createdAt: now,
        indexedAt: now,
        publicationSite: nil,
        render: ContentRenderFields(title: "Hello", publishedAt: ISO8601DateFormatter().string(from: now)),
        expiresAt: now.addingTimeInterval(3_600)
      )
    )
    let acknowledgements = AcknowledgementRecorder()
    let fixtureJSON = #"{"id":51,"type":"record","record":{"live":true,"rev":"rev-1","did":"did:plc:aaaaaaaaaaaaaaaaaaaaaaaa","collection":"site.standard.document","rkey":"article","action":"create","cid":"bafyrecord","record":{"$type":"site.standard.document","title":"Hello","publishedAt":"2026-07-22T00:00:00Z"}}}"#

    try await fixture.consumer.process(fixtureJSON) { id in
      await acknowledgements.record(id)
    }
    let state = try await fixture.store.fetchTapRepositorySyncState(
      environment: "test",
      repoDid: "did:plc:aaaaaaaaaaaaaaaaaaaaaaaa"
    )
    #expect(state?.parityStatus == .matched)
    #expect(state?.matchedEventCount == 1)
    #expect(try await fixture.store.hasProcessedTapEvent(environment: "test", eventId: 51))
    #expect(await acknowledgements.values == [51])

    // At-least-once redelivery is acknowledged without double-counting parity.
    try await fixture.consumer.process(fixtureJSON) { id in
      await acknowledgements.record(id)
    }
    let redeliveredState = try await fixture.store.fetchTapRepositorySyncState(
      environment: "test",
      repoDid: "did:plc:aaaaaaaaaaaaaaaaaaaaaaaa"
    )
    #expect(redeliveredState?.matchedEventCount == 1)
    #expect(await acknowledgements.values == [51, 51])
    _ = await fixture.telemetry.flushOnce()
    #expect(
      await fixture.telemetryRecorder.metrics(named: "socialwire.ingestion.events_total").isEmpty
    )
    #expect(
      await fixture.telemetryRecorder
        .metrics(named: "socialwire.ingestion.acknowledged_events_total")
        .reduce(0) { $0 + $1.value } == 2
    )
  }

  @Test("authoritative identity event removes inactive account content")
  func authoritativeIdentityLifecycle() async throws {
    let fixture = try makeFixture(mode: .authoritative)
    let now = Date()
    let uri = "at://did:plc:aaaaaaaaaaaaaaaaaaaaaaaa/site.standard.document/article"
    try await fixture.store.upsertContentItem(
      IndexedContentItem(
        uri: uri,
        cid: "bafyrecord",
        authorDid: "did:plc:aaaaaaaaaaaaaaaaaaaaaaaa",
        collection: "site.standard.document",
        createdAt: now,
        indexedAt: now,
        publicationSite: nil,
        render: ContentRenderFields(title: "Gone", publishedAt: ISO8601DateFormatter().string(from: now)),
        expiresAt: now.addingTimeInterval(3_600)
      )
    )
    let acknowledgements = AcknowledgementRecorder()
    let fixtureJSON = #"{"id":77,"type":"identity","identity":{"did":"did:plc:aaaaaaaaaaaaaaaaaaaaaaaa","handle":"alice.test","is_active":false,"status":"deleted"}}"#

    try await fixture.consumer.process(fixtureJSON) { id in
      await acknowledgements.record(id)
    }

    #expect(try await fixture.store.fetchContentIdentity(uri: uri) == nil)
    let state = try await fixture.store.fetchTapRepositorySyncState(
      environment: "test",
      repoDid: "did:plc:aaaaaaaaaaaaaaaaaaaaaaaa"
    )
    #expect(state?.accountStatus == .deleted)
    #expect(state?.parityStatus == .authoritative)
    #expect(await acknowledgements.values == [77])
    _ = await fixture.telemetry.flushOnce()
    let indexedMetrics = await fixture.telemetryRecorder.metrics(
      named: "socialwire.ingestion.events_total"
    )
    #expect(indexedMetrics.count == 1)
    #expect(indexedMetrics.first?.dimensions["event_type"] == "identity")
    #expect(indexedMetrics.first?.dimensions["collection"] == nil)
    #expect(indexedMetrics.first?.dimensions["operation"] == nil)
  }

  @Test("authoritative record atomically enqueues projection repair before ack")
  func authoritativeRecordEnqueuesRepair() async throws {
    let fixture = try makeFixture(mode: .authoritative)
    let acknowledgements = AcknowledgementRecorder()
    let fixtureJSON = #"{"id":81,"type":"record","record":{"live":true,"rev":"rev-81","did":"did:plc:aaaaaaaaaaaaaaaaaaaaaaaa","collection":"site.standard.document","rkey":"article","action":"create","cid":"bafy81","record":{"$type":"site.standard.document","title":"Durable","publishedAt":"2026-07-22T00:00:00Z"}}}"#

    try await fixture.consumer.process(fixtureJSON) { id in
      await acknowledgements.record(id)
    }

    let uri = "at://did:plc:aaaaaaaaaaaaaaaaaaaaaaaa/site.standard.document/article"
    #expect(try await fixture.store.fetchContentIdentity(uri: uri)?.cid == "bafy81")
    let repair = try await fixture.store.claimProjectionRepair(
      environment: "test",
      workerId: "repair-test",
      leaseUntil: Date().addingTimeInterval(60),
      at: Date()
    )
    #expect(repair?.eventId == 81)
    #expect(repair?.action == "upsert")
    #expect(await acknowledgements.values == [81])
    _ = await fixture.telemetry.flushOnce()
    let indexedMetrics = await fixture.telemetryRecorder.metrics(
      named: "socialwire.ingestion.events_total"
    )
    #expect(indexedMetrics.count == 1)
    #expect(indexedMetrics.first?.dimensions["event_type"] == "record")
    #expect(indexedMetrics.first?.dimensions["collection"] == "site.standard.document")
    #expect(indexedMetrics.first?.dimensions["operation"] == "create")
    if let repair {
      try await fixture.store.completeProjectionRepair(
        environment: "test",
        id: repair.id,
        workerId: "repair-test"
      )
    }
    #expect(
      try await fixture.store.claimProjectionRepair(
        environment: "test",
        workerId: "repair-test",
        leaseUntil: Date().addingTimeInterval(60),
        at: Date()
      ) == nil
    )
  }

  @Test("unrelated matches do not erase durable shadow discrepancies")
  func parityDiscrepanciesRequireSameRecordRevalidation() async throws {
    let fixture = try makeFixture(mode: .shadow)
    let now = Date()
    func item(rkey: String, cid: String) -> IndexedContentItem {
      IndexedContentItem(
        uri: "at://did:plc:aaaaaaaaaaaaaaaaaaaaaaaa/site.standard.document/\(rkey)",
        cid: cid,
        authorDid: "did:plc:aaaaaaaaaaaaaaaaaaaaaaaa",
        collection: "site.standard.document",
        createdAt: now,
        indexedAt: now,
        publicationSite: nil,
        render: ContentRenderFields(title: rkey, publishedAt: "2026-07-22T00:00:00Z"),
        expiresAt: now.addingTimeInterval(3_600)
      )
    }
    try await fixture.store.upsertContentItem(item(rkey: "a", cid: "old-a"))
    try await fixture.store.upsertContentItem(item(rkey: "b", cid: "good-b"))
    let acknowledgements = AcknowledgementRecorder()

    try await fixture.consumer.process(
      #"{"id":91,"type":"record","record":{"live":true,"rev":"rev-91","did":"did:plc:aaaaaaaaaaaaaaaaaaaaaaaa","collection":"site.standard.document","rkey":"a","action":"update","cid":"good-a","record":{"$type":"site.standard.document","title":"A"}}}"#
    ) { await acknowledgements.record($0) }
    #expect(
      try await fixture.store.fetchTapRepositorySyncState(
        environment: "test", repoDid: "did:plc:aaaaaaaaaaaaaaaaaaaaaaaa")?.parityStatus == .mismatch
    )

    try await fixture.consumer.process(
      #"{"id":92,"type":"record","record":{"live":true,"rev":"rev-92","did":"did:plc:aaaaaaaaaaaaaaaaaaaaaaaa","collection":"site.standard.document","rkey":"b","action":"update","cid":"good-b","record":{"$type":"site.standard.document","title":"B"}}}"#
    ) { await acknowledgements.record($0) }
    #expect(
      try await fixture.store.fetchTapRepositorySyncState(
        environment: "test", repoDid: "did:plc:aaaaaaaaaaaaaaaaaaaaaaaa")?.parityStatus == .mismatch
    )
    #expect(
      try await fixture.store.listTapParityDiscrepancies(
        environment: "test", repoDid: "did:plc:aaaaaaaaaaaaaaaaaaaaaaaa").map(\.status) == [.open]
    )

    try await fixture.store.upsertContentItem(item(rkey: "a", cid: "good-a"))
    try await fixture.consumer.process(
      #"{"id":93,"type":"record","record":{"live":true,"rev":"rev-93","did":"did:plc:aaaaaaaaaaaaaaaaaaaaaaaa","collection":"site.standard.document","rkey":"a","action":"update","cid":"good-a","record":{"$type":"site.standard.document","title":"A"}}}"#
    ) { await acknowledgements.record($0) }

    let discrepancies = try await fixture.store.listTapParityDiscrepancies(
      environment: "test", repoDid: "did:plc:aaaaaaaaaaaaaaaaaaaaaaaa")
    #expect(discrepancies.map(\.status) == [.resolved])
    #expect(discrepancies.first?.resolutionEventId == 93)
    #expect(
      try await fixture.store.fetchTapRepositorySyncState(
        environment: "test", repoDid: "did:plc:aaaaaaaaaaaaaaaaaaaaaaaa")?.parityStatus == .matched
    )
  }

  @Test("projection repair leases and mutations remain environment isolated")
  func projectionRepairEnvironmentIsolation() async throws {
    let fixture = try makeFixture(mode: .authoritative)
    let now = Date()
    func item(environment: String) -> IndexedContentItem {
      IndexedContentItem(
        uri: "at://did:plc:aaaaaaaaaaaaaaaaaaaaaaaa/site.standard.document/\(environment)",
        cid: "bafy-\(environment)",
        authorDid: "did:plc:aaaaaaaaaaaaaaaaaaaaaaaa",
        collection: "site.standard.document",
        createdAt: now,
        indexedAt: now,
        publicationSite: nil,
        render: ContentRenderFields(title: environment, publishedAt: "2026-07-22T00:00:00Z"),
        expiresAt: now.addingTimeInterval(3_600)
      )
    }

    try await fixture.store.applyTapContentMutation(
      .upsert(item(environment: "prod")),
      environment: "prod",
      eventId: 900,
      repoRev: "prod-rev",
      eventTime: now,
      observedAt: now
    )
    try await fixture.store.applyTapContentMutation(
      .upsert(item(environment: "dev")),
      environment: "dev",
      eventId: 900,
      repoRev: "dev-rev",
      eventTime: now,
      observedAt: now
    )

    let prodRepair = try #require(
      try await fixture.store.claimProjectionRepair(
        environment: "prod",
        workerId: "prod-worker",
        leaseUntil: now.addingTimeInterval(60),
        at: now
      )
    )
    #expect(prodRepair.environment == "prod")
    await #expect(throws: AppViewProjectionRepairError.self) {
      try await fixture.store.completeProjectionRepair(
        environment: "dev",
        id: prodRepair.id,
        workerId: "prod-worker"
      )
    }
    try await fixture.store.completeProjectionRepair(
      environment: "prod",
      id: prodRepair.id,
      workerId: "prod-worker"
    )

    let devRepair = try #require(
      try await fixture.store.claimProjectionRepair(
        environment: "dev",
        workerId: "dev-worker",
        leaseUntil: now.addingTimeInterval(60),
        at: now
      )
    )
    #expect(devRepair.environment == "dev")
    #expect(devRepair.uri.hasSuffix("/dev"))
  }

  @Test("projection repair backlog measures lifecycle and environment independently")
  func projectionRepairBacklogSnapshot() async throws {
    let fixture = try makeFixture(mode: .authoritative)
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func item(environment: String) -> IndexedContentItem {
      IndexedContentItem(
        uri: "at://did:plc:aaaaaaaaaaaaaaaaaaaaaaaa/site.standard.document/\(environment)",
        cid: "bafy-\(environment)",
        authorDid: "did:plc:aaaaaaaaaaaaaaaaaaaaaaaa",
        collection: "site.standard.document",
        createdAt: now,
        indexedAt: now,
        publicationSite: nil,
        render: ContentRenderFields(title: environment, publishedAt: "2027-01-15T08:00:00Z"),
        expiresAt: now.addingTimeInterval(3_600)
      )
    }

    for environment in ["prod", "dev"] {
      try await fixture.store.applyTapContentMutation(
        .upsert(item(environment: environment)),
        environment: environment,
        eventId: 901,
        repoRev: "\(environment)-rev",
        eventTime: now,
        observedAt: now
      )
    }

    let initialProd = try await fixture.store.projectionRepairBacklog(
      environment: "prod",
      at: now.addingTimeInterval(10)
    )
    #expect(initialProd.queuedCount == 1)
    #expect(initialProd.runningCount == 0)
    #expect(initialProd.failedCount == 0)
    #expect(initialProd.oldestActionableAt == now)
    #expect(initialProd.oldestActionableAgeSeconds == 10)

    var repair = try #require(
      try await fixture.store.claimProjectionRepair(
        environment: "prod",
        workerId: "prod-worker",
        leaseUntil: now.addingTimeInterval(60),
        at: now
      )
    )
    let runningProd = try await fixture.store.projectionRepairBacklog(
      environment: "prod",
      at: now.addingTimeInterval(1)
    )
    #expect(runningProd.queuedCount == 0)
    #expect(runningProd.runningCount == 1)
    #expect(runningProd.failedCount == 0)

    for attempt in 1...5 {
      let attemptAt = now.addingTimeInterval(TimeInterval(attempt))
      try await fixture.store.failProjectionRepair(
        environment: "prod",
        id: repair.id,
        workerId: "prod-worker",
        errorCategory: "test_failure",
        retryAt: attemptAt,
        at: attemptAt
      )
      if attempt < 5 {
        repair = try #require(
          try await fixture.store.claimProjectionRepair(
            environment: "prod",
            workerId: "prod-worker",
            leaseUntil: attemptAt.addingTimeInterval(60),
            at: attemptAt
          )
        )
      }
    }

    let failedProd = try await fixture.store.projectionRepairBacklog(
      environment: "prod",
      at: now.addingTimeInterval(10)
    )
    #expect(failedProd.queuedCount == 0)
    #expect(failedProd.runningCount == 0)
    #expect(failedProd.failedCount == 1)
    #expect(failedProd.oldestActionableAt == now)
    #expect(failedProd.oldestActionableAgeSeconds == 10)

    let dev = try await fixture.store.projectionRepairBacklog(
      environment: "dev",
      at: now.addingTimeInterval(10)
    )
    #expect(dev.queuedCount == 1)
    #expect(dev.runningCount == 0)
    #expect(dev.failedCount == 0)

    let empty = try await fixture.store.projectionRepairBacklog(
      environment: "staging",
      at: now.addingTimeInterval(10)
    )
    #expect(empty.queuedCount == 0)
    #expect(empty.runningCount == 0)
    #expect(empty.failedCount == 0)
    #expect(empty.oldestActionableAt == nil)
    #expect(empty.oldestActionableAgeSeconds == nil)
  }

  @Test("invalid events are never acknowledged")
  func invalidEventIsNotAcknowledged() async throws {
    let fixture = try makeFixture(mode: .shadow)
    let acknowledgements = AcknowledgementRecorder()
    await #expect(throws: TapEventParseError.self) {
      try await fixture.consumer.process(#"{"id":1,"type":"identity","identity":{}}"#) { id in
        await acknowledgements.record(id)
      }
    }
    #expect(await acknowledgements.values.isEmpty)
  }

  @Test("enabled configuration requires environment and admin authentication")
  func configurationValidation() throws {
    #expect(throws: TapConsumerConfigurationError.missingEnvironment) {
      try TapConsumerConfiguration.fromEnvironment([
        "TAP_CONSUMER_MODE": "shadow",
        "TAP_ADMIN_PASSWORD": "secret",
      ])
    }
    #expect(throws: TapConsumerConfigurationError.missingAdminPassword) {
      try TapConsumerConfiguration.fromEnvironment([
        "TAP_CONSUMER_MODE": "shadow",
        "APP_ENV": "dev",
      ])
    }
    let config = try TapConsumerConfiguration.fromEnvironment([
      "TAP_CONSUMER_MODE": "shadow",
      "APP_ENV": "dev",
      "TAP_ADMIN_PASSWORD": "secret",
      "TAP_BASE_URL": "https://tap.internal",
      "TAP_COLLECTION_FILTERS": "site.standard.document,com.standard.document",
    ])
    #expect(config.channelURL.absoluteString == "wss://tap.internal/channel")
    #expect(config.collections == ["site.standard.document"])
  }

  private func makeFixture(
    mode: TapConsumerMode
  ) throws -> (
    store: SQLiteThinAppViewStore,
    consumer: TapConsumer,
    telemetry: OperationsTelemetryBuffer,
    telemetryRecorder: TelemetrySignalRecorder
  ) {
    let path = NSTemporaryDirectory() + "tap-consumer-\(UUID().uuidString).sqlite"
    let logger = Logger(label: "tap-consumer.test")
    let store = try SQLiteThinAppViewStore(path: path, logger: logger)
    let config = TapConsumerConfiguration(
      mode: mode,
      environment: "test",
      baseURL: URL(string: "http://127.0.0.1:2480")!,
      channelURL: URL(string: "ws://127.0.0.1:2480/channel")!,
      adminPassword: "test-secret"
    )
    let indexer = ThinAppViewIndexer(
      store: store,
      config: ThinAppViewConfig.fromEnvironment(["ENABLE_THIN_APPVIEW": "true"]),
      logger: logger
    )
    let telemetryRecorder = TelemetrySignalRecorder()
    let telemetry = OperationsTelemetryBuffer(
      capacity: 100,
      batchSize: 100,
      logger: logger
    ) { signals in
      await telemetryRecorder.append(signals)
    }
    let consumer = TapConsumer(
      store: store,
      indexer: indexer,
      configuration: config,
      telemetry: telemetry,
      instanceId: "test-worker",
      logger: logger
    )
    return (store, consumer, telemetry, telemetryRecorder)
  }
}

private actor AcknowledgementRecorder {
  private(set) var values: [Int64] = []

  func record(_ id: Int64) {
    values.append(id)
  }
}

private actor TelemetrySignalRecorder {
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
