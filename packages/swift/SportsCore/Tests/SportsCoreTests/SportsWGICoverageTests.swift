import SportsCore
import Testing

struct SportsWGICoverageTests {
  @Test func officialClassesAndFinalistIdentitiesHaveDistinctHierarchy() throws {
    let catalog = SportsReviewedCatalog.entities
    let sport = SportsReviewedCatalog.id("sport:indoor-marching-arts")
    let wgi = SportsReviewedCatalog.id("competition:wgi")
    let entities = catalog.filter { $0.id == sport || $0.sportID == sport }
    #expect(entities.count == 345)
    #expect(entities.filter { $0.kind == "team" }.count == 317)
    #expect(Set(catalog.map(\.id)).count == catalog.count)
    for (key, classCount, groupCount) in [("color-guard", 8, 94), ("percussion", 9, 177), ("winds", 6, 46)] {
      let disciplineID = SportsReviewedCatalog.id("competition:wgi-" + key)
      let discipline = try #require(entities.first { $0.id == disciplineID })
      #expect(discipline.competitionIDs == [wgi])
      #expect(entities.filter { $0.kind == "competition" && $0.competitionIDs.contains(disciplineID) }.count == classCount)
      #expect(entities.filter { $0.kind == "team" && $0.competitionIDs.contains(disciplineID) }.count == groupCount)
    }
    let ayala = entities.filter { $0.kind == "team" && $0.name.hasPrefix("Ayala HS") }
    #expect(ayala.count == 2)
    #expect(Set(ayala.map(\.id)).count == 2)
    #expect(ayala.allSatisfy { $0.providerIDs.isEmpty && $0.division?.hasPrefix("2026 ") == true })
  }

  @Test func contextualNewsResolvesAllThreeDisciplinesAndClasses() {
    let catalog = SportsReviewedCatalog.entities
    for (title, discipline, classKey, teamName) in [
      ("Fusion Winter Guard wins WGI Color Guard Independent World finals", "color-guard", "iw", "Fusion Winter Guard"),
      ("Rhythm X wins WGI Percussion PIW championship", "percussion", "piw", "Rhythm X"),
      ("STRYKE Wynds wins WGI Winds Independent World finals", "winds", "wiw", "STRYKE Wynds")
    ] {
      let result = SportsResolver.analyze(title: title, summary: nil, catalog: catalog)
      #expect(result.eligible)
      #expect(result.competitionIDs.contains(SportsReviewedCatalog.id("competition:wgi")))
      #expect(result.competitionIDs.contains(SportsReviewedCatalog.id("competition:wgi-" + discipline)))
      #expect(result.associations.contains { $0.entityID == SportsReviewedCatalog.id("competition:wgi-class:" + classKey) })
      let team = catalog.first { $0.kind == "team" && $0.name == teamName }
      #expect(result.associations.contains { $0.entityID == team?.id && $0.confidence >= 0.9 })
    }
  }

  @Test func officialFinalistReviewTitlesResolveFromTheirOpeningContext() {
    // Primary source: https://www.wgi.org/2026-piw-class-finalist-review/
    let result = SportsResolver.analyze(title: "2026 PIW Class Finalist Review",
      summary: "WGI reviews its Independent World percussion finalists, including Rhythm X and Pulse Percussion.",
      catalog: SportsReviewedCatalog.entities)
    #expect(result.eligible)
    #expect(result.competitionIDs.contains(SportsReviewedCatalog.id("competition:wgi-percussion")))
    #expect(result.associations.contains { $0.entityID == SportsReviewedCatalog.id("competition:wgi-class:piw") })
  }

  @Test func genericNamesAndSchoolSportsRequireDisciplineEvidence() {
    let catalog = SportsReviewedCatalog.entities
    let wgiIDs = Set(catalog.filter { $0.sportID == SportsReviewedCatalog.id("sport:indoor-marching-arts") }.map(\.id))
    for title in ["WGI announces quarterly earnings", "Paramount and Matrix announce merger", "Avon HS basketball wins championship",
      "Wind gusts damage the guard station", "RCC opens new campus", "Rhythm X unveils uniforms"] {
      let result = SportsResolver.analyze(title: title, summary: nil, catalog: catalog)
      #expect(!result.associations.contains { wgiIDs.contains($0.entityID) })
    }
    let guardStory = SportsResolver.analyze(title: "Avon HS wins WGI Color Guard championship", summary: nil, catalog: catalog)
    let matchingTeams = catalog.filter { $0.kind == "team" && guardStory.associations.map(\.entityID).contains($0.id)
      && $0.sportID == SportsReviewedCatalog.id("sport:indoor-marching-arts") }
    #expect(matchingTeams.map(\.name) == ["Avon HS Color Guard"])
  }

  @Test func relatedEnsemblesDoNotCollapseAndNamedFeedsRemainMatchingOnly() throws {
    let catalog = SportsReviewedCatalog.entities
    let story = SportsResolver.analyze(title: "Infinity 2 qualifies for WGI percussion finals", summary: nil, catalog: catalog)
    let infinity = try #require(catalog.first { $0.name == "Infinity" && $0.kind == "team" })
    let infinity2 = try #require(catalog.first { $0.name == "Infinity 2" && $0.kind == "team" })
    #expect(!story.associations.contains { $0.entityID == infinity.id })
    #expect(story.associations.contains { $0.entityID == infinity2.id })
    let feeds = SportsNamedFeeds.catalog(entities: catalog)
    #expect(try #require(feeds.first { $0.entityIDs == [infinity2.id] }).matches(story))
    #expect(!((try #require(feeds.first { $0.entityIDs == [infinity.id] })).matches(story)))
    let concert = SportsResolver.analyze(title: "Ayala HS wins WGI concert percussion finals", summary: nil, catalog: catalog)
    let ayalaTeams = catalog.filter { $0.kind == "team" && $0.name.hasPrefix("Ayala HS") }
    #expect(ayalaTeams.filter { concert.associations.map(\.entityID).contains($0.id) }.map(\.name) == ["Ayala HS Concert Percussion"])
  }

  @Test func prelimRosterExtendsBeyondFinalistsWithExplicitClasses() throws {
    let catalog = SportsReviewedCatalog.entities
    for (name, code) in [("NorthCoast Academy", "pia"), ("Lotus", "pio"), ("Blue Knights", "piw"), ("Fishers HS Marching Percussion", "psw")] {
      let entity = try #require(catalog.first { $0.kind == "team" && $0.name == name && $0.sportID == SportsReviewedCatalog.id("sport:indoor-marching-arts") })
      #expect(entity.competitionIDs.contains(SportsReviewedCatalog.id("competition:wgi-class:" + code)))
      #expect(entity.division?.hasPrefix("2026 ") == true)
    }
    let unrelated = SportsResolver.analyze(title: "Lotus launches new electric car and United Airlines expands", summary: nil, catalog: catalog)
    let wgiTeams = Set(catalog.filter { $0.kind == "team" && $0.sportID == SportsReviewedCatalog.id("sport:indoor-marching-arts") }.map(\.id))
    #expect(!unrelated.associations.contains { wgiTeams.contains($0.entityID) })
    let contextual = SportsResolver.analyze(title: "Lotus joins WGI indoor percussion PIO prelims", summary: nil, catalog: catalog)
    let lotus = try #require(catalog.first { $0.name == "Lotus" && $0.kind == "team" })
    #expect(contextual.associations.contains { $0.entityID == lotus.id })
  }

  @Test func unitedProgramsAreSeparateAndContextual() throws {
    let catalog = SportsReviewedCatalog.entities
    let world = try #require(catalog.first { $0.name == "United Percussion" && $0.kind == "team" })
    let open = try #require(catalog.first { $0.name == "United Percussion 2" && $0.kind == "team" })
    #expect(world.id != open.id)
    #expect(world.aliases.contains("United Percussion World"))
    #expect(world.competitionIDs.contains(SportsReviewedCatalog.id("competition:wgi-class:piw")))
    #expect(open.competitionIDs.contains(SportsReviewedCatalog.id("competition:wgi-class:pio")))
    #expect(world.groupPath == ["Marching Arts", "WGI", "WGI Percussion", "Marching", "Independent", "World Class"])
    #expect(open.groupPath?.last == "Open Class")
    #expect(world.id == SportsReviewedCatalog.id("team:wgi:percussion:marching:united-percussion"))
    for (title, expected, excluded) in [
      ("United Percussion World announces WGI indoor percussion auditions", world.id, open.id),
      ("United Percussion 2 qualifies for WGI percussion semifinals", open.id, world.id),
      ("UP2 announces WGI indoor percussion auditions", open.id, world.id)
    ] {
      let story = SportsResolver.analyze(title: title, summary: nil, catalog: catalog)
      #expect(story.associations.contains { $0.entityID == expected })
      #expect(!story.associations.contains { $0.entityID == excluded })
    }
    for title in ["United wins football championship", "United Percussion announces quarterly earnings", "United Airlines expands service"] {
      let story = SportsResolver.analyze(title: title, summary: nil, catalog: catalog)
      #expect(!story.associations.contains { [world.id, open.id].contains($0.entityID) })
    }
  }

  @Test func localWinterGuardDoesNotImplyWGICompetitionMembership() {
    let result = SportsResolver.analyze(title: "Local winter guard wins city championship", summary: nil,
      catalog: SportsReviewedCatalog.entities)
    #expect(result.eligible)
    #expect(result.sportIDs.contains(SportsReviewedCatalog.id("sport:indoor-marching-arts")))
    #expect(!result.competitionIDs.contains(SportsReviewedCatalog.id("competition:wgi")))
  }
}
