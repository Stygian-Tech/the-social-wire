import Foundation
import Hummingbird

enum ReadAgeCalendar {
  static func calendar(timeZone identifier: String) throws -> Calendar {
    guard identifier == "UTC" || TimeZone.knownTimeZoneIdentifiers.contains(identifier),
          let timeZone = TimeZone(identifier: identifier)
    else { throw HTTPError(.badRequest, message: "timeZone must be an IANA time zone identifier") }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    return calendar
  }

  static func options(
    publishedDates: [Date], timeZone: String, now: Date
  ) throws -> ReadAgeOptionsResponse {
    var accumulator = try ReadAgeOptionAccumulator(timeZone: timeZone, now: now)
    accumulator.append(publishedDates: publishedDates)
    return try accumulator.response()
  }

  static func cutoff(_ raw: String, now: Date) throws -> Date {
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    guard let date = fractional.date(from: raw) ?? ISO8601DateFormatter().date(from: raw),
          date <= now
    else { throw HTTPError(.badRequest, message: "before must be an ISO 8601 timestamp at or before now") }
    return date
  }

  static func timestamp(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
  }
}
