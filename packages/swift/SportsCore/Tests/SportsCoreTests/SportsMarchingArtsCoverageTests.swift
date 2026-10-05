import SportsCore
import Testing

struct SportsMarchingArtsCoverageTests {
  @Test func umbrellaKeepsExistingDCIAndWGIIdentitiesAndPaths() throws {
    let catalog = SportsReviewedCatalog.entities
    let umbrella = try #require(catalog.first { $0.id == SportsReviewedCatalog.id("sport:marching-arts") })
    #expect(umbrella.name == "Marching Arts")
    for (seed, circuit) in [("team:dci:bluecoats", "DCI"), ("sport:drum-corps", "DCI"),
      ("sport:indoor-marching-arts", "WGI"), ("competition:wgi-percussion", "WGI"), ("competition:boa", "BOA")] {
      let entity = try #require(catalog.first { $0.id == SportsReviewedCatalog.id(seed) })
      #expect(Array((entity.groupPath ?? []).prefix(2)) == ["Marching Arts", circuit])
    }
    #expect(Set(catalog.map(\.id)).count == catalog.count)
  }

  @Test func officialBOAParticipantsAndFourClassesAreReviewedWithoutGuessedMembership() {
    let catalog = SportsReviewedCatalog.entities
    let boa = SportsReviewedCatalog.id("competition:boa")
    let bands = catalog.filter { $0.kind == "team" && $0.competitionIDs.contains(boa) }
    #expect(bands.count == 98)
    #expect(bands.allSatisfy { $0.providerIDs.isEmpty && $0.division == "2026 Grand Nationals Participant" })
    for code in ["a", "aa", "aaa", "aaaa"] {
      let id = SportsReviewedCatalog.id("competition:boa-class:" + code)
      #expect(catalog.contains { $0.id == id && $0.competitionIDs == [boa] })
      #expect(!bands.contains { $0.competitionIDs.contains(id) })
      let explicit = SportsResolver.analyze(title: "BOA Class \(code.uppercased()) championship announced",
        summary: nil, catalog: catalog)
      #expect(explicit.associations.contains { $0.entityID == id })
    }
  }

  @Test func allCircuitsResolveToMarchingArtsAndKeepMatchingOnlyFeeds() throws {
    let catalog = SportsReviewedCatalog.entities
    let feeds = SportsNamedFeeds.catalog(entities: catalog)
    let umbrellaID = SportsReviewedCatalog.id("sport:marching-arts")
    let umbrella = try #require(feeds.first { $0.entityIDs == [umbrellaID] })
    for title in ["Bluecoats win DCI drum corps championship", "Rhythm X wins WGI percussion finals",
      "Bands of America announces Grand National Championships", "Avon HS marching band prepares for BOA finals"] {
      let analysis = SportsResolver.analyze(title: title, summary: nil, catalog: catalog)
      #expect(analysis.eligible)
      #expect(analysis.sportIDs.contains(umbrellaID))
      #expect(umbrella.matches(analysis))
    }
    let nba = SportsResolver.analyze(title: "NBA basketball championship game", summary: nil, catalog: catalog)
    #expect(!umbrella.matches(nba))
  }

  @Test func boaAcronymAndSchoolNamesDoNotBecomeMarchingBandsWithoutContext() {
    let catalog = SportsReviewedCatalog.entities
    let boa = SportsReviewedCatalog.id("competition:boa")
    for title in ["BOA announces banking earnings", "Boa constrictor discovered in Carmel",
      "Avon HS basketball qualifies for state championship", "Grand national horse race begins"] {
      let result = SportsResolver.analyze(title: title, summary: nil, catalog: catalog)
      #expect(!result.competitionIDs.contains(boa))
    }
    let band = SportsResolver.analyze(title: "Avon HS marching band wins BOA championship", summary: nil, catalog: catalog)
    #expect(band.associations.contains { $0.entityID == SportsReviewedCatalog.id("team:boa:in:avon-hs") })
    let wgi = SportsResolver.analyze(title: "Avon HS wins WGI Color Guard finals", summary: nil, catalog: catalog)
    #expect(!wgi.associations.contains { $0.entityID == SportsReviewedCatalog.id("team:boa:in:avon-hs") })
    let plainBand = SportsResolver.analyze(title: "Avon HS marching band unveils its new show", summary: nil, catalog: catalog)
    #expect(plainBand.associations.contains { $0.entityID == SportsReviewedCatalog.id("team:boa:in:avon-hs") })
  }

  @Test func umbrellaFollowAndMuteApplyAcrossCircuits() {
    let catalog = SportsReviewedCatalog.entities
    let result = SportsResolver.analyze(title: "Rhythm X wins WGI percussion finals", summary: nil, catalog: catalog)
    let umbrella = SportsReviewedCatalog.id("sport:marching-arts")
    let candidate = SportsRankCandidate(item: SportsCoreTests().item("wgi-story"), analysis: result, baseScore: 1)
    #expect(SportsRanker.rank(candidates: [candidate], followIDs: [umbrella], entities: catalog).count == 1)
    #expect(SportsRanker.rank(candidates: [candidate], muteIDs: [umbrella], entities: catalog).isEmpty)
  }
}
