import SportsCore
import Testing

struct SportsSwimmingCoverageTests {
  @Test func reviewedSwimmingSeparatesNCAADivisionAndGender() throws {
    let catalog = SportsReviewedCatalog.entities
    let championships = catalog.filter { $0.name.hasPrefix("NCAA Division") && $0.name.contains("Swimming") }
    #expect(championships.count == 6)
    #expect(Set(championships.map(\.id)).count == 6)
    for division in ["Division I", "Division II", "Division III"] {
      #expect(Set(championships.filter { $0.division == division }.compactMap(\.gender)) == ["men", "women"])
    }
    let analysis = SportsResolver.analyze(title: "NCAA DIII Women's Swimming championships produce a relay record", summary: nil, catalog: catalog)
    let matched = championships.filter { entity in analysis.associations.contains { $0.entityID == entity.id } }
    #expect(matched.count == 1)
    #expect(matched.first?.division == "Division III")
    #expect(matched.first?.gender == "women")
    #expect(matched.first?.groupPath == ["NCAA", "Division III", "Swimming and Diving", "Women's"])
  }

  @Test func realAsianGamesArticlesReceiveValidatedSwimmingAssociations() throws {
    let catalog = SportsReviewedCatalog.entities
    let swimming = SportsReviewedCatalog.id("sport:swimming")
    let asianGames = SportsReviewedCatalog.id("competition:asian-games-swimming")
    for (title, summary) in [
      ("China’s swimming prodigy Yu Zidi bags third gold in Asian Games record", "The 13-year-old beat the previous 400m Asian Games record, set by China’s Ye Shiwen in 2014, by about 4.5 seconds."),
      ("Pan Zhanle Retains His 100m Freestyle Crown by 0.04 Seconds at the Asian Games", "Pan Zhanle defended his Asian Games 100m freestyle title in Nagoya with 47.61, a 0.04-second margin — his best swim since Paris 2024, in a race he says he believed he was losing until the final metre.")
    ] {
      let analysis = SportsResolver.analyze(title: title, summary: summary, catalog: catalog)
      #expect(analysis.eligible)
      #expect(analysis.sportIDs.contains(swimming))
      #expect(analysis.competitionIDs.contains(asianGames))
      #expect(analysis.associations.contains { $0.entityID == swimming && $0.confidence >= 0.9 && !$0.evidence.isEmpty })
      #expect(analysis.associations.contains { $0.entityID == asianGames && $0.prominence == 0 })
    }
  }

  @Test func internationalAndOlympicSwimmingFeedsStayMatchingOnly() throws {
    let catalog = SportsReviewedCatalog.entities
    for (title, key) in [
      ("World Aquatics Swimming Championships (25m) opens with relay record", "world-swimming-25m"),
      ("Swimming World Cup produces a world record in Baku", "swimming-world-cup"),
      ("World Para Swimming Championships gold medal race ends in record", "world-para-swimming"),
      ("Olympics: swimmer wins 100m backstroke gold medal", "olympic-swimming"),
      ("Paralympics: swimming relay team wins gold", "paralympic-swimming"),
      ("Paralympic swimming programme announced", "paralympic-swimming")
    ] {
      let id = SportsReviewedCatalog.id("competition:" + key)
      let feed = try #require(SportsNamedFeeds.catalog(entities: catalog).first { $0.entityIDs == [id] })
      let analysis = SportsResolver.analyze(title: title, summary: nil, catalog: catalog)
      #expect(analysis.eligible)
      #expect(feed.matches(analysis))
      #expect(!feed.matches(SportsResolver.analyze(title: "Olympics basketball final produces a gold medal", summary: nil, catalog: catalog)))
    }
  }

  @Test func recreationRoboticsAdultSwimAndOtherFreestyleSportsDoNotBecomeSwimmingNews() {
    let catalog = SportsReviewedCatalog.entities
    let swimming = SportsReviewedCatalog.id("sport:swimming")
    for title in ["MIT robot swims through water via living muscle cells", "Concrete Camouflage: a good swim at the gym", "Robot Chicken Adult Swim Special celebrates anniversary", "Swimmer killed in shark attack off Western Australia beach", "Hotel opens Olympic swimming pool", "Freestyle skiing wins Olympic gold medal", "BMX freestyle championship crowns a winner", "Freestyle bike race crowns a winner", "Freestyle race championships announced"] {
      let analysis = SportsResolver.analyze(title: title, summary: nil, catalog: catalog)
      #expect(!analysis.sportIDs.contains(swimming))
      #expect(!analysis.associations.contains { $0.entityID == swimming })
    }
  }
}
