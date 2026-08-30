public enum CircleCursorError: Error, Equatable, Sendable {
  case invalidSecret
  case invalidSignature
  case malformed
  case unsupportedVersion
  case invalidPayload
  case viewerMismatch
  case expired
}
