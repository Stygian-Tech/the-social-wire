import Foundation
import Logging
import Testing

@testable import WireWorkerCore

@Suite("Wire metadata scheduling")
struct WireMetadataSchedulingTests {
  @Test("completion clocks preserve full retry and freshness intervals", arguments: [FetchOutcome.success, .notModified, .failure, .negative])
  func completionTime(outcome: FetchOutcome) async throws {
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    let clock = MetadataTestClock(start)
    let store = SchedulingMetadataStore(count: 1)
    let client = SchedulingMetadataClient(clock: clock, outcome: outcome, elapsed: 120)
    let enricher = WireLinkMetadataEnricher(
      store: store, client: client, logger: Logger(label: "metadata.scheduling.tests"),
      batchSize: 1, maximumConcurrentFetches: 1, now: { clock.now })
    #expect(try await enricher.runBatch(asOf: start) == 1)
    let writes = await store.writes
    #expect(writes.count == 1)
    #expect(writes.first?.time == start.addingTimeInterval(120))
    #expect(writes.first?.lease == start.addingTimeInterval(300))
    #expect(writes.first?.outcome == outcome)
  }

  @Test("batches longer than a lease renew queued ownership without repeating claim scans")
  func slowBatch() async throws {
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    let clock = MetadataTestClock(start)
    let store = SchedulingMetadataStore(count: 8)
    let client = SchedulingMetadataClient(clock: clock, outcome: .success, elapsed: 100)
    let enricher = WireLinkMetadataEnricher(
      store: store, client: client, logger: Logger(label: "metadata.scheduling.tests"),
      batchSize: 8, maximumConcurrentFetches: 1, now: { clock.now })
    #expect(try await enricher.runBatch(asOf: start) == 8)
    let claims = await store.claims
    #expect(claims.map(\.limit) == [8])
    #expect(claims.map(\.time) == [start])
    #expect(await store.renewals.count == 7)
    #expect(await client.expiredAtStart == 0)
    #expect(await store.writes.allSatisfy { $0.time < $0.lease! })
  }

  @Test("reclaimed queued target is not fetched or completed")
  func expiredBeforeFetch() async throws {
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    let clock = MetadataTestClock(start)
    let store = SchedulingMetadataStore(count: 1, renewalAllowed: false, claimDelay: { clock.advance(301) })
    let client = SchedulingMetadataClient(clock: clock, outcome: .success, elapsed: 0)
    let enricher = WireLinkMetadataEnricher(
      store: store, client: client, logger: Logger(label: "metadata.scheduling.tests"),
      batchSize: 1, maximumConcurrentFetches: 1, now: { clock.now })
    _ = try await enricher.runBatch(asOf: start)
    #expect(await client.fetchCount == 0)
    #expect(await store.writes.isEmpty)
  }

  @Test("whole-fetch timeout cancels transport and schedules a transient retry")
  func timeout() async throws {
    let store = SchedulingMetadataStore(count: 1)
    let client = TimeoutMetadataClient()
    let enricher = WireLinkMetadataEnricher(
      store: store, client: client, logger: Logger(label: "metadata.scheduling.tests"),
      batchSize: 1, maximumConcurrentFetches: 1, fetchTimeout: .milliseconds(10))
    #expect(try await enricher.runBatch(asOf: Date()) == 1)
    #expect(await client.cancelled)
    #expect(await store.writes.map(\.outcome) == [.failure])
  }
}

private final class MetadataTestClock: @unchecked Sendable {
  private let lock = NSLock()
  private var value: Date
  init(_ value: Date) { self.value = value }
  var now: Date { lock.withLock { value } }
  func advance(_ seconds: TimeInterval) { lock.withLock { value.addTimeInterval(seconds) } }
}

private actor SchedulingMetadataStore: WireLinkMetadataStoring {
  struct Claim { let limit: Int; let time: Date }
  struct Write { let outcome: FetchOutcome; let time: Date; let lease: Date? }
  var claims: [Claim] = []
  var renewals: [String] = []
  let renewalAllowed: Bool
  var writes: [Write] = []
  private var remaining: Int
  private let claimDelay: @Sendable () -> Void
  init(count: Int, renewalAllowed: Bool = true, claimDelay: @escaping @Sendable () -> Void = {}) {
    remaining = count
    self.renewalAllowed = renewalAllowed
    self.claimDelay = claimDelay
  }
  func claimDue(limit: Int, asOf: Date) -> [WireLinkMetadataTarget] {
    claims.append(Claim(limit: limit, time: asOf))
    let count = min(limit, remaining)
    let targets = (0..<count).map { offset in
      WireLinkMetadataTarget(canonicalKey: "key-\(remaining - offset)",
        canonicalURL: "https://example.test/article", etag: nil, lastModified: nil,
        leaseExpiresAt: asOf.addingTimeInterval(300))
    }
    remaining -= count
    claimDelay()
    return targets
  }
  func renewClaim(_ target: WireLinkMetadataTarget, asOf: Date) -> WireLinkMetadataTarget? {
    renewals.append(target.canonicalKey)
    guard renewalAllowed else { return nil }
    return WireLinkMetadataTarget(canonicalKey: target.canonicalKey, canonicalURL: target.canonicalURL,
      etag: target.etag, lastModified: target.lastModified, leaseExpiresAt: asOf.addingTimeInterval(300))
  }
  func seedEmbedded(canonicalKey: String, metadata: WireLinkMetadata, asOf: Date) {}
  func markNotModified(canonicalKey: String, etag: String?, lastModified: String?, asOf: Date, leaseExpiresAt: Date?) {
    writes.append(Write(outcome: .notModified, time: asOf, lease: leaseExpiresAt))
  }
  func store(canonicalKey: String, metadata: WireLinkMetadata, asOf: Date, leaseExpiresAt: Date?) {
    writes.append(Write(outcome: .success, time: asOf, lease: leaseExpiresAt))
  }
  func markFailure(canonicalKey: String, negative: Bool, asOf: Date, leaseExpiresAt: Date?) {
    writes.append(Write(outcome: negative ? .negative : .failure, time: asOf, lease: leaseExpiresAt))
  }
}

private actor SchedulingMetadataClient: WireLinkMetadataFetching {
  let clock: MetadataTestClock
  let outcome: FetchOutcome
  let elapsed: TimeInterval
  var fetchCount = 0
  var expiredAtStart = 0
  init(clock: MetadataTestClock, outcome: FetchOutcome, elapsed: TimeInterval) {
    self.clock = clock; self.outcome = outcome; self.elapsed = elapsed
  }
  func fetch(_ target: WireLinkMetadataTarget) throws -> WireLinkMetadataFetchResult {
    fetchCount += 1
    if let expiry = target.leaseExpiresAt, expiry <= clock.now { expiredAtStart += 1 }
    clock.advance(elapsed)
    try outcome.check()
    if outcome == .notModified { return .notModified(etag: nil, lastModified: nil) }
    return .metadata(WireLinkMetadata(canonicalURL: target.canonicalURL, title: "Title",
      description: nil, imageURL: nil, siteName: nil, authorName: nil, publishedAt: nil,
      iconURL: nil, etag: nil, lastModified: nil, source: .openGraph))
  }
}

private actor TimeoutMetadataClient: WireLinkMetadataFetching {
  var cancelled = false
  func fetch(_ target: WireLinkMetadataTarget) async throws -> WireLinkMetadataFetchResult {
    do { try await Task.sleep(for: .seconds(60)) }
    catch { cancelled = true; throw error }
    return .notModified(etag: nil, lastModified: nil)
  }
}
