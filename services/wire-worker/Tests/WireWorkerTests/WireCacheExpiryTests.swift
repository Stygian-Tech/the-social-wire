import Foundation
import Testing

@testable import WireWorkerCore

@Suite("Wire cache expiry")
struct WireCacheExpiryTests {
  @Test("hourly deadlines preserve minimum retention without adding a full extra hour",
    arguments: [0.0, 0.001, 1.0, 1_800.0, 3_599.999, 3_600.0])
  func deadlineBoundaries(offset: TimeInterval) {
    let start = Date(timeIntervalSince1970: 1_800_000_000 + offset)
    for retention in [7.0 * 86_400, 30.0 * 86_400] {
      let minimum = start.addingTimeInterval(retention)
      let actual = WireCacheExpiry.hourlyDeadline(asOf: start, retention: retention)
      #expect(actual >= minimum)
      #expect(actual.timeIntervalSince(minimum) < 3_600)
      #expect(actual.timeIntervalSince1970.truncatingRemainder(dividingBy: 3_600) == 0)
      if offset == 0 || offset == 3_600 { #expect(actual == minimum) }
    }
  }

  @Test("observations within an hour share a deadline and the next hour advances it")
  func coalescedDeadline() {
    let start = Date(timeIntervalSince1970: 1_800_000_001)
    let first = WireCacheExpiry.hourlyDeadline(asOf: start, retention: 30 * 86_400)
    #expect(WireCacheExpiry.hourlyDeadline(
      asOf: start.addingTimeInterval(3_598), retention: 30 * 86_400) == first)
    #expect(WireCacheExpiry.hourlyDeadline(
      asOf: start.addingTimeInterval(3_600), retention: 30 * 86_400) == first.addingTimeInterval(3_600))
  }
}
