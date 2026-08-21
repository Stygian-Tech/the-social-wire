public enum WireCorpusServiceTrustError: Error, Equatable, Sendable {
  case invalidSecret
  case invalidServiceID
  case invalidTarget
  case invalidTimestamp
  case expiredTimestamp
  case invalidNonce
  case invalidSignature
}
