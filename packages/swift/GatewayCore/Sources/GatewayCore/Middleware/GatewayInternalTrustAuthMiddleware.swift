import Foundation
import HTTPTypes
import Hummingbird
import Logging

/// Accepts HMAC-signed Gateway attestations on AppView routes during distributed deployment.
public struct GatewayInternalTrustAuthMiddleware: RouterMiddleware {
  public typealias Context = GatewayRequestContext

  private let sharedSecret: String?
  private let logger: Logger

  public init(sharedSecret: String?, logger: Logger) {
    self.sharedSecret = sharedSecret
    self.logger = logger
  }

  public func handle(
    _ request: Request,
    context: GatewayRequestContext,
    next: (Request, GatewayRequestContext) async throws -> Response
  ) async throws -> Response {
    guard context.authContext == nil else {
      return try await next(request, context)
    }

    guard let sharedSecret else {
      return try await next(request, context)
    }

    guard
      let didHeader = HTTPField.Name(GatewayInternalTrust.didHeaderName),
      let timestampHeader = HTTPField.Name(GatewayInternalTrust.timestampHeaderName),
      let signatureHeader = HTTPField.Name(GatewayInternalTrust.signatureHeaderName),
      let did = request.headers[didHeader]?
        .trimmingCharacters(in: .whitespacesAndNewlines),
      !did.isEmpty,
      let timestamp = request.headers[timestampHeader]?
        .trimmingCharacters(in: .whitespacesAndNewlines),
      !timestamp.isEmpty,
      let signature = request.headers[signatureHeader]?
        .trimmingCharacters(in: .whitespacesAndNewlines),
      !signature.isEmpty
    else {
      return try await next(request, context)
    }

    let signedPath = GatewayInternalTrust.canonicalSignedPath(request.uri.path)
    do {
      try GatewayInternalTrust.verify(
        secret: sharedSecret,
        did: did,
        method: request.method.rawValue,
        pathWithQuery: signedPath,
        timestamp: timestamp,
        signature: signature
      )
    } catch {
      logger.warning(
        "Gateway internal trust verification failed",
        metadata: [
          "error": .string("\(error)"),
          "signedPath": .string(signedPath),
        ]
      )
      throw HTTPError(.unauthorized, message: "Invalid gateway internal trust headers")
    }

    guard let authHeaderRaw = request.headers[.authorization]?
      .trimmingCharacters(in: .whitespacesAndNewlines),
      !authHeaderRaw.isEmpty
    else {
      throw HTTPError(.unauthorized, message: "Missing Authorization header for gateway-proxied request")
    }

    let dpopProof = ATProtoAuthMiddleware.extractOptionalDPoPHeader(from: request)

    var mutableContext = context
    mutableContext.authContext = AuthContext(
      did: did,
      authorizationForwardingValue: authHeaderRaw,
      dpopProof: dpopProof,
      upstreamDpopProof: ATProtoUpstreamDPoP.extract(from: request)
    )
    return try await next(request, mutableContext)
  }

}
