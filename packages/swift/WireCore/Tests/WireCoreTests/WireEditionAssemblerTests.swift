import Foundation
import Testing
@testable import WireCore

struct WireEditionAssemblerTests {
  private let now = Date(timeIntervalSince1970: 1_800_000_000)

  @Test("assembles deterministic source-diverse leads and bounded publication panels")
  func publicationAssembly() {
    let ranked = (0..<7).flatMap { publication in
      (0..<4).map { story in
        item(
          id: "p\(publication)-s\(story)",
          domain: "source-\(publication).example",
          publication: "at://did:plc:p\(publication)/site.standard.publication/main"
        )
      }
    }

    let first = assemble(ranked)
    let second = assemble(ranked)

    #expect(first == second)
    #expect(first.algorithmVersion == "wire-edition-v2")
    #expect(first.leadStories.map(\.itemID) == ["p0-s0", "p1-s0", "p2-s0", "p3-s0"])
    #expect(first.publicationPanels.count == 6)
    #expect(first.publicationPanels.allSatisfy { $0.stories.count == 3 })
    #expect(first.publicationPanels.map(\.publication.key) == [
      "publication:at://did:plc:p0/site.standard.publication/main",
      "publication:at://did:plc:p1/site.standard.publication/main",
      "publication:at://did:plc:p2/site.standard.publication/main",
      "publication:at://did:plc:p3/site.standard.publication/main",
      "publication:at://did:plc:p4/site.standard.publication/main",
      "publication:at://did:plc:p5/site.standard.publication/main",
    ])
    #expect(first.trendingStories.map(\.itemID) == ranked.prefix(10).map(\.itemID))
  }

  @Test("deduplicates the primary story modules while trending remains a top-ten summary")
  func primaryModuleDeduplication() {
    let ranked = [
      item(id: "lead-a", domain: "a.example"),
      item(id: "lead-b", domain: "b.example"),
      item(id: "lead-c", domain: "c.example"),
      item(id: "lead-d", domain: "d.example"),
      item(id: "panel-1", domain: "panel.example", publication: "publication:panel"),
      item(id: "panel-2", domain: "panel.example", publication: "publication:panel"),
      item(id: "rail-1", domain: "rail-1.example", reasons: [.breakingStory]),
      item(id: "rail-2", domain: "rail-2.example", reasons: [.breakingStory]),
      item(id: "rail-3", domain: "rail-3.example", reasons: [.breakingStory]),
      item(id: "rail-4", domain: "rail-4.example", reasons: [.breakingStory]),
      item(id: "general", domain: "general.example"),
      item(id: "lead-a", domain: "duplicate.example"),
    ]

    let edition = assemble(ranked)
    let primaryIDs = edition.leadStories.map(\.itemID)
      + edition.publicationPanels.flatMap { $0.stories.map(\.itemID) }
      + edition.storyRails.flatMap { $0.stories.map(\.itemID) }
      + edition.generalStories.map(\.itemID)

    #expect(primaryIDs.count == Set(primaryIDs).count)
    #expect(primaryIDs == [
      "lead-a", "lead-b", "lead-c", "lead-d", "panel-1", "panel-2", "rail-1", "rail-2",
      "rail-3", "rail-4", "general",
    ])
    #expect(edition.storyRails.map(\.reason) == [.breakingStory])
    #expect(edition.storyRails.map(\.id) == ["breaking-developing"])
    #expect(edition.storyRails.map(\.title) == ["Breaking & Developing"])
    #expect(edition.trendingStories.map(\.itemID) == [
      "rail-1", "rail-2", "rail-3", "rail-4", "lead-a", "lead-b", "lead-c", "lead-d",
      "panel-1", "panel-2",
    ])
  }

  @Test("emits only the three stable editorial rails and leaves fresh publications general")
  func stableEditorialRails() {
    let leads = (0..<4).map { item(id: "lead-\($0)", domain: "lead-\($0).example") }
    let breaking = (0..<2).map {
      item(id: "breaking-\($0)", domain: "breaking-\($0).example", reasons: [.breakingStory])
    }
    let widely = (0..<2).map {
      item(id: "widely-\($0)", domain: "widely-\($0).example", reasons: [.widelyDiscussed])
    }
    let across = (0..<4).map {
      item(
        id: "across-\($0)",
        domain: "across-\($0).example",
        reasons: [.sharedAcrossCommunities]
      )
    }
    let resurfacing = (0..<4).map {
      item(id: "resurfacing-\($0)", domain: "resurfacing-\($0).example", reasons: [.resurfacing])
    }
    let fresh = (0..<4).map {
      item(id: "fresh-\($0)", domain: "fresh-\($0).example", reasons: [.freshPublication])
    }

    let edition = assemble(leads + breaking + widely + across + resurfacing + fresh)

    #expect(edition.storyRails.map(\.id) == [
      "breaking-developing", "across-communities", "resurfacing",
    ])
    #expect(edition.storyRails.map(\.title) == [
      "Breaking & Developing", "Across Communities", "Resurfacing",
    ])
    #expect(edition.storyRails[0].stories.map(\.itemID) == [
      "breaking-0", "breaking-1", "widely-0", "widely-1",
    ])
    #expect(edition.generalStories.map(\.itemID) == fresh.map(\.itemID))
  }

  @Test("decodes legacy reason-only rails with stable presentation metadata")
  func legacyRailDecoding() throws {
    let legacy = LegacyStoryRail(
      reason: .widelyDiscussed,
      stories: [item(id: "legacy", domain: "legacy.example")]
    )
    let decoded = try JSONDecoder().decode(
      WireEditionStoryRail.self,
      from: JSONEncoder().encode(legacy)
    )

    #expect(decoded.id == "breaking-developing")
    #expect(decoded.title == "Breaking & Developing")
    #expect(decoded.reason == .widelyDiscussed)
  }

  @Test("keeps underfilled groups in the general remainder")
  func underfill() {
    let ranked = [
      item(id: "lead", domain: "one.example", publication: "publication:one"),
      item(
        id: "underfilled-panel", domain: "one.example", publication: "publication:two",
        reasons: [.resurfacing]
      ),
    ]

    let edition = assemble(ranked)

    #expect(edition.leadStories.map(\.itemID) == ["lead"])
    #expect(edition.publicationPanels.isEmpty)
    #expect(edition.storyRails.isEmpty)
    #expect(edition.generalStories.map(\.itemID) == ["underfilled-panel"])
  }

  @Test("gives one supporting lead slot to a nearby direct Standard Site story")
  func standardSiteSupportingLeadPreference() {
    let ranked = [
      item(id: "first", domain: "one.example"),
      item(id: "second", domain: "two.example"),
      item(id: "third", domain: "three.example"),
      item(id: "fourth", domain: "four.example"),
      item(id: "fifth", domain: "five.example"),
      item(
        id: "standard", domain: "standard.example",
        representativeURI: "at://did:plc:standard/site.standard.document/story"
      ),
    ]

    let edition = assemble(ranked)

    #expect(edition.leadStories.map(\.itemID) == ["first", "second", "third", "standard"])
    #expect(edition.generalStories.map(\.itemID).contains("fourth"))
  }

  @Test("does not displace a canonical lead when Standard Site is outside the top ten")
  func boundedStandardSitePreference() {
    var ranked = (0..<11).map { item(id: "story-\($0)", domain: "source-\($0).example") }
    ranked.append(
      item(
        id: "late-standard", domain: "standard.example",
        representativeURI: "at://did:plc:standard/site.standard.document/late"
      )
    )

    #expect(assemble(ranked).leadStories.map(\.itemID) == [
      "story-0", "story-1", "story-2", "story-3",
    ])
  }

  @Test("ranks only privacy-safe talked-about account cohorts deterministically")
  func talkedAboutAccounts() throws {
    var candidates: [WireTalkedAboutAccountCandidate] = []
    for index in 0..<12 {
      let did = "did:plc:\(String(format: "%02d", index))"
      let storyCount = index == 11 ? 1 : 2 + (index % 3)
      let speakerCount = index == 10 ? 2 : 3 + (index % 2)
      let candidate = accountCandidate(
        did: did,
        stories: storyCount,
        speakers: speakerCount,
        bestStoryRank: 20 - index,
        latest: now.addingTimeInterval(Double(index))
      )
      candidates.append(candidate)
    }
    let duplicateWeaker = accountCandidate(
      did: "DID:PLC:09",
      stories: 2,
      speakers: 3,
      bestStoryRank: 100,
      latest: now.addingTimeInterval(-1)
    )

    var firstGenerator = SeededGenerator(seed: 7)
    var secondGenerator = SeededGenerator(seed: 19)
    let first = assemble(
      [],
      accounts: candidates.shuffled(using: &firstGenerator) + [duplicateWeaker]
    )
    let second = assemble(
      [],
      accounts: candidates.shuffled(using: &secondGenerator) + [duplicateWeaker]
    )

    #expect(first.talkedAboutAccounts == second.talkedAboutAccounts)
    #expect(first.talkedAboutAccounts.count == 10)
    #expect(!first.talkedAboutAccounts.contains { $0.did.lowercased() == "did:plc:10" })
    #expect(!first.talkedAboutAccounts.contains { $0.did.lowercased() == "did:plc:11" })

    let data = try JSONEncoder().encode(first)
    let json = try JSONSerialization.jsonObject(with: data)
    let object = try #require(json as? [String: Any])
    let people = try #require(object["talkedAboutAccounts"] as? [[String: Any]])
    #expect(people.allSatisfy { $0["mentionCount"] == nil })
    #expect(people.allSatisfy { $0["bestStoryRank"] == nil })
    #expect(object["score"] == nil)
    #expect(object["rank"] == nil)
  }

  private func assemble(
    _ items: [WireFeedItem],
    accounts: [WireTalkedAboutAccountCandidate] = []
  ) -> WireEdition {
    WireEditionAssembler.assemble(
      generationID: "generation",
      generatedAt: now,
      language: "und",
      cursor: "signed-cursor",
      source: .ranked,
      degraded: false,
      rankedItems: items,
      talkedAboutAccountCandidates: accounts
    )
  }

  private func item(
    id: String,
    domain: String,
    publication: String? = nil,
    representativeURI: String? = nil,
    reasons: [WireReasonCode] = []
  ) -> WireFeedItem {
    WireFeedItem(
      itemID: id,
      canonicalURL: "https://\(domain)/\(id)",
      representativeURI: representativeURI,
      title: "Story \(id)",
      summary: nil,
      publishedAt: now,
      thumbnailURL: nil,
      source: WireItemSource(
        name: "Publication \(domain)",
        domain: domain,
        publication: publication,
        publicationKey: publication.map { "publication:\($0)" },
        homepageURL: "https://\(domain)",
        iconURL: "https://\(domain)/icon.png"
      ),
      reasons: reasons,
      provenance: [.directShare]
    )
  }

  private func accountCandidate(
    did: String,
    stories: Int,
    speakers: Int,
    bestStoryRank: Int,
    latest: Date
  ) -> WireTalkedAboutAccountCandidate {
    WireTalkedAboutAccountCandidate(
      account: WireTalkedAboutAccount(
        did: did,
        handle: "\(did.suffix(2)).example",
        displayName: "Account \(did.suffix(2))",
        avatarURL: "https://example.com/avatar/\(did.suffix(2))"
      ),
      distinctStoryCount: stories,
      distinctSpeakerCount: speakers,
      bestStoryRank: bestStoryRank,
      latestMentionAt: latest
    )
  }
}

private struct LegacyStoryRail: Encodable {
  let reason: WireReasonCode
  let stories: [WireFeedItem]
}

private struct SeededGenerator: RandomNumberGenerator {
  private var state: UInt64

  init(seed: UInt64) { self.state = seed }

  mutating func next() -> UInt64 {
    state = state &* 6_364_136_223_846_793_005 &+ 1
    return state
  }
}
