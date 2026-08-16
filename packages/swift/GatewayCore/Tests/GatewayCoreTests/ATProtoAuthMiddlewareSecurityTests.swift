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

  private func protectedResponse(
    accessToken: String,
    dpopProof: String,
    supplementalJWKS: String?,
    legacyFallbackConfigured: Bool
  ) async throws -> TestResponse {
    let httpClient = HTTPClient(eventLoopGroupProvider: .singleton)

    let middleware = ATProtoAuthMiddleware(
      httpClient: httpClient,
      plcURL: "https://plc.invalid",
      gatewayClientPolicy: .permissive,
      supplementalJwksJSON: supplementalJWKS,
      allowDpopBoundStructuralFallback: legacyFallbackConfigured,
      logger: Logger(label: "auth.security.test")
    )
    let router = Router(context: GatewayRequestContext.self)
    let protected = router.group().add(middleware: middleware)
    protected.get("/protected") { _, context in
      ["did": context.authContext?.did ?? "missing"]
    }
    let app = Application(
      router: router,
      configuration: .init(address: .hostname("127.0.0.1", port: 0))
    )
    let headers: HTTPFields = {
      var headers = HTTPFields()
      headers[.authorization] = "DPoP \(accessToken)"
      headers[HTTPField.Name("DPoP")!] = dpopProof
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
