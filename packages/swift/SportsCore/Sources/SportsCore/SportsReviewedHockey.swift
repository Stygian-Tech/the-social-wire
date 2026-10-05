import Foundation

/// Reviewed discipline and competition identities; event-provider coverage is enabled separately.
enum SportsReviewedHockey {
  static let childSportKeys: Set<String> = ["ice-hockey", "field-hockey", "street-ball-hockey", "inline-hockey", "rink-hockey"]
  // Reviewed 2026-10-04. Reference facts only; no provider IDs, scores, imagery, or scraped brackets.
  static let reviewSources = [
    "https://www.fih.hockey/events/fih-pro-league",
    "https://www.fih.hockey/events/fih-hockey-worldcup-belgium-netherlands-2026",
    "https://www.ncaa.com/sports/fieldhockey",
    "https://www.ncaa.com/complete-history-dii-festival",
    "https://www.ncaa.org/championship/division-iii/field-hockey/",
    "https://www.isbhf.com/about-isbhf",
    "https://www.worldskate.org/inline-hockey.html",
    "https://www.worldskate.org/rink-hockey.html"
  ]

  static var entities: [SportsEntity] {
    let field = SportsReviewedCatalog.id("sport:field-hockey")
    var result: [SportsEntity] = []
    for (key, name, aliases) in [
      ("fih-pro-league", "FIH Hockey Pro League", ["FIH Pro League"]),
      ("fih-world-cup", "FIH Hockey World Cup", ["FIH World Cup"])
    ] {
      let parent = SportsReviewedCatalog.id("competition:" + key)
      result.append(.init(id: parent, name: name, kind: "competition", sportID: field, aliases: aliases, groupPath: ["Competitions", "Hockey", "Field Hockey", "International"]))
      for (gender, label) in [("men", "Men's"), ("women", "Women's")] {
        result.append(.init(id: SportsReviewedCatalog.id("competition:" + key + "-" + gender), name: "FIH \(label) \(key == "fih-pro-league" ? "Hockey Pro League" : "Hockey World Cup")", kind: "competition", sportID: field, competitionIDs: [parent], aliases: ["FIH \(label) \(key == "fih-pro-league" ? "Pro League" : "World Cup")", "\(label) FIH \(key == "fih-pro-league" ? "Pro League" : "World Cup")"], gender: gender, groupPath: ["Competitions", "Hockey", "Field Hockey", "International", name]))
      }
    }
    let ncaa = SportsReviewedCatalog.id("competition:ncaa-womens-field-hockey")
    result.append(.init(id: ncaa, name: "NCAA Women's Field Hockey", kind: "competition", sportID: field, aliases: ["NCAA field hockey", "college field hockey"], gender: "women", groupPath: ["Competitions", "Hockey", "Field Hockey", "NCAA"]))
    for (division, code) in [("Division I", "d1"), ("Division II", "d2"), ("Division III", "d3")] {
      result.append(.init(id: SportsReviewedCatalog.id("competition:ncaa-womens-field-hockey-" + code), name: "NCAA \(division) Women's Field Hockey", kind: "competition", sportID: field, competitionIDs: [ncaa], aliases: ["NCAA \(division) field hockey", "NCAA \(code.uppercased()) field hockey"], gender: "women", division: division, groupPath: ["Competitions", "Hockey", "Field Hockey", "NCAA", division]))
    }
    for (key, name, sport, aliases) in [
      ("isbhf-world-championships", "ISBHF World Championships", "street-ball-hockey", ["ISBHF World Ball Hockey Championships", "World Ball Hockey Championships"]),
      ("world-skate-inline-hockey", "World Skate Inline Hockey Championships", "inline-hockey", ["Inline Hockey World Championships"]),
      ("world-skate-rink-hockey", "World Skate Rink Hockey Championships", "rink-hockey", ["Rink Hockey World Championships"])
    ] {
      let label = sport == "street-ball-hockey" ? "Street/Ball Hockey" : sport == "inline-hockey" ? "Inline Hockey" : "Rink Hockey"
      result.append(.init(id: SportsReviewedCatalog.id("competition:" + key), name: name, kind: "competition", sportID: SportsReviewedCatalog.id("sport:" + sport), aliases: aliases, groupPath: ["Competitions", "Hockey", label, "International"]))
    }
    return result
  }
}
