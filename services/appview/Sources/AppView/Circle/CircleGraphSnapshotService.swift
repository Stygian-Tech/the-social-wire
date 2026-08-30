import Foundation

struct CircleGraphSnapshotService: Sendable {
  static let maximumDirectFollows = 500
  static let maximumOneHopActors = 20_000
  static let freshTarget: TimeInterval = 10 * 60
  static let staleMaximum: TimeInterval = 24 * 60 * 60

  private let viewerFollowReader: any CircleViewerFollowReading
  private let publicFollowReader: any CirclePublicFollowReading
  private let activityReader: any CircleRecentActivityReading
  private let cache: any CircleGraphSnapshotCaching
  private let directLimit: Int
  private let oneHopLimit: Int
  private let snapshotIDGenerator: @Sendable () -> UUID

  init(
    viewerFollowReader: any CircleViewerFollowReading,
    publicFollowReader: any CirclePublicFollowReading,
    activityReader: any CircleRecentActivityReading,
    cache: any CircleGraphSnapshotCaching,
    directLimit: Int = Self.maximumDirectFollows,
    oneHopLimit: Int = Self.maximumOneHopActors,
    snapshotIDGenerator: @escaping @Sendable () -> UUID = { UUID() }
  ) {
    self.viewerFollowReader = viewerFollowReader
    self.publicFollowReader = publicFollowReader
    self.activityReader = activityReader
    self.cache = cache
    self.directLimit = min(max(1, directLimit), Self.maximumDirectFollows)
    self.oneHopLimit = min(max(1, oneHopLimit), Self.maximumOneHopActors)
    self.snapshotIDGenerator = snapshotIDGenerator
  }

  func snapshot(
    viewerDID: String,
    excludedDIDs: Set<String>,
    now: Date = Date()
  ) async throws -> CircleGraphSnapshotResult {
    let normalizedViewer = Self.normalizeDID(viewerDID)
    guard !normalizedViewer.isEmpty else { throw CircleGraphSnapshotError.invalidViewerDID }

    var normalizedExclusions = Set(excludedDIDs.map(Self.normalizeDID).filter { !$0.isEmpty })
    normalizedExclusions.insert(normalizedViewer)

    let cached = try? await cache.load(
      viewerDID: normalizedViewer,
      excludedDIDs: normalizedExclusions
    )
    let usableCached = cached.flatMap { snapshot in
      snapshot.viewerDID == normalizedViewer ? snapshot : nil
    }
    if let usableCached {
      let age = Self.age(of: usableCached, at: now)
      if age <= Self.freshTarget {
        return result(snapshot: usableCached, source: .freshCache, age: age)
      }
    }

    do {
      let refreshed = try await buildSnapshot(
        viewerDID: normalizedViewer,
        excludedDIDs: normalizedExclusions,
        now: now
      )
      try? await cache.store(refreshed, excludedDIDs: normalizedExclusions)
      return result(snapshot: refreshed, source: .refreshed, age: 0)
    } catch {
      if let usableCached {
        let age = Self.age(of: usableCached, at: now)
        if age <= Self.staleMaximum {
          return result(snapshot: usableCached, source: .staleCache, age: age)
        }
      }
      throw error
    }
  }

  private func buildSnapshot(
    viewerDID: String,
    excludedDIDs: Set<String>,
    now: Date
  ) async throws -> CircleGraphSnapshot {
    let rootRead = try await completeViewerFollowList(viewerDID: viewerDID)
    let directCandidates = normalizedFollowees(
      rootRead.followeeDIDs,
      excluding: excludedDIDs
    )
    let directActivity = try await activityReader.mostRecentActivity(for: directCandidates)
    let selectedDirect = Array(
      directCandidates.sorted {
        Self.activityOrdered($0, $1, activity: directActivity)
      }.prefix(directLimit)
    )
    let directSet = Set(selectedDirect)

    let followLists = try await completeFollowLists(for: directSet)
    var pathsByCandidate: [String: Set<String>] = [:]
    let oneHopExclusions = excludedDIDs.union(directSet)
    for directDID in selectedDirect {
      let followees = normalizedFollowees(
        followLists[directDID]?.followeeDIDs ?? [],
        excluding: oneHopExclusions
      )
      for candidate in followees {
        pathsByCandidate[candidate, default: []].insert(directDID)
      }
    }

    let oneHopCandidates = Set(pathsByCandidate.keys)
    let oneHopActivity = try await activityReader.mostRecentActivity(for: oneHopCandidates)
    let selectedOneHop = Array(
      oneHopCandidates.sorted { lhs, rhs in
        let lhsPaths = pathsByCandidate[lhs]?.count ?? 0
        let rhsPaths = pathsByCandidate[rhs]?.count ?? 0
        if lhsPaths != rhsPaths { return lhsPaths > rhsPaths }
        return Self.activityOrdered(lhs, rhs, activity: oneHopActivity)
      }.prefix(oneHopLimit)
    )

    return CircleGraphSnapshot(
      snapshotID: snapshotIDGenerator(),
      viewerDID: viewerDID,
      directMembers: selectedDirect.map {
        CircleGraphMember(
          actorDID: $0,
          depth: .direct,
          pathCount: 1,
          recentActivityAt: directActivity[$0]
        )
      },
      oneHopMembers: selectedOneHop.map {
        CircleGraphMember(
          actorDID: $0,
          depth: .oneHop,
          pathCount: pathsByCandidate[$0]?.count ?? 0,
          recentActivityAt: oneHopActivity[$0]
        )
      },
      directCandidateCount: directCandidates.count,
      oneHopCandidateCount: oneHopCandidates.count,
      generatedAt: now
    )
  }

  private func completeFollowLists(
    for actorDIDs: Set<String>
  ) async throws -> [String: CircleFollowList] {
    guard !actorDIDs.isEmpty else { return [:] }
    let reads = try await publicFollowReader.follows(of: actorDIDs)
    var byActor: [String: CircleFollowList] = [:]
    for read in reads {
      let actorDID = Self.normalizeDID(read.actorDID)
      guard byActor[actorDID] == nil else {
        throw CircleGraphSnapshotError.duplicateFollowRead(actorDID: actorDID)
      }
      byActor[actorDID] = read
    }
    for actorDID in actorDIDs {
      guard let read = byActor[actorDID] else {
        throw CircleGraphSnapshotError.missingFollowRead(actorDID: actorDID)
      }
      guard read.isComplete else {
        throw CircleGraphSnapshotError.incompleteFollowRead(actorDID: actorDID)
      }
    }
    return byActor
  }

  private func completeViewerFollowList(viewerDID: String) async throws -> CircleFollowList {
    let read = try await viewerFollowReader.follows(viewerDID: viewerDID)
    guard Self.normalizeDID(read.actorDID) == viewerDID else {
      throw CircleGraphSnapshotError.missingFollowRead(actorDID: viewerDID)
    }
    guard read.isComplete else {
      throw CircleGraphSnapshotError.incompleteFollowRead(actorDID: viewerDID)
    }
    return read
  }

  private func normalizedFollowees(
    _ actorDIDs: [String],
    excluding excludedDIDs: Set<String>
  ) -> Set<String> {
    Set(actorDIDs.map(Self.normalizeDID).filter { !$0.isEmpty && !excludedDIDs.contains($0) })
  }

  private func result(
    snapshot: CircleGraphSnapshot,
    source: CircleGraphSnapshotSource,
    age: TimeInterval
  ) -> CircleGraphSnapshotResult {
    CircleGraphSnapshotResult(
      snapshot: snapshot,
      freshness: CircleGraphSnapshotFreshness(
        source: source,
        age: age,
        freshTarget: Self.freshTarget,
        staleMaximum: Self.staleMaximum
      )
    )
  }

  private static func activityOrdered(
    _ lhs: String,
    _ rhs: String,
    activity: [String: Date]
  ) -> Bool {
    let lhsActivity = activity[lhs]
    let rhsActivity = activity[rhs]
    if lhsActivity != rhsActivity {
      switch (lhsActivity, rhsActivity) {
      case (.some(let lhsDate), .some(let rhsDate)):
        return lhsDate > rhsDate
      case (.some, .none):
        return true
      case (.none, .some):
        return false
      case (.none, .none):
        break
      }
    }
    let lhsHash = CircleStableHash.value(lhs)
    let rhsHash = CircleStableHash.value(rhs)
    if lhsHash != rhsHash { return lhsHash < rhsHash }
    return lhs < rhs
  }

  private static func normalizeDID(_ did: String) -> String {
    did.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }

  private static func age(of snapshot: CircleGraphSnapshot, at now: Date) -> TimeInterval {
    max(0, now.timeIntervalSince(snapshot.generatedAt))
  }
}
