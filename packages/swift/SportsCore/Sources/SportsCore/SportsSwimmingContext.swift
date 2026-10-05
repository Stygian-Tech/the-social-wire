/// Swimming words also occur in recreation, robotics, television and unrelated freestyle sports.
enum SportsSwimmingContext {
  static func isCompetitive(_ text: String) -> Bool {
    let has = { SportsResolver.contains($0, in: text) }
    guard !["adult swim", "robot", "robots", "robotic", "freestyle rap", "freestyle dance"].contains(where: has) else { return false }
    let explicitSwimming = ["swimming", "swimmer", "swimmers", "swim", "backstroke", "breaststroke", "butterfly stroke", "individual medley"].contains(where: has)
    if !explicitSwimming && ["bmx", "ski", "skiing", "snowboard", "snowboarding", "skateboarding", "wrestling", "motocross"].contains(where: has) { return false }
    let distance = text.split(separator: " ").contains { token in
      ["m", "yd", "yards", "metres", "meters"].contains { unit in
        token.hasSuffix(unit) && Int(token.dropLast(unit.count)).map { $0 > 0 } == true
      }
    }
    let swimming = explicitSwimming || (has("freestyle") && distance)
    let competition = ["championship", "championships", "world record", "gold", "gold medal", "silver medal", "bronze medal", "medals", "swim meet", "swimming meet", "race", "relay", "olympics", "olympic games", "olympic swimming competition", "paralympics", "paralympic", "paralympic games", "paralympic swimming", "asian games", "ncaa", "world aquatics", "swimming world cup"].contains(where: has)
    return swimming && competition
  }

  static func competitionKeys(_ text: String) -> [String] {
    guard isCompetitive(text) else { return [] }
    var result: [String] = []
    if ["olympics", "olympic games", "olympic swimming"].contains(where: { SportsResolver.contains($0, in: text) }) { result.append("olympic-swimming") }
    if ["paralympics", "paralympic games", "paralympic swimming"].contains(where: { SportsResolver.contains($0, in: text) }) { result.append("paralympic-swimming") }
    if SportsResolver.contains("asian games", in: text) { result.append("asian-games-swimming") }
    if SportsResolver.contains("ncaa", in: text) { result.append("ncaa-swimming") }
    return result
  }
}
