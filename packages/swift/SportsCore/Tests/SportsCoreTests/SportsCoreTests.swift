import Foundation
import Testing
import SportsCore
import WireCore

struct SportsCoreTests {
  let catalog = SportsReviewedCatalog.entities
  func item(_ id: String, title: String = "Sports reporting", domain: String = "example.com") -> WireFeedItem {
    .init(itemID: id, canonicalURL: "https://" + domain + "/" + id, representativeURI: nil, title: title, summary: nil,
      publishedAt: Date(), thumbnailURL: nil, source: .init(name: domain, domain: domain, publication: nil, author: nil), reasons: [], provenance: [])
  }
  @Test func broadReviewedCoverageAndOpaqueIDs() {
    #expect(Set(catalog.map(\.id)).count == catalog.count)
    #expect(catalog.count > 350)
    for name in ["WNBA", "NFL", "NCAA Women's Basketball", "Indian Premier League", "Six Nations", "Formula 1", "AFL Women's", "Paralympic Games", "LPGA Tour", "Volleyball Nations League"] {
      #expect(catalog.contains { $0.name == name })
    }
    #expect(catalog.allSatisfy { $0.id.hasPrefix("sp_") })
    #expect(catalog.filter { !["athlete", "driver"].contains($0.kind) }.allSatisfy { $0.providerIDs.isEmpty })
  }
  @Test func unrelatedWordsAndAmbiguousNamesNeverResolve() {
    for title in ["Chicken stock makes a flavorful soup", "AI giants announce their new model", "United shareholders approve a deal", "Tigers roam the jungle", "Masters of modern art open exhibition", "Liverpool council approves housing budget", "Arsenal expands game ammunition line", "Athletics program funds new school building", "Boxing Day sales offer huge shopping discounts", "Cricket Wireless announces new phone plans", "Cricket infestations damage crops", "Volkswagen Golf GTI gets new engine", "Boxing cardboard parcels for shipping"] {
      let analysis = SportsResolver.analyze(title: title, summary: nil, catalog: catalog)
      #expect(!analysis.eligible, Comment(rawValue: title))
    }
  }
  @Test func multipleTeamsAndMatchingOnlyFeeds() throws {
    let analysis = SportsResolver.analyze(title: "Los Angeles Lakers beat Boston Celtics in NBA playoff game", summary: nil, catalog: catalog)
    let lakers = try #require(catalog.first { $0.name == "Los Angeles Lakers" })
    let celtics = try #require(catalog.first { $0.name == "Boston Celtics" })
    #expect(analysis.eligible)
    #expect(analysis.associations.contains { $0.entityID == lakers.id })
    #expect(analysis.associations.contains { $0.entityID == celtics.id })
    let feeds = SportsNamedFeeds.catalog(entities: catalog)
    #expect(try #require(feeds.first { $0.entityIDs == [lakers.id] }).matches(analysis))
    #expect(!feeds.first { $0.title == "Cricket" }!.matches(analysis))
  }
  @Test func contextualProgramAliasesPreserveSportsAndGenderDistinctions() throws {
    let positives = [
      ("What's Biggest Obstacle In Way Of Dodgers' 3-Peat? Derek Jeter, A-Rod Explain", "Are the Los Angeles Dodgers poised to three-peat? FOX Sports' Derek Jeter and Alex Rodriguez discussed the challenge ahead for Los Angeles."),
      ("Keelon Russell needed just over one quarter to snatch Kamario Taylor's crown", "Alabama Crimson Tide quarterback Keelon Russell started out hot against Mississippi State quarterback Kamario Taylor."),
      ("Oregon Coach Dan Lanning Gives Positive Dante Moore Injury Update", "Oregon head coach Dan Lanning provided a positive update on QB Dante Moore, who suffered a concussion against USC."),
      ("How Much Is USC Coach Lincoln Riley's Buyout? Contract Details In 2026", "Lincoln Riley's job security entered the 2026 season as one of college football's biggest storylines.")
    ]
    for (title, summary) in positives {
      let analysis = SportsResolver.analyze(title: title, summary: summary, catalog: catalog)
      #expect(analysis.eligible, Comment(rawValue: title))
      #expect(!analysis.associations.contains { association in catalog.first { $0.id == association.entityID }?.kind == "school" })
    }
    for title in ["Florida University announces new microscopy competition", "Oregon police investigate an injury", "Tennessee approves state budget", "USC researchers publish AI competition results"] {
      #expect(!SportsResolver.analyze(title: title, summary: nil, catalog: catalog).eligible)
    }
    let ambiguous = SportsResolver.analyze(title: "Florida prepares for college basketball season", summary: nil, catalog: catalog)
    #expect(!ambiguous.associations.contains { association in catalog.first { $0.id == association.entityID }?.kind == "ncaa-team" })
    let women = SportsResolver.analyze(title: "Florida Women's Basketball wins NCAA tournament", summary: nil, catalog: catalog)
    let selected = women.associations.compactMap { association in catalog.first { $0.id == association.entityID } }.filter { $0.kind == "ncaa-team" }
    #expect(selected.map(\.name) == ["Florida Women's Basketball"])
  }
  @Test func institutionsAndIncidentalSummaryMentionsDoNotQualifyAsSports() {
    let fixtures = [
      ("Tennessee grandmother was arrested at gunpoint while babysitting 4 children. Now she says an AI match led police to the wrong woman", "The officers did not independently verify the AI findings."),
      ("Researcher, Dartmouth Professor and Provost Face Accusations of Secretly Using AI", "A Florida University researcher faces questions about a Nikon microscopy video contest and competition entry."),
      ("Schwarzer Kasten und Schlüsselkarte: So revolutionierte Premiere vor 35 Jahren das Fernsehen", "Premiere führte in den 1990er Jahren eine Paywall für Kino, Live-Sport und werbefreies Fernsehen mit Vertrag und Decoder ein."),
      ("New television subscription package announced", "The package includes films and live sport.")
    ]
    for (title, summary) in fixtures {
      let analysis = SportsResolver.analyze(title: title, summary: summary, catalog: catalog)
      #expect(!analysis.eligible, Comment(rawValue: title))
      #expect(analysis.associations.isEmpty)
    }
    for (title, summary) in [
      ("Tennessee football coach announces recruiting changes", "The college football program prepares for its season."),
      ("Government introduces sports regulation reforms", "The new rules govern sports federations."),
      ("You’re sued and you know you are: New law puts onus on clubs to prevent player abuse", "Professional sports teams, governing bodies and operators of stadiums and events could all face legal action if players receive abuse due to changes in the law this month. Sports organisations have historically treated abusive behaviour directed at players, coaches and officials largely as a welfare, reputational and regulatory issue."),
      ("WNBA players negotiate new contract", "Women's basketball teams prepare for the tournament."),
      ("A historic victory in Paris", "The basketball team won the Olympics championship.")
    ] {
      let analysis = SportsResolver.analyze(title: title, summary: summary, catalog: catalog)
      #expect(analysis.eligible, Comment(rawValue: title))
      #expect(!analysis.associations.contains { association in catalog.first { $0.id == association.entityID }?.kind == "school" })
    }
  }
  @Test func openingSummaryLimitsIncidentalNewsletterSectionsAndKeepsEarlyCompetitions() {
    let economicOpening = String(repeating: "Industrial jobs and local economic policy affect city budgets. ", count: 40)
    let mixed = SportsResolver.analyze(title: "The Rundown: How losing industrial jobs hit Midwest cities", summary: economicOpening + " Later sports: NFL Chicago Bears quarterback prepares for the game.", catalog: catalog)
    #expect(!mixed.eligible); #expect(mixed.associations.isEmpty)
    for (headline, summary) in [
      ("RC Vannes passe proche de la plus grosse remontada contre Pau", "Le RC Vannes revient au score en Top 14 face à Pau."),
      ("Demi Vollering conserve son titre européen", "La cycliste termine une année qui comprend le Tour de France et un titre européen.")
    ] {
      let analysis = SportsResolver.analyze(title: headline, summary: summary, catalog: catalog)
      #expect(analysis.eligible, Comment(rawValue: headline))
      #expect(!analysis.competitionIDs.isEmpty)
    }
  }
  @Test func followOverridesBroadMuteButExplicitMuteWins() throws {
    let team = try #require(catalog.first { $0.name == "Los Angeles Lakers" })
    let analysis = SportsResolver.analyze(title: "Los Angeles Lakers win NBA championship", summary: nil, catalog: catalog)
    let candidate = SportsRankCandidate(item: item("lakers"), analysis: analysis, baseScore: 1)
    let broadMute = Set([try #require(team.sportID)])
    #expect(SportsRanker.rank(candidates: [candidate], muteIDs: broadMute, entities: catalog).isEmpty)
    #expect(SportsRanker.rank(candidates: [candidate], followIDs: [team.id], muteIDs: broadMute, entities: catalog).count == 1)
    #expect(SportsRanker.rank(candidates: [candidate], followIDs: [team.id], muteIDs: broadMute.union([team.id]), entities: catalog).isEmpty)
  }
  @Test func globalReservationAndDiversity() {
    let basketball = SportsReviewedCatalog.id("sport:basketball")
    let cricket = SportsReviewedCatalog.id("sport:cricket")
    let candidates = (0..<8).map { index in
      SportsRankCandidate(item: item("story-\(index)", domain: index < 5 ? "one.com" : "other.com"),
        analysis: .init(eligible: true, materiality: "reporting", associations: [], sportIDs: [index < 5 ? basketball : cricket]),
        baseScore: index == 7 ? 0.1 : 1, majorGlobal: index == 7)
    }
    let ranked = SportsRanker.rank(candidates: candidates, entities: catalog)
    #expect(ranked[2].item.source.domain == "other.com")
    #expect(ranked[4].majorGlobal)
  }
  @Test func organizationalAndConsequentialMaterialityDoesNotCreateEligibility() {
    for (headline, expected) in [("NFL commissioner resigns after governance investigation", "organizational-change"), ("NBA team qualifies for postseason", "consequential-game")] {
      let analysis = SportsResolver.analyze(title: headline, summary: nil, catalog: catalog)
      #expect(analysis.eligible); #expect(analysis.materiality == expected)
      let material = SportsRankCandidate(item: item("material", title: headline), analysis: analysis, baseScore: 1)
      let routine = SportsRankCandidate(item: item("routine"), analysis: .init(eligible: true, materiality: "reporting", associations: []), baseScore: 1.05)
      #expect(SportsRanker.rank(candidates: [routine, material], entities: catalog, reserveGlobal: false).first?.item.itemID == "material")
    }
    let unrelated = SportsResolver.analyze(title: "University president resigns after AI research competition", summary: "Florida announces leadership changes", catalog: catalog)
    #expect(!unrelated.eligible)
    #expect(unrelated.materiality == "organizational-change")
  }
  @Test func preferenceKeyChangesActionWithoutChangingRecordIdentity() {
    #expect(SportsIdentity.selectionRecordKey(action: "follow", id: "one") == SportsIdentity.selectionRecordKey(action: "mute", id: "one"))
    #expect(SportsIdentity.preferenceFingerprint(selections: [.init(reference: "one", action: "follow")]) != SportsIdentity.preferenceFingerprint(selections: [.init(reference: "one", action: "mute")]))
  }
  @Test func transferMembershipIsTimeBounded() {
    let start = Date(timeIntervalSince1970: 1000), transfer = Date(timeIntervalSince1970: 2000)
    let old = SportsMembership(entityID: "old-team", validFrom: start, validUntil: transfer)
    let new = SportsMembership(entityID: "new-team", validFrom: transfer)
    #expect(old.includes(start)); #expect(!old.includes(transfer)); #expect(new.includes(transfer))
  }
  @Test func NCAAProgramsRemainDistinct() throws {
    let men = try #require(catalog.first { $0.name == "Duke Men's Basketball" })
    let women = try #require(catalog.first { $0.name == "Duke Women's Basketball" })
    #expect(men.id != women.id); #expect(men.competitionIDs != women.competitionIDs)
    let analysis = SportsResolver.analyze(title: "Duke women's basketball wins the championship", summary: nil, catalog: catalog)
    #expect(analysis.associations.contains { $0.entityID == women.id })
    #expect(!analysis.associations.contains { $0.entityID == men.id })
  }
  @Test func eventStatusAndScoresDoNotGuessFinalFromClock() throws {
    let now = Date()
    let base = ["idEvent": "1", "strEvent": "Test match", "dateEvent": "2026-10-02", "strTime": "12:00:00", "intHomeScore": "3", "intAwayScore": "1"]
    let unknown = try #require(TheSportsDBAdapter.event(base, competitionID: "league", entities: [], now: now))
    #expect(unknown.status == "scheduled"); #expect(unknown.homeScore == nil)
    var finished = base; finished["strStatus"] = "Match Finished"
    #expect(TheSportsDBAdapter.event(finished, competitionID: "league", entities: [], now: now)?.homeScore == "3")
    var postponed = base; postponed["strStatus"] = "Postponed"
    #expect(TheSportsDBAdapter.event(postponed, competitionID: "league", entities: [], now: now)?.status == "postponed")
  }
  @Test func cursorRejectsCrossFeedViewerAndExpiry() throws {
    let codec = try SportsCursorCodec(secret: String(repeating: "a", count: 32))
    let now = Date(), cursor = SportsCursor(generationID: "generation", language: "en", preferenceFingerprint: "prefs", viewerScope: "viewer", nextOrdinal: 4, expiresAt: now.addingTimeInterval(100))
    let value = try codec.encode(cursor)
    #expect(throws: SportsCursorError.invalidContext) { try codec.decode(value, language: "en", preferenceFingerprint: "prefs", viewerScope: "other", now: now) }
    #expect(throws: SportsCursorError.invalidContext) { try codec.decode(value, language: "en", preferenceFingerprint: "prefs", viewerScope: "viewer", now: now, feed: "finance") }
    #expect(throws: SportsCursorError.expired) { try codec.decode(value, language: "en", preferenceFingerprint: "prefs", viewerScope: "viewer", now: now.addingTimeInterval(101)) }
  }
  @Test func repeatedNCAAImportPreservesOpaqueIdentityAndMembership() throws {
    let competition = try #require(catalog.first { $0.name == "NCAA Women's Basketball" })
    let first = try #require(SportsReferenceImport.team(record: ["idTeam": "123", "strTeam": "Duke Women's Basketball"], competition: competition, existing: catalog, now: Date(timeIntervalSince1970: 100)))
    let second = try #require(SportsReferenceImport.team(record: ["idTeam": "123", "strTeam": "Duke Women's Basketball"], competition: competition, existing: [first], now: Date(timeIntervalSince1970: 200)))
    #expect(first == second); #expect(first.kind == "ncaa-team")
    #expect(first.providerIDs["thesportsdb"] == "123")
  }
  @Test func catalogRevisionTreatsAliasesAndCompetitionIDsAsSets() throws {
    let a = SportsEntity(id: "entity", name: "Name", kind: "team", competitionIDs: ["a", "b"], aliases: ["one", "two"])
    let b = SportsEntity(id: "entity", name: "Name", kind: "team", competitionIDs: ["b", "a"], aliases: ["two", "one"])
    #expect(try SportsCatalogSnapshot.revision(entities: [a]) == SportsCatalogSnapshot.revision(entities: [b]))
  }
  @Test func athleteNewsAvailableWithoutEventProvider() throws {
    let person = try #require(catalog.first { $0.name == "Lewis Hamilton" })
    #expect(person.providerIDs["wikidata"] == "Q9673")
    let analysis = SportsResolver.analyze(title: "Lewis Hamilton wins Formula 1 race", summary: nil, catalog: catalog)
    #expect(analysis.associations.contains { $0.entityID == person.id })
    #expect(SportsNamedFeeds.catalog(entities: catalog).contains { $0.title == person.name && $0.matches(analysis) })
    #expect(!SportsResolver.analyze(title: "Hamilton planning board reviews a driver permit", summary: nil, catalog: catalog).associations.contains { $0.entityID == person.id })
  }
  @Test func rateLimitFailsWithoutHoldingCoordinatorForRetries() async throws {
    let adapter = TheSportsDBAdapter(apiKey: "fixture-key") { request in
      #expect(request.value(forHTTPHeaderField: "X-API-KEY") == "fixture-key")
      #expect(!request.url!.absoluteString.contains("fixture-key"))
      return (Data(), 429)
    }
    await #expect(throws: SportsProviderError.invalidResponse) { try await adapter.rows(path: "list/teams/4328") }
  }

  @Test func sharedSportCompetitionLabelsDoNotEraseLeagueMatching() throws {
    for (name, headline) in [("NFL", "NFL championship playoff schedule"), ("NHL", "NHL playoff hockey finals"), ("Formula 1", "F1 grand prix race schedule")] {
      let competition = try #require(catalog.first { $0.name == name && $0.kind == "competition" })
      let analysis = SportsResolver.analyze(title: headline, summary: nil, catalog: catalog)
      #expect(analysis.eligible)
      #expect(analysis.competitionIDs.contains(competition.id), Comment(rawValue: headline))
      #expect(SportsNamedFeeds.catalog(entities: catalog).first { $0.entityIDs == [competition.id] }!.matches(analysis))
    }
  }
  @Test func teamNicknameRequiresUniqueSportContext() throws {
    let baseball = try #require(catalog.first { $0.name == "San Francisco Giants" })
    let football = try #require(catalog.first { $0.name == "New York Giants" })
    let mlb = SportsResolver.analyze(title: "Giants baseball pitcher strikes out MLB batters", summary: nil, catalog: catalog)
    #expect(mlb.associations.contains { $0.entityID == baseball.id })
    #expect(!mlb.associations.contains { $0.entityID == football.id })
    let ambiguous = SportsResolver.analyze(title: "Giants discussion compares NFL and MLB seasons", summary: nil, catalog: catalog)
    #expect(!ambiguous.associations.contains { $0.entityID == baseball.id || $0.entityID == football.id })
  }

  @Test func localeSportEvidenceSharesCanonicalIdentity() throws {
    let basketball = try #require(catalog.first { $0.kind == "sport" && $0.name == "Basketball" })
    let football = try #require(catalog.first { $0.kind == "sport" && $0.name == "Football" })
    let spanish = SportsResolver.analyze(title: "Baloncesto mundial: noticias del torneo", summary: nil, catalog: catalog)
    #expect(spanish.eligible); #expect(spanish.sportIDs.contains(basketball.id))
    let futbol = SportsResolver.analyze(title: "Últimas noticias del fútbol internacional", summary: nil, catalog: catalog)
    #expect(futbol.sportIDs.contains(football.id))
  }

  @Test func teamImportsPreserveMultipleCompetitionsAndRenameHistory() throws {
    let league = SportsEntity(id: "league", name: "League", kind: "competition", sportID: "football")
    let cup = SportsEntity(id: "cup", name: "Cup", kind: "competition", sportID: "football")
    let first = try #require(SportsReferenceImport.team(record: ["idTeam": "123", "strTeam": "Old Club"], competition: league, existing: [], now: Date(timeIntervalSince1970: 100)))
    let second = try #require(SportsReferenceImport.team(record: ["idTeam": "123", "strTeam": "New Club"], competition: cup, existing: [first], now: Date(timeIntervalSince1970: 200)))
    #expect(second.id == first.id)
    #expect(second.competitionIDs == ["cup", "league"])
    #expect(second.aliases.contains("Old Club"))
    #expect(second.memberships?.count == 2)
    #expect(second.memberships?.first { $0.entityID == "league" }?.validFrom == Date(timeIntervalSince1970: 100))
    let repeated = try #require(SportsReferenceImport.team(record: ["idTeam": "123", "strTeam": "New Club"], competition: cup, existing: [second], now: Date(timeIntervalSince1970: 300)))
    #expect(repeated == second)
  }

  @Test func teamImportRejectsConflictingGenderWithoutChangingIdentity() throws {
    let men = SportsEntity(id: "men", name: "Men's League", kind: "competition", sportID: "football", gender: "men")
    let women = SportsEntity(id: "women", name: "Women's League", kind: "competition", sportID: "football", gender: "women")
    let now = Date(timeIntervalSince1970: 100)
    let record = ["idTeam": "123", "strTeam": "Shared Club Name"]
    let first = try #require(SportsReferenceImport.team(record: record, competition: men, existing: [], now: now))
    #expect(SportsReferenceImport.team(record: record, competition: women, existing: [first], now: now) == nil)
    #expect(SportsReferenceImport.team(record: record.merging(["strGender": "Female"]) { _, new in new }, competition: men, existing: [], now: now) == nil)
    let separate = try #require(SportsReferenceImport.team(record: ["idTeam": "456", "strTeam": "Shared Club Name", "strGender": "Female"], competition: women, existing: [first], now: now))
    #expect(separate.id != first.id)
    #expect(separate.gender == "women")
    #expect(separate.competitionIDs == [women.id])
  }

  @Test func membershipDatesCrossCatalogAndCorpusEncodingStrategies() throws {
    let member = SportsMembership(entityID: "team", validFrom: Date(timeIntervalSince1970: 1000), validUntil: Date(timeIntervalSince1970: 2000))
    let numeric = try JSONEncoder().encode(member)
    let isoDecoder = JSONDecoder(); isoDecoder.dateDecodingStrategy = .iso8601
    #expect(try isoDecoder.decode(SportsMembership.self, from: numeric) == member)
    let isoEncoder = JSONEncoder(); isoEncoder.dateEncodingStrategy = .iso8601
    let iso = try isoEncoder.encode(member)
    #expect(try JSONDecoder().decode(SportsMembership.self, from: iso) == member)
  }

  @Test func genericLeagueNamesRequireIndependentSportEvidence() throws {
    let laLiga = try #require(catalog.first { $0.name == "La Liga" && $0.kind == "competition" })
    let volleyball = SportsResolver.analyze(title: "Triunfo del Avarca ante el poderoso Heidelberg",
      summary: "Espectacular encuentro y con final feliz en el estreno de la Liga Iberdrola número 21 del Avarca de Menorca, después que este sábado superaran al potente Heidelberg, en un duelo de titanes (3-1). Una gran recepción, dureza en el saque y otra clase magistral de distribución de Ivone Martínez claves para este inicio feliz; con Paula Gürsching y Camila Hiruela en modo martillo en los momentos decisivos.", catalog: catalog)
    #expect(!volleyball.competitionIDs.contains(laLiga.id))
    #expect(!volleyball.sportIDs.contains(SportsReviewedCatalog.id("sport:football")))
    for title in ["La Liga: el fútbol español celebra una nueva jornada", "La Liga striker scores a hat trick", "La Liga: Real Madrid football club wins"] {
      let analysis = SportsResolver.analyze(title: title, summary: nil, catalog: catalog)
      #expect(analysis.eligible)
      #expect(analysis.competitionIDs.contains(laLiga.id), Comment(rawValue: title))
    }
    let generic = SportsEntity(id: "fixture-rugby-super-league", name: "Super League", kind: "competition", sportID: SportsReviewedCatalog.id("sport:rugby-league"))
    #expect(!SportsResolver.analyze(title: "Super League cricket wicket review", summary: nil, catalog: catalog + [generic]).competitionIDs.contains(generic.id))
    #expect(SportsResolver.analyze(title: "Super League rugby league championship", summary: nil, catalog: catalog + [generic]).competitionIDs.contains(generic.id))
    #expect(!SportsResolver.analyze(title: "Premier League cricket wicket review", summary: nil, catalog: catalog).competitionIDs.contains(SportsReviewedCatalog.id("competition:premier-league")))
    #expect(SportsResolver.analyze(title: "Premier League: Manchester United wins", summary: nil, catalog: catalog).competitionIDs.contains(SportsReviewedCatalog.id("competition:premier-league")))
  }

  @Test func ashesIdiomRequiresIndependentCricketEvidence() {
    let unrelated = SportsResolver.analyze(title: "Economic probabilities for our grandchildren (Cory Doctorow)",
      summary: "After a forest fire, the canopy opens; and when it does, the seedlings that were overshadowed for centuries by the old growth can sprout in the ashes and the sun. We can't afford to continue living under oligarchy.", catalog: catalog)
    #expect(!unrelated.eligible)
    #expect(unrelated.associations.isEmpty)
    let cricket = SportsResolver.analyze(title: "The Ashes", summary: "England's bowler takes five wickets in a cricket match.", catalog: catalog)
    #expect(cricket.eligible)
    #expect(cricket.competitionIDs.contains(SportsReviewedCatalog.id("competition:ashes")))
  }

  @Test func schoolIdentitiesDoNotBecomeUnsupportedInterestFeeds() {
    let school = SportsEntity(id: "fixture-school", name: "Fixture University", kind: "school")
    let team = SportsEntity(id: "fixture-team", name: "Fixture University Basketball", kind: "ncaa-team", schoolID: school.id)
    let feeds = SportsNamedFeeds.catalog(entities: [school, team])
    #expect(!SportsNamedFeeds.isSelectable(school))
    #expect(SportsNamedFeeds.isSelectable(team))
    #expect(feeds.map(\.id) == ["sports", "entity:" + team.id])
  }

  @Test func genderQualifiedCompetitionsAndProgramsKeepDistinctIdentities() throws {
    let men = try #require(catalog.first { $0.id == SportsReviewedCatalog.id("competition:brasileirao") })
    let women = try #require(catalog.first { $0.id == SportsReviewedCatalog.id("competition:brasileirao-feminino-a1") })
    #expect(men.gender == "men"); #expect(men.division == "Série A")
    #expect(women.gender == "women"); #expect(women.division == "A1")
    let brazil = SportsResolver.analyze(title: "Brasileirão Feminino: Assista ao vivo e de graça ao jogo Corinthians x São Paulo", summary: "Confira as transmissões de jogos de futebol.", catalog: catalog)
    #expect(brazil.eligible); #expect(brazil.competitionIDs.contains(women.id))
    #expect(!brazil.competitionIDs.contains(men.id))
    #expect(brazil.sportIDs.contains(SportsReviewedCatalog.id("sport:football")))
    let softball = SportsResolver.analyze(title: "Women's College World Series softball final", summary: nil, catalog: catalog)
    #expect(softball.competitionIDs.contains(SportsReviewedCatalog.id("competition:ncaa-softball")))
    #expect(!softball.competitionIDs.contains(SportsReviewedCatalog.id("competition:ncaa-baseball")))
    for title in ["Women's Bundesliga soccer championship", "Bundesliga femenina: fútbol y goles", "Serie A Women soccer championship", "Serie A femminile calcio final"] {
      let analysis = SportsResolver.analyze(title: title, summary: nil, catalog: catalog)
      #expect(analysis.eligible, Comment(rawValue: title))
      #expect(!analysis.competitionIDs.contains(SportsReviewedCatalog.id("competition:bundesliga")))
      #expect(!analysis.competitionIDs.contains(SportsReviewedCatalog.id("competition:serie-a")))
      #expect(analysis.sportIDs.contains(SportsReviewedCatalog.id("sport:football")))
    }
    let mixed = SportsResolver.analyze(title: "Men's Six Nations and Women's Six Nations rugby championship", summary: nil, catalog: catalog)
    #expect(mixed.competitionIDs.contains(SportsReviewedCatalog.id("competition:six-nations")))
    #expect(mixed.competitionIDs.contains(SportsReviewedCatalog.id("competition:womens-six-nations")))
    let footballMixed = SportsResolver.analyze(title: "Men's Bundesliga soccer and Women's Bundesliga soccer finals", summary: nil, catalog: catalog)
    #expect(footballMixed.competitionIDs.contains(SportsReviewedCatalog.id("competition:bundesliga")))
    let womenTeam = SportsResolver.analyze(title: "Chelsea Women soccer championship", summary: nil, catalog: catalog)
    #expect(!womenTeam.associations.contains { $0.entityID == SportsReviewedCatalog.id("team:premier-league:Chelsea") })
    #expect(womenTeam.associations.contains { $0.entityID == SportsReviewedCatalog.id("team:wsl:Chelsea Women") })
  }

  @Test func providerRosterRetainsCompetitionGenderAndExplicitEvidence() throws {
    let league = SportsEntity(id: "women-league", name: "Women's League", kind: "competition", sportID: "football", gender: "women")
    let inherited = try #require(SportsReferenceImport.team(record: ["idTeam": "fixture-team", "strTeam": "Fixture Club"], competition: league, existing: [], now: Date()))
    #expect(inherited.gender == "women")
    let declared = try #require(SportsReferenceImport.team(record: ["idTeam": "fixture-team", "strTeam": "Fixture Club", "strGender": "Female"], competition: league, existing: [], now: Date()))
    #expect(declared.gender == "women")
  }

  @Test func teamsOutweighCompetitionsAndSportsWithBoundedBoost() {
    let entities = [SportsEntity(id: "sport", name: "Sport", kind: "sport"), SportsEntity(id: "league", name: "League", kind: "competition", sportID: "sport"), SportsEntity(id: "team", name: "Team", kind: "team", sportID: "sport", competitionIDs: ["league"])]
    func candidate(_ id: String, score: Double, team: Bool, league: Bool, sport: Bool) -> SportsRankCandidate {
      SportsRankCandidate(item: item(id), analysis: SportsArticleAnalysis(eligible: true, materiality: "general", associations: team ? [SportsAssociation(entityID: "team", confidence: 1, evidence: ["structured-metadata"], prominence: 0)] : [], sportIDs: sport ? ["sport"] : [], competitionIDs: league ? ["league"] : []), baseScore: score)
    }
    let ranked = SportsRanker.rank(candidates: [candidate("sport", score: 1, team: false, league: false, sport: true), candidate("league", score: 1, team: false, league: true, sport: false), candidate("team", score: 1, team: true, league: false, sport: false)], followIDs: ["sport", "league", "team"], entities: entities, reserveGlobal: false)
    #expect(ranked.prefix(2).map { $0.item.itemID } == ["team", "league"])
    let capped = SportsRanker.rank(candidates: [candidate("all", score: 1, team: true, league: true, sport: true), candidate("baseline", score: 1.36, team: false, league: false, sport: false)], followIDs: ["sport", "league", "team"], entities: entities, reserveGlobal: false)
    #expect(capped.first?.item.itemID == "baseline")
  }
}
