import Foundation

struct SportsBracketSource: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let competitionID: String
    let season: String
    let title: String
    let url: String
    let reviewedAt: String
    let mode: String

    var reviewedDate: Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: reviewedAt) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: reviewedAt)
    }

    func reviewedDateLabel(locale: Locale = .current) -> String? {
        guard let reviewedDate else { return nil }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateStyle = .medium
        return formatter.string(from: reviewedDate)
    }

    var externalURL: URL? {
        guard mode == "external", let value = URL(string: url), value.scheme == "https", value.host != nil else { return nil }
        return value
    }
}
