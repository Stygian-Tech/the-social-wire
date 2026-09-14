import Foundation
import Hummingbird
import OperationsCore

/// Pool readiness is an ingestion-health signal, not proof that every repository is complete.
struct GatewayIngestionHealthSnapshot: Encodable, Sendable, ResponseEncodable {
  let service: String = "gateway"
  let poolReadiness: String
  let freshness: OperationsHealthState = .unknown
  let completeness: OperationsHealthState
  let checkedAt: Date?
  let validUntil: Date?

  static let unknown = Self(poolReadiness: "unobserved", completeness: .unknown,
                            checkedAt: nil, validUntil: nil)

  func evaluated(at now: Date) -> Self {
    guard let checkedAt, let validUntil else { return self }
    guard checkedAt <= now, now < validUntil else {
      return Self(poolReadiness: "stale", completeness: .unknown,
                  checkedAt: checkedAt, validUntil: validUntil)
    }
    return self
  }

  var dependencyState: [String: String] {
    var state = ["projection_pool": poolReadiness,
                 "ingestion_completeness": completeness.rawValue]
    if let checkedAt { state["ingestion_observed_at"] = checkedAt.ISO8601Format() }
    if let validUntil { state["ingestion_valid_until"] = validUntil.ISO8601Format() }
    return state
  }
}
