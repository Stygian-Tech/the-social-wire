enum WireWorkerConfigError: Error, Equatable, Sendable {
  case missingDatabaseURL
  case invalidMode(String)
  case invalidExternalSignalMode(String)
  case invalidRole(String)
  case invalidBoolean(String)
  case invalidPositiveInteger(String)
  case invalidInboxSourceGenerations
  case missingInboxEnvironment
  case invalidInboxEnvironment(String)
  case missingActorHMACSecret
  case invalidActorHMACSecret
  case invalidLabeler(String)
}
