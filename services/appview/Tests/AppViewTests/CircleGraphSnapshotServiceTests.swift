import Foundation
import Testing

@testable import AppView

@Suite("Your Circle graph snapshots")
struct CircleGraphSnapshotServiceTests {
  private let viewer = "did:plc:viewer"
  private let now = Date(timeIntervalSince1970: 2_000_000_000)
  private let refreshedSnapshotID = UUID(uuidString: "00000000-0000-0000-0000-000000000039")!

  @Test("builds a complete deduplicated graph and removes moderation exclusions and cycles")
  func buildsCompleteGraph() async throws {
    let viewerFollowReader = CircleTestViewerFollowReader(
      list: CircleFollowList(
        actorDID: "did:plc:viewer",
        followeeDIDs: [
          "did:plc:direct-a", " DID:PLC:DIRECT-A ", "did:plc:direct-b",
          "did:plc:blocked", "did:plc:muted", "did:plc:list-blocked", "did:plc:viewer",
        ],
        isComplete: true
      ))
    let publicFollowReader = CircleTestPublicFollowReader(lists: [
      "did:plc:direct-a": CircleFollowList(
        actorDID: "did:plc:direct-a",
        followeeDIDs: [
          "did:plc:shared", "did:plc:only-a", "did:plc:only-a", "did:plc:viewer",
          "did:plc:direct-a", "did:plc:direct-b", "did:plc:blocked",
        ],
        isComplete: true
      ),
      "did:plc:direct-b": CircleFollowList(
        actorDID: "did:plc:direct-b",
        followeeDIDs: [
          "did:plc:shared", "did:plc:only-b", "did:plc:direct-a",
          "did:plc:list-blocked",
        ],
        isComplete: true
      ),
    ])
    let activityReader = CircleTestActivityReader(activity: [
      "did:plc:shared": now.addingTimeInterval(-60),
      "did:plc:only-b": now.addingTimeInterval(-120),
      "did:plc:only-a": now.addingTimeInterval(-180),
    ])
    let cache = CircleTestSnapshotCache()
    let service = CircleGraphSnapshotService(
      viewerFollowReader: viewerFollowReader,
      publicFollowReader: publicFollowReader,
      activityReader: activityReader,
      cache: cache,
      snapshotIDGenerator: { refreshedSnapshotID }
    )

    let result = try await service.snapshot(
      viewerDID: " DID:PLC:VIEWER ",
      excludedDIDs: ["did:plc:blocked", "did:plc:muted", "did:plc:list-blocked"],
      now: now
    )

    #expect(result.freshness.source == .refreshed)
    #expect(result.snapshot.snapshotID == refreshedSnapshotID)
    #expect(result.freshness.isStale == false)
    #expect(
      result.snapshot.directMembers.map(\.actorDID)
        == [
          "did:plc:direct-a", "did:plc:direct-b",
        ].sorted { CircleStableHash.value($0) < CircleStableHash.value($1) })
    #expect(
      result.snapshot.oneHopMembers.map(\.actorDID) == [
        "did:plc:shared", "did:plc:only-b", "did:plc:only-a",
      ])
    #expect(result.snapshot.oneHopMembers.map(\.pathCount) == [2, 1, 1])
    #expect(result.snapshot.directCandidateCount == 2)
    #expect(result.snapshot.oneHopCandidateCount == 3)
    #expect(result.snapshot.directWasCapped == false)
    #expect(result.snapshot.oneHopWasCapped == false)
    #expect(await viewerFollowReader.requestedViewerDIDs == [viewer])
    #expect(
      await publicFollowReader.requestedActorSets == [
        [
          "did:plc:direct-a", "did:plc:direct-b",
        ]
      ])
    #expect(await publicFollowReader.requestedActorSets.allSatisfy { !$0.contains(viewer) })
  }

  @Test("caps by path count, then recent activity, then stable hash")
  func deterministicCapPriority() async throws {
    let viewerFollowReader = CircleTestViewerFollowReader(
      list: CircleFollowList(
        actorDID: viewer,
        followeeDIDs: ["did:plc:old", "did:plc:new", "did:plc:newest"],
        isComplete: true
      ))
    let publicFollowReader = CircleTestPublicFollowReader(lists: [
      "did:plc:new": CircleFollowList(
        actorDID: "did:plc:new",
        followeeDIDs: ["did:plc:two-new", "did:plc:two-old", "did:plc:stable-a"],
        isComplete: true
      ),
      "did:plc:newest": CircleFollowList(
        actorDID: "did:plc:newest",
        followeeDIDs: ["did:plc:two-new", "did:plc:two-old", "did:plc:stable-b"],
        isComplete: true
      ),
    ])
    let activityReader = CircleTestActivityReader(activity: [
      "did:plc:old": now.addingTimeInterval(-300),
      "did:plc:new": now.addingTimeInterval(-200),
      "did:plc:newest": now.addingTimeInterval(-100),
      "did:plc:two-new": now.addingTimeInterval(-60),
      "did:plc:two-old": now.addingTimeInterval(-600),
    ])
    let service = CircleGraphSnapshotService(
      viewerFollowReader: viewerFollowReader,
      publicFollowReader: publicFollowReader,
      activityReader: activityReader,
      cache: CircleTestSnapshotCache(),
      directLimit: 2,
      oneHopLimit: 3
    )

    let result = try await service.snapshot(viewerDID: viewer, excludedDIDs: [], now: now)

    #expect(result.snapshot.directMembers.map(\.actorDID) == ["did:plc:newest", "did:plc:new"])
    #expect(result.snapshot.directCandidateCount == 3)
    #expect(result.snapshot.directWasCapped)
    #expect(
      result.snapshot.oneHopMembers.prefix(2).map(\.actorDID) == [
        "did:plc:two-new", "did:plc:two-old",
      ])
    let stableWinner = ["did:plc:stable-a", "did:plc:stable-b"].min {
      let lhs = CircleStableHash.value($0)
      let rhs = CircleStableHash.value($1)
      return lhs == rhs ? $0 < $1 : lhs < rhs
    }
    #expect(result.snapshot.oneHopMembers.last?.actorDID == stableWinner)
    #expect(result.snapshot.oneHopCandidateCount == 4)
    #expect(result.snapshot.oneHopWasCapped)
  }

  @Test("enforces the 500 direct-follow production ceiling")
  func directProductionCeiling() async throws {
    let directDIDs = (0...CircleGraphSnapshotService.maximumDirectFollows).map {
      "did:plc:direct-\($0)"
    }
    let lists = Dictionary(
      uniqueKeysWithValues: directDIDs.map {
        ($0, CircleFollowList(actorDID: $0, followeeDIDs: [], isComplete: true))
      })
    let service = CircleGraphSnapshotService(
      viewerFollowReader: CircleTestViewerFollowReader(
        list: CircleFollowList(
          actorDID: viewer,
          followeeDIDs: directDIDs,
          isComplete: true
        )),
      publicFollowReader: CircleTestPublicFollowReader(lists: lists),
      activityReader: CircleTestActivityReader(),
      cache: CircleTestSnapshotCache()
    )

    let result = try await service.snapshot(viewerDID: viewer, excludedDIDs: [], now: now)

    #expect(result.snapshot.directMembers.count == 500)
    #expect(result.snapshot.directCandidateCount == 501)
    #expect(result.snapshot.directWasCapped)
  }

  @Test("enforces the 20,000 unique one-hop production ceiling")
  func oneHopProductionCeiling() async throws {
    let candidates = (0...CircleGraphSnapshotService.maximumOneHopActors).map {
      "did:plc:candidate-\($0)"
    }
    let directDID = "did:plc:direct"
    let service = CircleGraphSnapshotService(
      viewerFollowReader: CircleTestViewerFollowReader(
        list: CircleFollowList(
          actorDID: viewer,
          followeeDIDs: [directDID],
          isComplete: true
        )),
      publicFollowReader: CircleTestPublicFollowReader(lists: [
        directDID: CircleFollowList(
          actorDID: directDID,
          followeeDIDs: candidates,
          isComplete: true
        )
      ]),
      activityReader: CircleTestActivityReader(),
      cache: CircleTestSnapshotCache()
    )

    let result = try await service.snapshot(viewerDID: viewer, excludedDIDs: [], now: now)

    #expect(result.snapshot.oneHopMembers.count == 20_000)
    #expect(result.snapshot.oneHopCandidateCount == 20_001)
    #expect(result.snapshot.oneHopWasCapped)
  }

  @Test("serves a fresh cached snapshot without graph reads")
  func servesFreshCache() async throws {
    let cached = snapshot(generatedAt: now.addingTimeInterval(-9 * 60))
    let viewerFollowReader = CircleTestViewerFollowReader(error: CircleTestError.unavailable)
    let publicFollowReader = CircleTestPublicFollowReader(error: CircleTestError.unavailable)
    let service = CircleGraphSnapshotService(
      viewerFollowReader: viewerFollowReader,
      publicFollowReader: publicFollowReader,
      activityReader: CircleTestActivityReader(),
      cache: CircleTestSnapshotCache(snapshot: cached)
    )

    let result = try await service.snapshot(viewerDID: viewer, excludedDIDs: [], now: now)

    #expect(result.snapshot == cached)
    #expect(result.freshness.source == .freshCache)
    #expect(result.freshness.age == 9 * 60)
    #expect(await viewerFollowReader.requestCount == 0)
    #expect(await publicFollowReader.requestCount == 0)
  }

  @Test("serves stale metadata only after a failed refresh and within 24 hours")
  func servesStaleCache() async throws {
    let cached = snapshot(generatedAt: now.addingTimeInterval(-11 * 60))
    let service = CircleGraphSnapshotService(
      viewerFollowReader: CircleTestViewerFollowReader(error: CircleTestError.unavailable),
      publicFollowReader: CircleTestPublicFollowReader(error: CircleTestError.unavailable),
      activityReader: CircleTestActivityReader(),
      cache: CircleTestSnapshotCache(snapshot: cached)
    )

    let result = try await service.snapshot(viewerDID: viewer, excludedDIDs: [], now: now)

    #expect(result.snapshot == cached)
    #expect(result.freshness.source == .staleCache)
    #expect(result.freshness.isStale)
    #expect(result.freshness.refreshFailed)
    #expect(result.freshness.age == 11 * 60)
    #expect(result.freshness.freshTarget == 10 * 60)
    #expect(result.freshness.staleMaximum == 24 * 60 * 60)
  }

  @Test("never serves a snapshot past the 24-hour stale maximum")
  func rejectsExpiredCache() async {
    let cached = snapshot(generatedAt: now.addingTimeInterval(-(24 * 60 * 60 + 1)))
    let service = CircleGraphSnapshotService(
      viewerFollowReader: CircleTestViewerFollowReader(error: CircleTestError.unavailable),
      publicFollowReader: CircleTestPublicFollowReader(error: CircleTestError.unavailable),
      activityReader: CircleTestActivityReader(),
      cache: CircleTestSnapshotCache(snapshot: cached)
    )

    await #expect(throws: CircleTestError.unavailable) {
      _ = try await service.snapshot(viewerDID: viewer, excludedDIDs: [], now: now)
    }
  }

  @Test("never publishes a partial root or one-hop read")
  func rejectsPartialReads() async {
    let unusedPublicReader = CircleTestPublicFollowReader()
    let partialRoot = CircleGraphSnapshotService(
      viewerFollowReader: CircleTestViewerFollowReader(
        list: CircleFollowList(
          actorDID: viewer,
          followeeDIDs: [],
          isComplete: false
        )),
      publicFollowReader: unusedPublicReader,
      activityReader: CircleTestActivityReader(),
      cache: CircleTestSnapshotCache()
    )
    await #expect(throws: CircleGraphSnapshotError.incompleteFollowRead(actorDID: viewer)) {
      _ = try await partialRoot.snapshot(viewerDID: viewer, excludedDIDs: [], now: now)
    }
    #expect(await unusedPublicReader.requestCount == 0)

    let partialOneHop = CircleGraphSnapshotService(
      viewerFollowReader: CircleTestViewerFollowReader(
        list: CircleFollowList(
          actorDID: viewer,
          followeeDIDs: ["did:plc:direct"],
          isComplete: true
        )),
      publicFollowReader: CircleTestPublicFollowReader(lists: [
        "did:plc:direct": CircleFollowList(
          actorDID: "did:plc:direct",
          followeeDIDs: ["did:plc:candidate"],
          isComplete: false
        )
      ]),
      activityReader: CircleTestActivityReader(),
      cache: CircleTestSnapshotCache()
    )
    await #expect(
      throws: CircleGraphSnapshotError.incompleteFollowRead(actorDID: "did:plc:direct")
    ) {
      _ = try await partialOneHop.snapshot(viewerDID: viewer, excludedDIDs: [], now: now)
    }
  }

  @Test("reuses stale complete data instead of publishing a partial refresh")
  func partialRefreshFallsBackToStaleCompleteSnapshot() async throws {
    let cached = snapshot(generatedAt: now.addingTimeInterval(-60 * 60))
    let service = CircleGraphSnapshotService(
      viewerFollowReader: CircleTestViewerFollowReader(
        list: CircleFollowList(
          actorDID: viewer,
          followeeDIDs: [],
          isComplete: false
        )),
      publicFollowReader: CircleTestPublicFollowReader(),
      activityReader: CircleTestActivityReader(),
      cache: CircleTestSnapshotCache(snapshot: cached)
    )

    let result = try await service.snapshot(viewerDID: viewer, excludedDIDs: [], now: now)

    #expect(result.snapshot == cached)
    #expect(result.freshness.source == .staleCache)
  }

  private func snapshot(generatedAt: Date) -> CircleGraphSnapshot {
    CircleGraphSnapshot(
      snapshotID: UUID(uuidString: "00000000-0000-0000-0000-000000000040")!,
      viewerDID: viewer,
      directMembers: [],
      oneHopMembers: [],
      directCandidateCount: 0,
      oneHopCandidateCount: 0,
      generatedAt: generatedAt
    )
  }
}

private enum CircleTestError: Error, Equatable, Sendable {
  case unavailable
}

private actor CircleTestPublicFollowReader: CirclePublicFollowReading {
  private let lists: [String: CircleFollowList]
  private let error: CircleTestError?
  private(set) var requestCount = 0
  private(set) var requestedActorSets: [Set<String>] = []

  init(
    lists: [String: CircleFollowList] = [:],
    error: CircleTestError? = nil
  ) {
    self.lists = lists
    self.error = error
  }

  init(error: CircleTestError) {
    self.lists = [:]
    self.error = error
  }

  func follows(of actorDIDs: Set<String>) async throws -> [CircleFollowList] {
    requestCount += 1
    requestedActorSets.append(actorDIDs)
    if let error { throw error }
    return actorDIDs.compactMap { lists[$0] }
  }
}

private actor CircleTestViewerFollowReader: CircleViewerFollowReading {
  private let list: CircleFollowList?
  private let error: CircleTestError?
  private(set) var requestCount = 0
  private(set) var requestedViewerDIDs: [String] = []

  init(list: CircleFollowList) {
    self.list = list
    self.error = nil
  }

  init(error: CircleTestError) {
    self.list = nil
    self.error = error
  }

  func follows(viewerDID: String) async throws -> CircleFollowList {
    requestCount += 1
    requestedViewerDIDs.append(viewerDID)
    if let error { throw error }
    return try #require(list)
  }
}

private actor CircleTestActivityReader: CircleRecentActivityReading {
  private let activity: [String: Date]

  init(activity: [String: Date] = [:]) {
    self.activity = activity
  }

  func mostRecentActivity(for actorDIDs: Set<String>) async throws -> [String: Date] {
    activity.filter { actorDIDs.contains($0.key) }
  }
}

private actor CircleTestSnapshotCache: CircleGraphSnapshotCaching {
  private var snapshot: CircleGraphSnapshot?

  init(snapshot: CircleGraphSnapshot? = nil) {
    self.snapshot = snapshot
  }

  func load(
    viewerDID: String,
    excludedDIDs: Set<String>
  ) async throws -> CircleGraphSnapshot? {
    snapshot
  }

  func store(
    _ snapshot: CircleGraphSnapshot,
    excludedDIDs: Set<String>
  ) async throws {
    self.snapshot = snapshot
  }
}
