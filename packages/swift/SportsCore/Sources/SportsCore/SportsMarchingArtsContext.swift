/// Acronyms and school names require evidence of the performing activity.
enum SportsMarchingArtsContext {
  static func permitsBOA(_ text: String) -> Bool {
    if SportsResolver.contains("Bands of America", in: text) { return true }
    guard SportsResolver.contains("BOA", in: text) else { return false }
    if ["marching band", "bands", "band", "marching championship", "marching competition"]
      .contains(where: { SportsResolver.contains($0, in: text) }) { return true }
    return ["BOA Class A", "BOA Class AA", "BOA Class AAA", "BOA Class AAAA"]
      .contains { SportsResolver.contains($0, in: text) }
      && ["championship", "champion", "competition", "finals"].contains { SportsResolver.contains($0, in: text) }
  }

  static func permits(_ text: String) -> Bool {
    SportsDrumCorpsContext.permits(text) || SportsWGIContext.permits(text) || permitsBOA(text)
      || SportsResolver.contains("marching arts", in: text)
      || SportsResolver.contains("marching band", in: text)
  }
}
