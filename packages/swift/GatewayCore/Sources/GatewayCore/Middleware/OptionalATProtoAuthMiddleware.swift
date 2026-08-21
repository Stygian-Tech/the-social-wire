import Hummingbird

/// Accepts anonymous requests only when no authentication material was supplied.
/// Any partial or invalid credential attempt is delegated to the strict middleware and fails 401.
public struct OptionalATProtoAuthMiddleware: RouterMiddleware {
  public typealias Context = GatewayRequestContext

  public enum Decision: Equatable, Sendable {
    case anonymous
    case verify
  }

  private let strict: ATProtoAuthMiddleware

  public init(strict: ATProtoAuthMiddleware) {
    self.strict = strict
  }

  public func handle(
    _ request: Request,
    context: GatewayRequestContext,
    next: (Request, GatewayRequestContext) async throws -> Response
  ) async throws -> Response {
    switch Self.decision(
      hasAuthorization: request.headers[.authorization] != nil,
      hasDPoP: ATProtoAuthMiddleware.extractOptionalDPoPHeader(from: request) != nil
    ) {
    case .anonymous:
      return try await next(request, context)
    case .verify:
      return try await strict.handle(request, context: context, next: next)
    }
  }

  public static func decision(hasAuthorization: Bool, hasDPoP: Bool) -> Decision {
    hasAuthorization || hasDPoP ? .verify : .anonymous
  }
}
