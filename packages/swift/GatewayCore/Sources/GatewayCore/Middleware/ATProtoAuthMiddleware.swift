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
  private let logger: Logger

  public init(
    httpClient: HTTPClient,
    plcURL: String,
    gatewayClientPolicy: OAuthGatewayClientPolicy,
    logger: Logger
  ) {
    self.httpClient = httpClient
    self.plcURL = plcURL
    self.gatewayClientPolicy = gatewayClientPolicy
    self.logger = logger
  }

  public func handle(
    _ request: Request,
    context: GatewayRequestContext,
    next: (Request, GatewayRequestContext) async throws -> Response
  ) async throws -> Response {
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

    let authOutcome: OAuthAccessTokenVerifier.VerifiedAccessToken
    do {
      authOutcome = try await OAuthAccessTokenVerifier.verify(
        accessTokenJWT: accessTokenJWT,
        httpClient: httpClient,
        plcURL: plcURL,
        logger: logger
      )
    } catch {
      logger.warning("Access token JWKS verification failed", metadata: ["error": "\(error)"])
      throw HTTPError(.unauthorized, message: "Invalid or stale ATProto OAuth access token")
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

    guard
      let dpopProofCandidate = Self.extractOptionalDPoPHeader(from: request)?
        .trimmingCharacters(in: .whitespacesAndNewlines),
      !dpopProofCandidate.isEmpty
    else {
      throw HTTPError(.unauthorized, message: "Missing RFC 9449 DPoP proof header")
    }

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

    let did = authOutcome.did
    let dpopProofStored = dpopProofCandidate

    let forwardingAuthorization = authHeaderRaw.trimmingCharacters(in: .whitespacesAndNewlines)

    var mutableContext = context
    mutableContext.authContext = AuthContext(
      did: did,
      authorizationForwardingValue: forwardingAuthorization,
      dpopProof: dpopProofStored
    )

    return try await next(request, mutableContext)
  }

  /// Best-effort header lookup across common casings (**RFC 9449** mandates `DPoP` but intermediaries normalize differently).
  private static func extractOptionalDPoPHeader(from request: Request) -> String? {
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
