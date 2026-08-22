import Foundation
import WireCore

/// Public getWireEdition DTO. The Corpus Edge and WireCore use embedded story
/// modules internally; the public contract exposes one de-duplicated story
/// collection with stable ID references so clients never receive duplicate cards.
struct WireEditionResponse: Encodable, Sendable {
  struct Publication: Encodable, Sendable {
    let name: String
    let domain: String
    let publication: String?
    let publicationKey: String
    let homepageURL: String?
    let iconURL: String?

    private enum CodingKeys: String, CodingKey {
      case name
      case domain
      case publication
      case publicationKey
      case homepageURL = "homepageUrl"
      case iconURL = "iconUrl"
    }
  }

  struct PublicationSpotlight: Encodable, Sendable {
    let id: String
    let publication: Publication
    let storyIDs: [String]

    private enum CodingKeys: String, CodingKey {
      case id
      case publication
      case storyIDs = "storyIds"
    }
  }

  struct StoryRail: Encodable, Sendable {
    let id: String
    let title: String
    let storyIDs: [String]

    private enum CodingKeys: String, CodingKey {
      case id
      case title
      case storyIDs = "storyIds"
    }
  }

  struct Person: Encodable, Sendable {
    let did: String
    let handle: String
    let displayName: String
    let avatarURL: String?
    let description: String?

    private enum CodingKeys: String, CodingKey {
      case did
      case handle
      case displayName
      case avatarURL = "avatarUrl"
      case description
    }
  }

  let editionVersion: String
  let generationID: String
  let generatedAt: Date
  let language: String
  let source: WirePageSource
  let degraded: Bool
  let stories: [WireFeedItem]
  let topStoryIDs: [String]
  let publicationSpotlights: [PublicationSpotlight]
  let storyRails: [StoryRail]
  let people: [Person]
  let trendingStoryIDs: [String]
  let moreCursor: String?

  init(edition: WireEdition) {
    var stories: [WireFeedItem] = []
    var seen = Set<String>()
    func append(_ candidates: [WireFeedItem]) {
      for story in candidates where seen.insert(story.itemID).inserted {
        stories.append(story)
      }
    }
    append(edition.leadStories)
    for panel in edition.publicationPanels { append(panel.stories) }
    for rail in edition.storyRails { append(rail.stories) }
    append(edition.generalStories)
    append(edition.trendingStories)

    self.editionVersion = edition.algorithmVersion
    self.generationID = edition.generationID
    self.generatedAt = edition.generatedAt
    self.language = edition.language
    self.source = edition.source
    self.degraded = edition.degraded
    self.stories = stories
    self.topStoryIDs = edition.leadStories.map(\.itemID)
    self.publicationSpotlights = edition.publicationPanels.map { panel in
      PublicationSpotlight(
        id: panel.publication.key,
        publication: Publication(
          name: panel.publication.name,
          domain: panel.publication.domain,
          publication: panel.publication.id,
          publicationKey: panel.publication.key,
          homepageURL: panel.publication.homepageURL,
          iconURL: panel.publication.iconURL
        ),
        storyIDs: panel.stories.map(\.itemID)
      )
    }
    var rails = edition.storyRails.map { rail in
      StoryRail(id: rail.id, title: rail.title, storyIDs: Self.uniqueIDs(rail.stories))
    }
    let general = Self.uniqueIDs(edition.generalStories)
    if !general.isEmpty {
      rails.append(
        StoryRail(
          id: "more-across-the-social-web",
          title: "More Across the Social Web",
          storyIDs: general
        )
      )
    }
    self.storyRails = rails
    self.people = edition.talkedAboutAccounts.map { account in
      Person(
        did: account.did,
        handle: account.handle ?? account.did,
        displayName: account.displayName ?? account.handle ?? account.did,
        avatarURL: account.avatarURL,
        description: account.description
      )
    }
    self.trendingStoryIDs = edition.trendingStories.map(\.itemID)
    self.moreCursor = edition.cursor
  }

  private enum CodingKeys: String, CodingKey {
    case editionVersion
    case generationID = "generationId"
    case generatedAt
    case language
    case source
    case degraded
    case stories
    case topStoryIDs = "topStoryIds"
    case publicationSpotlights
    case storyRails
    case people
    case trendingStoryIDs = "trendingStoryIds"
    case moreCursor
  }

  private static func uniqueIDs(_ stories: [WireFeedItem]) -> [String] {
    var seen = Set<String>()
    return stories.map(\.itemID).filter { seen.insert($0).inserted }
  }

}
