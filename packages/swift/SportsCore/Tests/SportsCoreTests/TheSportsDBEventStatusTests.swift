import Foundation
import Testing
@testable import SportsCore

struct TheSportsDBEventStatusTests {
  @Test func documentedActiveCodesRetainScores() throws {
    for code in ["Q1", "Q2", "Q3", "Q4", "P1", "P2", "P3", "IN1", "IN2", "IN9", "OT", "ET", "PT", "BT", "S1", "S5", "1H", "2H", "HT"] {
      let event = try #require(TheSportsDBAdapter.event(row(code), competitionID: "reviewed", entities: [], now: .distantFuture))
      #expect(event.status == "in-progress")
      #expect(event.homeScore == "7")
    }
  }
  @Test func terminalCodesDoNotBecomeActive() throws {
    for code in ["FT", "AOT", "AET", "AP", "PEN"] {
      let event = try #require(TheSportsDBAdapter.event(row(code), competitionID: "reviewed", entities: [], now: .distantPast))
      #expect(event.status == "finished")
      #expect(event.awayScore == "3")
    }
    #expect(TheSportsDBEventStatus.normalize(" PST ") == "postponed")
    #expect(TheSportsDBEventStatus.normalize("POST") == "postponed")
    #expect(TheSportsDBEventStatus.normalize("CANC") == "cancelled")
  }
  @Test func unknownInterruptedAndCricketCodesDoNotGuessActivity() throws {
    for code in ["", "NS", "TBD", "SUSP", "INTR", "ABD", "unknown", "innings break"] {
      let event = try #require(TheSportsDBAdapter.event(row(code), competitionID: "reviewed", entities: [], now: .distantFuture))
      #expect(event.status == "scheduled")
      #expect(event.homeScore == nil)
    }
  }
  private func row(_ status: String) -> [String: String] {
    ["idEvent": "1", "strEvent": "Reviewed game", "dateEvent": "2026-10-04", "strTime": "17:00:00", "strStatus": status, "intHomeScore": "7", "intAwayScore": "3"]
  }
}
