import Foundation

struct FeedReadAgeOption: Codable, Equatable, Identifiable, Sendable {
    let days: Int
    let before: String
    let count: Int

    var id: Int { days }
    var title: String { days == 1 ? "1 Day" : "\(days) Days" }
    var cutoffDate: Date? { DateFormatters.date(from: before) }
}
