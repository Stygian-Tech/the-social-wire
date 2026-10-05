import Foundation
import SportsCore
import Testing
import WireCore
@testable import AppView

struct SportsEventTeamFilterTests {
  @Test func absentAndExplicitEmptyRemainDistinct() throws {
    #expect(try SportsEventTeamFilter.decode(nil) == nil)
    #expect(try SportsEventTeamFilter.decode("") == [])
    #expect(try SportsEventTeamFilter.decode("sp_b,sp_a,sp_b") == ["sp_a", "sp_b"])
  }

  @Test func onlyActiveTeamsAreAccepted() throws {
    let catalog = [SportsEntity(id: "team", name: "Team", kind: "team"), SportsEntity(id: "ncaa", name: "NCAA", kind: "ncaa-team"), SportsEntity(id: "national", name: "National", kind: "national-side"), SportsEntity(id: "sport", name: "Sport", kind: "sport"), SportsEntity(id: "retired", name: "Retired", kind: "team", active: false)]
    #expect(try SportsEventTeamFilter.validate(["team", "ncaa", "national"], catalog: catalog) == Set(["team", "ncaa", "national"]))
    for id in ["sport", "retired", "missing"] {
      #expect(throws: WireServingError.invalidCursor) { try SportsEventTeamFilter.validate([id], catalog: catalog) }
    }
  }

  @Test func rejectsMalformedAndUnboundedSelections() throws {
    for raw in ["sp_a,", ",sp_a", "sp a", String(repeating: "a", count: 129), Array(repeating: "sp_a", count: 101).joined(separator: ",")] {
      #expect(throws: WireServingError.invalidCursor) { try SportsEventTeamFilter.decode(raw) }
    }
  }
  @Test func preferredEntitiesAndViewerTimeZoneAreValidated() throws {
    let catalog = [SportsEntity(id: "sport", name: "Sport", kind: "sport"), SportsEntity(id: "person", name: "Person", kind: "athlete"), SportsEntity(id: "retired", name: "Retired", kind: "team", active: false)]
    #expect(try SportsEventTeamFilter.preferred(["sport", "person"], catalog: catalog) == Set(["sport", "person"]))
    #expect(throws: WireServingError.invalidCursor) { try SportsEventTeamFilter.preferred(["retired"], catalog: catalog) }
    #expect(try SportsEventTeamFilter.timeZone("America/New_York").identifier == "America/New_York")
    #expect(throws: WireServingError.invalidCursor) { try SportsEventTeamFilter.timeZone("Invalid/Zone") }
  }
}
