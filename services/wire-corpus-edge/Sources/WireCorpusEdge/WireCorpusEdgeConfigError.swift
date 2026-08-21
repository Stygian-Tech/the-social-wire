enum WireCorpusEdgeConfigError: Error, Equatable, Sendable {
  case productionOnly
  case missingDatabaseURL
  case missingSharedSecret
  case invalidSharedSecret
  case missingAllowedServiceID
  case invalidAllowedServiceID
}
