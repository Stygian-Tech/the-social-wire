import Foundation
import Logging
import PostgresNIO
import SportsCore

enum SportsProviderRefreshPolicy {
  /// Payload changes receive one bounded refresh without clearing last-successful data or claim history.
  static func key(_ resource: String, competitionID: String, season: String? = nil) -> String {
    let base = resource + ":" + competitionID + (season.map { ":" + $0 } ?? "")
    // Retry-policy cutover gives prior failed daily claims one normal bounded attempt.
    if resource == "reference" { return base + ":v3" }
    return ["events", "standings"].contains(resource) ? base + ":v2" : base
  }
  static func failedClaim(asOf: Date, interval: TimeInterval) -> Date {
    asOf.addingTimeInterval(-interval + 300)
  }
  static func failureMetadata(_ error: any Error) -> Logger.Metadata {
    if error is SportsProviderError { return ["category": "provider-response"] }
    if error is URLError { return ["category": "provider-transport"] }
    if error is DecodingError { return ["category": "decode"] }
    if error is EncodingError { return ["category": "encode"] }
    if let postgres = error as? PSQLError {
      var metadata: Logger.Metadata = ["category": "postgres"]
      if let code = postgres.serverInfo?[.sqlState], code.utf8.count == 5,
        code.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) }) {
        metadata["sqlState"] = .string(code)
      }
      return metadata
    }
    return ["category": "other"]
  }
  static func isDue(key: String, interval: TimeInterval, requested: [String: Date], asOf: Date) -> Bool {
    requested[key].map { asOf.timeIntervalSince($0) >= interval } ?? true
  }
}
