import Foundation
import WireCore

struct WireGenerationCommit: Sendable {
  var generationID: UUID
  var feedKey: String
  var languageBucket: String
  var configVersion: String
  var generatedAt: Date
  var expiresAt: Date
  var activate: Bool
  var result: WireRankingResult
}
