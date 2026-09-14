/// Discovery capacity and deadlines are availability failures, never evidence
/// that a viewer's token is invalid or permission to skip authentication.
enum JWKSVerificationCacheFailure: Error, Sendable, Equatable {
  case overloaded
  case timedOut
}
