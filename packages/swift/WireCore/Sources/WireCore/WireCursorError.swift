public enum WireCursorError: Error, Equatable, Sendable {
  case invalidSecret
  case invalidSignature
  case malformed
  case unsupportedVersion
  case invalidPayload
}
