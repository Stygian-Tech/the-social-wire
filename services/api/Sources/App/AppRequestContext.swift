import Hummingbird

/// Custom request context that carries per-request auth state through the middleware chain.
///
/// Hummingbird 2 uses a typed context instead of a stringly-keyed storage bag.
/// `ATProtoAuthMiddleware` sets `authContext` after verifying the DPoP token;
/// route handlers read it to obtain the caller's DID.
struct AppRequestContext: RequestContext {
  var coreContext: CoreRequestContextStorage

  /// Injected by `ATProtoAuthMiddleware` after successful token verification.
  /// `nil` on unauthenticated routes (e.g. `/health`).
  var authContext: AuthContext?

  init(source: Source) {
    self.coreContext = .init(source: source)
    self.authContext = nil
  }
}
