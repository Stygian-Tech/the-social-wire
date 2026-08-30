import Foundation
import GatewayCore
import Hummingbird
import WireCore

struct CircleDiscoveryService: Sendable {
  static let editionVersion = "circle-edition-v1"
  static let pageSize = 50

  private let candidateFetcher: any CircleCandidateFetching
  private let mode: CircleDiscoveryMode
  private let privateState: any CirclePrivateStateStoring
  private let actorHasher: WireActorHasher
  private let cursorCodec: CircleCursorCodec
  private let moderation: WireViewerModerationService
  private let repo: ATProtoAuthenticatedRepoClient
  private let publicFollowReader: any CirclePublicFollowReading
  private let activityReader: any CircleRecentActivityReading
  private let profileReader: any CircleProfileReading
  private let feedStore: any WireFeedStore

  init(
    candidateFetcher: any CircleCandidateFetching,
    mode: CircleDiscoveryMode,
    privateState: any CirclePrivateStateStoring,
    actorHasher: WireActorHasher,
    cursorCodec: CircleCursorCodec,
    moderation: WireViewerModerationService,
    repo: ATProtoAuthenticatedRepoClient,
    publicFollowReader: any CirclePublicFollowReading,
    activityReader: any CircleRecentActivityReading,
    profileReader: any CircleProfileReading,
    feedStore: any WireFeedStore
  ) {
    self.candidateFetcher = candidateFetcher
    self.mode = mode
    self.privateState = privateState
    self.actorHasher = actorHasher
    self.cursorCodec = cursorCodec
    self.moderation = moderation
    self.repo = repo
    self.publicFollowReader = publicFollowReader
    self.activityReader = activityReader
    self.profileReader = profileReader
    self.feedStore = feedStore
  }

  func catalog(now: Date) async throws -> CircleCatalogResponse {
    let wireCatalog = try await feedStore.getCatalog(now: now)
    return Self.catalogResponse(wireCatalog: wireCatalog, enabled: mode.isVisible)
  }

  static func catalogResponse(
    wireCatalog: WireFeedCatalog,
    enabled: Bool
  ) -> CircleCatalogResponse {
    return CircleCatalogResponse(
      enabled: enabled,
      available: wireCatalog.available,
      title: "Your Circle",
      subtitle: "Stories shared and discussed by people you follow and the people they follow.",
      supportedLanguages: wireCatalog.supportedLanguages,
      latestGenerationID: wireCatalog.latestGenerationID,
      generatedAt: wireCatalog.generatedAt
    )
  }

  func edition(
    request: Request,
    auth: AuthContext,
    language: String,
    cursor: String?,
    now: Date
  ) async throws -> CircleEditionResponse {
    guard let proofs = CircleGraphDPoP.extract(from: request),
      proofs.count == CircleGraphDPoP.methods.count
    else { throw WireServingError.moderationUnavailable }
    let moderationSnapshot = try await moderation.requireSnapshot(
      auth: auth,
      proofs: Array(proofs.prefix(WireModerationDPoP.methods.count)),
      now: now
    )
    let graphService = CircleGraphSnapshotService(
      viewerFollowReader: ATProtoCircleViewerFollowReader(
        repo: repo,
        auth: auth,
        listRecordsProof: proofs[WireModerationDPoP.methods.count]
      ),
      publicFollowReader: publicFollowReader,
      activityReader: activityReader,
      cache: privateState
    )
    let graph = try await graphService.snapshot(
      viewerDID: auth.did,
      excludedDIDs: moderationSnapshot.blockedDIDs.union(moderationSnapshot.mutedDIDs),
      now: now
    )
    let membership = try hashedMembership(graph.snapshot)
    let actorHashes = membership.keys.sorted()
    let hidden = try await privateState.hiddenStoryIDs(viewerDID: auth.did)
    let candidates: WireCorpusCandidateResponse
    if actorHashes.isEmpty {
      candidates = WireCorpusCandidateResponse(
        generationID: "circle-empty-\(Int(now.timeIntervalSince1970 / 300))",
        generatedAt: now,
        language: language,
        stories: [],
        exhausted: true
      )
    } else {
      candidates = try await candidateFetcher.candidates(
        actorHashes: actorHashes,
        language: language,
        since: now.addingTimeInterval(-7 * 24 * 60 * 60),
        limit: WireCorpusCandidateRequest.maximumStoriesPerRequest,
        now: now
      )
    }
    let startOrdinal = try cursorOrdinal(
      cursor,
      viewerDID: auth.did,
      snapshotID: graph.snapshot.snapshotID,
      generationID: candidates.generationID,
      language: language,
      now: now
    )
    if startOrdinal == 0,
      let cached = try await privateState.cachedEdition(
        viewerDID: auth.did,
        snapshotID: graph.snapshot.snapshotID,
        generationID: candidates.generationID,
        language: language,
        now: now
      )
    {
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .iso8601
      if let response = try? decoder.decode(CircleEditionResponse.self, from: cached) {
        return response
      }
    }

    let candidateByID = Dictionary(
      uniqueKeysWithValues: candidates.stories.map {
        ($0.item.itemID, $0)
      })
    let rankInput = candidates.stories.compactMap { story -> CircleRankCandidate? in
      guard !hidden.contains(story.item.itemID) else { return nil }
      let signals = story.facts.compactMap { fact -> CircleParticipantSignal? in
        guard let member = membership[fact.actorHash] else { return nil }
        return CircleParticipantSignal(
          participantKey: fact.actorHash,
          relationship: member.relationship,
          occurredAt: fact.occurredAt
        )
      }
      return CircleRankCandidate(
        canonicalKey: story.item.itemID,
        participantSignals: signals,
        quality: 1,
        presentation: Self.presentationScore(story.item),
        interestMatch: Self.interestMatch(
          story.topicKeys,
          viewerInterests: moderationSnapshot.interestTags
        )
      )
    }
    let ranked = try CircleRanker.rank(candidates: rankInput, asOf: now).items
    let pageRanked = Array(ranked.dropFirst(startOrdinal).prefix(Self.pageSize))
    let pageStories = pageRanked.compactMap { candidateByID[$0.candidate.canonicalKey] }
    let pageEnd = startOrdinal + pageStories.count
    let moreCursor =
      pageEnd < ranked.count
      ? try cursorCodec.encode(
        CircleCursor(
          snapshotID: graph.snapshot.snapshotID.uuidString.lowercased(),
          generationID: candidates.generationID,
          language: language,
          nextOrdinal: pageEnd,
          expiresAt: min(
            now.addingTimeInterval(24 * 60 * 60),
            graph.snapshot.generatedAt.addingTimeInterval(CircleGraphSnapshotService.staleMaximum)
          )
        ),
        viewerID: auth.did
      )
      : nil
    let publicStories = try await makePublicStories(
      pageStories,
      membership: membership,
      now: now
    )
    let publicByID = Dictionary(uniqueKeysWithValues: publicStories.map { ($0.storyID, $0) })
    let presentationItems = pageStories.map { story in
      Self.presentationItem(story, membership: membership, now: now)
    }
    let source: WirePageSource = graph.freshness.isStale ? .staleGeneration : .ranked
    let assembled = WireEditionAssembler.assemble(
      generationID: candidates.generationID,
      generatedAt: candidates.generatedAt,
      language: language,
      cursor: moreCursor,
      source: source,
      degraded: graph.freshness.isStale,
      rankedItems: presentationItems
    )
    let response = CircleEditionResponse(
      editionVersion: Self.editionVersion,
      generationID: candidates.generationID,
      generatedAt: candidates.generatedAt,
      language: language,
      source: source.rawValue,
      degraded: graph.freshness.isStale,
      stories: pageStories.compactMap { publicByID[$0.item.itemID] },
      topStoryIDs: assembled.leadStories.map(\.itemID),
      publicationSpotlights: assembled.publicationPanels.map { panel in
        CirclePublicationSpotlight(
          id: panel.publication.key,
          publication: panel.stories[0].source,
          storyIDs: panel.stories.map(\.itemID)
        )
      },
      storyRails: assembled.storyRails.map {
        CircleStoryRail(id: $0.id, title: $0.title, storyIDs: $0.stories.map(\.itemID))
      },
      trendingStoryIDs: assembled.trendingStories.map(\.itemID),
      moreCursor: moreCursor
    )
    if startOrdinal == 0 {
      let encoder = JSONEncoder()
      encoder.dateEncodingStrategy = .iso8601
      try await privateState.storeEdition(
        viewerDID: auth.did,
        snapshotID: graph.snapshot.snapshotID,
        generationID: candidates.generationID,
        language: language,
        expiresAt: min(
          now.addingTimeInterval(10 * 60),
          graph.snapshot.generatedAt.addingTimeInterval(CircleGraphSnapshotService.staleMaximum)
        ),
        payload: try encoder.encode(response)
      )
    }
    return response
  }

  func setHidden(
    viewerDID: String,
    storyID: String,
    hidden: Bool,
    now: Date
  ) async throws -> CircleHiddenItemResponse {
    let trimmed = storyID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed.utf8.count <= 128 else {
      throw WireServingError.invalidCursor
    }
    try await privateState.setHidden(
      viewerDID: viewerDID,
      storyID: trimmed,
      hidden: hidden,
      now: now
    )
    return CircleHiddenItemResponse(storyID: trimmed, hidden: hidden)
  }

  func purge(viewerDID: String) async throws {
    try await privateState.purge(viewerDID: viewerDID)
  }

  private struct Membership: Sendable {
    let actorDID: String
    let relationship: CircleRelationship
    let publicRelationship: String
  }

  private func hashedMembership(
    _ snapshot: CircleGraphSnapshot
  ) throws -> [String: Membership] {
    var result: [String: Membership] = [:]
    for member in snapshot.directMembers {
      result[try actorHasher.hash(member.actorDID)] = Membership(
        actorDID: member.actorDID,
        relationship: .direct,
        publicRelationship: "direct"
      )
    }
    for member in snapshot.oneHopMembers {
      result[try actorHasher.hash(member.actorDID)] = Membership(
        actorDID: member.actorDID,
        relationship: .oneHop(pathCount: member.pathCount),
        publicRelationship: "one_hop"
      )
    }
    return result
  }

  private func cursorOrdinal(
    _ encoded: String?,
    viewerDID: String,
    snapshotID: UUID,
    generationID: String,
    language: String,
    now: Date
  ) throws -> Int {
    guard let encoded else { return 0 }
    do {
      let cursor = try cursorCodec.decode(encoded, viewerID: viewerDID, now: now)
      guard cursor.snapshotID == snapshotID.uuidString.lowercased(),
        cursor.generationID == generationID,
        cursor.language == language
      else { throw WireServingError.cursorExpired }
      return cursor.nextOrdinal
    } catch CircleCursorError.expired {
      throw WireServingError.cursorExpired
    } catch let serving as WireServingError {
      throw serving
    } catch {
      throw WireServingError.invalidCursor
    }
  }

  private func makePublicStories(
    _ stories: [WireCorpusCandidateStory],
    membership: [String: Membership],
    now: Date
  ) async throws -> [CircleStory] {
    var selectedFactsByStory: [String: [(WireCorpusSignalFact, Membership)]] = [:]
    var actorDIDs = Set<String>()
    for story in stories {
      var bestByActor: [String: (WireCorpusSignalFact, Membership)] = [:]
      for fact in story.facts where fact.isNamedAttributionEligible {
        guard let member = membership[fact.actorHash] else { continue }
        if let existing = bestByActor[fact.actorHash], existing.0.occurredAt >= fact.occurredAt {
          continue
        }
        bestByActor[fact.actorHash] = (fact, member)
      }
      let selected = bestByActor.values.sorted { lhs, rhs in
        if lhs.1.publicRelationship != rhs.1.publicRelationship {
          return lhs.1.publicRelationship == "direct"
        }
        if lhs.0.occurredAt != rhs.0.occurredAt { return lhs.0.occurredAt > rhs.0.occurredAt }
        return lhs.1.actorDID < rhs.1.actorDID
      }.prefix(8)
      selectedFactsByStory[story.item.itemID] = Array(selected)
      actorDIDs.formUnion(selected.map { $0.1.actorDID })
    }
    let profiles = try await profileReader.profiles(actorDIDs: actorDIDs)
    return stories.map { story in
      let facts = story.facts.filter { membership[$0.actorHash] != nil }
      let direct = facts.contains { membership[$0.actorHash]?.publicRelationship == "direct" }
      let oneHop = facts.contains { membership[$0.actorHash]?.publicRelationship == "one_hop" }
      let distinct = Set(facts.map(\.actorHash)).count
      let replies = facts.filter { $0.kind == .reply }.count
      let latest = facts.map(\.occurredAt).max()
      var reasons: [String] = []
      if direct { reasons.append("shared_by_following") }
      if oneHop { reasons.append("shared_by_extended_circle") }
      if distinct >= 3 { reasons.append("popular_in_your_circle") }
      if replies > 0 { reasons.append("discussed_in_your_circle") }
      if let latest, now.timeIntervalSince(latest) <= 6 * 60 * 60 {
        reasons.append("fresh_from_your_circle")
      }
      let sharers = (selectedFactsByStory[story.item.itemID] ?? []).compactMap {
        fact, member -> CircleSharer? in
        guard let identity = profiles[member.actorDID] else { return nil }
        let action = fact.kind == .recommendation ? "recommended" : "shared"
        return CircleSharer(
          identity: identity,
          relationship: member.publicRelationship,
          action: action,
          sourceURI: fact.sourceURI,
          timestamp: fact.occurredAt
        )
      }
      return CircleStory(
        storyID: story.item.itemID,
        canonicalURL: story.item.canonicalURL,
        representativeURI: story.item.representativeURI,
        title: story.item.title,
        summary: story.item.summary,
        publishedAt: story.item.publishedAt,
        thumbnailURL: story.item.thumbnailURL,
        source: story.item.source,
        reasons: Array(reasons.prefix(3)),
        discussionCount: replies,
        sharers: sharers
      )
    }
  }

  private static func presentationItem(
    _ story: WireCorpusCandidateStory,
    membership: [String: Membership],
    now: Date
  ) -> WireFeedItem {
    let facts = story.facts.filter { membership[$0.actorHash] != nil }
    var reasons: [WireReasonCode] = []
    if Set(facts.map(\.actorHash)).count >= 3 { reasons.append(.sharedAcrossCommunities) }
    if facts.contains(where: { $0.kind == .reply }) { reasons.append(.widelyDiscussed) }
    if let latest = facts.map(\.occurredAt).max(), now.timeIntervalSince(latest) <= 60 * 60 {
      reasons.append(.breakingStory)
    }
    return WireFeedItem(
      itemID: story.item.itemID,
      canonicalURL: story.item.canonicalURL,
      representativeURI: story.item.representativeURI,
      title: story.item.title,
      summary: story.item.summary,
      publishedAt: story.item.publishedAt,
      thumbnailURL: story.item.thumbnailURL,
      source: story.item.source,
      reasons: reasons,
      provenance: story.item.provenance
    )
  }

  private static func presentationScore(_ item: WireFeedItem) -> Double {
    var score = 0.4
    if item.summary?.isEmpty == false { score += 0.3 }
    if item.thumbnailURL?.isEmpty == false { score += 0.3 }
    return score
  }

  private static func interestMatch(
    _ topicKeys: [String],
    viewerInterests: Set<String>
  ) -> Double {
    guard !viewerInterests.isEmpty else { return 0 }
    let normalized = Set(topicKeys.map { $0.lowercased() })
    return min(1, Double(normalized.intersection(viewerInterests).count) / 2)
  }
}
