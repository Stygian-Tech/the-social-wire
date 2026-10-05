import SportsCore
import Testing

struct SportsFormulaOneCatalogTests {
  @Test func reviewedFormulaOneGridContainsElevenDistinctTeams() throws {
    let f1 = SportsReviewedCatalog.id("competition:f1")
    let teams = SportsReviewedCatalog.entities.filter { $0.kind == "team" && $0.competitionIDs.contains(f1) }
    let expected: Set<String> = ["McLaren Formula 1 Team", "Mercedes Formula 1 Team", "Scuderia Ferrari", "Red Bull Racing", "Racing Bulls", "Aston Martin Formula 1 Team", "Alpine Formula 1 Team", "Williams Formula 1 Team", "Haas Formula 1 Team", "Audi Formula 1 Team", "Cadillac Formula 1 Team"]
    #expect(Set(teams.map(\.name)) == expected)
    #expect(Set(teams.map(\.id)).count == 11)
    let redBull = try #require(teams.first { $0.name == "Red Bull Racing" })
    let racingBulls = try #require(teams.first { $0.name == "Racing Bulls" })
    #expect(redBull.id == SportsReviewedCatalog.id("team:f1:Red Bull Racing"))
    #expect(redBull.aliases.contains("RBR"))
    #expect(redBull.aliases.contains("Oracle Red Bull Racing"))
    #expect(racingBulls.aliases.contains("VCARB"))
    #expect(racingBulls.aliases.contains("Visa Cash App Racing Bulls"))
    #expect(!teams.contains { $0.aliases.contains("RB") })
    #expect(redBull.id != racingBulls.id)
  }

  @Test func constructorAcronymsRequireFormulaOneAndStaySeparate() throws {
    let catalog = SportsReviewedCatalog.entities
    let redBull = try #require(catalog.first { $0.name == "Red Bull Racing" })
    let racingBulls = try #require(catalog.first { $0.name == "Racing Bulls" })
    for (headline, id, other) in [
      ("RBR announces F1 upgrade ahead of race", redBull.id, racingBulls.id),
      ("VCARB announces Formula 1 driver signing", racingBulls.id, redBull.id),
      ("Oracle Red Bull Racing wins Formula One championship", redBull.id, racingBulls.id),
      ("Visa Cash App Racing Bulls earns F1 podium", racingBulls.id, redBull.id)
    ] {
      let analysis = SportsResolver.analyze(title: headline, summary: nil, catalog: catalog)
      #expect(analysis.associations.contains { $0.entityID == id })
      #expect(!analysis.associations.contains { $0.entityID == other })
    }
    for headline in ["RBR publishes quarterly research report", "RBR sponsors cycling race", "VCARB wins charity road race", "RB announces new product"] {
      let analysis = SportsResolver.analyze(title: headline, summary: nil, catalog: catalog)
      #expect(!analysis.associations.contains { $0.entityID == redBull.id || $0.entityID == racingBulls.id })
    }
    let both = SportsResolver.analyze(title: "RBR and VCARB confirm F1 driver lineups", summary: nil, catalog: catalog)
    #expect(both.associations.contains { $0.entityID == redBull.id })
    #expect(both.associations.contains { $0.entityID == racingBulls.id })
  }
}
