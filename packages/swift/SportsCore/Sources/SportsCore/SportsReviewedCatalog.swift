import Foundation

/// Reviewed name identities. Provider mappings are activated separately after coverage/rights review.
public enum SportsReviewedCatalog {
  public static let version = "sports-reviewed-v12"
  public static func id(_ key: String) -> String { SportsIdentity.entityID(seed: "reviewed:" + key) }
  public static let sports: [(String, String, [String])] = [
    ("football", "Football", ["soccer", "fútbol", "futbol", "fußball", "calcio"]), ("american-football", "American Football", ["NFL", "quarterback", "touchdown"]),
    ("basketball", "Basketball", ["baloncesto", "basquetebol"]), ("baseball", "Baseball", []), ("softball", "Softball", []),
    ("hockey", "Hockey", []), ("ice-hockey", "Ice Hockey", ["NHL"]),
    ("field-hockey", "Field Hockey", ["hockey on grass", "hockey sur gazon"]), ("street-ball-hockey", "Street/Ball Hockey", ["street hockey", "ball hockey", "dek hockey", "hokejbal"]),
    ("inline-hockey", "Inline Hockey", ["inline roller hockey"]), ("rink-hockey", "Rink Hockey", ["quad roller hockey", "hardball hockey"]), ("cricket", "Cricket", ["críquet", "kriket"]), ("rugby-union", "Rugby Union", []),
    ("rugby-league", "Rugby League", []), ("motorsport", "Motorsport", ["Formula 1", "Formula One", "F1", "MotoGP"]),
    ("tennis", "Tennis", ["tenis"]), ("golf", "Golf", []), ("combat-sports", "Combat Sports", ["boxing", "mixed martial arts", "UFC", "boxeo"]),
    ("cycling", "Cycling", ["ciclismo"]), ("athletics", "Athletics", ["track and field", "atletismo"]), ("swimming", "Swimming", ["natación", "natation"]),
    ("volleyball", "Volleyball", ["voleibol"]), ("handball", "Handball", ["balonmano"]), ("australian-football", "Australian Football", ["Aussie rules"]),
    ("multi-sport", "Olympic and Paralympic Sports", ["Olympics", "Olympic Games", "Paralympics"]),
    ("winter-sports", "Winter Sports", ["alpine skiing", "snowboarding", "biathlon"]),
    ("badminton", "Badminton", []), ("table-tennis", "Table Tennis", []), ("lacrosse", "Lacrosse", []),
    ("drum-corps", "Drum Corps", ["drum and bugle corps"]),
    ("indoor-marching-arts", "Indoor Marching Arts", []),
    ("marching-arts", "Marching Arts", [])
  ]
  private static let competitions: [(String, String, String, [String])] = [
    ("nfl", "NFL", "american-football", ["National Football League"]),
    ("nba", "NBA", "basketball", ["National Basketball Association"]), ("wnba", "WNBA", "basketball", ["Women's National Basketball Association"]),
    ("mlb", "MLB", "baseball", ["Major League Baseball"]), ("nhl", "NHL", "ice-hockey", ["National Hockey League"]),
    ("mls", "MLS", "football", ["Major League Soccer"]), ("nwsl", "NWSL", "football", ["National Women's Soccer League"]),
    ("ncaa-football", "NCAA Division I Football", "american-football", ["college football", "NCAA football", "College Football Playoff"]),
    ("ncaa-mens-basketball", "NCAA Men's Basketball", "basketball", ["men's college basketball", "NCAA men's basketball"]),
    ("ncaa-womens-basketball", "NCAA Women's Basketball", "basketball", ["women's college basketball", "NCAA women's basketball"]),
    ("ncaa-baseball", "NCAA Baseball", "baseball", ["college baseball", "College World Series"]),
    ("ncaa-softball", "NCAA Softball", "softball", ["college softball", "Women's College World Series"]),
    ("ncaa-hockey", "NCAA Ice Hockey", "ice-hockey", ["college hockey", "Frozen Four"]),
    ("premier-league", "Premier League", "football", ["English Premier League"]),
    ("efl-championship", "EFL Championship", "football", ["Sky Bet Championship", "English League Championship"]),
    ("efl-league-one", "EFL League One", "football", ["Sky Bet League One", "English League One", "English League 1"]),
    ("efl-league-two", "EFL League Two", "football", ["Sky Bet League Two", "English League Two", "English League 2"]), ("wsl", "Women's Super League", "football", ["Barclays WSL"]),
    ("champions-league", "UEFA Champions League", "football", []), ("womens-champions-league", "UEFA Women's Champions League", "football", []),
    ("la-liga", "La Liga", "football", []), ("bundesliga", "Bundesliga", "football", []), ("serie-a", "Serie A", "football", []),
    ("ligue-1", "Ligue 1", "football", []), ("liga-mx", "Liga MX", "football", []), ("brasileirao", "Brasileirão Série A", "football", ["Brasileirão", "Campeonato Brasileiro", "Campeonato Brasileiro Série A"]),
    ("brasileirao-feminino-a1", "Brasileirão Feminino A1", "football", ["Brasileirão Feminino", "Campeonato Brasileiro Feminino", "Brasileiro Feminino A1"]),
    ("libertadores", "Copa Libertadores", "football", []), ("world-cup", "FIFA World Cup", "football", []),
    ("womens-world-cup", "FIFA Women's World Cup", "football", []), ("euros", "UEFA European Championship", "football", ["UEFA Euro"]),
    ("afcon", "Africa Cup of Nations", "football", ["AFCON"]), ("asian-cup", "AFC Asian Cup", "football", []),
    ("ipl", "Indian Premier League", "cricket", ["IPL cricket"]), ("wpl", "Women's Premier League", "cricket", ["WPL cricket"]),
    ("bbl", "Big Bash League", "cricket", []), ("wbbl", "Women's Big Bash League", "cricket", []),
    ("psl", "Pakistan Super League", "cricket", []), ("ashes", "The Ashes", "cricket", []),
    ("cricket-world-cup", "ICC Cricket World Cup", "cricket", []), ("t20-world-cup", "ICC T20 World Cup", "cricket", []),
    ("womens-cricket-world-cup", "ICC Women's Cricket World Cup", "cricket", []), ("world-test", "World Test Championship", "cricket", []),
    ("six-nations", "Six Nations", "rugby-union", []), ("womens-six-nations", "Women's Six Nations", "rugby-union", []),
    ("rugby-world-cup", "Rugby World Cup", "rugby-union", []), ("womens-rugby-world-cup", "Women's Rugby World Cup", "rugby-union", []),
    ("urc", "United Rugby Championship", "rugby-union", []), ("top14", "Top 14", "rugby-union", []),
    ("super-rugby", "Super Rugby", "rugby-union", []), ("premiership-rugby", "Premiership Rugby", "rugby-union", []),
    ("nrl", "NRL", "rugby-league", ["National Rugby League"]), ("super-league", "Rugby Super League", "rugby-league", []),
    ("f1", "Formula 1", "motorsport", ["F1", "Formula One"]), ("f2", "Formula 2", "motorsport", []),
    ("formula-e", "Formula E", "motorsport", []), ("motogp", "MotoGP", "motorsport", []),
    ("nascar", "NASCAR", "motorsport", []), ("indycar", "IndyCar", "motorsport", []), ("wec", "World Endurance Championship", "motorsport", []),
    ("atp", "ATP Tour", "tennis", []), ("wta", "WTA Tour", "tennis", []), ("wimbledon", "Wimbledon", "tennis", []),
    ("roland-garros", "Roland Garros", "tennis", ["French Open tennis"]), ("us-open-tennis", "US Open Tennis", "tennis", []),
    ("australian-open", "Australian Open", "tennis", []), ("pga", "PGA Tour", "golf", []), ("lpga", "LPGA Tour", "golf", []),
    ("masters", "Masters Tournament", "golf", ["Augusta National"]), ("open-championship", "The Open Championship", "golf", []),
    ("ufc", "UFC", "combat-sports", ["Ultimate Fighting Championship"]), ("tour-de-france", "Tour de France", "cycling", []),
    ("giro", "Giro d'Italia", "cycling", []), ("diamond-league", "Diamond League", "athletics", []),
    ("world-athletics", "World Athletics Championships", "athletics", []), ("world-aquatics", "World Aquatics Championships", "swimming", []),
    ("vnl", "Volleyball Nations League", "volleyball", []), ("handball-world", "IHF World Championship", "handball", []),
    ("afl", "AFL", "australian-football", ["Australian Football League"]), ("aflw", "AFL Women's", "australian-football", ["AFLW"]),
    ("olympics", "Olympic Games", "multi-sport", ["Olympics"]), ("paralympics", "Paralympic Games", "multi-sport", ["Paralympics"])
  ]
  public static var entities: [SportsEntity] {
    let sportEntities = sports.map { SportsEntity(id: id("sport:" + $0.0), name: $0.1, kind: "sport", sportID: SportsReviewedHockey.childSportKeys.contains($0.0) ? id("sport:hockey") : nil, aliases: $0.2,
      groupPath: $0.0 == "drum-corps" ? ["Marching Arts", "DCI"]
        : $0.0 == "indoor-marching-arts" ? ["Marching Arts", "WGI"]
        : $0.0 == "marching-arts" ? ["Marching Arts"] : nil) }
    let womenCompetitions = Set(["wnba", "nwsl", "wsl", "womens-champions-league", "womens-world-cup", "ncaa-womens-basketball", "ncaa-softball", "wpl", "wbbl", "womens-cricket-world-cup", "womens-six-nations", "womens-rugby-world-cup", "aflw", "wta", "lpga", "brasileirao-feminino-a1"])
    let menCompetitions = Set(["nfl", "nba", "mlb", "nhl", "mls", "ncaa-football", "ncaa-mens-basketball", "ncaa-baseball", "premier-league", "efl-championship", "efl-league-one", "efl-league-two", "champions-league", "la-liga", "bundesliga", "serie-a", "ligue-1", "liga-mx", "brasileirao", "libertadores", "world-cup", "euros", "afcon", "asian-cup", "ipl", "bbl", "psl", "ashes", "cricket-world-cup", "t20-world-cup", "world-test", "six-nations", "rugby-world-cup", "urc", "top14", "super-rugby", "premiership-rugby", "nrl", "super-league", "atp", "pga", "afl"])
    let competitionEntities = competitions.map { SportsEntity(id: id("competition:" + $0.0), name: $0.1, kind: "competition", sportID: id("sport:" + $0.2), aliases: $0.3, gender: womenCompetitions.contains($0.0) ? "women" : menCompetitions.contains($0.0) ? "men" : nil, division: $0.0 == "brasileirao" ? "Série A" : $0.0 == "brasileirao-feminino-a1" ? "A1" : nil) }
    let college = SportsReviewedCollegePrograms.entities
    let drumCorps = SportsReviewedDrumCorps.entities
    let wgi = SportsReviewedWGI.entities
    let boa = SportsReviewedBOA.entities
    let allCompetitions = competitionEntities + college.filter { $0.kind == "competition" } + SportsReviewedSwimming.entities + SportsReviewedParaSwimming.entities + SportsReviewedHockey.entities + drumCorps.filter { $0.kind == "competition" } + wgi.filter { $0.kind == "competition" } + boa.filter { $0.kind == "competition" }
    let byCompetition = Dictionary(uniqueKeysWithValues: allCompetitions.map { ($0.id, $0) })
    let teams = (SportsReviewedTeams.entities + college.filter { $0.kind != "competition" } + SportsReviewedNationalSides.entities + drumCorps.filter { $0.kind == "team" } + wgi.filter { $0.kind == "team" } + boa.filter { $0.kind == "team" }).map { entity in
      let declared = SportsResolver.normalize(entity.name).split(separator: " ").compactMap { SportsGenderContext.gender(String($0)) }.first
      let inherited = Set(entity.competitionIDs.compactMap { byCompetition[$0]?.gender })
      let gender = entity.gender ?? declared ?? (inherited.count == 1 ? inherited.first : nil)
      return SportsEntity(id: entity.id, name: entity.name, kind: entity.kind, sportID: entity.sportID,
        competitionIDs: entity.competitionIDs, aliases: entity.aliases, providerIDs: entity.providerIDs, active: entity.active,
        memberships: entity.memberships ?? [], schoolID: entity.schoolID, gender: gender, division: entity.division, groupPath: entity.groupPath, abbreviation: entity.abbreviation)
    }
    let result = sportEntities + allCompetitions + teams + SportsReviewedPeople.entities
    let groupingIndex = Dictionary(uniqueKeysWithValues: result.map { ($0.id, $0) })
    return result.map { SportsCatalogGrouping.group($0, catalog: groupingIndex) }
  }
}
