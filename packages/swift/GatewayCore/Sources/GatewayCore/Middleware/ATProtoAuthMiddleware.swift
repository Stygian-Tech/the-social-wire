import AsyncHTTPClient
import Foundation
import HTTPTypes
import Hummingbird
import Logging
import NIOCore

/// Context injected once ATProto OAuth access tokens pass cryptographic verification.
public struct AuthContext: Sendable {
  public let did: String
  public let authorizationForwardingValue: String
  public let dpopProof: String?
  /// DPoP proof bound to the viewer PDS XRPC endpoint (not the gateway ingress URL).
  public let upstreamDpopProof: String?

  public init(
    did: String,
    authorizationForwardingValue: String,
    dpopProof: String?,
    upstreamDpopProof: String? = nil
  ) {
    self.did = did
    self.authorizationForwardingValue = authorizationForwardingValue
    self.dpopProof = dpopProof
    self.upstreamDpopProof = upstreamDpopProof
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
  typealias AccessTokenVerifier = @Sendable (String) async throws
    -> OAuthAccessTokenVerifier.VerifiedAccessToken

  private let httpClient: HTTPClient
  private let plcURL: String
  private let gatewayClientPolicy: OAuthGatewayClientPolicy
  private let supplementalJwksJSON: String?
  private let accessTokenVerifier: AccessTokenVerifier
  private let attestor: any PDSAccessTokenAttesting
  private let attestationReceipt: ATProtoSessionAttestationReceipt?
  private let replayGuard: DPoPReplayGuard
  private let logger: Logger

  public init(
    httpClient: HTTPClient,
    plcURL: String,
    gatewayClientPolicy: OAuthGatewayClientPolicy,
    attestationReceipt: ATProtoSessionAttestationReceipt? = nil,
    supplementalJwksJSON: String? = nil,
    // Retained for source compatibility; structural token fallback is intentionally disabled.
    allowDpopBoundStructuralFallback _: Bool = false,
    logger: Logger
  ) {
    self.httpClient = httpClient
    self.plcURL = plcURL
    self.gatewayClientPolicy = gatewayClientPolicy
    self.supplementalJwksJSON = supplementalJwksJSON
    self.accessTokenVerifier = { accessTokenJWT in
      try await OAuthAccessTokenVerifier.verify(
        accessTokenJWT: accessTokenJWT,
        httpClient: httpClient,
        plcURL: plcURL,
        logger: logger,
        supplementalJwksJSON: supplementalJwksJSON
      )
    }
    self.attestor = PDSAccessTokenAttestor(
      httpClient: httpClient,
      plcURL: plcURL,
      logger: logger
    )
    self.attestationReceipt = attestationReceipt
    self.replayGuard = DPoPReplayGuard()
    self.logger = logger
  }

  init(
    httpClient: HTTPClient,
    plcURL: String,
    gatewayClientPolicy: OAuthGatewayClientPolicy,
    supplementalJwksJSON: String? = nil,
    accessTokenVerifier: @escaping AccessTokenVerifier,
    attestor: any PDSAccessTokenAttesting,
    attestationReceipt: ATProtoSessionAttestationReceipt,
    replayGuard: DPoPReplayGuard = DPoPReplayGuard(),
    logger: Logger
  ) {
    self.httpClient = httpClient
    self.plcURL = plcURL
    self.gatewayClientPolicy = gatewayClientPolicy
    self.supplementalJwksJSON = supplementalJwksJSON
    self.accessTokenVerifier = accessTokenVerifier
    self.attestor = attestor
    self.attestationReceipt = attestationReceipt
    self.replayGuard = replayGuard
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

    let forwardingAuthorization = authHeaderRaw.trimmingCharacters(in: .whitespacesAndNewlines)
    let resolvedAuthentication: (
      token: OAuthAccessTokenVerifier.VerifiedAccessToken,
      proof: DPoPProofVerifier.VerifiedProof,
      responseNonce: String?,
      responseReceipt: String?
    )
    do {
      let token = try await accessTokenVerifier(accessTokenJWT)
      let proof = try DPoPProofVerifier.verify(
        proofJWT: dpopProofCandidate,
        request: request,
        accessTokenJWT: accessTokenJWT,
        accessTokenCnFJkt: token.cnfJkt
      )
      resolvedAuthentication = (token, proof, nil, nil)
    } catch {
      guard OAuthAccessTokenVerifier.permitsActivePDSFallback(
        error: error,
        supplementalJwksJSON: supplementalJwksJSON
      ) else {
        logger.warning("Access token cryptographic verification failed")
        throw HTTPError(.unauthorized, message: "Invalid or stale ATProto OAuth access token")
      }
      guard let attestationReceipt else {
        logger.warning("Active PDS token attestation is not configured")
        throw HTTPError(.unauthorized, message: "Invalid or stale ATProto OAuth access token")
      }

      let candidate: PDSAccessTokenAttestor.Candidate
      do {
        candidate = try PDSAccessTokenAttestor.decodeCandidate(accessTokenJWT)
        let proof = try DPoPProofVerifier.verify(
          proofJWT: dpopProofCandidate,
          request: request,
          accessTokenJWT: accessTokenJWT,
          accessTokenCnFJkt: candidate.cnfJkt
        )
        let requiresReceipt = ATProtoUpstreamDPoP.extract(from: request) != nil
          || Self.upstreamDPoPIsPrepared(request)
        if requiresReceipt {
          guard let rawReceipt = request.headers[
            HTTPField.Name(ATProtoSessionAttestationReceipt.receiptHeaderName)!
          ] else {
            return Self.attestationRequiredResponse()
          }
          guard let receipt = ATProtoSessionAttestationReceipt.validatedReceipt(rawReceipt) else {
            throw PDSAccessTokenAttestationError.invalid
          }
          let claims: ATProtoSessionAttestationReceipt.VerifiedClaims
          do {
            claims = try attestationReceipt.verify(
              receipt,
              accessTokenJWT: accessTokenJWT,
              expectedDID: candidate.did,
              expectedCnFJkt: candidate.cnfJkt,
              tokenExpiresAt: candidate.expiresAt
            )
          } catch ATProtoSessionAttestationReceipt.Error.expired {
            return Self.attestationRequiredResponse()
          } catch {
            throw PDSAccessTokenAttestationError.invalid
          }
          let responseReceipt = try attestationReceipt.issue(
            accessTokenJWT: accessTokenJWT,
            did: candidate.did,
            cnfJkt: candidate.cnfJkt,
            tokenExpiresAt: candidate.expiresAt,
            authoritativeValidUntil: claims.validUntil
          )
          resolvedAuthentication = (candidate.token, proof, nil, responseReceipt)
        } else {
          let attestation = try await attestor.attest(
            accessTokenJWT: accessTokenJWT,
            authorizationValue: forwardingAuthorization,
            gatewayProof: proof,
            sessionProof: ATProtoSessionDPoP.extract(from: request)
          )
          let responseReceipt = try attestationReceipt.issue(
            accessTokenJWT: accessTokenJWT,
            did: candidate.did,
            cnfJkt: candidate.cnfJkt,
            tokenExpiresAt: candidate.expiresAt,
            authoritativeValidUntil: attestation.attestationExpiresAt
          )
          resolvedAuthentication = (
            attestation.token,
            proof,
            attestation.responseNonce,
            responseReceipt
          )
        }
      } catch PDSAccessTokenAttestationError.nonceChallenge(let nonce) {
        var headers = HTTPFields()
        headers[HTTPField.Name(ATProtoSessionDPoP.nonceHeaderName)!] = nonce
        return Response(status: .unauthorized, headers: headers)
      } catch PDSAccessTokenAttestationError.unavailable {
        logger.error("Active PDS token attestation dependency unavailable")
        throw HTTPError(.serviceUnavailable, message: "ATProto authentication dependency unavailable")
      } catch PDSAccessTokenAttestationError.overloaded {
        logger.warning("Active PDS token attestation admission overloaded")
        throw HTTPError(.serviceUnavailable, message: "ATProto authentication dependency unavailable")
      } catch {
        logger.warning("Active PDS token attestation rejected")
        throw HTTPError(.unauthorized, message: "Invalid or stale ATProto OAuth access token")
      }
    }

    let authOutcome = resolvedAuthentication.token
    let verifiedGatewayProof = resolvedAuthentication.proof

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

    do {
      try await replayGuard.consume(
        thumbprint: verifiedGatewayProof.jwkThumbprint,
        jti: verifiedGatewayProof.jti,
        validUntil: verifiedGatewayProof.validUntil
      )
    } catch {
      logger.warning("DPoP replay rejected")
      throw HTTPError(.unauthorized, message: "Invalid DPoP proof for this request")
    }

    var mutableContext = context
    mutableContext.authContext = AuthContext(
      did: authOutcome.did,
      authorizationForwardingValue: forwardingAuthorization,
      dpopProof: dpopProofCandidate,
      upstreamDpopProof: ATProtoUpstreamDPoP.extract(from: request)
    )

    var response = try await next(request, mutableContext)
    if let attestationResponseNonce = resolvedAuthentication.responseNonce {
      response.headers[HTTPField.Name(ATProtoSessionDPoP.nonceHeaderName)!] = attestationResponseNonce
    }
    if let responseReceipt = resolvedAuthentication.responseReceipt {
      response.headers[
        HTTPField.Name(ATProtoSessionAttestationReceipt.receiptHeaderName)!
      ] = responseReceipt
    }
    return response
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

  private static func upstreamDPoPIsPrepared(_ request: Request) -> Bool {
    guard let name = HTTPField.Name(ATProtoSessionAttestationReceipt.upstreamPreparedHeaderName),
      let value = request.headers[name]
    else { return false }
    return value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "true"
  }

  private static func attestationRequiredResponse() -> Response {
    var headers = HTTPFields()
    headers[
      HTTPField.Name(ATProtoSessionAttestationReceipt.requiredHeaderName)!
    ] = "true"
    headers[.contentType] = "application/json"
    let body = #"{"error":"ATProtoSessionAttestationRequired"}"#
    return Response(
      status: .preconditionRequired,
      headers: headers,
      body: .init(byteBuffer: ByteBuffer(string: body))
    )
  }
}
