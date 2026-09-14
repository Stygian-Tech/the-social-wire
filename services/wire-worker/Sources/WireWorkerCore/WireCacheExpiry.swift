import Foundation

enum WireCacheExpiry {
  /// Keep the full retention interval while coalescing refreshes into UTC hours.
  /// A deadline already on the boundary stays unchanged; extension is less than one hour.
  static func hourlyDeadline(asOf: Date, retention: TimeInterval) -> Date {
    let deadline = asOf.addingTimeInterval(retention).timeIntervalSince1970
    return Date(timeIntervalSince1970: ceil(deadline / 3_600) * 3_600)
  }
}
