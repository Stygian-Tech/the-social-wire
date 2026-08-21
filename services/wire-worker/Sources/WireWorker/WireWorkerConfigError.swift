enum WireWorkerConfigError: Error, Equatable, Sendable {
  case missingDatabaseURL
  case invalidMode(String)
  case invalidPositiveInteger(String)
  case missingActorHMACSecret
  case invalidActorHMACSecret
  case invalidLabeler(String)
}
