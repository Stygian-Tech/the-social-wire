enum WireCorpusEdgeConfigError: Error, Equatable, Sendable {
  case unsupportedEnvironment
  case missingDatabaseURL
  case missingSharedSecret
  case invalidSharedSecret
  case missingAllowedServiceID
  case invalidAllowedServiceID
}
