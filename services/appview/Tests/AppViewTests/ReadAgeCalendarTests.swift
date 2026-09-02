import Foundation
import Hummingbird
import Testing

@testable import AppView

@Suite("Read age calendar cutoffs")
struct ReadAgeCalendarTests {
  @Test("only represented unread calendar-day buckets appear, with cumulative counts")
  func representedBuckets() throws {
    let result = try ReadAgeCalendar.options(
      publishedDates: [
        date("2026-09-02T05:00:00Z"), // Today, exactly midnight.
        date("2026-09-03T05:00:00Z"), // Future.
        date("2026-09-01T12:00:00Z"),
        date("2026-08-30T06:00:00Z"),
        date("2026-08-30T12:00:00Z"),
      ],
      timeZone: "America/Chicago", now: date("2026-09-02T17:00:00Z")
    )
    #expect(result.options.map(\.days) == [1, 3])
    #expect(result.options.map(\.count) == [3, 2])
    #expect(result.options.map(\.before) == ["2026-09-02T05:00:00.000Z", "2026-08-31T05:00:00.000Z"])
    #expect(result.referenceDay == "2026-09-02T05:00:00.000Z")
  }

  @Test("calendar subtraction handles spring and fall daylight-saving changes")
  func daylightSaving() throws {
    let spring = try ReadAgeCalendar.options(
      publishedDates: [date("2026-03-08T12:00:00Z"), date("2026-03-07T12:00:00Z")],
      timeZone: "America/Chicago", now: date("2026-03-09T17:00:00Z")
    )
    #expect(spring.options.map(\.before) == ["2026-03-09T05:00:00.000Z", "2026-03-08T06:00:00.000Z"])
    let fall = try ReadAgeCalendar.options(
      publishedDates: [date("2026-11-01T12:00:00Z"), date("2026-10-31T12:00:00Z")],
      timeZone: "America/Chicago", now: date("2026-11-02T17:00:00Z")
    )
    #expect(fall.options.map(\.before) == ["2026-11-02T06:00:00.000Z", "2026-11-01T05:00:00.000Z"])
  }

  @Test("the viewer time zone controls which stories are from yesterday")
  func viewerTimeZone() throws {
    let now = date("2026-09-02T01:00:00Z")
    let published = [date("2026-09-01T12:00:00Z")]
    #expect(try ReadAgeCalendar.options(publishedDates: published, timeZone: "Asia/Tokyo", now: now).options.map(\.days) == [1])
    #expect(try ReadAgeCalendar.options(publishedDates: published, timeZone: "America/Chicago", now: now).options.isEmpty)
  }

  @Test("rejects invalid zones, malformed cutoffs and future cutoffs")
  func invalidRequests() throws {
    let now = date("2026-09-02T17:00:00Z")
    #expect(throws: HTTPError.self) { try ReadAgeCalendar.calendar(timeZone: "Not/AZone") }
    #expect(throws: HTTPError.self) { try ReadAgeCalendar.cutoff("yesterday", now: now) }
    #expect(throws: HTTPError.self) { try ReadAgeCalendar.cutoff("2026-09-03T00:00:00Z", now: now) }
    #expect(try ReadAgeCalendar.cutoff("2026-09-02T17:00:00.000Z", now: now) == now)
    #expect(try ReadAgeCalendar.cutoff("2026-09-02T17:00:00Z", now: now) == now)
    for scope in [
      ScopedMarkAllReadScope(kind: "wire", publicationId: nil, folderRkey: nil),
      ScopedMarkAllReadScope(kind: "publication", publicationId: nil, folderRkey: nil),
      ScopedMarkAllReadScope(kind: "folder", publicationId: nil, folderRkey: " "),
    ] {
      #expect(throws: HTTPError.self) { try AppViewReadAgeRoutes.validate(scope: scope) }
    }
  }

  private func date(_ raw: String) -> Date {
    ISO8601DateFormatter().date(from: raw)!
  }
}
