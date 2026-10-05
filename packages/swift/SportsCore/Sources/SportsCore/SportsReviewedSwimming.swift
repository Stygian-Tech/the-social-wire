import Foundation

/// Factual competition identities reviewed against the governing bodies' championship pages.
enum SportsReviewedSwimming {
  static let reviewSources = [
    "https://www.ncaa.org/championship/division-i/swimming-and-diving/",
    "https://www.ncaa.org/championship/division-ii/swimming-and-diving/",
    "https://www.ncaa.org/championship/division-iii/swimming-and-diving/",
    "https://www.worldaquatics.com/swimming/competitions",
    "https://www.paralympic.org/swimming/events",
    "https://www.aichi-nagoya2026.org/sport/swimming/"
  ]
  static var entities: [SportsEntity] {
    let swimming = SportsReviewedCatalog.id("sport:swimming")
    let ncaa = SportsReviewedCatalog.id("competition:ncaa-swimming")
    var result = [SportsEntity(id: ncaa, name: "NCAA Swimming and Diving", kind: "competition", sportID: swimming,
      aliases: ["NCAA swimming", "NCAA swimming championships", "college swimming"],
      groupPath: ["NCAA", "Swimming and Diving"])]
    for (division, code) in [("Division I", "DI"), ("Division II", "DII"), ("Division III", "DIII")] {
      for (gender, label) in [("men", "Men's"), ("women", "Women's")] {
        result.append(.init(id: SportsReviewedCatalog.id("competition:ncaa-\(code.lowercased())-\(gender)-swimming"),
          name: "NCAA \(division) \(label) Swimming and Diving Championships", kind: "competition", sportID: swimming,
          competitionIDs: [ncaa], aliases: ["NCAA \(code) \(label) Swimming", "NCAA \(division) \(label) Swimming", "\(code) \(label) swimming championships"],
          gender: gender, division: division, groupPath: ["NCAA", division, "Swimming and Diving", label]))
      }
    }
    let international: [(String, String, [String], String, [String])] = [
      ("world-swimming", "World Swimming Championships", ["World Aquatics swimming championships", "FINA World Swimming Championships"], "https://www.worldaquatics.com/swimming/competitions", []),
      ("world-swimming-25m", "World Aquatics Swimming Championships (25m)", ["World Short Course Swimming Championships", "World Swimming Championships 25m"], "https://www.worldaquatics.com/swimming/competitions", ["world-swimming"]),
      ("swimming-world-cup", "Swimming World Cup", ["World Aquatics Swimming World Cup", "FINA Swimming World Cup"], "https://www.worldaquatics.com/swimming/competitions", []),
      ("world-para-swimming", "World Para Swimming Championships", ["Para Swimming World Championships", "IPC Swimming World Championships"], "https://www.paralympic.org/swimming/events", ["para-swimming"]),
      ("olympic-swimming", "Olympic Swimming", ["Olympic swimming competition"], "https://www.worldaquatics.com/swimming/competitions", ["olympics"]),
      ("paralympic-swimming", "Paralympic Swimming", ["Paralympic swimming competition"], "https://www.paralympic.org/swimming/events", ["paralympics", "para-swimming"]),
      ("asian-games-swimming", "Asian Games Swimming", ["swimming at the Asian Games"], "https://www.aichi-nagoya2026.org/sport/swimming/", [])
    ]
    result += international.map { key, name, aliases, _, parents in
      .init(id: SportsReviewedCatalog.id("competition:" + key), name: name, kind: "competition", sportID: swimming,
        competitionIDs: parents.map { SportsReviewedCatalog.id("competition:" + $0) }, aliases: aliases,
        groupPath: ["Competitions", "Swimming", "International"])
    }
    return result
  }
}
