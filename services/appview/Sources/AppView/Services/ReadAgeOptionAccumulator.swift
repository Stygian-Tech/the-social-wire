import Foundation
import Hummingbird

/// Keeps one histogram for the whole scan without revisiting dates from earlier pages.
struct ReadAgeOptionAccumulator {
  private let calendar: Calendar
  private let today: Date
  private var countsByDay: [Int: Int] = [:]

  init(timeZone: String, now: Date) throws {
    calendar = try ReadAgeCalendar.calendar(timeZone: timeZone)
    today = calendar.startOfDay(for: now)
  }

  mutating func append(publishedDates: [Date]) {
    for publishedAt in publishedDates where publishedAt < today {
      let publicationDay = calendar.startOfDay(for: publishedAt)
      guard let days = calendar.dateComponents([.day], from: publicationDay, to: today).day,
            days >= 1
      else { continue }
      // Every older calendar age belongs to the final week option.
      countsByDay[min(days, 7), default: 0] += 1
    }
  }

  func response() throws -> ReadAgeOptionsResponse {
    var cumulative = 0
    var options: [ReadAgeOption] = []
    for days in countsByDay.keys.sorted(by: >) {
      cumulative += countsByDay[days, default: 0]
      guard let before = calendar.date(byAdding: .day, value: -(days - 1), to: today) else {
        throw HTTPError(.badRequest, message: "Cannot calculate calendar-day cutoff")
      }
      options.append(ReadAgeOption(days: days, before: ReadAgeCalendar.timestamp(before), count: cumulative))
    }
    return ReadAgeOptionsResponse(options: options.reversed(), referenceDay: ReadAgeCalendar.timestamp(today))
  }
}
