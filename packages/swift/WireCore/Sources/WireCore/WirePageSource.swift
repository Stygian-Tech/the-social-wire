public enum WirePageSource: String, Codable, CaseIterable, Sendable {
  case ranked
  case staleGeneration = "stale_generation"
  case simplifiedFallback = "simplified_fallback"
}
