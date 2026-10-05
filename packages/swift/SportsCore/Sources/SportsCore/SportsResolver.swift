import Foundation

public enum SportsResolver {
  public static let version = "sports-resolver-v14"
  public static func normalize(_ text: String) -> String {
    text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
      .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
  }
  public static func contains(_ phrase: String, in text: String) -> Bool {
    (" " + text + " ").contains(" " + normalize(phrase) + " ")
  }
  public static func analyze(title: String, summary: String?, catalog: [SportsEntity]) -> SportsArticleAnalysis {
    analyze(title: title, summary: summary, index: SportsEntityIndex(entities: catalog))
  }
  public static func analyze(title: String, summary: String?, index: SportsEntityIndex) -> SportsArticleAnalysis {
    let headline = normalize(title)
    // Some corpus summaries contain a full newsletter body. Its later sections
    // must not turn an unrelated opening story into a Sports article.
    let openingSummary = String((summary ?? "").prefix(1000))
    let text = normalize(title + " " + openingSummary)
    if contains("boxing day", in: text) && ["sale", "sales", "discount", "shopping"].contains(where: { contains($0, in: text) }) { return .init(eligible: false, materiality: "reporting", associations: []) }
    let context = ["match", "game", "season", "tournament", "championship", "playoff", "player", "athlete", "coach", "race", "grand prix", "goal", "wicket", "innings", "touchdown", "quarterback", "basketball", "football", "soccer", "cricket", "rugby", "tennis", "golf", "hockey", "baseball", "boxing", "olympics", "paralympics", "sports", "sport", "roster", "transfer", "striker", "pitcher", "driver", "podium"].contains { contains($0, in: text) }
    let specificTokens: [String: [String]] = [
      "football": ["soccer", "futbol", "balompie", "calcio", "fifa", "uefa", "striker", "goalkeeper", "hat trick", "penalty kick", "football club", "fc", "nwsl", "wsl"],
      "american-football": ["nfl", "quarterback", "qb", "touchdown", "super bowl", "college football", "linebacker", "wide receiver", "gridiron"],
      "basketball": ["basketball", "nba", "wnba", "three pointer", "dunk", "point guard"],
      "baseball": ["baseball", "mlb", "pitcher", "home run", "world series", "innings", "batting"],
      "hockey": ["hockey", "nhl", "fih"],
      "ice-hockey": ["ice hockey", "nhl", "stanley cup", "ice rink", "skates", "puck"],
      "field-hockey": ["field hockey", "fih", "hockey india", "hockeyroos", "kookaburras"],
      "street-ball-hockey": ["ball hockey", "street hockey", "dek hockey"],
      "inline-hockey": ["inline hockey", "roller inline hockey"],
      "rink-hockey": ["rink hockey", "roller hockey", "quad hockey"],
      "cricket": ["wicket", "innings", "bowler", "batting", "icc", "t20", "odi", "ipl", "cricket match", "cricket tournament", "cricket world cup", "cricket team", "cricket player"],
      "rugby-union": ["rugby", "six nations", "scrum", "super rugby", "rugby union"],
      "rugby-league": ["rugby league", "nrl", "state of origin"],
      "motorsport": ["f1", "formula 1", "formula one", "grand prix", "race", "racing", "motogp", "nascar", "indycar"],
      "tennis": ["tennis", "wimbledon", "atp", "wta", "australian open", "roland garros"],
      "golf": ["pga", "lpga", "augusta", "golfer", "golf tournament", "golf championship", "golf course"],
      "combat-sports": ["boxer", "boxing match", "boxing championship", "ufc", "mma", "mixed martial arts", "fight", "fighter"],
      "athletics": ["track and field", "world athletics", "diamond league", "sprinter", "marathon"],
      "cycling": ["cycling race", "tour de france", "giro", "peloton"],
      "swimming": ["swimmer", "swimming championship", "world aquatics", "freestyle", "backstroke"],
      "drum-corps": ["drum corps", "drum and bugle corps", "drum bugle corps", "drumcorps", "marching music"]
    ]
    // These league labels recur in different sports and countries. They cannot
    // supply their own sport context ("la Liga Iberdrola" is not Spanish football).
    let genericLeagueLabels = Set(["la liga", "laliga", "premier league", "premiership", "super league", "superleague", "bundesliga", "serie a", "the ashes"])
    func independentSportEvidence(_ entity: SportsEntity) -> Bool {
      guard let sportID = entity.sportID,
        let key = SportsReviewedCatalog.sports.first(where: { SportsReviewedCatalog.id("sport:" + $0.0) == sportID })?.0
      else { return false }
      let tokens = (specificTokens[key] ?? []).filter { !genericLeagueLabels.contains(normalize($0)) && $0 != "fc" }
      if tokens.contains(where: { contains($0, in: text) }) { return true }
      // A reviewed full team name in this competition provides context without
      // requiring English terminology in localized match reporting.
      return index.entities.contains { team in
        ["team", "national-side", "ncaa-team"].contains(team.kind)
          && team.competitionIDs.contains(entity.id)
          && normalize(team.name).split(separator: " ").count >= 2
          && contains(team.name, in: text)
      }
    }
    func hasSportEvidence(_ entity: SportsEntity) -> Bool {
      if entity.kind == "ncaa-team", contains(entity.name, in: text) { return true }
      if entity.name == "Los Angeles Dodgers", contains(entity.name, in: text),
        ["three peat", "3 peat"].contains(where: { contains($0, in: text) }) { return true }
      let sportID = entity.kind == "sport" ? entity.id : entity.sportID
      guard let sportID else { return context }
      let key = SportsReviewedCatalog.sports.first { SportsReviewedCatalog.id("sport:" + $0.0) == sportID }?.0
      if key == "swimming" { return SportsSwimmingContext.isCompetitive(text) }
      if key == "drum-corps" { return SportsDrumCorpsContext.permits(text) }
      if key == "indoor-marching-arts" { return SportsWGIContext.permits(entity: entity, text: text) }
      if key == "marching-arts" { return SportsMarchingArtsContext.permitsBOA(text) || (entity.kind == "team" && contains("marching band", in: text)) }
      let tokens = key.flatMap { specificTokens[$0] } ?? []
      let competitionNames = index.entities.filter { entity.competitionIDs.contains($0.id) && $0.kind == "competition" }
        .filter { competition in
          !([competition.name] + competition.aliases).contains(where: { genericLeagueLabels.contains(normalize($0)) }) || independentSportEvidence(competition)
        }
        .flatMap { [$0.name] + $0.aliases }
      return (tokens + competitionNames).contains { contains($0, in: text) }
    }
    let candidateOffsets = Set(text.split(separator: " ").flatMap { index.byFirstToken[String($0)] ?? [] })
    let ambiguous = Set(["united", "giants", "tigers", "cardinals", "usc", "athletics", "masters", "football", "hockey", "swimming", "cycling", "arsenal", "dream", "sky", "sun", "heat", "fire", "storm", "cricket", "golf", "boxing"])
    var associations: [SportsAssociation] = []
    for offset in candidateOffsets.sorted() {
      let entity = index.entities[offset]
      // Schools identify institutions; their sport-specific programs identify news interests.
      guard entity.kind != "school" else { continue }
      let marchingArtsID = SportsReviewedCatalog.id("sport:marching-arts")
      if entity.id == marchingArtsID, !SportsMarchingArtsContext.permits(text) { continue }
      if entity.sportID == marchingArtsID, !SportsMarchingArtsContext.permitsBOA(text),
        !(entity.kind == "team" && contains("marching band", in: text)) { continue }
      let wgiSportID = SportsReviewedCatalog.id("sport:indoor-marching-arts")
      if (entity.id == wgiSportID || entity.sportID == wgiSportID),
        !SportsWGIContext.permits(entity: entity, text: text) { continue }
      let drumCorpsID = SportsReviewedCatalog.id("sport:drum-corps")
      if (entity.id == drumCorpsID || entity.sportID == drumCorpsID),
        !SportsDrumCorpsContext.permits(text) { continue }
      if let code = SportsReviewedParaSwimming.classCode(for: entity.id),
        !SportsParaSwimmingContext.containsClass(code, in: text) { continue }
      let swimmingID = SportsReviewedCatalog.id("sport:swimming")
      if (entity.id == swimmingID || entity.sportID == swimmingID),
        entity.id != SportsReviewedCatalog.id("competition:world-aquatics"),
        !SportsSwimmingContext.isCompetitive(text) { continue }
      let matching = ([entity.name] + entity.aliases).filter { alias in
        guard contains(alias, in: text), SportsGenderContext.permits(alias: alias, text: text, gender: entity.gender) else { return false }
        guard entity.kind == "team", [drumCorpsID, wgiSportID, marchingArtsID].contains(entity.sportID ?? "") else { return true }
        // Blue Devils B/C are separate corps; Indianapolis Colts and Arsenal FC
        // must not become corps simply because DCI appears elsewhere in a story.
        // Remove fully named other teams before looking for an independent mention.
        let normalizedAlias = normalize(alias)
        let longerNames = index.entities.filter {
          $0.id != entity.id && ["team", "ncaa-team", "national-side"].contains($0.kind)
            && normalize($0.name).count > normalizedAlias.count && contains(alias, in: normalize($0.name))
        }.map { normalize($0.name) }.sorted { $0.count > $1.count }
        let remaining = longerNames.reduce(" " + text + " ") {
          $0.replacingOccurrences(of: " " + $1 + " ", with: " ")
        }
        return contains(alias, in: remaining)
      }
      guard let alias = matching.sorted(by: { $0.count > $1.count }).first else { continue }
      let normalizedAlias = normalize(alias)
      if entity.kind == "competition", genericLeagueLabels.contains(normalizedAlias), !independentSportEvidence(entity) { continue }
      let requiresContext = ambiguous.contains(normalizedAlias) || ["athlete", "driver", "school", "team", "national-side", "ncaa-team"].contains(entity.kind)
      guard !requiresContext || hasSportEvidence(entity) else { continue }
      if ["team", "ncaa-team", "athlete", "driver"].contains(entity.kind),
        ["ammunition", "weapon", "gaming", "video game", "council", "housing budget"].contains(where: { contains($0, in: text) }),
        !entity.competitionIDs.contains(where: { id in index.entities.first { $0.id == id }.map { contains($0.name, in: text) } ?? false }) { continue }
      // Abbreviated F1 constructor names need Formula 1 evidence; a generic race
      // (cycling, local road racing, etc.) does not disambiguate these acronyms.
      if ["rbr", "vcarb"].contains(normalizedAlias),
        !["f1", "formula 1", "formula one"].contains(where: { contains($0, in: text) }) { continue }
      // A surname or bare three-letter school abbreviation is never enough.
      if ["athlete", "driver"].contains(entity.kind), normalizedAlias.split(separator: " ").count < 2 { continue }
      if normalizedAlias == "usc", !["college football", "college basketball", "quarterback", "qb"].contains(where: { contains($0, in: text) }) { continue }
      let primary = matching.contains { contains($0, in: headline) }
      associations.append(.init(entityID: entity.id, confidence: requiresContext ? 0.94 : 0.98,
        evidence: ["name:" + alias, primary ? "headline" : "summary"] + (context ? ["sports-context"] : []), prominence: primary ? 0 : 1))
    }
    // Broad sport and competition references may share a label (NFL/F1); competing
    // teams or people sharing an alias are unresolved unless their full names match.
    let entityByID = Dictionary(index.entities.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let groups = Dictionary(grouping: associations, by: { $0.evidence.first ?? "" })
    associations = associations.filter { association in
      guard let entity = entityByID[association.entityID] else { return false }
      let peers = (groups[association.evidence.first ?? ""] ?? []).filter { other in
        guard let peer = entityByID[other.entityID] else { return false }
        let personalKinds = ["team", "ncaa-team", "national-side", "athlete", "driver"]
        return entity.kind == peer.kind || (personalKinds.contains(entity.kind) && personalKinds.contains(peer.kind))
      }
      return peers.count == 1 || contains(entity.name, in: text)
    }
    if SportsMarchingArtsContext.permits(text) {
      let id = SportsReviewedCatalog.id("sport:marching-arts")
      if entityByID[id] != nil && !associations.contains(where: { $0.entityID == id }) {
        associations.append(.init(entityID: id, confidence: 0.94, evidence: ["marching-arts-context"],
          prominence: SportsMarchingArtsContext.permits(headline) ? 0 : 1))
      }
    }
    if SportsWGIContext.permits(text) {
      let wgiCompetition = SportsReviewedCatalog.id("competition:wgi")
      let organizationEvidence = contains("WGI", in: text) || contains("Winter Guard International", in: text)
        || associations.contains { entityByID[$0.entityID]?.kind == "team"
          && entityByID[$0.entityID]?.competitionIDs.contains(wgiCompetition) == true }
      let ids = [SportsReviewedCatalog.id("sport:indoor-marching-arts")]
        + (organizationEvidence ? [wgiCompetition] + SportsWGIContext.disciplines(in: text).map {
          SportsReviewedCatalog.id("competition:wgi-" + $0)
        } : [])
      for id in ids where entityByID[id] != nil && !associations.contains(where: { $0.entityID == id }) {
        associations.append(.init(entityID: id, confidence: 0.94, evidence: ["indoor-marching-arts-context"],
          prominence: SportsWGIContext.permits(headline) ? 0 : 1))
      }
    }
    if SportsSwimmingContext.isCompetitive(text) {
      let inferred = [SportsReviewedCatalog.id("sport:swimming")]
        + SportsSwimmingContext.competitionKeys(text).map { SportsReviewedCatalog.id("competition:" + $0) }
        + (SportsParaSwimmingContext.permits(text) ? [SportsReviewedCatalog.id("competition:para-swimming")] : [])
      for id in inferred where entityByID[id] != nil && !associations.contains(where: { $0.entityID == id }) {
        associations.append(.init(entityID: id, confidence: 0.94, evidence: ["competitive-swimming-context", "stroke-or-swimming-and-competition"], prominence: SportsSwimmingContext.isCompetitive(headline) ? 0 : 1))
      }
    }
    let matched = Set(associations.map(\.entityID))
    let entities = index.entities.filter { matched.contains($0.id) }
    let sports = SportsSportHierarchy.ancestors(of: Set(entities.compactMap(\.sportID) + entities.filter { $0.kind == "sport" }.map(\.id)), catalog: index.entities)
    let competitions = Set(entities.flatMap(\.competitionIDs) + entities.filter { $0.kind == "competition" }.map(\.id))
    let broadHeadlineEvidence = ["sports", "sport", "olympics", "paralympics", "anti doping", "world cup"].contains { contains($0, in: headline) }
    let headlineAssociation = associations.contains { $0.prominence == 0 }
    // Incidental summary mentions (for example a broadcaster's Live-Sport package)
    // are insufficient. Require two distinct sports-specific summary clues.
    let weakClues = Set(["race", "racing", "fight", "fighter", "driver", "fc", "augusta", "giro"])
    let summaryClues = Set(specificTokens.values.flatMap { $0 }.filter { !weakClues.contains($0) }
      + ["olympics", "paralympics", "anti doping", "sports regulation", "sports federation", "sports governing body", "sports governing bodies", "sports teams", "sports organisations", "sports organizations"])
    let normalizedSummary = normalize(openingSummary)
    let summaryClueCount = summaryClues.filter { contains($0, in: normalizedSummary) }.count
    let contextualSummaryTeam = associations.contains { association in
      association.prominence == 1 && entityByID[association.entityID].map { ["team", "ncaa-team", "national-side"].contains($0.kind) } == true
    }
    let earlyCompetition = associations.contains { association in
      association.prominence == 1 && association.confidence >= 0.98 && entityByID[association.entityID]?.kind == "competition"
    }
    let substantiveSummary = earlyCompetition || summaryClueCount >= 2 || (summaryClueCount >= 1 && contextualSummaryTeam)
    let eligible = headlineAssociation || broadHeadlineEvidence || substantiveSummary
    let materiality: String
    if ["championship", "champion", "world cup", "gold medal", "final", "playoff"].contains(where: { contains($0, in: headline) }) { materiality = "championship" }
    else if ["clinches", "clinched", "qualifies", "qualified", "eliminated", "relegated", "promotion secured"].contains(where: { contains($0, in: headline) }) { materiality = "consequential-game" }
    else if ["coach", "coaching", "owner", "ownership", "commissioner", "president", "governance", "governing body", "league leadership"].contains(where: { contains($0, in: headline) })
      && ["fired", "dismissed", "resigns", "resigned", "appointed", "appoints", "hired", "hires", "sells", "sale", "takeover", "replaced", "changes"].contains(where: { contains($0, in: headline) }) { materiality = "organizational-change" }
    else if ["transfer", "trade", "signs", "signed", "contract"].contains(where: { contains($0, in: headline) }) { materiality = "transfer" }
    else if ["injury", "injured", "concussion", "surgery"].contains(where: { contains($0, in: headline) }) { materiality = "injury" }
    else if ["record", "world record", "historic"].contains(where: { contains($0, in: headline) }) { materiality = "record" }
    else if ["suspended", "suspension", "doping", "banned", "disciplinary"].contains(where: { contains($0, in: headline) }) { materiality = "disciplinary" }
    else if ["prediction", "predictions", "betting", "odds", "fantasy picks", "promo code", "tickets on sale"].contains(where: { contains($0, in: headline) }) { materiality = "routine-chatter" }
    else { materiality = "reporting" }
    return .init(eligible: eligible, materiality: materiality, associations: eligible ? associations.sorted { ($0.prominence, $0.entityID) < ($1.prominence, $1.entityID) } : [], sportIDs: eligible ? sports.sorted() : [], competitionIDs: eligible ? competitions.sorted() : [])
  }
}
