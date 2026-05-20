import AsyncHTTPClient
import Foundation
import Logging
import Testing

@testable import App

@Suite("OAuthAccessTokenJWT")
struct OAuthAccessTokenJWTTests {
  @Test("extracts Bearer token segment")
  func extractBearer() {
    let token = OAuthAccessTokenJWT.extract(accessAuthorizationValue: "Bearer eyJhbG.test.sig")
    #expect(token == "eyJhbG.test.sig")
  }

  @Test("extracts DPoP token segment")
  func extractDPoP() {
    let token = OAuthAccessTokenJWT.extract(accessAuthorizationValue: "DPoP eyJhbG.test.sig")
    #expect(token == "eyJhbG.test.sig")
  }

  @Test("returns nil for malformed Authorization header")
  func extractNil() {
    #expect(OAuthAccessTokenJWT.extract(accessAuthorizationValue: "Basic abc") == nil)
    #expect(OAuthAccessTokenJWT.extract(accessAuthorizationValue: "") == nil)
  }
}

@Suite("OAuthAccessTokenVerifier")
struct OAuthAccessTokenVerifierTests {
  private func base64urlJSON(_ object: [String: Any]) -> String {
    let data = try! JSONSerialization.data(withJSONObject: object)
    return data.base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  @Test("missing issuer claim fails before JWKS fetch")
  func missingIssuer() async throws {
    let header = base64urlJSON(["alg": "ES256", "typ": "JWT"])
    let payload = base64urlJSON([
      "sub": "did:plc:testuser",
      "exp": Int(Date().addingTimeInterval(3600).timeIntervalSince1970),
    ])
    let jwt = "\(header).\(payload).fake"

    let client = HTTPClient(eventLoopGroupProvider: .singleton)
    await #expect(throws: OAuthAccessTokenVerifier.VerifyError.self) {
      _ = try await OAuthAccessTokenVerifier.verify(
        accessTokenJWT: jwt,
        httpClient: client,
        plcURL: "https://plc.directory",
        logger: Logger(label: "oauth.test")
      )
    }
    try await client.shutdown()
  }

  @Test("unsupported issuer form fails")
  func unsupportedIssuer() async throws {
    let header = base64urlJSON(["alg": "ES256", "typ": "JWT"])
    let payload = base64urlJSON([
      "iss": "not-a-did-or-url",
      "sub": "did:plc:testuser",
      "exp": Int(Date().addingTimeInterval(3600).timeIntervalSince1970),
    ])
    let jwt = "\(header).\(payload).fake"

    let client = HTTPClient(eventLoopGroupProvider: .singleton)
    await #expect(throws: OAuthAccessTokenVerifier.VerifyError.self) {
      _ = try await OAuthAccessTokenVerifier.verify(
        accessTokenJWT: jwt,
        httpClient: client,
        plcURL: "https://plc.directory",
        logger: Logger(label: "oauth.test")
      )
    }
    try await client.shutdown()
  }
}
