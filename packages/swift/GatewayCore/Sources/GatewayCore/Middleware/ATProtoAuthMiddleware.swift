import AsyncHTTPClient
import Foundation
import HTTPTypes
import Hummingbird
import Logging

/// Context injected once ATProto OAuth access tokens pass cryptographic verification.
public struct AuthContext: Sendable {
  public let did: String
  public let authorizationForwardingValue: String
  public let dpopProof: String?

  public init(did: String, authorizationForwardingValue: String, dpopProof: String?) {
    self.did = did
    self.authorizationForwardingValue = authorizationForwardingValue
    self.dpopProof = dpopProof
  }
}

public enum OAuthAccessTokenJWT {
  /// Returns the bearer segment after `DPoP ` / `Bearer ` prefixes.
  static func extract(accessAuthorizationValue raw: String) -> Substring? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.lowercased().hasPrefix("dpop ") {
      let rest = trimmed.dropFirst(5)
      return rest.trimmingCharacters(in: .whitespacesAndNewlines)[...]
    }
    if trimmed.lowercased().hasPrefix("bearer ") {
      let rest = trimmed.dropFirst(7)
      return rest.trimmingCharacters(in: .whitespacesAndNewlines)[...]
    }
    return nil
  }
}

/// Verifies ATProto OAuth access JWTs remotely via **`issuer`** metadata + JWKS.
public struct ATProtoAuthMiddleware: RouterMiddleware {
  public typealias Context = GatewayRequestContext

  private let httpClient: HTTPClient
  private let plcURL: String
  private let gatewayClientPolicy: OAuthGatewayClientPolicy
  private let supplementalJwksJSON: String?
  private let allowDpopBoundStructuralFallback: Bool
  private let logger: Logger

  public init(
    httpClient: HTTPClient,
    plcURL: String,
    gatewayClientPolicy: OAuthGatewayClientPolicy,
    supplementalJwksJSON: String? = nil,
    allowDpopBoundStructuralFallback: Bool = false,
    logger: Logger
  ) {
    self.httpClient = httpClient
    self.plcURL = plcURL
    self.gatewayClientPolicy = gatewayClientPolicy
    self.supplementalJwksJSON = supplementalJwksJSON
    self.allowDpopBoundStructuralFallback = allowDpopBoundStructuralFallback
    self.logger = logger
  }

  public func handle(
    _ request: Request,
    context: GatewayRequestContext,
    next: (Request, GatewayRequestContext) async throws -> Response
  ) async throws -> Response {
    if context.authContext != nil {
      return try await next(request, context)
    }

    guard let authHeaderRaw = request.headers[.authorization] else {
      throw HTTPError(.unauthorized, message: "Missing Authorization header")
    }

    guard let tokenSlice = OAuthAccessTokenJWT.extract(accessAuthorizationValue: authHeaderRaw) else {
      throw HTTPError(.unauthorized, message: "Authorization header must prefix DPoP or Bearer")
    }

    let accessTokenJWT = String(tokenSlice)
    guard !accessTokenJWT.isEmpty else {
      throw HTTPError(.unauthorized, message: "Empty access token payload")
    }

    guard
      let dpopProofCandidate = Self.extractOptionalDPoPHeader(from: request)?
        .trimmingCharacters(in: .whitespacesAndNewlines),
      !dpopProofCandidate.isEmpty
    else {
      throw HTTPError(.unauthorized, message: "Missing RFC 9449 DPoP proof header")
    }

    let authOutcome: OAuthAccessTokenVerifier.VerifiedAccessToken
    do {
      authOutcome = try await OAuthAccessTokenVerifier.verify(
        accessTokenJWT: accessTokenJWT,
        httpClient: httpClient,
        plcURL: plcURL,
        logger: logger,
        supplementalJwksJSON: supplementalJwksJSON
      )
    } catch {
      if allowDpopBoundStructuralFallback {
        logger.info(
          "JWKS verification failed; attempting DPoP-bound structural fallback",
          metadata: ["error": .string("\(error)")]
        )
        do {
          authOutcome = try await OAuthAccessTokenVerifier.verifyDpopBoundStructural(
            accessTokenJWT: accessTokenJWT,
            request: request,
            dpopProof: dpopProofCandidate,
            logger: logger
          )
        } catch {
          logger.warning(
            "DPoP-bound structural access token fallback failed",
            metadata: ["error": .string("\(error)")]
          )
          throw HTTPError(.unauthorized, message: "Invalid or stale ATProto OAuth access token")
        }
      } else {
        logger.warning(
          "Access token JWKS verification failed",
          metadata: [
            "error": .string("\(error)"),
            "hint": .string(
              "Issuer oauth/jwks often omits access-token signing keys (e.g. bsky.social returns {\"keys\":[]}). "
                + "Configure GATEWAY_APPVIEW_INTERNAL_SECRET for distributed fallback or "
                + "OAUTH_ACCESS_TOKEN_SUPPLEMENTAL_JWKS_JSON when operator keys are available."
            ),
          ]
        )
        throw HTTPError(.unauthorized, message: "Invalid or stale ATProto OAuth access token")
      }
    }

    do {
      try gatewayClientPolicy.assertAllowedJWTClient(
        clientIdClaim: authOutcome.clientIdClaim,
        azpClaim: authOutcome.azpClaim,
        audiences: authOutcome.audiences
      )
    } catch let policyError as HTTPError {
      throw policyError
    } catch {
      throw HTTPError(.forbidden)
    }

    if !allowDpopBoundStructuralFallback {
      do {
        try DPoPProofVerifier.verify(
          proofJWT: dpopProofCandidate,
          request: request,
          accessTokenJWT: accessTokenJWT,
          accessTokenCnFJkt: authOutcome.cnfJkt
        )
      } catch {
        logger.warning("DPoP verification failed", metadata: ["error": "\(error)"])
        throw HTTPError(.unauthorized, message: "Invalid DPoP proof for this request")
      }
    }

    let forwardingAuthorization = authHeaderRaw.trimmingCharacters(in: .whitespacesAndNewlines)

    var mutableContext = context
    mutableContext.authContext = AuthContext(
      did: authOutcome.did,
      authorizationForwardingValue: forwardingAuthorization,
      dpopProof: dpopProofCandidate
    )

    return try await next(request, mutableContext)
  }

  /// Best-effort header lookup across common casings (**RFC 9449** mandates `DPoP` but intermediaries normalize differently).
  public static func extractOptionalDPoPHeader(from request: Request) -> String? {
    for label in ["DPoP", "Dpop", "dpop"] {
      guard let name = HTTPField.Name(label) else { continue }
      let proofCandidate = request.headers[name]
      if let proof = proofCandidate?.trimmingCharacters(in: .whitespacesAndNewlines), !proof.isEmpty {
        return proof
      }
    }
    return nil
  }
}
