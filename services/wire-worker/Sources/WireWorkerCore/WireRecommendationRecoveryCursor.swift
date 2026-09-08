import Foundation

actor WireRecommendationRecoveryCursor {
  struct Position: Sendable {
    let time: Date
    let environment: String
    let generation: String
    let sequence: Int64
  }

  private var positions: [String: Position] = [:]

  func position(for scope: String) -> Position? { positions[scope] }
  func advance(_ position: Position?, for scope: String) { positions[scope] = position }
}
