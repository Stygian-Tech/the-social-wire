struct ClientPerformanceRequest: Codable, Sendable {
  let event: ClientPerformanceEvent
  let durationMs: Double
  let feedType: String
  let cacheState: String
  let outcome: String
  let environment: String
}
