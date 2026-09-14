import Foundation

struct WireRecommendationHydrationJob: Sendable {
  let environment: String
  let sourceURI: String
  let generation: String
  let sequence: Int64
  let expectedCID: String?
  let subjectURI: String?
  let repoDID: String
  let originalRevision: String?
  let originalTime: Date
  let token: String
  let attempts: Int

  var retryDelay: TimeInterval {
    min(3_600, 30 * pow(2, Double(min(max(0, attempts - 1), 7))))
  }
}
