import Foundation

public enum WireEditionAssembler {
  public static let version = "wire-edition-v2"
  public static let maximumLeadStories = 4
  public static let maximumPublicationPanels = 6
  public static let minimumStoriesPerPublicationPanel = 2
  public static let maximumStoriesPerPublicationPanel = 3
  public static let minimumStoriesPerRail = 4
  public static let maximumStoriesPerRail = 10
  public static let maximumStoryRails = 3
  public static let maximumTrendingStories = 10
  public static let maximumTalkedAboutAccounts = 10
  public static let minimumTalkedAboutStoryCount = 2
  public static let minimumTalkedAboutSpeakerCount = 3

  public static func assemble(
    generationID: String,
    generatedAt: Date,
    language: String,
    cursor: String? = nil,
    source: WirePageSource,
    degraded: Bool,
    rankedItems: [WireFeedItem],
    talkedAboutAccountCandidates: [WireTalkedAboutAccountCandidate] = []
  ) -> WireEdition {
    let stories = uniqueStories(rankedItems)
    var allocated = Set<String>()

    let leads = leadStories(from: stories)
    allocated.formUnion(leads.map(\.itemID))

    let panels = publicationPanels(from: stories, excluding: &allocated)
    let rails = storyRails(from: stories, excluding: &allocated)
    let general = stories.filter { !allocated.contains($0.itemID) }

    return WireEdition(
      generationID: generationID,
      generatedAt: generatedAt,
      language: language,
      cursor: cursor,
      source: source,
      degraded: degraded,
      leadStories: leads,
      publicationPanels: panels,
      storyRails: rails,
      generalStories: general,
      trendingStories: trendingStories(from: stories),
      talkedAboutAccounts: talkedAboutAccounts(from: talkedAboutAccountCandidates)
    )
  }

  private static func uniqueStories(_ stories: [WireFeedItem]) -> [WireFeedItem] {
    var seen = Set<String>()
    return stories.filter { seen.insert($0.itemID).inserted }
  }

  private static func leadStories(from stories: [WireFeedItem]) -> [WireFeedItem] {
    var domains = Set<String>()
    var result: [WireFeedItem] = []
    for story in stories {
      guard domains.insert(normalized(story.source.domain)).inserted else { continue }
      result.append(story)
      if result.count == maximumLeadStories { break }
    }
    guard result.count == maximumLeadStories,
      !result.contains(where: isDirectStandardSiteStory),
      let standardSiteStory = stories.prefix(10).first(where: { story in
        isDirectStandardSiteStory(story)
          && !result.contains(where: { $0.itemID == story.itemID })
          && !result.dropLast().contains(where: {
            normalized($0.source.domain) == normalized(story.source.domain)
          })
      })
    else { return result }
    result[result.index(before: result.endIndex)] = standardSiteStory
    return result
  }

  private static func isDirectStandardSiteStory(_ story: WireFeedItem) -> Bool {
    guard let uri = story.representativeURI?.lowercased() else { return false }
    return uri.contains("/site.standard.document/") || uri.contains("/site.standard.entry/")
  }

  private static func publicationPanels(
    from stories: [WireFeedItem],
    excluding allocated: inout Set<String>
  ) -> [WireEditionPublicationPanel] {
    var keysInOrder: [String] = []
    var groups: [String: [WireFeedItem]] = [:]
    for story in stories where !allocated.contains(story.itemID) {
      let key = publicationKey(for: story)
      if groups[key] == nil { keysInOrder.append(key) }
      groups[key, default: []].append(story)
    }

    var result: [WireEditionPublicationPanel] = []
    for key in keysInOrder {
      guard let candidates = groups[key],
        candidates.count >= minimumStoriesPerPublicationPanel,
        let first = candidates.first
      else { continue }
      let selected = Array(candidates.prefix(maximumStoriesPerPublicationPanel))
      result.append(
        WireEditionPublicationPanel(
          publication: WireEditionPublication(
            key: key,
            id: first.source.publication,
            name: first.source.name,
            domain: first.source.domain,
            homepageURL: first.source.homepageURL,
            iconURL: first.source.iconURL
          ),
          stories: selected
        )
      )
      allocated.formUnion(selected.map(\.itemID))
      if result.count == maximumPublicationPanels { break }
    }
    return result
  }

  private static func storyRails(
    from stories: [WireFeedItem],
    excluding allocated: inout Set<String>
  ) -> [WireEditionStoryRail] {
    var result: [WireEditionStoryRail] = []
    appendRail(
      id: WireEditionStoryRail.breakingDevelopingID,
      title: WireEditionStoryRail.breakingDevelopingTitle,
      reason: .breakingStory,
      stories: stories,
      allocated: &allocated,
      matches: {
        $0.reasons.contains(.breakingStory) || $0.reasons.contains(.widelyDiscussed)
      },
      to: &result
    )
    appendRail(
      id: WireEditionStoryRail.acrossCommunitiesID,
      title: WireEditionStoryRail.acrossCommunitiesTitle,
      reason: .sharedAcrossCommunities,
      stories: stories,
      allocated: &allocated,
      matches: { $0.reasons.contains(.sharedAcrossCommunities) },
      to: &result
    )
    appendRail(
      id: WireEditionStoryRail.resurfacingID,
      title: WireEditionStoryRail.resurfacingTitle,
      reason: .resurfacing,
      stories: stories,
      allocated: &allocated,
      matches: { $0.reasons.contains(.resurfacing) },
      to: &result
    )
    return result
  }

  private static func appendRail(
    id: String,
    title: String,
    reason: WireReasonCode,
    stories: [WireFeedItem],
    allocated: inout Set<String>,
    matches: (WireFeedItem) -> Bool,
    to result: inout [WireEditionStoryRail]
  ) {
    let candidates = stories.filter { !allocated.contains($0.itemID) && matches($0) }
    guard candidates.count >= minimumStoriesPerRail else { return }
    let selected = Array(candidates.prefix(maximumStoriesPerRail))
    result.append(
      WireEditionStoryRail(id: id, title: title, reason: reason, stories: selected)
    )
    allocated.formUnion(selected.map(\.itemID))
  }

  private static func trendingStories(from stories: [WireFeedItem]) -> [WireFeedItem] {
    let prioritized = stories.filter {
      $0.reasons.contains(.breakingStory) || $0.reasons.contains(.widelyDiscussed)
    }
    let prioritizedIDs = Set(prioritized.map(\.itemID))
    let rankFill = stories.filter { !prioritizedIDs.contains($0.itemID) }
    return Array((prioritized + rankFill).prefix(maximumTrendingStories))
  }

  private static func talkedAboutAccounts(
    from candidates: [WireTalkedAboutAccountCandidate]
  ) -> [WireTalkedAboutAccount] {
    var bestByDID: [String: WireTalkedAboutAccountCandidate] = [:]
    for candidate in candidates
    where candidate.distinctStoryCount >= minimumTalkedAboutStoryCount
      && candidate.distinctSpeakerCount >= minimumTalkedAboutSpeakerCount
    {
      let key = normalized(candidate.account.did)
      if let current = bestByDID[key], !precedes(candidate, current) { continue }
      bestByDID[key] = candidate
    }
    return bestByDID.values.sorted(by: precedes).prefix(maximumTalkedAboutAccounts).map(\.account)
  }

  private static func precedes(
    _ left: WireTalkedAboutAccountCandidate,
    _ right: WireTalkedAboutAccountCandidate
  ) -> Bool {
    if left.distinctStoryCount != right.distinctStoryCount {
      return left.distinctStoryCount > right.distinctStoryCount
    }
    if left.distinctSpeakerCount != right.distinctSpeakerCount {
      return left.distinctSpeakerCount > right.distinctSpeakerCount
    }
    if left.bestStoryRank != right.bestStoryRank { return left.bestStoryRank < right.bestStoryRank }
    if left.latestMentionAt != right.latestMentionAt {
      return (left.latestMentionAt ?? .distantPast) > (right.latestMentionAt ?? .distantPast)
    }
    return normalized(left.account.did) < normalized(right.account.did)
  }

  private static func publicationKey(for story: WireFeedItem) -> String {
    if let key = story.source.publicationKey?.trimmingCharacters(in: .whitespacesAndNewlines),
      !key.isEmpty
    {
      return normalized(key)
    }
    if let publication = story.source.publication?.trimmingCharacters(in: .whitespacesAndNewlines),
      !publication.isEmpty
    {
      return "publication:\(normalized(publication))"
    }
    return "domain:\(normalized(story.source.domain))"
  }

  private static func normalized(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }
}
