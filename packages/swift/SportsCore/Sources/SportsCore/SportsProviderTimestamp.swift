import Foundation

/// TheSportsDB's event timestamps use UTC when no explicit offset is supplied.
enum SportsProviderTimestamp {
  static func parse(_ value: String) -> Date? {
    let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
    let naive = text.range(of: "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]+)?$", options: .regularExpression) != nil
    let timestamp = naive ? text + "Z" : text
    let formatter = ISO8601DateFormatter()
    if let date = formatter.date(from: timestamp) { return date }
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: timestamp)
  }
}
