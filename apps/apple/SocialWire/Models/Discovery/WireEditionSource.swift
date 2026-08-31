enum WireEditionSource: String, Codable, Equatable, Sendable {
    case ranked
    case staleGeneration = "stale_generation"
    case simplifiedFallback = "simplified_fallback"
}
