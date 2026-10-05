/// WGI initials, school names, Guard, Winds, Matrix and Paramount overlap unrelated subjects.
enum SportsWGIContext {
  static func disciplines(in text: String) -> [String] {
    let has = { SportsResolver.contains($0, in: text) }
    let organization = has("WGI") || has("Winter Guard International")
    var result: [String] = []
    if ["winter guard", "winterguard", "indoor color guard", "indoor colour guard"].contains(where: has)
      || (organization && ["color guard", "colour guard", "guard", "colorguard"].contains(where: has)) { result.append("color-guard") }
    if ["indoor percussion", "indoor drumline"].contains(where: has)
      || (organization && ["percussion", "drumline", "PIA", "PIO", "PIW", "PSA", "PSO", "PSW", "PSCA", "PSCO", "PSCW"].contains(where: has)) { result.append("percussion") }
    if ["indoor winds", "winter winds", "WGI Winds"].contains(where: has)
      || (organization && ["winds", "wynds", "WSA", "WSO", "WSW", "WIA", "WIO", "WIW"].contains(where: has)) { result.append("winds") }
    return result
  }

  static func permits(_ text: String) -> Bool {
    !disciplines(in: text).isEmpty || SportsResolver.contains("Winter Guard International", in: text)
      || (SportsResolver.contains("WGI", in: text) && SportsResolver.contains("Sport of the Arts", in: text))
  }

  static func permits(entity: SportsEntity, text: String) -> Bool {
    guard permits(text) else { return false }
    let disciplines = disciplines(in: text)
    for key in ["color-guard", "percussion", "winds"] {
      let id = SportsReviewedCatalog.id("competition:wgi-" + key)
      if entity.id == id || entity.competitionIDs.contains(id) {
        guard disciplines.contains(key) else { return false }
      }
    }
    if entity.kind == "team", entity.groupPath?.contains("Concert") == true {
      return SportsResolver.contains("concert", in: text)
    }
    if entity.kind == "team", entity.groupPath?.contains("Marching") == true,
      SportsResolver.contains("concert percussion", in: text) && !SportsResolver.contains("marching", in: text) { return false }
    return true
  }
}
