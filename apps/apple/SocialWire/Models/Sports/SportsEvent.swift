import Foundation

struct SportsEvent: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let competitionID: String
    let entityIDs: [String]
    let title: String
    let startsAt: String
    var startTimeKnown: Bool? = nil
    let status: String
    let homeName: String?
    let awayName: String?
    let homeScore: String?
    let awayScore: String?
    let updatedAt: String

    var scheduleDateLabel: String {
        guard let date = ISO8601DateFormatter().date(from: startsAt) else { return "TBD" }
        if startTimeKnown == false {
            // The provider date-only placeholder must not shift to the prior local day.
            var format = Date.FormatStyle.dateTime.month().day()
            format.timeZone = .gmt
            return "\(date.formatted(format)) · TBD"
        }
        return date.formatted(.dateTime.month().day().hour().minute())
    }

    var scheduleStatusLabel: String? {
        let value = status.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.lowercased() != "scheduled" else { return nil }
        return value.lowercased() == "tbd" ? "TBD" : value.capitalized
    }

    func activityLabel(now: Date, hideScores: Bool, timeZone: TimeZone = .current) -> String? {
        guard !hideScores else { return nil }
        if status == "in-progress" { return "In Progress" }
        guard status == "finished", let start = ISO8601DateFormatter().date(from: startsAt) else { return nil }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
        return start <= now && calendar.isDate(start, inSameDayAs: now) ? "Final Today" : nil
    }
}
