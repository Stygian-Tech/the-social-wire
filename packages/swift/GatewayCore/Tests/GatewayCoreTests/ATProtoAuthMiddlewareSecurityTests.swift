import AsyncHTTPClient
import Crypto
import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import Logging
import Testing

@testable import GatewayCore

@Suite("ATProtoAuthMiddleware security")
struct ATProtoAuthMiddlewareSecurityTests {
  private actor CallCounter {
    private(set) var count = 0
    func increment() { count += 1 }
  }

  private struct StubAttestor: PDSAccessTokenAttesting {
    enum Behavior: Sendable {
      case success(OAuthAccessTokenVerifier.VerifiedAccessToken, String?)
      case nonce(String)
      case overloaded
    }

    let calls: CallCounter
    let behavior: Behavior

    func attest(
      accessTokenJWT _: String,
      authorizationValue _: String,
      gatewayProof _: DPoPProofVerifier.VerifiedProof,
      sessionProof _: String?
    ) async throws -> PDSAccessTokenAttestationOutcome {
      await calls.increment()
      switch behavior {
      case .success(let token, let nonce):
        return .init(
          token: token,
          responseNonce: nonce,
          attestationExpiresAt: Date().addingTimeInterval(60)
        )
      case .nonce(let nonce):
        throw PDSAccessTokenAttestationError.nonceChallenge(nonce)
      case .overloaded:
        throw PDSAccessTokenAttestationError.overloaded
      }
    }
  }
  private struct JWK: Encodable {
    let alg = "ES256"
    let crv = "P-256"
    let kid: String
    let kty = "EC"
    let use = "sig"
    let x: String
    let y: String
  }

  private struct AccessTokenHeader: Encodable {
    let alg = "ES256"
    let kid: String
    let typ = "JWT"
  }

  private struct AccessTokenClaims: Encodable {
    struct Confirmation: Encodable { let jkt: String }

    let iss: String
    let sub: String
    let exp: Int
    let cnf: Confirmation
  }

  private struct DPoPHeader: Encodable {
    let alg = "ES256"
    let typ = "dpop+jwt"
    let jwk: JWK
  }

  private struct DPoPClaims: Encodable {
    let jti: String
    let iat: Int
    let htm: String
    let htu: String
    let ath: String
  }

  private struct JWKS: Encodable {
    let keys: [JWK]
  }

  private let encoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return encoder
  }()

  @Test("rejects an unverified structural access token when legacy fallback is configured")
  func rejectsUnverifiedStructuralFallback() async throws {
    let proofKey = P256.Signing.PrivateKey()
    let proofJWK = jwk(for: proofKey, kid: "attacker-proof")
    let accessToken = try signedAccessToken(
      issuer: "not-a-did-or-url",
      subject: "did:plc:forged-operator",
      confirmationThumbprint: try thumbprint(of: proofJWK),
      signingKey: P256.Signing.PrivateKey(),
      kid: "attacker-token"
    )
    let proof = try dpopProof(
      accessToken: accessToken,
      key: proofKey,
      jwk: proofJWK,
      htu: "http://localhost/protected"
    )

    let response = try await protectedResponse(
      accessToken: accessToken,
      dpopProof: proof,
      supplementalJWKS: nil,
      legacyFallbackConfigured: true
    )

    #expect(response.status == .unauthorized)
  }

  @Test("accepts an issuer-verified access token with valid DPoP when legacy fallback is configured")
  func acceptsIssuerVerifiedTokenWithValidDPoP() async throws {
    let issuerKey = P256.Signing.PrivateKey()
    let issuerJWK = jwk(for: issuerKey, kid: "trusted-issuer")
    let proofKey = P256.Signing.PrivateKey()
    let proofJWK = jwk(for: proofKey, kid: "legitimate-proof")
    let accessToken = try signedAccessToken(
      issuer: "https://issuer.example",
      subject: "did:plc:legitimate-viewer",
      confirmationThumbprint: try thumbprint(of: proofJWK),
      signingKey: issuerKey,
      kid: issuerJWK.kid
    )
    let proof = try dpopProof(
      accessToken: accessToken,
      key: proofKey,
      jwk: proofJWK,
      htu: "http://localhost/protected"
    )

    let response = try await protectedResponse(
      accessToken: accessToken,
      dpopProof: proof,
      supplementalJWKS: try jwksJSON(containing: issuerJWK),
      legacyFallbackConfigured: true
    )

    #expect(response.status == .ok)
  }

  @Test("rejects invalid DPoP for an issuer-verified token when legacy fallback is configured")
  func rejectsInvalidDPoPForIssuerVerifiedToken() async throws {
    let issuerKey = P256.Signing.PrivateKey()
    let issuerJWK = jwk(for: issuerKey, kid: "trusted-issuer")
    let proofKey = P256.Signing.PrivateKey()
    let proofJWK = jwk(for: proofKey, kid: "wrong-target-proof")
    let accessToken = try signedAccessToken(
      issuer: "https://issuer.example",
      subject: "did:plc:legitimate-viewer",
      confirmationThumbprint: try thumbprint(of: proofJWK),
      signingKey: issuerKey,
      kid: issuerJWK.kid
    )
    let proof = try dpopProof(
      accessToken: accessToken,
      key: proofKey,
      jwk: proofJWK,
      htu: "http://localhost/a-different-route"
    )

    let response = try await protectedResponse(
      accessToken: accessToken,
      dpopProof: proof,
      supplementalJWKS: try jwksJSON(containing: issuerJWK),
      legacyFallbackConfigured: true
    )

    #expect(response.status == .unauthorized)
  }

  @Test("nonempty JWKS signature failure never invokes active PDS fallback")
  func nonemptyJWKSSignatureFailureDoesNotFallback() async throws {
    let fixture = try fallbackFixture()
    let calls = CallCounter()
    let attestor = StubAttestor(
      calls: calls,
      behavior: .success(fixture.verifiedToken, nil)
    )
    let unrelatedIssuerKey = P256.Signing.PrivateKey()
    let response = try await protectedResponse(
      accessToken: fixture.accessToken,
      dpopProof: fixture.gatewayProof,
      supplementalJWKS: try jwksJSON(
        containing: jwk(for: unrelatedIssuerKey, kid: "nonempty-issuer")),
      accessTokenVerifier: { _ in throw OAuthAccessTokenVerifier.VerifyError.signatureRejected },
      attestor: attestor,
      sessionProof: "unused"
    )

    #expect(response.status == .unauthorized)
    #expect(await calls.count == 0)
  }

  @Test("empty JWKS downgrades to attestation and propagates the PDS nonce")
  func emptyJWKSFallbackPropagatesNonce() async throws {
    let fixture = try fallbackFixture()
    let calls = CallCounter()
    let attestor = StubAttestor(
      calls: calls,
      behavior: .success(fixture.verifiedToken, "next-session-nonce")
    )
    let response = try await protectedResponse(
      accessToken: fixture.accessToken,
      dpopProof: fixture.gatewayProof,
      supplementalJWKS: #"{"keys":[]}"#,
      accessTokenVerifier: { _ in throw OAuthAccessTokenVerifier.VerifyError.jwksEmpty("issuer") },
      attestor: attestor,
      sessionProof: "session-proof"
    )

    #expect(response.status == .ok)
    #expect(await calls.count == 1)
    #expect(
      response.headers[HTTPField.Name(ATProtoSessionDPoP.nonceHeaderName)!]
        == "next-session-nonce"
    )
    #expect(
      response.headers[
        HTTPField.Name(ATProtoSessionAttestationReceipt.receiptHeaderName)!
      ] != nil
    )
  }

  @Test("receipt is portable across instances and preserves prepared upstream proof bytes")
  func receiptSkipsSecondProbeAcrossInstances() async throws {
    let fixture = try fallbackFixture()
    let firstCalls = CallCounter()
    let verifier: ATProtoAuthMiddleware.AccessTokenVerifier = { _ in
      throw OAuthAccessTokenVerifier.VerifyError.jwksEmpty("issuer")
    }
    let first = try await protectedResponse(
      accessToken: fixture.accessToken,
      dpopProof: fixture.gatewayProof,
      supplementalJWKS: #"{"keys":[]}"#,
      accessTokenVerifier: verifier,
      attestor: StubAttestor(calls: firstCalls, behavior: .success(fixture.verifiedToken, nil)),
      sessionProof: "session-proof"
    )
    let receipt = try #require(
      first.headers[HTTPField.Name(ATProtoSessionAttestationReceipt.receiptHeaderName)!]
    )
    let secondCalls = CallCounter()
    let handlerCalls = CallCounter()
    let upstreamProof = "route-proof-one,route-proof-two"
    let second = try await protectedResponse(
      accessToken: fixture.accessToken,
      dpopProof: fixture.gatewayProof,
      supplementalJWKS: #"{"keys":[]}"#,
      accessTokenVerifier: verifier,
      attestor: StubAttestor(calls: secondCalls, behavior: .success(fixture.verifiedToken, nil)),
      upstreamProof: upstreamProof,
      attestationReceipt: receipt,
      handlerCalls: handlerCalls
    )

    #expect(first.status == .ok)
    #expect(second.status == .ok)
    #expect(await firstCalls.count == 1)
    #expect(await secondCalls.count == 0)
    #expect(await handlerCalls.count == 1)
    #expect(responseHeader(second, "X-Test-Upstream-DPoP") == upstreamProof)
    #expect(responseHeader(second, ATProtoSessionAttestationReceipt.receiptHeaderName) != nil)
  }

  @Test("missing or expired receipt returns a preflight marker without probing or handling")
  func receiptPreconditionRequired() async throws {
    let fixture = try fallbackFixture()
    let verifier: ATProtoAuthMiddleware.AccessTokenVerifier = { _ in
      throw OAuthAccessTokenVerifier.VerifyError.noJwksCandidates
    }
    let authority = try ATProtoSessionAttestationReceipt(
      secret: "gateway-core-test-attestation-receipt-secret"
    )
    let expired = try authority.issue(
      accessTokenJWT: fixture.accessToken,
      did: fixture.verifiedToken.did,
      cnfJkt: try #require(fixture.verifiedToken.cnfJkt),
      tokenExpiresAt: Date().addingTimeInterval(3_600),
      authoritativeValidUntil: Date().addingTimeInterval(-1),
      now: Date().addingTimeInterval(-61)
    )

    for receipt in [String?.none, expired] {
      let probes = CallCounter()
      let handlers = CallCounter()
      let response = try await protectedResponse(
        accessToken: fixture.accessToken,
        dpopProof: fixture.gatewayProof,
        supplementalJWKS: #"{"keys":[]}"#,
        accessTokenVerifier: verifier,
        attestor: StubAttestor(calls: probes, behavior: .success(fixture.verifiedToken, nil)),
        upstreamProof: "prepared-route-proof",
        attestationReceipt: receipt,
        handlerCalls: handlers
      )
      #expect(response.status == .preconditionRequired)
      #expect(
        responseHeader(response, ATProtoSessionAttestationReceipt.requiredHeaderName) == "true"
      )
      #expect(response.body.getString(at: 0, length: response.body.readableBytes)?.contains(
        "ATProtoSessionAttestationRequired") == true)
      #expect(await probes.count == 0)
      #expect(await handlers.count == 0)
    }
  }

  @Test("prepared marker requires a receipt before a route proof exists")
  func preparedMarkerRequiresReceipt() async throws {
    let fixture = try fallbackFixture()
    let probes = CallCounter()
    let handlers = CallCounter()
    let response = try await protectedResponse(
      accessToken: fixture.accessToken,
      dpopProof: fixture.gatewayProof,
      supplementalJWKS: #"{"keys":[]}"#,
      accessTokenVerifier: { _ in throw OAuthAccessTokenVerifier.VerifyError.noJwksCandidates },
      attestor: StubAttestor(calls: probes, behavior: .success(fixture.verifiedToken, nil)),
      upstreamPrepared: true,
      handlerCalls: handlers
    )

    #expect(response.status == .preconditionRequired)
    #expect(await probes.count == 0)
    #expect(await handlers.count == 0)
  }

  @Test("forged receipt is a generic unauthorized response")
  func forgedReceiptIsUnauthorized() async throws {
    let fixture = try fallbackFixture()
    let probes = CallCounter()
    let handlers = CallCounter()
    let response = try await protectedResponse(
      accessToken: fixture.accessToken,
      dpopProof: fixture.gatewayProof,
      supplementalJWKS: #"{"keys":[]}"#,
      accessTokenVerifier: { _ in throw OAuthAccessTokenVerifier.VerifyError.noJwksCandidates },
      attestor: StubAttestor(calls: probes, behavior: .success(fixture.verifiedToken, nil)),
      upstreamProof: "prepared-route-proof",
      attestationReceipt: "forged.receipt",
      handlerCalls: handlers
    )

    #expect(response.status == .unauthorized)
    #expect(responseHeader(response, ATProtoSessionAttestationReceipt.requiredHeaderName) == nil)
    #expect(await probes.count == 0)
    #expect(await handlers.count == 0)
  }

  @Test("direct JWKS authentication never requires an attestation receipt")
  func directJWKSPathDoesNotRequireReceipt() async throws {
    let fixture = try fallbackFixture()
    let probes = CallCounter()
    let handlers = CallCounter()
    let response = try await protectedResponse(
      accessToken: fixture.accessToken,
      dpopProof: fixture.gatewayProof,
      supplementalJWKS: #"{"keys":[{}]}"#,
      accessTokenVerifier: { _ in fixture.verifiedToken },
      attestor: StubAttestor(calls: probes, behavior: .success(fixture.verifiedToken, nil)),
      upstreamProof: "direct-route-proof",
      handlerCalls: handlers
    )

    #expect(response.status == .ok)
    #expect(await probes.count == 0)
    #expect(await handlers.count == 1)
    #expect(responseHeader(response, "X-Test-Upstream-DPoP") == "direct-route-proof")
    #expect(responseHeader(response, ATProtoSessionAttestationReceipt.receiptHeaderName) == nil)
  }

  @Test("PDS nonce challenge uses only the dedicated response header")
  func dedicatedNonceChallenge() async throws {
    let fixture = try fallbackFixture()
    let calls = CallCounter()
    let response = try await protectedResponse(
      accessToken: fixture.accessToken,
      dpopProof: fixture.gatewayProof,
      supplementalJWKS: #"{"keys":[]}"#,
      accessTokenVerifier: { _ in throw OAuthAccessTokenVerifier.VerifyError.noJwksCandidates },
      attestor: StubAttestor(calls: calls, behavior: .nonce("challenge-nonce")),
      sessionProof: "session-proof"
    )

    #expect(response.status == .unauthorized)
    #expect(
      response.headers[HTTPField.Name(ATProtoSessionDPoP.nonceHeaderName)!] == "challenge-nonce"
    )
    #expect(response.headers[HTTPField.Name("DPoP-Nonce")!] == nil)
  }

  @Test("active PDS admission overload remains an availability failure")
  func attestationOverloadIsServiceUnavailable() async throws {
    let fixture = try fallbackFixture()
    let calls = CallCounter()
    let response = try await protectedResponse(
      accessToken: fixture.accessToken,
      dpopProof: fixture.gatewayProof,
      supplementalJWKS: #"{"keys":[]}"#,
      accessTokenVerifier: { _ in throw OAuthAccessTokenVerifier.VerifyError.noJwksCandidates },
      attestor: StubAttestor(calls: calls, behavior: .overloaded),
      sessionProof: "session-proof"
    )

    #expect(response.status == .serviceUnavailable)
    #expect(await calls.count == 1)
  }

  @Test("a cached attestation does not bypass Gateway DPoP replay protection")
  func cachedAttestationStillRejectsGatewayReplay() async throws {
    let fixture = try fallbackFixture()
    let probes = CallCounter()
    let attestor = PDSAccessTokenAttestor(
      authorityResolver: { _ in
        .init(
          pdsBase: "https://pds.public.social",
          authorizationServers: ["https://issuer.public.social"]
        )
      },
      sessionProbe: { _, _, _ in
        await probes.increment()
        return ("did:plc:middlewareattestation", true, nil)
      }
    )
    let sessionProof = try dpopProof(
      accessToken: fixture.accessToken,
      key: fixture.proofKey,
      jwk: fixture.proofJWK,
      htu: "https://pds.public.social/xrpc/com.atproto.server.getSession"
    )
    let verifier: ATProtoAuthMiddleware.AccessTokenVerifier = { _ in
      throw OAuthAccessTokenVerifier.VerifyError.jwksEmpty("issuer")
    }
    let replayGuard = DPoPReplayGuard()
    let first = try await protectedResponse(
      accessToken: fixture.accessToken,
      dpopProof: fixture.gatewayProof,
      supplementalJWKS: #"{"keys":[]}"#,
      accessTokenVerifier: verifier,
      attestor: attestor,
      replayGuard: replayGuard,
      sessionProof: sessionProof
    )
    let replay = try await protectedResponse(
      accessToken: fixture.accessToken,
      dpopProof: fixture.gatewayProof,
      supplementalJWKS: #"{"keys":[]}"#,
      accessTokenVerifier: verifier,
      attestor: attestor,
      replayGuard: replayGuard,
      sessionProof: nil
    )

    #expect(first.status == .ok)
    #expect(replay.status == .unauthorized)
    #expect(await probes.count == 1)
  }

  @Test("replay guard capacity exhaustion fails closed as unauthorized")
  func replayGuardCapacityExhaustionFailsClosed() async throws {
    let fixture = try fallbackFixture()
    let calls = CallCounter()
    let replayGuard = DPoPReplayGuard(retention: 120, maximumEntries: 1)
    try await replayGuard.consume(thumbprint: "existing-key", jti: "existing-proof")

    let response = try await protectedResponse(
      accessToken: fixture.accessToken,
      dpopProof: fixture.gatewayProof,
      supplementalJWKS: #"{"keys":[]}"#,
      accessTokenVerifier: { _ in throw OAuthAccessTokenVerifier.VerifyError.jwksEmpty("issuer") },
      attestor: StubAttestor(calls: calls, behavior: .success(fixture.verifiedToken, nil)),
      replayGuard: replayGuard,
      sessionProof: "session-proof"
    )

    #expect(response.status == .unauthorized)
    #expect(await calls.count == 1)
  }

  private func protectedResponse(
    accessToken: String,
    dpopProof: String,
    supplementalJWKS: String?,
    legacyFallbackConfigured: Bool = false,
    accessTokenVerifier: ATProtoAuthMiddleware.AccessTokenVerifier? = nil,
    attestor: (any PDSAccessTokenAttesting)? = nil,
    replayGuard: DPoPReplayGuard = DPoPReplayGuard(),
    sessionProof: String? = nil,
    upstreamProof: String? = nil,
    upstreamPrepared: Bool = false,
    attestationReceipt: String? = nil,
    handlerCalls: CallCounter? = nil
  ) async throws -> TestResponse {
    let httpClient = HTTPClient(eventLoopGroupProvider: .singleton)

    let middleware: ATProtoAuthMiddleware
    if let accessTokenVerifier, let attestor {
      middleware = ATProtoAuthMiddleware(
        httpClient: httpClient,
        plcURL: "https://plc.invalid",
        gatewayClientPolicy: .permissive,
        supplementalJwksJSON: supplementalJWKS,
        accessTokenVerifier: accessTokenVerifier,
        attestor: attestor,
        attestationReceipt: try ATProtoSessionAttestationReceipt(
          secret: "gateway-core-test-attestation-receipt-secret"
        ),
        replayGuard: replayGuard,
        logger: Logger(label: "auth.security.test")
      )
    } else {
      middleware = ATProtoAuthMiddleware(
        httpClient: httpClient,
        plcURL: "https://plc.invalid",
        gatewayClientPolicy: .permissive,
        attestationReceipt: try ATProtoSessionAttestationReceipt(
          secret: "gateway-core-test-attestation-receipt-secret"
        ),
        supplementalJwksJSON: supplementalJWKS,
        allowDpopBoundStructuralFallback: legacyFallbackConfigured,
        logger: Logger(label: "auth.security.test")
      )
    }
    let router = Router(context: GatewayRequestContext.self)
    let protected = router.group().add(middleware: middleware)
    protected.get("/protected") { _, context in
      if let handlerCalls { await handlerCalls.increment() }
      var headers = HTTPFields()
      if let upstreamProof = context.authContext?.upstreamDpopProof {
        headers[HTTPField.Name("X-Test-Upstream-DPoP")!] = upstreamProof
      }
      return Response(status: .ok, headers: headers)
    }
    let app = Application(
      router: router,
      configuration: .init(address: .hostname("127.0.0.1", port: 0))
    )
    let headers: HTTPFields = {
      var headers = HTTPFields()
      headers[.authorization] = "DPoP \(accessToken)"
      headers[HTTPField.Name("DPoP")!] = dpopProof
      if let sessionProof {
        headers[HTTPField.Name(ATProtoSessionDPoP.headerName)!] = sessionProof
      }
      if let upstreamProof {
        headers[HTTPField.Name(ATProtoUpstreamDPoP.headerName)!] = upstreamProof
      }
      if upstreamPrepared {
        headers[
          HTTPField.Name(ATProtoSessionAttestationReceipt.upstreamPreparedHeaderName)!
        ] = "true"
      }
      if let attestationReceipt {
        headers[
          HTTPField.Name(ATProtoSessionAttestationReceipt.receiptHeaderName)!
        ] = attestationReceipt
      }
      return headers
    }()
    do {
      let response = try await app.test(.router) { client in
        try await client.execute(uri: "/protected", method: .get, headers: headers)
      }
      try await httpClient.shutdown()
      return response
    } catch {
      try? await httpClient.shutdown()
      throw error
    }
  }

  private func responseHeader(_ response: TestResponse, _ name: String) -> String? {
    response.headers[HTTPField.Name(name)!]
  }

  private func fallbackFixture() throws -> (
    accessToken: String,
    gatewayProof: String,
    proofKey: P256.Signing.PrivateKey,
    proofJWK: JWK,
    verifiedToken: OAuthAccessTokenVerifier.VerifiedAccessToken
  ) {
    let proofKey = P256.Signing.PrivateKey()
    let proofJWK = jwk(for: proofKey, kid: "fallback-proof")
    let thumbprint = try thumbprint(of: proofJWK)
    let accessToken = try signedAccessToken(
      issuer: "https://issuer.public.social",
      subject: "did:plc:middlewareattestation",
      confirmationThumbprint: thumbprint,
      signingKey: P256.Signing.PrivateKey(),
      kid: "pds-attested-token"
    )
    let gatewayProof = try dpopProof(
      accessToken: accessToken,
      key: proofKey,
      jwk: proofJWK,
      htu: "http://localhost/protected"
    )
    return (
      accessToken,
      gatewayProof,
      proofKey,
      proofJWK,
      .init(
        did: "did:plc:middlewareattestation",
        cnfJkt: thumbprint,
        clientIdClaim: nil,
        azpClaim: nil,
        audiences: []
      )
    )
  }

  private func signedAccessToken(
    issuer: String,
    subject: String,
    confirmationThumbprint: String,
    signingKey: P256.Signing.PrivateKey,
    kid: String
  ) throws -> String {
    let header = try base64url(AccessTokenHeader(kid: kid))
    let claims = try base64url(
      AccessTokenClaims(
        iss: issuer,
        sub: subject,
        exp: Int(Date().addingTimeInterval(3_600).timeIntervalSince1970),
        cnf: .init(jkt: confirmationThumbprint)
      ))
    return try sign(header: header, payload: claims, key: signingKey)
  }

  private func dpopProof(
    accessToken: String,
    key: P256.Signing.PrivateKey,
    jwk: JWK,
    htu: String
  ) throws -> String {
    let header = try base64url(DPoPHeader(jwk: jwk))
    let claims = try base64url(
      DPoPClaims(
        jti: UUID().uuidString,
        iat: Int(Date().timeIntervalSince1970),
        htm: "GET",
        htu: htu,
        ath: AccessTokenAth.expectedAth(accessTokenJWT: accessToken)
      ))
    return try sign(header: header, payload: claims, key: key)
  }

  private func jwk(for key: P256.Signing.PrivateKey, kid: String) -> JWK {
    let coordinates = key.publicKey.x963Representation.dropFirst()
    return JWK(
      kid: kid,
      x: Base64URL.encodeNoPadding(data: Data(coordinates.prefix(32))),
      y: Base64URL.encodeNoPadding(data: Data(coordinates.suffix(32)))
    )
  }

  private func thumbprint(of jwk: JWK) throws -> String {
    struct ThumbprintJWK: Encodable {
      let crv: String
      let kty: String
      let x: String
      let y: String
    }
    let canonical = ThumbprintJWK(crv: jwk.crv, kty: jwk.kty, x: jwk.x, y: jwk.y)
    return Base64URL.encodeNoPadding(digest: SHA256.hash(data: try encoder.encode(canonical)))
  }

  private func jwksJSON(containing jwk: JWK) throws -> String {
    String(decoding: try encoder.encode(JWKS(keys: [jwk])), as: UTF8.self)
  }

  private func base64url<T: Encodable>(_ value: T) throws -> String {
    Base64URL.encodeNoPadding(data: try encoder.encode(value))
  }

  private func sign(
    header: String,
    payload: String,
    key: P256.Signing.PrivateKey
  ) throws -> String {
    let input = Data("\(header).\(payload)".utf8)
    let signature = try key.signature(for: SHA256.hash(data: input))
    return "\(header).\(payload).\(Base64URL.encodeNoPadding(data: signature.rawRepresentation))"
  }
}
