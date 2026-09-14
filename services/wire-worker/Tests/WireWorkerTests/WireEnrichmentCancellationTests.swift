import Foundation
import Logging
import Testing

@testable import WireWorkerCore

@Suite("Wire enrichment cancellation")
struct WireEnrichmentCancellationTests {
  @Test("cancelled metadata batches stop fetching and do not write outcomes", arguments: FetchOutcome.allCases)
  func cancelMetadata(outcome: FetchOutcome) async throws {
    let gate = FetchGate()
    let store = MetadataCancellationStore()
    let client = MetadataCancellationClient(gate: gate, outcome: outcome)
    let enricher = WireLinkMetadataEnricher(
      store: store, client: client, logger: Logger(label: "enrichment.tests"),
      batchSize: 3, maximumConcurrentFetches: 1)
    let task = Task { try await enricher.runBatch(asOf: Date()) }
    var started = gate.started.makeAsyncIterator()
    _ = await started.next()
    task.cancel()
    await gate.release()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(await client.fetchCount == 1)
    #expect(await store.writes.isEmpty)
  }

  @Test("cancelled profile batches stop fetching and do not write outcomes", arguments: FetchOutcome.allCases)
  func cancelProfiles(outcome: FetchOutcome) async throws {
    let gate = FetchGate()
    let store = ProfileCancellationStore()
    let client = ProfileCancellationClient(gate: gate, outcome: outcome)
    let enricher = WireTalkedAccountProfileEnricher(
      store: store, client: client, logger: Logger(label: "enrichment.tests"),
      batchSize: 3, maximumConcurrentFetches: 1)
    let task = Task { try await enricher.runBatch(asOf: Date()) }
    var started = gate.started.makeAsyncIterator()
    _ = await started.next()
    task.cancel()
    await gate.release()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(await client.fetchCount == 1)
    #expect(await store.writes.isEmpty)
  }

  @Test("ordinary metadata failures preserve negative versus retry policy", arguments: [FetchOutcome.negative, .failure])
  func metadataFailures(outcome: FetchOutcome) async throws {
    let store = MetadataCancellationStore()
    let client = MetadataCancellationClient(gate: nil, outcome: outcome)
    let enricher = WireLinkMetadataEnricher(
      store: store, client: client, logger: Logger(label: "enrichment.tests"),
      batchSize: 3, maximumConcurrentFetches: 1)
    #expect(try await enricher.runBatch(asOf: Date()) == 3)
    #expect(await store.writes == Array(repeating: outcome == .negative ? "negative" : "retry", count: 3))
  }

  @Test("ordinary profile failures preserve retries")
  func profileFailures() async throws {
    let store = ProfileCancellationStore()
    let client = ProfileCancellationClient(gate: nil, outcome: .failure)
    let enricher = WireTalkedAccountProfileEnricher(
      store: store, client: client, logger: Logger(label: "enrichment.tests"),
      batchSize: 3, maximumConcurrentFetches: 1)
    #expect(try await enricher.runBatch(asOf: Date()) == 3)
    #expect(await store.writes == Array(repeating: "retry", count: 3))
  }

  @Test("already cancelled batches do not claim work")
  func cancelledBeforeClaim() async throws {
    let metadata = MetadataCancellationStore()
    let profiles = ProfileCancellationStore()
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      let metadataEnricher = WireLinkMetadataEnricher(
        store: metadata, client: MetadataCancellationClient(gate: nil, outcome: .success),
        logger: Logger(label: "enrichment.tests"), batchSize: 3, maximumConcurrentFetches: 1)
      let profileEnricher = WireTalkedAccountProfileEnricher(
        store: profiles, client: ProfileCancellationClient(gate: nil, outcome: .success),
        logger: Logger(label: "enrichment.tests"), batchSize: 3, maximumConcurrentFetches: 1)
      await #expect(throws: CancellationError.self) { try await metadataEnricher.runBatch(asOf: Date()) }
      await #expect(throws: CancellationError.self) { try await profileEnricher.runBatch(asOf: Date()) }
    }
    await task.value
    #expect(await metadata.claimCount == 0)
    #expect(await profiles.claimCount == 0)
  }
}

enum FetchOutcome: CaseIterable, Sendable {
  case success, notModified, failure, negative, cancellation

  func check() throws {
    switch self {
    case .success, .notModified: return
    case .failure: throw WireLinkMetadataQueryError.transientStatus(503)
    case .negative: throw WireLinkMetadataQueryError.invalidResponse
    case .cancellation: throw CancellationError()
    }
  }
}

/// Deliberately ignores cancellation until released, modeling a transport returning a late
/// response or a non-CancellationError after its enclosing lease has been cancelled.
private actor FetchGate {
  nonisolated let started: AsyncStream<Void>
  private let startedContinuation: AsyncStream<Void>.Continuation
  private var continuation: CheckedContinuation<Void, Never>?
  private var released = false

  init() {
    (started, startedContinuation) = AsyncStream.makeStream(of: Void.self)
  }

  func wait() async {
    guard !released else { return }
    await withCheckedContinuation { continuation in
      self.continuation = continuation
      startedContinuation.yield(())
    }
  }

  func release() {
    released = true
    continuation?.resume()
    continuation = nil
  }
}

private actor MetadataCancellationClient: WireLinkMetadataFetching {
  let gate: FetchGate?
  let outcome: FetchOutcome
  var fetchCount = 0
  init(gate: FetchGate?, outcome: FetchOutcome) { self.gate = gate; self.outcome = outcome }

  func fetch(_ target: WireLinkMetadataTarget) async throws -> WireLinkMetadataFetchResult {
    fetchCount += 1
    await gate?.wait()
    try outcome.check()
    if outcome == .notModified { return .notModified(etag: nil, lastModified: nil) }
    return .metadata(WireLinkMetadata(
      canonicalURL: target.canonicalURL, title: "Title", description: nil, imageURL: nil,
      siteName: nil, authorName: nil, publishedAt: nil, iconURL: nil, etag: nil,
      lastModified: nil, source: .openGraph))
  }
}

private actor ProfileCancellationClient: WireTalkedAccountProfileFetching {
  let gate: FetchGate?
  let outcome: FetchOutcome
  var fetchCount = 0
  init(gate: FetchGate?, outcome: FetchOutcome) { self.gate = gate; self.outcome = outcome }

  func fetch(did: String) async throws -> WireTalkedAccountProfile {
    fetchCount += 1
    await gate?.wait()
    try outcome.check()
    return WireTalkedAccountProfile(did: did, handle: "example.test", displayName: nil, avatarURL: nil, description: nil)
  }
}

private actor MetadataCancellationStore: WireLinkMetadataStoring {
  var claimCount = 0
  var writes: [String] = []
  func claimDue(limit: Int, asOf: Date) -> [WireLinkMetadataTarget] {
    claimCount += 1
    return (0..<min(limit, 3)).map { WireLinkMetadataTarget(canonicalKey: "\($0)", canonicalURL: "https://example.test/\($0)", etag: nil, lastModified: nil) }
  }
  func renewClaim(_ target: WireLinkMetadataTarget, asOf: Date) -> WireLinkMetadataTarget? { target }
  func seedEmbedded(canonicalKey: String, metadata: WireLinkMetadata, asOf: Date) { writes.append("seed") }
  func markNotModified(canonicalKey: String, etag: String?, lastModified: String?, asOf: Date, leaseExpiresAt: Date?) { writes.append("notModified") }
  func store(canonicalKey: String, metadata: WireLinkMetadata, asOf: Date, leaseExpiresAt: Date?) { writes.append("success") }
  func markFailure(canonicalKey: String, negative: Bool, asOf: Date, leaseExpiresAt: Date?) { writes.append(negative ? "negative" : "retry") }
}

private actor ProfileCancellationStore: WireTalkedAccountProfileStoring {
  var claimCount = 0
  var writes: [String] = []
  func claimDue(limit: Int, asOf: Date) -> [String] {
    claimCount += 1
    return ["did:plc:first", "did:plc:second", "did:plc:third"]
  }
  func store(_ profile: WireTalkedAccountProfile, asOf: Date) { writes.append("success") }
  func markFailure(did: String, asOf: Date) { writes.append("retry") }
}
