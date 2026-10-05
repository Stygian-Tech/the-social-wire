/// Reviewed organization and school short names; never applies one ensemble's code to another program.
enum SportsReviewedAmateurAbbreviations {
  // Reviewed 2026-10-04 against official organization/school references:
  // https://www.ncaa.com/news/basketball-women/article/2026-04-05/ucla-wins-2026-di-womens-basketball-championship
  // https://uwbadgers.com/documents/download/2015/8/21/release_20140825aaa.pdf
  // https://ohiostatebuckeyes.com/documents/download/2026/5/26/4_2026_FB_Media_Guide_2025_Review_FINAL.pdf
  // https://seminoles.com/sports/football and https://shop.goheels.com/?SITE=UNC
  // https://www.dci.org/news/spotlight-of-the-week-1992-santa-clara-vanguard/
  // https://www.dci.org/news/spotlight-of-the-week-2008-boston-crusaders/
  // https://www.dci.org/news/dvd-spotlight-of-the-week-2010-blue-devils/
  // https://ascendperformingarts.org/ and https://regiment.org/pr-academy-opens-registration-for-virtual-and-in-person-camps/
  // https://unitedpercussion.org/2027 and https://www.wgi.org/independent-world-percussion-champions/
  // https://ascendperformingarts.org/ensembles/bkpe/audition/
  static let schoolCodes: [String: String] = [
    "UCLA": "UCLA", "UConn": "UConn", "LSU": "LSU", "USC": "USC",
    "Wisconsin": "WISC", "Ohio State": "OSU", "Florida State": "FSU", "North Carolina": "UNC"
  ]
  static let codes: [String: String] = {
    let schoolCodesByID = Dictionary(uniqueKeysWithValues: schoolCodes.map { (SportsReviewedCatalog.id("school:" + $0.key), $0.value) })
    var result = Dictionary(uniqueKeysWithValues: SportsReviewedCollegePrograms.entities.compactMap { team -> (String, String)? in
      guard team.kind == "ncaa-team", let school = team.schoolID, let code = schoolCodesByID[school] else { return nil }
      return (team.id, code)
    })
    for (key, code) in [("blue-devils", "BD"), ("blue-knights", "BK"), ("boston-crusaders", "BAC"), ("santa-clara-vanguard", "SCV"), ("phantom-regiment", "PR")] {
      result[SportsReviewedCatalog.id("team:dci:" + key)] = code
    }
    for (name, code) in [("United Percussion", "UPW"), ("United Percussion 2", "UP2"), ("RCC", "RCC"), ("Blue Knights", "BKPE")] {
      result[SportsReviewedCatalog.id(SportsReviewedWGI.groupKey(discipline: "percussion", format: "Marching", name: name))] = code
    }
    return result
  }()
}
