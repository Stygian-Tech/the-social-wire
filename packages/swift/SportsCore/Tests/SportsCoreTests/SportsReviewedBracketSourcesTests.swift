import Foundation
import Testing
@testable import SportsCore

struct SportsReviewedBracketSourcesTests {
  @Test func externalSourcesAreReviewedSeasonSpecificAndContainNoImportedArtwork() throws {
    let sources = SportsReviewedBracketSources.sources
    #expect(sources.count == 6)
    #expect(Set(sources.map(\.id)).count == sources.count)
    for source in sources {
      let url = try #require(URL(string: source.url))
      #expect(url.scheme == "https")
      #expect(["www.nfl.com", "www.nba.com", "www.nhl.com", "www.mlb.com", "www.ncaa.com"].contains(url.host))
      #expect(source.mode == "external")
      #expect(!source.season.isEmpty)
      #expect(source.reviewedAt == Date(timeIntervalSince1970: 1791072000))
      let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(source)) as? [String: Any])
      #expect(Set(object.keys) == Set(["id", "competitionID", "season", "title", "url", "reviewedAt", "mode"]))
    }
    #expect(sources.first { $0.competitionID == SportsReviewedCatalog.id("competition:nfl") }?.season == "2025")
  }

  @Test func scopesSourcesToSelectedFeedAndFollowedTeamsWithoutCrossDivisionBackfill() throws {
    let catalog = SportsReviewedCatalog.entities
    let global = try #require(SportsNamedFeeds.catalog(entities: catalog).first { $0.id == "sports" })
    let nfl = SportsReviewedCatalog.id("competition:nfl")
    let eagle = try #require(catalog.first { $0.kind == "team" && $0.name == "Philadelphia Eagles" })
    let feeds = SportsNamedFeeds.catalog(entities: catalog)
    let nbaFeed = try #require(feeds.first { $0.entityIDs == [SportsReviewedCatalog.id("competition:nba")] })
    #expect(SportsReviewedBracketSources.matching(definition: global, catalog: catalog, teamIDs: [eagle.id]).map(\.competitionID) == [nfl])
    #expect(SportsReviewedBracketSources.matching(definition: nbaFeed, catalog: catalog, teamIDs: [eagle.id]).isEmpty)
    #expect(SportsReviewedBracketSources.matching(definition: global, catalog: catalog, teamIDs: []).isEmpty)
    let divisionII = try #require(catalog.first { $0.kind == "ncaa-team" && $0.division == "Division II" && $0.competitionIDs.contains(SportsReviewedCatalog.id("competition:ncaa-womens-basketball:Division II")) })
    let teamFeed = try #require(feeds.first { $0.entityIDs == [divisionII.id] })
    #expect(SportsReviewedBracketSources.matching(definition: teamFeed, catalog: catalog, teamIDs: nil).isEmpty)
  }
}
