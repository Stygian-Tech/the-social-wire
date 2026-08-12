public enum RedisConfigurationError: Error, Sendable, Equatable {
  case invalidURL
  case invalidDatabase
  case invalidPoolConfiguration
}
