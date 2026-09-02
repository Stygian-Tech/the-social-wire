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
    let calendar = try calendar(timeZone: timeZone)
    let today = calendar.startOfDay(for: now)
    var countsByDay: [Int: Int] = [:]
    for publishedAt in publishedDates where publishedAt < today {
      let publicationDay = calendar.startOfDay(for: publishedAt)
      guard let days = calendar.dateComponents([.day], from: publicationDay, to: today).day,
            days >= 1
      else { continue }
      countsByDay[days, default: 0] += 1
    }
    var cumulative = 0
    var options: [ReadAgeOption] = []
    for days in countsByDay.keys.sorted(by: >) {
      cumulative += countsByDay[days, default: 0]
      guard let before = calendar.date(byAdding: .day, value: -(days - 1), to: today) else {
        throw HTTPError(.badRequest, message: "Cannot calculate calendar-day cutoff")
      }
      options.append(ReadAgeOption(days: days, before: timestamp(before), count: cumulative))
    }
    return ReadAgeOptionsResponse(options: options.reversed(), referenceDay: timestamp(today))
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
