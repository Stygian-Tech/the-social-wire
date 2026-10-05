import Foundation

public enum SportsReviewedCollegePrograms {
  /// Existing Division I identities remain stable; affiliations are sport-specific.
  public static var entities: [SportsEntity] {
    let schools = ["Alabama", "Auburn", "Clemson", "Duke", "Florida", "Florida State", "Georgia", "Iowa", "Kansas", "Kentucky", "LSU", "Miami", "Michigan", "Michigan State", "North Carolina", "Notre Dame", "Ohio State", "Oklahoma", "Oregon", "Penn State", "South Carolina", "Stanford", "Tennessee", "Texas", "Texas A&M", "UCLA", "UConn", "USC", "Utah", "Virginia", "Virginia Tech", "Washington", "Wisconsin"]
    var result: [SportsEntity] = []
    var rosters = SportsReviewedCollegeRosters.conferences
    let divisionI: [(String, String, [String])] = [
      ("sec", "Southeastern Conference", ["Alabama", "Auburn", "Florida", "Georgia", "Kentucky", "LSU", "Oklahoma", "South Carolina", "Tennessee", "Texas", "Texas A&M"]),
      ("big-ten", "Big Ten Conference", ["Iowa", "Michigan", "Michigan State", "Ohio State", "Oregon", "Penn State", "UCLA", "USC", "Washington", "Wisconsin"]),
      ("acc", "Atlantic Coast Conference", ["Clemson", "Duke", "Florida State", "Miami", "North Carolina", "Stanford", "Virginia", "Virginia Tech"]),
      ("big-12", "Big 12 Conference", ["Kansas", "Utah"])
    ]
    for (key, name, members) in divisionI {
      for (sport, label) in [("ncaa-football", "Football"), ("ncaa-mens-basketball", "Men's Basketball"), ("ncaa-womens-basketball", "Women's Basketball")] {
        rosters.append(.init(key: key, name: name, division: "Division I", sportKey: sport, label: label,
          schools: members + (key == "acc" && sport != "ncaa-football" ? ["Notre Dame"] : []), source: key == "acc" ? "https://theacc.com/sports/2026/1/30/GEN_0130265701.aspx" : key == "big-12" ? "https://big12sports.com/standings.aspx?path=football" : key == "sec" ? "https://www.secsports.com/standings/football" : "https://bigten.org/standings.aspx?path=football"))
      }
    }
    for label in ["Men's Basketball", "Women's Basketball"] {
      rosters.append(.init(key: "big-east", name: "Big East Conference", division: "Division I",
        sportKey: label.hasPrefix("Women") ? "ncaa-womens-basketball" : "ncaa-mens-basketball", label: label,
        schools: ["UConn"], source: "https://www.bigeast.com/sports/2026/9/10/BE_history_090926.aspx"))
    }
    // Additional independent verification: https://uconnhuskies.com/sports/football/schedule/2026
    // and https://d26erm6jy2o8yz.cloudfront.net/news/2026/9/2/football-huskies-kick-off-2026-saturday-against-lafayette
    // Football independents are not assigned their school's basketball conference.
    rosters.append(.init(key: "independent", name: "Independents", division: "Division I", sportKey: "ncaa-football", label: "Football", schools: ["Notre Dame", "UConn"], source: "https://web3.ncaa.org/directory/orgDetail?id=513"))
    var schoolIDs: Set<String> = []
    var divisionCompetitions: Set<String> = []
    for roster in rosters {
      let sport = roster.sportKey == "ncaa-football" ? "american-football" : "basketball"
      let gender = roster.label.hasPrefix("Women") ? "women" : "men"
      let baseKey = roster.division == "Division I" ? roster.sportKey : roster.sportKey + ":" + roster.division
      let baseID = SportsReviewedCatalog.id("competition:" + baseKey)
      if roster.division != "Division I", divisionCompetitions.insert(baseID).inserted {
        result.append(.init(id: baseID, name: "NCAA " + roster.division + " " + roster.label, kind: "competition",
          sportID: SportsReviewedCatalog.id("sport:" + sport), gender: gender, division: roster.division,
          groupPath: ["NCAA", roster.division, roster.label]))
      }
      let conferenceID = SportsReviewedCatalog.id("competition:" + roster.competitionKey)
      let path = ["NCAA", roster.division, roster.label, roster.name]
      result.append(.init(id: conferenceID, name: roster.name + " " + roster.label, kind: "competition",
        sportID: SportsReviewedCatalog.id("sport:" + sport), aliases: [roster.name + " " + roster.label, roster.key.uppercased().replacingOccurrences(of: "-", with: " ") + " " + roster.label],
        gender: gender, division: roster.division, groupPath: Array(path.dropLast())))
      for school in roster.schools {
        let schoolID = SportsReviewedCatalog.id("school:" + school)
        if schoolIDs.insert(schoolID).inserted { result.append(.init(id: schoolID, name: school, kind: "school")) }
        result.append(.init(id: SportsReviewedCatalog.id("ncaa-team:" + school + ":" + roster.sportKey),
          name: school + " " + roster.label, kind: "ncaa-team", sportID: SportsReviewedCatalog.id("sport:" + sport),
          competitionIDs: [baseID, conferenceID], aliases: [school, school + " " + roster.label.lowercased()],
          memberships: [.init(entityID: conferenceID, validFrom: Date(timeIntervalSince1970: 1782864000), validUntil: Date(timeIntervalSince1970: 1814400000), season: "2026-27")],
          schoolID: schoolID, gender: gender, division: roster.division, groupPath: path))
      }
    }
    assert(Set(schools).isSubset(of: Set(result.filter { $0.kind == "school" }.map(\.name))))
    return result
  }
}
