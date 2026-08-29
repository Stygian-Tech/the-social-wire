import Foundation
import Testing
@testable import WireCore

@Suite("The Wire ranker")
struct WireRankerTests {
  private let now = Date(timeIntervalSince1970: 2_000_000_000)

  @Test("is deterministic independent of input order")
  func deterministic() throws {
    let candidates = [
      candidate("b", actors: 20, signals1h: 6),
      candidate("a", actors: 20, signals1h: 6),
    ]
    let first = try WireRanker.rank(candidates: candidates, asOf: now, config: .init())
    let second = try WireRanker.rank(
      candidates: Array(candidates.reversed()), asOf: now, config: .init())
    #expect(first == second)
    #expect(Set(first.items.map(\.candidate.canonicalKey)) == ["a", "b"])
  }

  @Test("eligible story ordering rotates deterministically at thirty-minute boundaries")
  func deterministicRotation() throws {
    let bucketStart = Date(
      timeIntervalSince1970:
        floor(now.timeIntervalSince1970 / WireRanker.rotationInterval)
        * WireRanker.rotationInterval
    )
    let keys = (0..<20).map { "rotation-\($0)" }
    let firstNudges = keys.map { WireRanker.rotationNudge(canonicalKey: $0, asOf: bucketStart) }
    let sameBucketNudges = keys.map {
      WireRanker.rotationNudge(
        canonicalKey: $0,
        asOf: bucketStart.addingTimeInterval(WireRanker.rotationInterval - 1)
      )
    }
    let nextBucket = bucketStart.addingTimeInterval(WireRanker.rotationInterval)
    let nextNudges = keys.map { WireRanker.rotationNudge(canonicalKey: $0, asOf: nextBucket) }

    #expect(firstNudges == sameBucketNudges)
    #expect(firstNudges != nextNudges)
    #expect(firstNudges.allSatisfy { (0...WireRanker.maximumRotationNudge).contains($0) })
    #expect(nextNudges.allSatisfy { (0...WireRanker.maximumRotationNudge).contains($0) })

    let candidates = keys.map { candidate($0, actors: 8) }
    let first = try WireRanker.rank(candidates: candidates, asOf: bucketStart, config: .init())
    let repeated = try WireRanker.rank(
      candidates: Array(candidates.reversed()), asOf: bucketStart, config: .init()
    )
    let rotated = try WireRanker.rank(
      candidates: candidates, asOf: nextBucket, config: .init()
    )
    #expect(first == repeated)
    #expect(
      first.items.map(\.candidate.canonicalKey)
        != rotated.items.map(\.candidate.canonicalKey)
    )
  }

  @Test("filters candidates by age, quality, and signal floor")
  func eligibilityFilters() throws {
    var old = candidate("old", actors: 10)
    old.publishedAt = now.addingTimeInterval(-3_000_000)
    var lowQuality = candidate("quality", actors: 10)
    lowQuality.sourceConfidence = 0.1
    var quiet = candidate("quiet", actors: 0, recommendations: 0)
    quiet.representativeURI = "at://did:example:quiet/app.bsky.feed.post/1"
    let accepted = candidate("accepted", actors: 5)
    let result = try WireRanker.rank(
      candidates: [old, lowQuality, quiet, accepted], asOf: now, config: .init()
    )
    #expect(result.items.map(\.candidate.canonicalKey) == ["accepted"])
    #expect(result.diagnostics.rejectedForAge == 1)
    #expect(result.diagnostics.rejectedForQuality == 1)
    #expect(result.diagnostics.rejectedForSignalFloor == 1)
  }

  @Test("default freshness decays on a ten-hour half-life")
  func freshnessHalfLife() throws {
    var tenHoursOld = candidate("ten-hours", actors: 5)
    tenHoursOld.publishedAt = now.addingTimeInterval(-36_000)
    var twentyHoursOld = candidate("twenty-hours", actors: 5)
    twentyHoursOld.publishedAt = now.addingTimeInterval(-72_000)
    let freshnessOnly = WireRankingWeights(
      distinctSharers24h: 0,
      shareVelocity1h: 0,
      likeBreadthVelocity: 0,
      repostBreadthVelocity: 0,
      communitySpread: 0,
      freshness: 1,
      resurfacingAcceleration: 0,
      sourceConfidence: 0,
      standardSiteAuthority: 0,
      openGraphMetadata: 0,
      recommendationBreadth: 0,
      positiveFeedbackBreadth: 0
    )
    let result = try WireRanker.rank(
      candidates: [twentyHoursOld, tenHoursOld],
      asOf: now,
      config: .init(weights: freshnessOnly, missingThumbnailPenalty: 0)
    )
    let scores = Dictionary(
      uniqueKeysWithValues: result.items.map { ($0.candidate.canonicalKey, $0.score) })

    #expect((0.5...0.505).contains(try #require(scores["ten-hours"])))
    #expect((0.25...0.255).contains(try #require(scores["twenty-hours"])))
  }

  @Test("emits public reason codes without actor data")
  func reasonCodes() throws {
    var item = candidate("story", actors: 15, signals1h: 8, communities: 4)
    item.publishedAt = now.addingTimeInterval(-7_200)
    item.firstSeenAt = now.addingTimeInterval(-7_200)
    item.lastSignalAt = now.addingTimeInterval(-600)
    let result = try WireRanker.rank(candidates: [item], asOf: now, config: .init())
    #expect(result.items[0].reasonCodes.contains(.breakingStory))
    #expect(result.items[0].reasonCodes.contains(.widelyDiscussed))
    #expect(result.items[0].reasonCodes.count == 2)
  }

  @Test("recommendations can satisfy the admission floor")
  func recommendationsAdmit() throws {
    let result = try WireRanker.rank(
      candidates: [candidate("recommended", actors: 0, recommendations: 2)],
      asOf: now,
      config: .init()
    )
    #expect(result.items.count == 1)
  }

  @Test("a verified fresh burst enters before the daily conversation floor")
  func breakingBurstAdmission() throws {
    let burst = candidate("burst", actors: 3, signals1h: 3, openGraph: true)
    let result = try WireRanker.rank(
      candidates: [burst], asOf: now, config: .init(minimumRankedItems: 1)
    )
    #expect(result.items.map(\.candidate.canonicalKey) == ["burst"])
    #expect(result.items[0].reasonCodes.contains(.breakingStory))
  }

  @Test("unverified presentation metadata cannot enter through backfill")
  func metadataQualityGate() throws {
    let unverified = candidate("unverified", actors: 20, openGraph: false)
    let result = try WireRanker.rank(candidates: [unverified], asOf: now, config: .init())
    #expect(result.items.isEmpty)
    #expect(result.diagnostics.rejectedForQuality == 1)
  }

  @Test("trusted direct publications have a bounded fresh-content lane")
  func freshPublicationLane() throws {
    let result = try WireRanker.rank(
      candidates: [
        candidate("fresh", actors: 1, signals1h: 0, recommendations: 0, standardSite: true)
      ],
      asOf: now,
      config: .init()
    )
    #expect(result.items.count == 1)
    #expect(result.items[0].reasonCodes.contains(.freshPublication))
  }

  @Test("a single social share cannot use the authoritative publication lane")
  func socialShareCannotUseFreshPublicationLane() throws {
    let result = try WireRanker.rank(
      candidates: [candidate("social", actors: 1, signals1h: 1, openGraph: true)],
      asOf: now,
      config: .init()
    )
    #expect(result.items.isEmpty)
    #expect(result.diagnostics.rejectedForSignalFloor == 1)
  }

  @Test("passive engagement cannot satisfy the conversation gate")
  func passiveEngagementDoesNotAdmit() throws {
    var passive = candidate("passive", actors: 20)
    passive.shares24h = 0
    passive.recommendations24h = 0
    passive.distinctLikes24h = 20
    passive.distinctReposts24h = 20
    let result = try WireRanker.rank(candidates: [passive], asOf: now, config: .init())
    let nextRotation = try WireRanker.rank(
      candidates: [passive],
      asOf: now.addingTimeInterval(WireRanker.rotationInterval),
      config: .init()
    )
    #expect(result.items.isEmpty)
    #expect(nextRotation.items.isEmpty)
    #expect(result.diagnostics.rejectedForSignalFloor == 1)
  }

  @Test("fresh Standard Site publication needs one authoritative signal")
  func freshStandardSiteNeedsAuthoritativeSignal() throws {
    let quiet = candidate("quiet-standard", actors: 0, standardSite: true)
    let published = candidate("published-standard", actors: 1, standardSite: true)
    let result = try WireRanker.rank(
      candidates: [quiet, published], asOf: now, config: .init()
    )
    #expect(result.items.map(\.candidate.canonicalKey) == ["published-standard"])
    #expect(result.diagnostics.rejectedForSignalFloor == 1)
  }

  @Test("bounded source quality signals break otherwise equal ranking ties")
  func sourceQualitySignals() throws {
    let plain = candidate("a-plain", actors: 8)
    let openGraph = candidate("b-open-graph", actors: 8, openGraph: true)
    let standard = candidate("c-standard", actors: 8, standardSite: true)
    let result = try WireRanker.rank(
      candidates: [plain, openGraph, standard], asOf: now, config: .init()
    )
    #expect(result.items.map(\.candidate.canonicalKey) == [
      "c-standard", "b-open-graph", "a-plain",
    ])
  }

  @Test("a usable thumbnail applies the full configured quality penalty without gating admission")
  func usableThumbnailDownrank() throws {
    let withoutThumbnail = candidate("story", actors: 8)
    let withThumbnail = candidate("story", actors: 8, thumbnail: true)
    let config = WireRankingConfig(minimumRankedItems: 1)

    let withoutResult = try WireRanker.rank(
      candidates: [withoutThumbnail], asOf: now, config: config
    )
    let withResult = try WireRanker.rank(
      candidates: [withThumbnail], asOf: now, config: config
    )

    #expect(withResult.items.count == 1)
    #expect(withoutResult.items.count == 1)
    #expect(
      abs(withResult.items[0].score - withoutResult.items[0].score
        - config.missingThumbnailPenalty) < 0.000_001
    )
    #expect(withoutResult.diagnostics.rejectedForQuality == 0)
  }

  @Test("an image-bearing article outranks a more discussed article without publisher artwork")
  func thumbnailQualityOutweighsConversationDifference() throws {
    let imageBearing = candidate("image-bearing", actors: 5, thumbnail: true)
    let noImage = candidate("no-image", actors: 20)

    let result = try WireRanker.rank(
      candidates: [noImage, imageBearing], asOf: now,
      config: .init(minimumRankedItems: 2)
    )

    #expect(result.items.map(\.candidate.canonicalKey) == [
      "image-bearing", "no-image",
    ])
    #expect(result.diagnostics.rejectedForQuality == 0)
  }

  @Test("explicit quality signals rank recommendation above feedback above a like")
  func qualitySignalHierarchy() throws {
    var liked = candidate("a-liked", actors: 5)
    liked.likes24h = 1
    liked.likes1h = 1
    liked.distinctLikes24h = 1
    var feedback = candidate("b-feedback", actors: 5)
    feedback.positiveFeedback24h = 1
    var recommended = candidate("c-recommended", actors: 5, recommendations: 1)
    recommended.shares24h = 5
    let result = try WireRanker.rank(
      candidates: [liked, feedback, recommended], asOf: now, config: .init()
    )
    #expect(result.items.map(\.candidate.canonicalKey) == [
      "c-recommended", "b-feedback", "a-liked",
    ])
  }

  @Test("feedback cannot admit and negative feedback is bounded")
  func feedbackIsBoundedAndCannotAdmit() throws {
    var quiet = candidate("quiet-feedback", actors: 0)
    quiet.shares24h = 0
    quiet.positiveFeedback24h = 10
    var discussed = candidate("discussed", actors: 5)
    discussed.negativeFeedback24h = 10
    let result = try WireRanker.rank(
      candidates: [quiet, discussed], asOf: now, config: .init()
    )
    #expect(result.items.map(\.candidate.canonicalKey) == ["discussed"])
    #expect(result.items[0].score >= 0)
  }

  @Test("platform destination penalties match exact hosts and subdomains only")
  func platformDestinationPenalty() throws {
    var publisher = candidate("a-publisher", actors: 5)
    publisher.sourceDomain = "notyoutube.com"
    var platform = candidate("b-platform", actors: 5)
    platform.sourceDomain = "www.youtube.com"
    let result = try WireRanker.rank(
      candidates: [platform, publisher], asOf: now, config: .init()
    )
    #expect(result.items.map(\.candidate.canonicalKey) == ["a-publisher", "b-platform"])
    #expect(WireDomainPenaltyPolicy().penalty(for: "www.instagram.com") == 0.05)
    #expect(WireDomainPenaltyPolicy().penalty(for: "notreddit.com") == 0)
  }

  @Test("commercial and unsupported targets enforce the quality gate")
  func commercialQualityGate() throws {
    let normal = candidate("normal", actors: 5)
    var limited = candidate("limited", actors: 5)
    limited.commercialClass = .limited
    limited.commercialScore = 4
    var advertisement = candidate("advertisement", actors: 20)
    advertisement.commercialClass = .probableAd
    advertisement.commercialScore = 8
    var socialPost = candidate("social-post", actors: 20)
    socialPost.targetKind = .socialPost

    let result = try WireRanker.rank(
      candidates: [limited, advertisement, socialPost, normal], asOf: now, config: .init())

    #expect(result.items.map(\.candidate.canonicalKey) == ["normal", "limited"])
    #expect(result.items[0].score > result.items[1].score)
    #expect(result.diagnostics.rejectedForQuality == 2)
  }

  @Test("quality backfill excludes candidates without verified presentation metadata")
  func qualityBackfill() throws {
    let quality = candidate("quality", actors: 3, openGraph: true)
    let general = candidate("general", actors: 3, openGraph: false)
    let result = try WireRanker.rank(
      candidates: [general, quality], asOf: now, config: .init(minimumRankedItems: 1)
    )
    #expect(result.items.map(\.candidate.canonicalKey) == ["quality"])
    #expect(result.diagnostics.qualityBackfillCount == 1)
    #expect(result.diagnostics.generalBackfillCount == 0)
  }

  private func candidate(
    _ key: String,
    actors: Int,
    signals1h: Int = 2,
    communities: Int = 2,
    recommendations: Int = 0,
    standardSite: Bool = false,
    openGraph: Bool = true,
    thumbnail: Bool = false
  ) -> WireCandidate {
    WireCandidate(
      canonicalKey: key,
      canonicalURL: "https://\(key).example/story",
      representativeURI: "at://did:example:\(key)/site.standard.document/1",
      sourceDomain: "\(key).example",
      publicationID: "publication-\(key)",
      authorKey: "author-\(key)",
      topicKeys: ["technology"],
      publishedAt: now.addingTimeInterval(-3_600),
      firstSeenAt: now.addingTimeInterval(-3_600),
      lastSignalAt: now.addingTimeInterval(-60),
      distinctActors1h: max(0, actors / 2),
      distinctActors24h: actors,
      distinctActors7d: actors,
      signals1h: signals1h,
      signals24h: 16,
      signals7d: 20,
      communities24h: communities,
      recommendations24h: recommendations,
      shares1h: signals1h,
      shares24h: actors,
      sourceConfidence: 0.8,
      isStandardSite: standardSite,
      hasUsableOpenGraphMetadata: openGraph,
      hasUsableThumbnail: thumbnail
    )
  }
}
