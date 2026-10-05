import SportsCore
import Testing

struct SportsDrumCorpsCoverageTests {
  @Test func reviewedDirectoryHasDistinctClassesAndStableCorpsIdentities() throws {
    let catalog = SportsReviewedCatalog.entities
    let sportID = SportsReviewedCatalog.id("sport:drum-corps")
    let dciID = SportsReviewedCatalog.id("competition:dci")
    let sport = try #require(catalog.first { $0.id == sportID })
    #expect(sport.name == "Drum Corps")
    let dci = try #require(catalog.first { $0.id == dciID })
    #expect(dci.sportID == sportID)
    let corps = catalog.filter { $0.kind == "team" && $0.sportID == sportID }
    #expect(corps.count == 57)
    #expect(Set(corps.map(\.id)).count == corps.count)
    for (key, name, count) in [("world", "World Class", 23), ("open", "Open Class", 17),
      ("all-age", "All-Age Class", 14), ("international", "International Class", 3)] {
      let classID = SportsReviewedCatalog.id("competition:dci-" + key)
      let competition = try #require(catalog.first { $0.id == classID })
      #expect(competition.competitionIDs == [dciID])
      #expect(competition.groupPath == ["Marching Arts", "DCI", name])
      let members = corps.filter { $0.competitionIDs.contains(classID) }
      #expect(members.count == count)
      #expect(members.allSatisfy { $0.division == name && $0.groupPath == competition.groupPath
        && $0.competitionIDs.contains(dciID) && $0.active })
    }
    let bluecoats = try #require(corps.first { $0.name == "Bluecoats" })
    #expect(bluecoats.id == SportsReviewedCatalog.id("team:dci:bluecoats"))
    #expect(bluecoats.providerIDs.isEmpty)
    #expect(corps.allSatisfy { $0.providerIDs.isEmpty })
    #expect(Set(catalog.map(\.id)).count == catalog.count)
  }

  @Test func everyReviewedDrumCorpsEntityHasAMatchingOnlyNamedFeed() throws {
    let catalog = SportsReviewedCatalog.entities
    let sportID = SportsReviewedCatalog.id("sport:drum-corps")
    let entities = catalog.filter { $0.sportID == sportID || $0.id == sportID }
    let feeds = SportsNamedFeeds.catalog(entities: catalog)
    #expect(entities.count == 63)
    let unrelated = SportsResolver.analyze(title: "NBA Cavaliers win basketball championship", summary: nil, catalog: catalog)
    for entity in entities {
      let feed = try #require(feeds.first { $0.entityIDs == [entity.id] })
      #expect(feed.id == "entity:" + entity.id)
      #expect(feed.groupPath == entity.groupPath)
      #expect(!feed.matches(unrelated))
    }
    let bluecoats = try #require(feeds.first { $0.entityIDs == [SportsReviewedCatalog.id("team:dci:bluecoats")] })
    let colts = try #require(feeds.first { $0.entityIDs == [SportsReviewedCatalog.id("team:dci:colts")] })
    let analysis = SportsResolver.analyze(title: "Bluecoats win DCI World Class championship", summary: nil, catalog: catalog)
    #expect(bluecoats.matches(analysis))
    #expect(!colts.matches(analysis))
  }

  @Test func contextualReportingResolvesCompetitionClassAndCorps() {
    let catalog = SportsReviewedCatalog.entities
    let sportID = SportsReviewedCatalog.id("sport:drum-corps")
    let dciID = SportsReviewedCatalog.id("competition:dci")
    for (title, seed) in [
      ("Drum Corps International announces championship schedule", "competition:dci"),
      ("Bluecoats win DCI World Class championship", "team:dci:bluecoats"),
      ("Colts drum and bugle corps announce their summer program", "team:dci:colts"),
      ("The Cavaliers drum corps qualify for championship finals", "team:dci:cavaliers"),
      ("Troopers drum corps set a record at DCI finals", "team:dci:troopers"),
      ("DCI Open Class corps prepare for championship finals", "competition:dci-open")
    ] {
      let analysis = SportsResolver.analyze(title: title, summary: nil, catalog: catalog)
      #expect(analysis.eligible)
      #expect(analysis.sportIDs.contains(sportID))
      #expect(analysis.competitionIDs.contains(dciID))
      #expect(analysis.associations.contains { $0.entityID == SportsReviewedCatalog.id(seed)
        && $0.confidence >= 0.9 && $0.resolverVersion == SportsResolver.version })
    }
    let summaryContext = SportsResolver.analyze(title: "Colts announce summer program",
      summary: "The drum corps prepares brass and percussion performers for DCI competition.", catalog: catalog)
    #expect(summaryContext.associations.contains { $0.entityID == SportsReviewedCatalog.id("team:dci:colts") })
  }

  @Test func overlappingNamesAndAcronymsDoNotResolveWithoutDrumCorpsEvidence() {
    let catalog = SportsReviewedCatalog.entities
    let sportID = SportsReviewedCatalog.id("sport:drum-corps")
    let drumCorpsIDs = Set(catalog.filter { $0.sportID == sportID || $0.id == sportID }.map(\.id))
    for title in ["Cavaliers win NBA basketball championship", "Colts sign NFL quarterback",
      "Troopers win military marksmanship competition", "DCI announces quarterly earnings",
      "DCI investigators announce arrests", "High school marching band wins regional championship",
      "Bluecoats unveil new uniforms", "Arsenal wins Premier League football match",
      "Hurricanes win NHL playoff game"] {
      let analysis = SportsResolver.analyze(title: title, summary: nil, catalog: catalog)
      #expect(analysis.sportIDs.allSatisfy { $0 != sportID })
      #expect(!analysis.associations.contains { drumCorpsIDs.contains($0.entityID) })
    }
  }

  @Test func nestedCorpsNamesResolveOnlyExplicitParticipants() {
    let catalog = SportsReviewedCatalog.entities
    let blueDevils = SportsReviewedCatalog.id("team:dci:blue-devils")
    for suffix in ["b", "c"] {
      let title = "Blue Devils \(suffix.uppercased()) drum corps perform at DCI championship"
      let analysis = SportsResolver.analyze(title: title, summary: nil, catalog: catalog)
      #expect(analysis.eligible)
      #expect(analysis.associations.contains { $0.entityID == SportsReviewedCatalog.id("team:dci:blue-devils-" + suffix) })
      #expect(!analysis.associations.contains { $0.entityID == blueDevils })
    }
    let both = SportsResolver.analyze(title: "Blue Devils and Blue Devils B drum corps perform together", summary: nil, catalog: catalog)
    #expect(both.associations.contains { $0.entityID == blueDevils })
    #expect(both.associations.contains { $0.entityID == SportsReviewedCatalog.id("team:dci:blue-devils-b") })
  }

  @Test func unrelatedFullTeamNamesStayDistinctEvenWithDCIContext() {
    let catalog = SportsReviewedCatalog.entities
    for (title, seed) in [
      ("Indianapolis Colts support DCI drum corps fundraiser", "team:dci:colts"),
      ("Cleveland Cavaliers support DCI drum corps fundraiser", "team:dci:cavaliers")
    ] {
      let analysis = SportsResolver.analyze(title: title, summary: nil, catalog: catalog)
      #expect(analysis.eligible)
      #expect(!analysis.associations.contains { $0.entityID == SportsReviewedCatalog.id(seed) })
    }
    let both = SportsResolver.analyze(title: "Indianapolis Colts sponsor Colts drum corps fundraiser", summary: nil, catalog: catalog)
    #expect(both.associations.contains { $0.entityID == SportsReviewedCatalog.id("team:dci:colts") })
  }
}
