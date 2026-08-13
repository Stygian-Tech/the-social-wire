import Foundation

public enum RedisRankingWindow: String, Sendable, CaseIterable {
  case oneHour = "1h"
  case oneDay = "24h"
  case sevenDays = "7d"

  public var expiration: TimeInterval {
    switch self {
    case .oneHour: 60 * 60
    case .oneDay: 24 * 60 * 60
    case .sevenDays: 7 * 24 * 60 * 60
    }
  }
}
