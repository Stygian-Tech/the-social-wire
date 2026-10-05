/// DCI and corps names overlap businesses, military units and ball-sport teams.
enum SportsDrumCorpsContext {
  static func permits(_ text: String) -> Bool {
    let has = { SportsResolver.contains($0, in: text) }
    if ["drum corps", "drum and bugle corps", "drum bugle corps", "drumcorps", "marching music"].contains(where: has) { return true }
    guard has("DCI") else { return false }
    return ["corps", "drumline", "brass", "percussion", "color guard", "colour guard", "world class", "open class", "all age", "Bluecoats", "Phantom Regiment", "Santa Clara Vanguard", "Carolina Crown", "Boston Crusaders"].contains(where: has)
  }
}
