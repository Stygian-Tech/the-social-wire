import Foundation
import Testing
@testable import SocialWire

@Suite("Sports Feed Picker Hierarchy")
struct SportsFeedPickerNodeTests {
    @Test("Hockey branches keep field and ice competitions distinct without changing feed identities")
    func hockeyUmbrella() throws {
        let hockey = entity("hockey", name: "Hockey", kind: "sport")
        let ice = entity("ice", name: "Ice Hockey", kind: "sport", sport: hockey.id)
        let field = entity("field", name: "Field Hockey", kind: "sport", sport: hockey.id)
        let nhl = entity("nhl", name: "NHL", kind: "competition", sport: ice.id)
        let fih = entity("fih", name: "FIH Hockey Pro League", kind: "competition", sport: field.id)
        let flyers = entity("flyers", name: "Philadelphia Flyers", kind: "team", sport: ice.id, competitions: [nhl.id])
        let feeds = [feed(hockey), feed(ice, path: ["Hockey", "Ice Hockey"]), feed(field, path: ["Hockey", "Field Hockey"]), feed(nhl, path: ["Competitions", "Hockey", "Ice Hockey"]), feed(fih, path: ["Competitions", "Hockey", "Field Hockey", "International"]), feed(flyers, path: ["Teams", "Hockey", "Ice Hockey", "NHL", "Eastern Conference", "Metropolitan"])]
        let roots = SportsFeedPickerNode.make(feeds: feeds, entities: [hockey, ice, field, nhl, fih, flyers])
        let root = try #require(roots.first { $0.title == "Hockey" })
        #expect(roots.count == 1)
        #expect(root.feed?.id == "entity:hockey")
        let iceBranch = try #require(root.children.first { $0.title == "Ice Hockey" })
        let fieldBranch = try #require(root.children.first { $0.title == "Field Hockey" })
        #expect(iceBranch.feed?.id == "entity:ice")
        #expect(iceBranch.children.first { $0.title == "NHL" }?.feed?.id == "entity:nhl")
        #expect(fieldBranch.children.first { $0.title == "International" }?.children.first?.feed?.id == "entity:fih")
        #expect(fieldBranch.children.contains { $0.title == "NHL" } == false)
    }

    @Test("reviewed Marching Arts umbrella groups DCI WGI and BOA while preserving canonical sport identities")
    func marchingArtsUmbrella() throws {
        let marching = entity("marching", name: "Marching Arts", kind: "sport")
        let drum = entity("drum", name: "Drum Corps", kind: "sport")
        let indoor = entity("indoor", name: "Indoor Marching Arts", kind: "sport")
        let corps = entity("corps", name: "Bluecoats", kind: "team", sport: drum.id)
        let guardUnit = entity("guard", name: "Example Guard", kind: "team", sport: indoor.id)
        let band = entity("band", name: "Example Band", kind: "team", sport: marching.id)
        let feeds = [feed(marching), feed(drum, path: ["Marching Arts", "DCI"]), feed(indoor, path: ["Marching Arts", "WGI"]), feed(corps, path: ["Marching Arts", "DCI", "World Class"]), feed(guardUnit, path: ["Marching Arts", "WGI", "Color Guard"]), feed(band, path: ["Marching Arts", "BOA", "AAAA"])]
        let roots = SportsFeedPickerNode.make(feeds: feeds, entities: [marching, drum, indoor, corps, guardUnit, band])
        #expect(roots.map(\.title) == ["Marching Arts"])
        let root = try #require(roots.first)
        #expect(root.feed?.id == "entity:marching")
        #expect(root.children.map(\.title) == ["BOA", "DCI", "WGI"])
        let dci = try #require(root.children.first { $0.title == "DCI" })
        #expect(dci.children.first { $0.title == "Drum Corps" }?.feed?.id == "entity:drum")
        #expect(dci.children.first { $0.title == "World Class" }?.children.first?.feed?.id == "entity:corps")
        #expect(corps.sportID == "drum")
    }

    private func entity(_ id: String, name: String, kind: String, sport: String? = nil, competitions: [String] = [], active: Bool = true) -> SportsEntity {
        .init(id: id, name: name, kind: kind, sportID: sport, competitionIDs: competitions, aliases: [], providerIDs: [:], active: active)
    }

    private func feed(_ entity: SportsEntity, path: [String]? = nil) -> SportsNamedFeed {
        .init(id: "entity:\(entity.id)", title: entity.name, kind: entity.kind, entityIDs: [entity.id], description: "Matching Stories", groupPath: path)
    }

    @Test("default browsing starts with sports and descends through league and conference")
    func leagueHierarchy() throws {
        let sport = entity("football", name: "American Football", kind: "sport")
        let league = entity("nfl", name: "NFL", kind: "competition", sport: sport.id)
        let team = entity("giants", name: "New York Giants", kind: "team", sport: sport.id, competitions: [league.id])
        let roots = SportsFeedPickerNode.make(feeds: [.all, feed(sport), feed(league, path: ["Competitions", "American Football"]), feed(team, path: ["Teams", "American Football", "NFL", "NFC", "East"])], entities: [sport, league, team])
        #expect(roots.map(\.title) == ["All Sports", "American Football"])
        let football = try #require(roots.first { $0.title == "American Football" })
        #expect(football.feed?.id == "entity:football")
        #expect(football.children.map(\.title) == ["NFL"])
        let nfl = try #require(football.children.first)
        #expect(nfl.feed?.id == "entity:nfl")
        let conference = try #require(nfl.children.first)
        #expect(conference.title == "NFC")
        #expect(conference.children.first?.title == "East")
        #expect(conference.children.first?.children.first?.feed?.id == "entity:giants")
    }

    @Test("professional conference and division branches preserve league and team navigation", arguments: [
        ("Baseball", "MLB", "American League", "East", "New York Yankees"),
        ("Baseball", "MLB", "National League", "West", "Los Angeles Dodgers"),
        ("Ice Hockey", "NHL", "Eastern Conference", "Metropolitan", "Philadelphia Flyers")
    ])
    func professionalDivisions(sportName: String, leagueName: String, conferenceName: String, divisionName: String, teamName: String) throws {
        let sport = entity("sport", name: sportName, kind: "sport")
        let league = entity("league", name: leagueName, kind: "competition", sport: sport.id)
        let team = entity("team", name: teamName, kind: "team", sport: sport.id, competitions: [league.id])
        let roots = SportsFeedPickerNode.make(feeds: [feed(sport), feed(league), feed(team, path: ["Teams", sportName, leagueName, conferenceName, divisionName])], entities: [sport, league, team])
        let root = try #require(roots.first { $0.title == sportName })
        let leagueNode = try #require(root.children.first { $0.title == leagueName })
        #expect(leagueNode.feed?.id == "entity:league")
        let conference = try #require(leagueNode.children.first { $0.title == conferenceName })
        let division = try #require(conference.children.first { $0.title == divisionName })
        #expect(division.children.first?.feed?.id == "entity:team")
        #expect(division.children.first?.title == teamName)
        #expect(conference.feed == nil)
    }

    @Test("canonical competition relationships organize legacy paths without mixing sports")
    func canonicalRelationships() throws {
        let swimming = entity("swimming", name: "Swimming", kind: "sport")
        let cycling = entity("cycling", name: "Cycling", kind: "sport")
        let league = entity("swim-world", name: "World Series", kind: "competition", sport: swimming.id)
        let athlete = entity("swimmer", name: "A Swimmer", kind: "athlete", sport: swimming.id, competitions: [league.id])
        let roots = SportsFeedPickerNode.make(feeds: [feed(swimming), feed(cycling), feed(league), feed(athlete)], entities: [swimming, cycling, league, athlete])
        let swimRoot = try #require(roots.first { $0.title == "Swimming" })
        #expect(swimRoot.children.map(\.title) == ["World Series"])
        #expect(swimRoot.children.first?.children.first?.feed?.id == "entity:swimmer")
        #expect(roots.first { $0.title == "Cycling" }?.children.isEmpty == true)
    }

    @Test("NCAA divisions and conferences are preserved under the canonical sport")
    func ncaaPaths() throws {
        let sport = entity("football", name: "American Football", kind: "sport")
        let team = entity("mount-union", name: "Mount Union Football", kind: "ncaa-team", sport: sport.id)
        let roots = SportsFeedPickerNode.make(feeds: [feed(sport), feed(team, path: ["NCAA", "Division III", "Football", "Ohio Athletic Conference"])], entities: [sport, team])
        let root = try #require(roots.first)
        #expect(root.title == "American Football")
        #expect(root.children.first?.title == "NCAA")
        #expect(root.children.first?.children.first?.title == "Division III")
        #expect(root.children.first?.children.first?.children.first?.title == "Ohio Athletic Conference")
        #expect(root.children.first?.children.first?.children.first?.children.first?.feed?.id == "entity:mount-union")
    }

    @Test("S, SB, and SM classifications remain distinct under para swimming")
    func classifications() throws {
        let sport = entity("swimming", name: "Swimming", kind: "sport")
        let para = entity("para", name: "Para Swimming", kind: "competition", sport: sport.id)
        let classes = ["S14", "SB14", "SM14"].map { entity($0, name: "Para Swimming \($0)", kind: "classification", sport: sport.id, competitions: [para.id]) }
        let feeds = [feed(sport), feed(para, path: ["Competitions", "Swimming", "Para Swimming"])] + classes.map { feed($0, path: ["Swimming", "Para Swimming", "Classes and Medley Indices", $0.id]) }
        let roots = SportsFeedPickerNode.make(feeds: feeds, entities: [sport, para] + classes)
        let paraNode = try #require(roots.first?.children.first)
        #expect(paraNode.title == "Para Swimming")
        #expect(paraNode.feed?.id == "entity:para")
        let category = try #require(paraNode.children.first)
        #expect(category.title == "Classes and Medley Indices")
        #expect(Set(category.children.map(\.title)) == ["S14", "SB14", "SM14"])
        #expect(Set(category.children.compactMap { $0.children.first?.feed?.id }) == ["entity:S14", "entity:SB14", "entity:SM14"])
    }

    @Test("inactive catalog entities do not leak into browsing and identities are order independent")
    func activeAndStable() throws {
        let sport = entity("tennis", name: "Tennis", kind: "sport")
        let retired = entity("retired", name: "Retired Competition", kind: "competition", sport: sport.id, active: false)
        let feeds = [feed(sport), feed(retired)]
        let first = SportsFeedPickerNode.make(feeds: feeds, entities: [sport, retired])
        let second = SportsFeedPickerNode.make(feeds: feeds.reversed(), entities: [retired, sport])
        #expect(first.map(\.id) == second.map(\.id))
        #expect(first.first?.children.isEmpty == true)
        let node = try #require(first.first)
        #expect(node.find(node.id)?.feed?.id == "entity:tennis")
    }
}
