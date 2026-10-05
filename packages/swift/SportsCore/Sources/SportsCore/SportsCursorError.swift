public enum SportsCursorError: Error, Equatable, Sendable {
  case invalidSecret, malformed, invalidSignature, invalidContext, expired
}
