import Foundation
import Testing
@testable import SocialWire

@Suite("Sports Feed Picker Groups")
struct SportsFeedPickerGroupTests {
    private func feed(_ id: String, path: [String] = [], kind: String = "ncaa-team") throws -> SportsNamedFeed {
        let object: [String: Any] = ["id": id, "title": "Team \(id)", "kind": kind, "entityIDs": [id], "description": "Matching Stories", "groupPath": path]
        return try JSONDecoder().decode(SportsNamedFeed.self, from: JSONSerialization.data(withJSONObject: object))
    }

    @Test("para swimming classes and medley indices remain distinct selectable groups")
    func paraSwimmingClasses() throws {
        let feeds = try [feed("s8", path: ["Swimming", "Para Swimming", "S"], kind: "classification"), feed("sb8", path: ["Swimming", "Para Swimming", "SB"], kind: "classification"), feed("sm8", path: ["Swimming", "Para Swimming", "SM"], kind: "classification")]
        let groups = SportsFeedPickerGroup.make(feeds: feeds, selectedID: "sports", query: "", activeEntityIDs: ["s8", "sb8", "sm8"])
        #expect(groups.count == 3)
        #expect(Set(groups.flatMap(\.feeds).map(\.id)) == ["s8", "sb8", "sm8"])
        #expect(groups.allSatisfy { $0.title.hasPrefix("Classes and Medley Indices") })
        let entity = try JSONDecoder().decode(SportsEntity.self, from: Data(#"{"id":"s8","name":"Para Swimming S8","kind":"classification","competitionIDs":[],"aliases":[],"providerIDs":{},"active":true}"#.utf8))
        #expect(entity.isSelectable)
    }

    @Test("sport, division, and conference form distinct headings")
    func paths() throws {
        let feeds = try [feed("d2", path: ["Football", "Division II", "Gulf South"]), feed("d3", path: ["Football", "Division III", "Centennial"])]
        let groups = SportsFeedPickerGroup.make(feeds: feeds, selectedID: "sports", query: "", activeEntityIDs: ["d2", "d3"])
        #expect(groups.map(\.title) == ["NCAA Teams › Football › Division II › Gulf South", "NCAA Teams › Football › Division III › Centennial"])
        #expect(Set(groups.map(\.id)).count == 2)
    }

    @Test("all active teams remain browsable beyond100 and selected survives search")
    func coverage() throws {
        let feeds = try (0..<250).map { try feed(String($0), path: ["Football", "Division III", "Centennial"]) }
        let active = Set(feeds.flatMap(\.entityIDs))
        let all = SportsFeedPickerGroup.make(feeds: feeds, selectedID: "249", query: "", activeEntityIDs: active)
        #expect(all.flatMap(\.feeds).count == 250)
        let selected = SportsFeedPickerGroup.make(feeds: feeds, selectedID: "249", query: "No Match", activeEntityIDs: [])
        #expect(selected.flatMap(\.feeds).map(\.id) == ["249"])
        let conference = SportsFeedPickerGroup.make(feeds: feeds, selectedID: "sports", query: "centennial", activeEntityIDs: active)
        #expect(conference.flatMap(\.feeds).count == 250)
    }

    @Test("catalog aliases find Formula 1 teams without conflating Red Bull and Racing Bulls")
    func teamAliases() throws {
        let feeds = try [feed("red-bull-racing", path: ["Motorsport", "Formula 1"], kind: "team"), feed("racing-bulls", path: ["Motorsport", "Formula 1"], kind: "team")]
        let aliases = ["red-bull-racing": ["Red Bull Racing", "RBR"], "racing-bulls": ["Racing Bulls", "VCARB", "Visa Cash App Racing Bulls"]]
        let active = Set(feeds.flatMap(\.entityIDs))
        let redBull = SportsFeedPickerGroup.make(feeds: feeds, selectedID: "sports", query: "rbr", activeEntityIDs: active, aliasesByEntityID: aliases)
        #expect(redBull.flatMap(\.feeds).map(\.id) == ["red-bull-racing"])
        let racingBulls = SportsFeedPickerGroup.make(feeds: feeds, selectedID: "sports", query: "Racing Bulls", activeEntityIDs: active, aliasesByEntityID: aliases)
        #expect(racingBulls.flatMap(\.feeds).map(\.id) == ["racing-bulls"])
        let sponsor = SportsFeedPickerGroup.make(feeds: feeds, selectedID: "sports", query: "vcArb", activeEntityIDs: active, aliasesByEntityID: aliases)
        #expect(sponsor.flatMap(\.feeds).map(\.id) == ["racing-bulls"])
        let selected = SportsFeedPickerGroup.make(feeds: feeds, selectedID: "red-bull-racing", query: "VCARB", activeEntityIDs: active, aliasesByEntityID: aliases)
        #expect(Set(selected.flatMap(\.feeds).map(\.id)) == ["red-bull-racing", "racing-bulls"])
    }

    @Test("inactive entities hide and person search remains intentional")
    func filtering() throws {
        let feeds = try [feed("active", kind: "team"), feed("inactive", kind: "team"), feed("driver", path: ["Motorsport", "Formula 1"], kind: "driver")]
        let groups = SportsFeedPickerGroup.make(feeds: feeds, selectedID: "sports", query: "", activeEntityIDs: ["active", "driver"])
        #expect(groups.flatMap(\.feeds).map(\.id) == ["active"])
        let query = SportsFeedPickerGroup.make(feeds: feeds, selectedID: "sports", query: "Formula 1", activeEntityIDs: ["active", "driver"])
        #expect(query.flatMap(\.feeds).map(\.id) == ["driver"])
    }
}
