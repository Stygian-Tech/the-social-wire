import Foundation

/// Separate schedules keep expensive observations out of the minute counter sample.
public enum DatabaseCostTelemetryGroup: CaseIterable, Sendable {
  case counters
  case statements
  case tables
  case expiry

  public var intervalSeconds: TimeInterval {
    switch self {
    case .counters: 60
    case .statements: 300
    case .tables: 900
    case .expiry: 30
    }
  }
}
