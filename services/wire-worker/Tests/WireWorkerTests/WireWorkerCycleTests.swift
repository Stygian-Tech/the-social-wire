import Foundation
import Testing
import WireCore
@testable import WireWorker

@Suite("The Wire worker cycle")
struct WireWorkerCycleTests {
  private let now = Date(timeIntervalSince1970: 2_000_000_000)

  @Test("off mode performs no data operation")
  func off() async throws {
    let store = FakeWireStore(candidates: [candidate])
    let cycle = WireWorkerCycle(store: store, config: config(mode: .off))
    #expect(try await cycle.run(asOf: now) == .off)
    let snapshot = await store.snapshot()
    #expect(snapshot.pingCount == 1)
    #expect(snapshot.cleanupCount == 0)
    #expect(snapshot.loadCount == 0)
    #expect(snapshot.commits.isEmpty)
  }

  @Test(arguments: [(WireFeedMode.shadow, false), (.api, true), (.visible, true)])
  func materializesMode(_ mode: WireFeedMode, activated: Bool) async throws {
    let store = FakeWireStore(candidates: activationCandidates)
    let outcome = try await WireWorkerCycle(
      store: store,
      config: config(mode: mode),
      labelRefresher: SuccessfulLabelRefresher()
    ).run(asOf: now)
    guard case .generated(_, let itemCount, let didActivate) = outcome else {
      Issue.record("Expected generation outcome")
      return
    }
    #expect(itemCount == WireDataPolicy.minimumGlobalCandidates)
    #expect(didActivate == activated)
    let commits = await store.snapshot().commits
    #expect(commits.count == 1)
    #expect(commits[0].activate == activated)
    #expect(commits[0].result.items[0].candidate.canonicalKey == "item-0")
  }

  @Test("an undersized locale generation cannot move the active pointer")
  func localeEligibility() async throws {
    let store = FakeWireStore(candidates: [candidate])
    var localeConfig = config(mode: .visible)
    localeConfig.languageBucket = "en"
    let outcome = try await WireWorkerCycle(
      store: store,
      config: localeConfig,
      labelRefresher: SuccessfulLabelRefresher()
    ).run(asOf: now)
    guard case .generated(_, _, let activated) = outcome else {
      Issue.record("Expected generation outcome")
      return
    }
    #expect(!activated)
    let snapshot = await store.snapshot()
    #expect(snapshot.commits[0].activate == false)
  }

  @Test("the global cycle also commits up to twelve eligible locale generations")
  func localeDiscovery() async throws {
    let store = FakeWireStore(
      candidates: activationCandidates,
      languageBuckets: (1...15).map { "l\($0)" }
    )
    _ = try await WireWorkerCycle(
      store: store,
      config: config(mode: .visible),
      labelRefresher: SuccessfulLabelRefresher()
    ).run(asOf: now)
    let commits = await store.snapshot().commits
    #expect(commits.count == 13)
    #expect(commits.first?.languageBucket == "und")
    #expect(commits.dropFirst().map(\.languageBucket) == (1...12).map { "l\($0)" })
  }

  @Test("baseline moderation failure prevents generation activation")
  func moderationFailureFailsClosed() async {
    let store = FakeWireStore(candidates: activationCandidates)
    let cycle = WireWorkerCycle(
      store: store,
      config: config(mode: .visible),
      labelRefresher: FailingLabelRefresher()
    )
    await #expect(throws: WireLabelQueryError.staleRefresh) {
      try await cycle.run(asOf: now)
    }
    #expect(await store.snapshot().commits.isEmpty)
  }

  @Test("generation maintenance runs once without draining an inbox batch")
  func generationMaintenance() async throws {
    let maintainer = FakeInboxMaintainer()
    _ = try await WireWorkerCycle(
      store: FakeWireStore(candidates: activationCandidates),
      config: config(mode: .shadow),
      inboxMaintainer: maintainer,
      labelRefresher: SuccessfulLabelRefresher()
    ).run(asOf: now)
    #expect(await maintainer.callCount == 1)
  }

  private var candidate: WireCandidate {
    candidate(index: nil)
  }

  private var activationCandidates: [WireCandidate] {
    (0..<WireDataPolicy.minimumGlobalCandidates).map { candidate(index: $0) }
  }

  private func candidate(index: Int?) -> WireCandidate {
    let suffix = index.map { "-\($0)" } ?? ""
    return WireCandidate(
      canonicalKey: "item\(suffix)",
      canonicalURL: "https://example\(suffix).com/item",
      representativeURI: "at://did:example:writer\(suffix)/site.standard.document/item",
      sourceDomain: "example\(suffix).com",
      firstSeenAt: now.addingTimeInterval(-300),
      distinctActors1h: 3,
      distinctActors24h: 6,
      distinctActors7d: 6,
      signals1h: 4,
      signals24h: 8,
      signals7d: 8,
      communities24h: 2,
      sourceConfidence: 0.8
    )
  }

  private func config(mode: WireFeedMode) -> WireWorkerConfig {
    WireWorkerConfig(
      databaseURL: "postgres://unused/wire",
      mode: mode,
      role: .combined,
      intervalSeconds: 60,
      candidateLimit: 500,
      generationRetentionSeconds: 3_600,
      retentionBatchSize: 50,
      languageBucket: "und",
      ranking: .init(),
      actorHMACSecret: String(repeating: "s", count: 32),
      baselineLabelers: try! WireLabelerEndpoint.parse(WireLabelerEndpoint.blueskyDefault),
      labelRefreshMaximumAgeSeconds: 900,
      inboxBatchSize: 1_000,
      inboxConcurrency: 16,
      inboxIdleMilliseconds: 250,
      inboxCleanupBatchSize: 5_000,
      inboxCleanupIdleMilliseconds: 1_000,
      inboxCleanupEnabled: true,
      postgresMaximumConnections: 12
    )
  }
}

private struct SuccessfulLabelRefresher: WireBaselineLabelRefreshing {
  func refresh(asOf: Date) async throws {}
}

private struct FailingLabelRefresher: WireBaselineLabelRefreshing {
  func refresh(asOf: Date) async throws { throw WireLabelQueryError.staleRefresh }
}

private actor FakeInboxMaintainer: WireInboxMaintaining {
  private(set) var callCount = 0
  func maintain(asOf: Date) { callCount += 1 }
}

private actor FakeWireStore: WireGenerationStore {
  struct Snapshot: Sendable {
    var pingCount: Int
    var cleanupCount: Int
    var loadCount: Int
    var commits: [WireGenerationCommit]
  }

  let candidates: [WireCandidate]
  let languageBuckets: [String]
  var pingCount = 0
  var cleanupCount = 0
  var loadCount = 0
  var commits: [WireGenerationCommit] = []

  init(candidates: [WireCandidate], languageBuckets: [String] = []) {
    self.candidates = candidates
    self.languageBuckets = languageBuckets
  }
  func ping() { pingCount += 1 }
  func eligibleLanguageBuckets(limit: Int, minimumCandidates: Int, asOf: Date) -> [String] {
    Array(languageBuckets.prefix(limit))
  }
  func loadCandidates(languageBucket: String, limit: Int, asOf: Date) -> [WireCandidate] {
    loadCount += 1
    return Array(candidates.prefix(limit))
  }
  func commit(_ generation: WireGenerationCommit) { commits.append(generation) }
  func deleteExpired(asOf: Date, batchSize: Int) { cleanupCount += 1 }
  func snapshot() -> Snapshot {
    Snapshot(pingCount: pingCount, cleanupCount: cleanupCount, loadCount: loadCount, commits: commits)
  }
}
