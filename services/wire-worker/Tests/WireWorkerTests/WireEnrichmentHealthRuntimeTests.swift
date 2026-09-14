import Foundation
import Logging
import Testing

@testable import WireWorkerCore

@Suite("Independent enrichment diagnostics")
struct WireEnrichmentHealthRuntimeTests {
  @Test("success, unavailable and failures all retain the fifteen-minute delay")
  func pacingAndAvailability() async throws {
    let store = EnrichmentDiagnosticStore(outcomes: [.failure, .unavailable, .success])
    let timing = EnrichmentDiagnosticTiming()
    let logs = EnrichmentDiagnosticLogs()
    try await WireEnrichmentHealthRuntime.run(
      store: store, logger: Logger(label: "health-test") { _ in EnrichmentDiagnosticLogHandler(logs: logs) },
      clock: timing, sleeper: timing, iterationLimit: 3)
    #expect(await timing.delays == [60_000, 900_000, 900_000, 900_000])
    #expect(await store.observations == [60, 960, 1_860].map(Date.init(timeIntervalSince1970:)))
    let events = logs.events()
    #expect(events.count == 3)
    #expect(events[0]["available"] == "false")
    #expect(events[0]["failure_category"] == "collection_failed")
    #expect(events[0]["attempted_at"] == Date(timeIntervalSince1970: 60).ISO8601Format())
    #expect(events[0]["observed_at"] == nil && events[0]["metadata_hits"] == nil)
    #expect(events[1]["available"] == "false" && events[1]["metadata_hits"] == nil)
    #expect(events[2]["available"] == "true" && events[2]["metadata_hits"] == "7")
    #expect(events[2]["observed_at"] == Date(timeIntervalSince1970: 1_860).ISO8601Format())
    #expect(!events.description.contains("private database failure"))
  }

  @Test("a slow sample keeps its observation time and waits before the next scan")
  func noCatchUpOrRetimestamp() async throws {
    let timing = EnrichmentDiagnosticTiming()
    let store = EnrichmentDiagnosticStore(outcomes: [.success, .success], timing: timing)
    let logs = EnrichmentDiagnosticLogs()
    try await WireEnrichmentHealthRuntime.run(
      store: store, logger: Logger(label: "health-test") { _ in EnrichmentDiagnosticLogHandler(logs: logs) },
      clock: timing, sleeper: timing, iterationLimit: 2)
    // Each mock collection takes twenty minutes: even then it waits another
    // fifteen minutes and keeps the original as-of time on the resulting log.
    #expect(await store.observations == [60, 2_160].map(Date.init(timeIntervalSince1970:)))
    #expect(await timing.delays == [60_000, 900_000, 900_000])
    #expect(logs.events().map { $0["observed_at"] } == [60, 2_160].map {
      Date(timeIntervalSince1970: $0).ISO8601Format()
    })
  }

  @Test("cancellation stops collection without a retry or unavailable sample")
  func cancellation() async throws {
    let store = EnrichmentDiagnosticStore(outcomes: [.canceled])
    let timing = EnrichmentDiagnosticTiming()
    let logs = EnrichmentDiagnosticLogs()
    await #expect(throws: CancellationError.self) {
      try await WireEnrichmentHealthRuntime.run(
        store: store, logger: Logger(label: "health-test") { _ in EnrichmentDiagnosticLogHandler(logs: logs) },
        clock: timing, sleeper: timing, iterationLimit: 2)
    }
    #expect(await store.observations.count == 1)
    #expect(await timing.delays == [60_000])
    #expect(logs.events().isEmpty)
  }

  @Test("metadata batches do not launch logging-only corpus scans")
  func batchDoesNotCollectHealth() async throws {
    let store = EnrichmentDiagnosticStore(outcomes: [.failure])
    let enricher = WireLinkMetadataEnricher(
      store: store, client: EnrichmentDiagnosticFetchClient(), logger: Logger(label: "health-test"),
      batchSize: 10, maximumConcurrentFetches: 2)
    #expect(try await enricher.runBatch(asOf: Date()) == 0)
    #expect(await store.claims == 1)
    #expect(await store.observations.isEmpty)
  }
}

private actor EnrichmentDiagnosticTiming: WireInboxDrainClock, WireInboxDrainSleeping {
  private var seconds: TimeInterval = 0
  var delays: [Int] = []
  func now() -> Date { Date(timeIntervalSince1970: seconds) }
  func sleep(milliseconds: Int) {
    delays.append(milliseconds)
    seconds += Double(milliseconds) / 1_000
  }
  func advance() { seconds += 1_200 }
}

private actor EnrichmentDiagnosticStore: WireLinkMetadataStoring {
  enum Outcome: Sendable { case failure, unavailable, success, canceled }
  struct Failure: Error, CustomStringConvertible {
    var description: String { "private database failure" }
  }
  private var outcomes: [Outcome]
  private let timing: EnrichmentDiagnosticTiming?
  var observations: [Date] = []
  var claims = 0
  init(outcomes: [Outcome], timing: EnrichmentDiagnosticTiming? = nil) {
    self.outcomes = outcomes
    self.timing = timing
  }
  func healthSnapshot(asOf: Date) async throws -> WireEnrichmentHealthSnapshot? {
    observations.append(asOf)
    await timing?.advance()
    switch outcomes.removeFirst() {
    case .failure: throw Failure()
    case .unavailable: return nil
    case .canceled: throw CancellationError()
    case .success:
      return WireEnrichmentHealthSnapshot(
        metadataHitCount: 7, metadataStaleCount: 2, metadataMissCount: 3,
        metadataFailureCount: 1, oldestFailureAgeSeconds: 4,
        peopleEligibleCount: 5, peopleFreshCount: 6)
    }
  }
  func claimDue(limit: Int, asOf: Date) -> [WireLinkMetadataTarget] { claims += 1; return [] }
  func seedEmbedded(canonicalKey: String, metadata: WireLinkMetadata, asOf: Date) {}
  func renewClaim(_ target: WireLinkMetadataTarget, asOf: Date) -> WireLinkMetadataTarget? { nil }
  func markNotModified(canonicalKey: String, etag: String?, lastModified: String?, asOf: Date, leaseExpiresAt: Date?) {}
  func store(canonicalKey: String, metadata: WireLinkMetadata, asOf: Date, leaseExpiresAt: Date?) {}
  func markFailure(canonicalKey: String, negative: Bool, asOf: Date, leaseExpiresAt: Date?) {}
}

private struct EnrichmentDiagnosticFetchClient: WireLinkMetadataFetching {
  func fetch(_ target: WireLinkMetadataTarget) async throws -> WireLinkMetadataFetchResult {
    throw CancellationError()
  }
}

private final class EnrichmentDiagnosticLogs: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [[String: String]] = []
  func append(_ event: LogEvent) {
    lock.lock()
    defer { lock.unlock() }
    values.append(event.metadata?.mapValues(\.description) ?? [:])
  }
  func events() -> [[String: String]] {
    lock.lock()
    defer { lock.unlock() }
    return values
  }
}

private struct EnrichmentDiagnosticLogHandler: LogHandler {
  var metadataProvider: Logger.MetadataProvider?
  var metadata: Logger.Metadata = [:]
  var logLevel: Logger.Level = .info
  let logs: EnrichmentDiagnosticLogs
  subscript(metadataKey key: String) -> Logger.Metadata.Value? {
    get { metadata[key] }
    set { metadata[key] = newValue }
  }
  func log(event: LogEvent) { logs.append(event) }
}
