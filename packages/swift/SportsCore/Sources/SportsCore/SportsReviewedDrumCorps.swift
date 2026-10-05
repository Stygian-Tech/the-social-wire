/// Directory identities reviewed against https://www.dci.org/corps/ on 2026-10-04.
/// Class membership is a reviewed snapshot, not a historical result or event-data claim.
/// Corps keys deliberately omit class so reclassification preserves follows and mutes.
enum SportsReviewedDrumCorps {
  static let classes: [(key: String, name: String, corps: [(key: String, name: String, aliases: [String])])] = [
    ("world", "World Class", [
      ("blue-devils", "Blue Devils", []), ("blue-knights", "Blue Knights", []),
      ("blue-stars", "Blue Stars", []), ("bluecoats", "Bluecoats", []),
      ("boston-crusaders", "Boston Crusaders", []), ("carolina-crown", "Carolina Crown", []),
      ("colts", "Colts", []), ("crossmen", "Crossmen", []), ("genesis", "Genesis", []),
      ("gold", "Gold", []), ("madison-scouts", "Madison Scouts", []), ("mandarins", "Mandarins", []),
      ("music-city", "Music City", []), ("pacific-crest", "Pacific Crest", []),
      ("phantom-regiment", "Phantom Regiment", []), ("santa-clara-vanguard", "Santa Clara Vanguard", ["SCV"]),
      ("seattle-cascades", "Seattle Cascades", ["Cascades"]), ("spartans", "Spartans", []),
      ("spirit-of-atlanta", "Spirit of Atlanta", []), ("academy", "The Academy", ["Academy Drum Corps"]),
      ("battalion", "The Battalion", ["Battalion Drum Corps"]), ("cavaliers", "The Cavaliers", ["Cavaliers"]),
      ("troopers", "Troopers", [])
    ]),
    ("open", "Open Class", [
      ("7th-regiment", "7th Regiment", ["Seventh Regiment"]), ("arsenal", "Arsenal", []),
      ("blue-devils-b", "Blue Devils B", []), ("blue-devils-c", "Blue Devils C", []),
      ("colt-cadets", "Colt Cadets", []), ("columbians", "Columbians", []), ("eclipse", "Eclipse", []),
      ("gems", "Gems", ["Boise Gems"]), ("golden-empire", "Golden Empire", []),
      ("guardians", "Guardians", []), ("heat-wave", "Heat Wave", []), ("impulse", "Impulse", []),
      ("les-stentors", "Les Stentors", []), ("memphis-blues", "Memphis Blues", []),
      ("raiders", "Raiders", []), ("river-city-rhythm", "River City Rhythm", []), ("zephyrus", "Zephyrus", [])
    ]),
    ("all-age", "All-Age Class", [
      ("atlanta-cv", "Atlanta CV", []), ("bushwackers", "Bushwackers Drum Corps", ["Bushwackers"]),
      ("cincinnati-tradition", "Cincinnati Tradition", []), ("columbus-saints", "Columbus Saints", []),
      ("fusion-core", "Fusion Core", []), ("govenaires", "Govenaires", []),
      ("hawthorne-caballeros", "Hawthorne Caballeros", []), ("hurricanes", "Hurricanes", ["Connecticut Hurricanes"]),
      ("mbi", "MBI", ["Minnesota Brass"]), ("northern-lights", "Northern Lights", []),
      ("reading-buccaneers", "Reading Buccaneers", []), ("rogues-hollow-regiment", "Rogues Hollow Regiment", []),
      ("sunrisers", "Sunrisers", []), ("white-sabers", "White Sabers", [])
    ]),
    ("international", "International Class", [
      ("beijing-57-high-school", "Beijing 57 High School", []),
      ("calgary-stampede-showband", "Calgary Stampede Showband", []),
      ("mercedes-marching-band", "Mercedes Marching Band", [])
    ])
  ]

  static var entities: [SportsEntity] {
    let sport = SportsReviewedCatalog.id("sport:drum-corps")
    let dci = SportsReviewedCatalog.id("competition:dci")
    var result: [SportsEntity] = [
      .init(id: dci, name: "Drum Corps International", kind: "competition", sportID: sport,
        aliases: ["DCI"], groupPath: ["Marching Arts", "DCI"])
    ]
    for entry in classes {
      let competition = SportsReviewedCatalog.id("competition:dci-" + entry.key)
      let path = ["Marching Arts", "DCI", entry.name]
      result.append(.init(id: competition, name: "DCI " + entry.name, kind: "competition", sportID: sport,
        competitionIDs: [dci], aliases: ["Drum Corps International " + entry.name],
        division: entry.name, groupPath: path))
      result += entry.corps.map { corps in
        .init(id: SportsReviewedCatalog.id("team:dci:" + corps.key), name: corps.name, kind: "team", sportID: sport,
          competitionIDs: [competition, dci], aliases: corps.aliases, division: entry.name, groupPath: path)
      }
    }
    return result
  }
}
