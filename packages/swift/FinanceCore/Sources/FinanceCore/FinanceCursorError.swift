public enum FinanceCursorError: Error, Equatable, Sendable {
  case invalidSecret, malformed, invalidSignature, invalidContext, expired
}
