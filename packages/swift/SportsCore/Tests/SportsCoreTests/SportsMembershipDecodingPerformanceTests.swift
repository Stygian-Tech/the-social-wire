import Foundation
import Testing
@testable import SportsCore

@Suite("Sports Membership Decode Budget")
struct SportsMembershipDecodingPerformanceTests {
  @Test func acceptsOffsetDatesAndRejectsMalformedMembershipDates() throws {
    let value = Data(#"{"entityID":"competition:test","validFrom":"2026-01-01T02:00:00+02:00","validUntil":null}"#.utf8)
    let decoded = try JSONDecoder().decode(SportsMembership.self, from: value)
    #expect(decoded.validFrom == Date(timeIntervalSince1970: 1_767_225_600))
    #expect(decoded.validUntil == nil)
    let malformed = Data(#"{"entityID":"competition:test","validFrom":"not-a-date"}"#.utf8)
    #expect(throws: DecodingError.self) { try JSONDecoder().decode(SportsMembership.self, from: malformed) }
  }

  @Test func largePublicCatalogMembershipsDecodeWithinBudget() throws {
    let count = 11_000
    let item = #"{"entityID":"competition:test","validFrom":"2026-01-01T00:00:00Z","validUntil":"2027-01-01T00:00:00.123Z","season":"2026"}"#
    let payload = Data(("[" + Array(repeating: item, count: count).joined(separator: ",") + "]").utf8)
    let started = ContinuousClock.now
    let memberships = try JSONDecoder().decode([SportsMembership].self, from: payload)
    let elapsed = started.duration(to: .now)
    print("Membership decode elapsed: \(elapsed)")
    #expect(memberships.count == count)
    #expect(memberships.first?.includes(Date(timeIntervalSince1970: 1_780_000_000)) == true)
    #expect(elapsed < .seconds(3))
  }
}
