import Foundation
import Testing
@testable import SocialWire

@Suite("Sports Feed")
struct SportsFeedTests {
    @Test func preservesOptionalProviderAbbreviationInCatalogDTO() throws {
        let payload = Data(#"{"id":"team","name":"Fixture Team","kind":"team","competitionIDs":[],"aliases":[],"providerIDs":{"thesportsdb":"123"},"active":true,"abbreviation":"ABC"}"#.utf8)
        let entity = try JSONDecoder().decode(SportsEntity.self, from: payload)
        #expect(entity.abbreviation == "ABC")
        #expect(try JSONDecoder().decode(SportsEntity.self, from: JSONEncoder().encode(entity)).abbreviation == "ABC")
    }

    @Test("schedule labels omit Scheduled and only mark explicit unknown start times TBD")
    func scheduleLabels() throws {
        let legacy = Data(#"{"id":"e","competitionID":"league","entityIDs":[],"title":"Match","startsAt":"2026-10-04T00:00:00Z","status":"scheduled","updatedAt":"now"}"#.utf8)
        let unknown = Data(#"{"id":"e","competitionID":"league","entityIDs":[],"title":"Match","startsAt":"2026-10-04T00:00:00Z","startTimeKnown":false,"status":"scheduled","updatedAt":"now"}"#.utf8)
        let event = try JSONDecoder().decode(SportsEvent.self, from: legacy)
        #expect(event.scheduleStatusLabel == nil)
        #expect(!event.scheduleDateLabel.contains("TBD"))
        #expect(try JSONDecoder().decode(SportsEvent.self, from: unknown).scheduleDateLabel.contains("TBD"))
    }

    @Test("older preferences default visible; sports settings survive serialization")
    func preferences() throws {
        var value = try JSONDecoder().decode(ReaderFeedPreferences.self, from: Data("{}".utf8))
        #expect(value.showSports)
        #expect(!value.hideSportsScores)
        value.showSports = false; value.hideSportsScores = true
        #expect(try JSONDecoder().decode(ReaderFeedPreferences.self, from: JSONEncoder().encode(value)) == value)
        #expect(NewsPrimaryFeed.defaultFeeds.count == 4)
        #expect(NewsTab.available(wire: true, circle: true, sports: true).contains(.sports))
        #expect(!NewsTab.available(wire: true, circle: true).contains(.sports))
    }

    @Test("only active supported Sports kinds can receive interests")
    func selectableEntities() {
        for kind in ["sport", "competition", "team", "national-side", "ncaa-team", "athlete", "driver", "school", "organization"] {
            let entity = SportsEntity(id: kind, name: kind, kind: kind, sportID: nil, competitionIDs: [], aliases: [], providerIDs: [:], active: true)
            #expect(entity.isSelectable == !["school", "organization"].contains(kind))
            let inactive = SportsEntity(id: kind, name: kind, kind: kind, sportID: nil, competitionIDs: [], aliases: [], providerIDs: [:], active: false)
            #expect(!inactive.isSelectable)
        }
    }

    @Test("follow and mute replace one public entity record")
    func recordKeys() throws {
        let follow = SportsSelectionRecord(reference: "opaque-team", action: "follow", createdAt: "now", updatedAt: "now")
        let mute = SportsSelectionRecord(reference: "opaque-team", action: "mute", createdAt: "now", updatedAt: "now")
        #expect(follow.key == mute.key)
        #expect(follow.key.count == 64)
        #expect(follow.key != SportsSelectionRecord.key(reference: "other-team"))
        let data = try JSONEncoder().encode(follow)
        let record = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(record["$type"] as? String == SportsSelectionRecord.collection)
    }

    @Test("a direct follow overrides broader mutes but explicit team mutes win")
    func mutes() {
        let item = fixture(index: 0, team: true)
        let broad = selection("sport", "mute")
        #expect(!SportsPersonalization.isPermitted(item, selections: [broad]))
        #expect(SportsPersonalization.isPermitted(item, selections: [broad, selection("team", "follow")]))
        #expect(!SportsPersonalization.isPermitted(item, selections: [selection("team", "mute")]))
    }

    @Test("named feeds never reserve an unrelated global story")
    func matchingOnly() {
        let items = (0..<10).map { fixture(index: $0, team: $0 == 3, major: $0 == 9) }
        let interests = [selection("team", "follow")]
        let global = SportsPersonalization.reorder(items, selections: interests, global: true)
        #expect(global.first?.id == "story-3")
        #expect(global[4].majorGlobal)
        let named = SportsPersonalization.reorder(items, selections: interests, global: false)
        #expect(named.map(\.id) == items.map(\.id))
    }

    @Test("class interests boost matching stories and explicit class mutes exclude them")
    func classificationInterest() {
        let plain = fixture(index: 0, team: false)
        let entity = SportsEntity(id: "s8", name: "Para Swimming S8", kind: "classification", sportID: "swimming", competitionIDs: ["para-swimming"], aliases: ["S8"], providerIDs: [:], active: true)
        let association = SportsAssociation(entityID: "s8", confidence: 0.95, evidence: ["class-context"], prominence: 0, resolverVersion: "v10")
        let matching = SportsFeedItem(story: fixture(index: 1, team: false).story, entities: [entity], associations: [association], materiality: "reporting", majorGlobal: false)
        let fillers = (2..<12).map { fixture(index: $0, team: false) }
        #expect(SportsPersonalization.reorder([plain, matching] + fillers, selections: [selection("s8", "follow")], global: true).first?.id == matching.id)
        #expect(!SportsPersonalization.isPermitted(matching, selections: [selection("s8", "mute")]))
    }

    @Test("My Teams includes followed team kinds, excludes muted teams and broader interests")
    func followedTeams() {
        let entities = ["team", "ncaa-team", "national-side", "sport", "athlete", "driver"].map {
            SportsEntity(id: $0, name: $0, kind: $0, sportID: nil, competitionIDs: [], aliases: [], providerIDs: [:], active: true)
        }
        let follows = entities.map { selection($0.id, "follow") }
        #expect(SportsEntity.followedTeamIDs(entities: entities, selections: follows) == ["national-side", "ncaa-team", "team"])
        #expect(SportsEntity.followedTeamIDs(entities: entities, selections: follows + [selection("team", "mute")]) == ["national-side", "ncaa-team"])
        #expect(SportsEntity.followedTeamIDs(entities: entities, selections: []) == [])
        #expect(SportsEntity.followedIDs(selections: follows + [selection("team", "mute")]) == ["athlete", "driver", "national-side", "ncaa-team", "sport"])
    }

    @Test("schedule labels identify both sport and competition")
    func eventContext() {
        let sport = SportsEntity(id: "football", name: "American Football", kind: "sport", sportID: nil, competitionIDs: [], aliases: [], providerIDs: [:], active: true)
        let league = SportsEntity(id: "nfl", name: "NFL", kind: "competition", sportID: "football", competitionIDs: [], aliases: [], providerIDs: [:], active: true)
        #expect(SportsEntity.eventContext(competitionID: "nfl", entities: [sport, league]) == "American\u{00A0}Football · NFL")
        #expect(SportsEntity.eventContext(competitionID: "nfl", entities: [league]) == "NFL")
        #expect(SportsEntity.eventContext(competitionID: "unknown", entities: [sport, league]) == nil)
    }

    @Test("event score fields decode without replacing the article feed contract")
    func events() throws {
        let json = Data(#"{"events":[{"id":"event","competitionID":"league","entityIDs":["team"],"title":"Team A vs Team B","startsAt":"2026-10-03T17:00:00Z","status":"postponed","homeScore":"2","awayScore":"1","updatedAt":"2026-10-03T17:30:00Z"}],"updatedAt":"2026-10-03T17:30:00Z","degraded":true}"#.utf8)
        let result = try JSONDecoder().decode(SportsEventsResponse.self, from: json)
        #expect(result.events.first?.status == "postponed")
        #expect(result.degraded)
        #expect(result.standings == nil)
        #expect(result.schedulesStatus == nil)
        #expect(result.bracketSources == nil)
        #expect(result.eventsLimited == nil)
    }

    @Test("team-scoped responses reject broad events and unscoped standings")
    func teamResponseGuard() throws {
        let json = Data(#"{"events":[{"id":"event","competitionID":"league","entityIDs":["team"],"title":"Team A vs Team B","startsAt":"2026-10-03T17:00:00Z","status":"scheduled","updatedAt":"2026-10-03T17:30:00Z"}],"degraded":false,"standings":[{"competitionID":"league","season":"2026","sourceURL":"https://www.thesportsdb.com/","status":"available","degraded":false,"rows":[{"id":"row","entityID":"team","name":"Team","rank":1},{"id":"other-row","entityID":"opponent","name":"Opponent","rank":2}]}]}"#.utf8)
        var result = try JSONDecoder().decode(SportsEventsResponse.self, from: json)
        #expect(result.matchesTeamScope(["team"]))
        #expect(result.standings?.first?.rows.map(\.rank) == [1, 2])
        #expect(!result.matchesTeamScope(["other"]))
        #expect(!result.matchesTeamScope([]))
        let unscoped = Data(#"{"events":[],"degraded":false,"standings":[{"competitionID":"league","season":"2026","sourceURL":"https://www.thesportsdb.com/","status":"available","degraded":false,"rows":[{"id":"row","name":"Team"}]}]}"#.utf8)
        result = try JSONDecoder().decode(SportsEventsResponse.self, from: unscoped)
        #expect(!result.matchesTeamScope(["team"]))
        result.standings = []
        #expect(result.matchesTeamScope(["team"]))
    }

    @Test("standings zones decode without requiring them on legacy rows")
    func standingsZones() throws {
        let json = Data(#"{"events":[],"degraded":false,"standings":[{"competitionID":"efl","season":"2026-2027","sourceURL":"https://www.thesportsdb.com/","status":"available","degraded":false,"rows":[{"id":"team","name":"Example","rank":3,"zone":{"kind":"playoff","label":"Promotion Playoffs","sourceURL":"https://www.efl.com/"}},{"id":"legacy","name":"Legacy"},{"id":"future","name":"Future","zone":{"kind":"future-kind","label":"New Zone","sourceURL":"https://example.com/"}}]}]}"#.utf8)
        let response = try JSONDecoder().decode(SportsEventsResponse.self, from: json)
        #expect(response.standings?.first?.rows[0].zone?.label == "Promotion Playoffs")
        #expect(response.standings?.first?.rows[0].zone?.systemImage == "flag.fill")
        #expect(response.standings?.first?.rows[1].zone == nil)
        #expect(response.standings?.first?.rows[2].zone?.systemImage == "info.circle")
        #expect(try JSONDecoder().decode(SportsEventsResponse.self, from: JSONEncoder().encode(response)) == response)
    }

    @Test("event activity markers disappear with Hide Scores and ignore old refreshed results")
    func eventActivity() throws {
        let now = ISO8601DateFormatter().date(from: "2026-10-04T20:00:00Z")!
        let json = Data(#"{"id":"event","competitionID":"league","entityIDs":[],"title":"Example","startsAt":"2026-10-04T19:00:00Z","status":"finished","updatedAt":"2026-10-04T20:00:00Z"}"#.utf8)
        let recent = try JSONDecoder().decode(SportsEvent.self, from: json)
        #expect(recent.activityLabel(now: now, hideScores: false, timeZone: TimeZone(secondsFromGMT: 0)!) == "Final Today")
        #expect(recent.activityLabel(now: now, hideScores: true) == nil)
        #expect(recent.activityLabel(now: now.addingTimeInterval(25 * 3600), hideScores: false) == nil)
        let activeJSON = Data(String(decoding: json, as: UTF8.self).replacingOccurrences(of: "finished", with: "in-progress").utf8)
        let active = try JSONDecoder().decode(SportsEvent.self, from: activeJSON)
        #expect(active.activityLabel(now: now, hideScores: false) == "In Progress")
        #expect(active.activityLabel(now: now, hideScores: true) == nil)
        let nextDay = ISO8601DateFormatter().date(from: "2026-10-05T01:00:00Z")!
        #expect(recent.activityLabel(now: nextDay, hideScores: false, timeZone: TimeZone(secondsFromGMT: 0)!) == nil)
        #expect(recent.activityLabel(now: nextDay, hideScores: false, timeZone: TimeZone(identifier: "America/New_York")!) == "Final Today")
    }

    @Test("official bracket sources and bounded schedule flags are optional and open externally")
    func bracketSources() throws {
        let json = Data(#"{"events":[],"degraded":false,"eventsLimited":true,"bracketSources":[{"id":"mlb-2026","competitionID":"mlb","season":"2026","title":"MLB Postseason","url":"https://www.mlb.com/postseason","reviewedAt":"2026-10-04T00:00:00Z","mode":"external"}]}"#.utf8)
        let response = try JSONDecoder().decode(SportsEventsResponse.self, from: json)
        #expect(response.eventsLimited == true)
        #expect(response.bracketSources?.first?.externalURL?.host == "www.mlb.com")
        #expect(response.bracketSources?.first?.reviewedDate == ISO8601DateFormatter().date(from: "2026-10-04T00:00:00Z"))
        let unsupported = SportsBracketSource(id: "unsafe", competitionID: "mlb", season: "2026", title: "Unsupported", url: "javascript:alert(1)", reviewedAt: "now", mode: "external")
        #expect(unsupported.externalURL == nil)
        let inline = SportsBracketSource(id: "inline", competitionID: "mlb", season: "2026", title: "Inline", url: "https://example.com", reviewedAt: "now", mode: "inline")
        #expect(inline.externalURL == nil)
        #expect(try JSONDecoder().decode(SportsEventsResponse.self, from: JSONEncoder().encode(response)) == response)
    }

    @Test("personal schedules reject missing or obsolete server preference and timezone echoes")
    func scheduleContext() throws {
        let json = Data(#"{"events":[],"degraded":false,"preferredIDs":["team","league"],"timeZone":"America/New_York"}"#.utf8)
        var response = try JSONDecoder().decode(SportsEventsResponse.self, from: json)
        #expect(response.matchesOrderingContext(preferredIDs: ["league", "team"], timeZone: "America/New_York"))
        #expect(!response.matchesOrderingContext(preferredIDs: ["other"], timeZone: "America/New_York"))
        #expect(!response.matchesOrderingContext(preferredIDs: ["team", "league"], timeZone: "UTC"))
        response.preferredIDs = nil; response.timeZone = nil
        #expect(!response.matchesOrderingContext(preferredIDs: ["team"], timeZone: "America/New_York"))
        #expect(response.matchesOrderingContext(preferredIDs: [], timeZone: "America/New_York"))
    }

    @Test("schedule modes select only the requested followed category without generic backfill")
    func scheduleModes() {
        let entities = ["sport", "competition", "classification", "conference", "group", "team", "national-side", "ncaa-team", "athlete", "driver"].map { kind in
            SportsEntity(id: kind, name: kind, kind: kind, sportID: nil, competitionIDs: [], aliases: [], providerIDs: [:], active: true)
        }
        let follows = entities.map { selection($0.id, "follow") }
        #expect(SportsEntity.preferredIDs(entities: entities, selections: follows, scope: "sports") == ["sport"])
        #expect(SportsEntity.preferredIDs(entities: entities, selections: follows, scope: "leagues") == ["classification", "competition", "conference", "group"])
        #expect(SportsEntity.preferredIDs(entities: entities, selections: follows, scope: "teams") == ["national-side", "ncaa-team", "team"])
        #expect(SportsEntity.preferredIDs(entities: entities, selections: follows, scope: "all").count == 10)
        #expect(SportsEntity.preferredIDs(entities: entities, selections: [selection("team", "follow")], scope: "sports").isEmpty)
        #expect(SportsEntity.preferredIDs(entities: entities, selections: follows + [selection("sport", "mute")], scope: "sports").isEmpty)
        #expect(SportsEntity.preferredIDs(entities: entities, selections: follows, scope: "unknown").isEmpty)
    }

    @Test("review calendar dates preserve UTC while fetched timestamps remain instants")
    func reviewCalendarDate() {
        let source = SportsBracketSource(id: "source", competitionID: "league", season: "2026", title: "Bracket", url: "https://www.nfl.com/playoffs/bracket", reviewedAt: "2026-10-04T00:00:00Z", mode: "external")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        #expect(calendar.component(.day, from: source.reviewedDate!) == 3)
        #expect(source.reviewedDateLabel(locale: Locale(identifier: "en_US_POSIX")) == "Oct 4, 2026")
    }

    @Test("entity overview selects actual current/latest data and the nearest upcoming fixtures")
    func entityOverview() throws {
        let now = ISO8601DateFormatter().date(from: "2026-10-04T20:00:00Z")!
        let json = Data(#"{"events":[{"id":"late","competitionID":"league","entityIDs":[],"title":"Later","startsAt":"2026-10-07T20:00:00Z","status":"scheduled","updatedAt":"2026-10-04T20:00:00Z"},{"id":"latest","competitionID":"league","entityIDs":[],"title":"Latest","startsAt":"2026-10-04T17:00:00Z","status":"finished","updatedAt":"2026-10-04T20:00:00Z"},{"id":"next","competitionID":"league","entityIDs":[],"title":"Next","startsAt":"2026-10-05T20:00:00Z","status":"scheduled","updatedAt":"2026-10-04T20:00:00Z"},{"id":"active","competitionID":"league","entityIDs":[],"title":"Current","startsAt":"2026-10-04T19:00:00Z","status":"in-progress","updatedAt":"2026-10-04T20:00:00Z"}],"degraded":false}"#.utf8)
        var response = try JSONDecoder().decode(SportsEventsResponse.self, from: json)
        #expect(response.featuredEvent(now: now)?.id == "active")
        #expect(response.upcomingEvents(now: now, limit: 1).map(\.id) == ["next"])
        response = SportsEventsResponse(events: response.events.filter { $0.id != "active" }, updatedAt: response.updatedAt, degraded: response.degraded)
        #expect(response.featuredEvent(now: now)?.id == "latest")
        #expect(response.upcomingEvents(now: now, limit: 0).isEmpty)
    }

    @Test("sport and competition display names keep words together without altering canonical search text")
    func sportsNonbreakingNames() {
        let entity = SportsEntity(id: "f1", name: "Formula 1", kind: "competition", sportID: "motorsport", competitionIDs: [], aliases: [], providerIDs: [:], active: true)
        #expect(entity.displayName == "Formula\u{00A0}1")
        #expect(entity.name == "Formula 1")
        #expect(SportsEntity.displayName("American Football", kind: "sport") == "American\u{00A0}Football")
        #expect(SportsEntity.displayName("Red Bull Racing", kind: "team") == "Red Bull Racing")
        let feed = SportsNamedFeed(id: "entity:f1", title: entity.name, kind: entity.kind, entityIDs: [entity.id], description: "Formula 1 News")
        #expect(feed.matchesSearch("Formula 1"))
    }

    @Test("standings decode optional statistics and independent schedule availability")
    func standings() throws {
        let json = Data(#"{"events":[],"degraded":false,"schedulesStatus":"empty","standings":[{"competitionID":"league","season":"2026","sourceURL":"https://www.thesportsdb.com/","status":"available","degraded":true,"rows":[{"id":"team","name":"Example United","rank":1,"points":"23","group":"Group A"}]}]}"#.utf8)
        let result = try JSONDecoder().decode(SportsEventsResponse.self, from: json)
        #expect(result.schedulesStatus == "empty")
        #expect(result.standings?.first?.id == "league:2026")
        #expect(result.standings?.first?.degraded == true)
        #expect(result.standings?.first?.rows.first?.rank == 1)
        #expect(result.standings?.first?.rows.first?.played == nil)
        #expect(result.standings?.first?.rows.first?.points == "23")
        #expect(result.standings?.first?.providerName == "TheSportsDB")
        #expect(result.standings?.first?.providerURL?.host == "www.thesportsdb.com")
    }

    private func selection(_ id: String, _ action: String) -> SportsSelectionRecord {
        SportsSelectionRecord(reference: id, action: action, createdAt: "now", updatedAt: "now")
    }

    private func fixture(index: Int, team: Bool, major: Bool = false) -> SportsFeedItem {
        let entity = SportsEntity(id: "team", name: "Team", kind: "team", sportID: "sport", competitionIDs: ["league"], aliases: [], providerIDs: [:], active: true)
        let story = WireFeedItem(itemId: "story-\(index)", canonicalUrl: "https://example.com/\(index)", representativeUri: nil, title: "Story", summary: nil, publishedAt: nil, thumbnailUrl: nil, source: WireFeedSource(name: "News", domain: "example.com"), reasons: [], provenance: [])
        let association = SportsAssociation(entityID: "team", confidence: 0.95, evidence: ["name"], prominence: 0, resolverVersion: "v1")
        return SportsFeedItem(story: story, entities: team ? [entity] : [], associations: team ? [association] : [], materiality: "reporting", majorGlobal: major)
    }
}
