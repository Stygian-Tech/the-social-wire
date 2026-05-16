import Crypto
import Foundation
import Testing

@testable import App

private struct CanonicalJSON {
  let encoder: JSONEncoder = {
    let enc = JSONEncoder()
    enc.outputFormatting = [.sortedKeys]
    return enc
  }()

  func base64url<T: Encodable>(_ value: T) throws -> String {
    Base64URL.encodeNoPadding(data: try encoder.encode(value))
  }

  func rfc7638Thumbprint(ec: JWKBody) throws -> String {
    let utf8Blob = try encoder.encode(ec)
    let digest = SHA256.hash(data: utf8Blob)
    return Base64URL.encodeNoPadding(digest: digest)
  }
}

private struct JWTDPoPHeader: Encodable {
  let alg: String
  let typ: String
  let jwk: JWKBody
}

private struct JWKBody: Codable {
  let crv: String
  let kty: String
  let x: String
  let y: String
}

private struct JWTDPoPPayload: Encodable {
  let jti: String
  let iat: Int
  let htm: String
  let htu: String
  let ath: String
}

@Suite("DPoPProofVerifier")
struct DPoPProofVerifierTests {
  @Test("accepts freshly signed ES-256 proofs with matching ath")
  func verifiesHappyPath() throws {
    let key = P256.Signing.PrivateKey()
    let raw = key.publicKey.x963Representation.dropFirst()
    let xCoordinate = raw.prefix(32)
    let yCoordinate = raw.suffix(32)

    let jwk = JWKBody(
      crv: "P-256",
      kty: "EC",
      x: Base64URL.encodeNoPadding(data: Data(xCoordinate)),
      y: Base64URL.encodeNoPadding(data: Data(yCoordinate))
    )

    let helper = CanonicalJSON()

    let accessTokenJWT = #"eyJhbGciOiJFUzI1NiIsInR5cCI6Imp3dCJ9.eyJqdGkiOiJhIn0.fake.sigpart"#

    let header = JWTDPoPHeader(alg: "ES256", typ: "dpop+jwt", jwk: jwk)
    let htu = "http://localhost:8080/v1/sync/preferences"

    let payload = JWTDPoPPayload(
      jti: UUID().uuidString,
      iat: Int(Date().timeIntervalSince1970),
      htm: "GET",
      htu: htu,
      ath: AccessTokenAth.expectedAth(accessTokenJWT: accessTokenJWT)
    )

    let headerSegment = try helper.base64url(header)
    let payloadSegment = try helper.base64url(payload)

    let signingInput = Data((headerSegment + "." + payloadSegment).utf8)
    let hashed = SHA256.hash(data: signingInput)
    let signature = try key.signature(for: hashed)
    let sigSegment = Base64URL.encodeNoPadding(data: signature.rawRepresentation)

    let proofJWT = headerSegment + "." + payloadSegment + "." + sigSegment

    try DPoPProofVerifier.verify(
      proofJWT: proofJWT,
      uppercasedHTTPMethod: "GET",
      expectedHtuURL: htu,
      accessTokenJWT: accessTokenJWT,
      accessTokenCnFJkt: try helper.rfc7638Thumbprint(ec: jwk)
    )
  }

  @Test("rejects proof when cnf thumbprint mismatches computed jwk hash")
  func rejectsMismatchedCnfThumbprint() throws {
    let key = P256.Signing.PrivateKey()
    let strip = key.publicKey.x963Representation.dropFirst()
    let jwk = JWKBody(
      crv: "P-256",
      kty: "EC",
      x: Base64URL.encodeNoPadding(data: Data(strip.prefix(32))),
      y: Base64URL.encodeNoPadding(data: Data(strip.suffix(32)))
    )

    let helper = CanonicalJSON()
    let wrongThumb = "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"

    let accessTokenJWT = "token.part.three"

    let headerSegment = try helper.base64url(JWTDPoPHeader(alg: "ES256", typ: "dpop+jwt", jwk: jwk))
    let payloadSegment = try helper.base64url(
      JWTDPoPPayload(
        jti: "jti-test",
        iat: Int(Date().timeIntervalSince1970),
        htm: "GET",
        htu: "http://localhost/ok",
        ath: AccessTokenAth.expectedAth(accessTokenJWT: accessTokenJWT)
      )
    )

    let signingBytes = Data((headerSegment + "." + payloadSegment).utf8)
    let signature = try key.signature(for: SHA256.hash(data: signingBytes))
    let jwt = headerSegment + "." + payloadSegment + "." + Base64URL.encodeNoPadding(data: signature.rawRepresentation)

    var mismatchedConfirmation = false
    do {
      try DPoPProofVerifier.verify(
        proofJWT: jwt,
        uppercasedHTTPMethod: "GET",
        expectedHtuURL: "http://localhost/ok",
        accessTokenJWT: accessTokenJWT,
        accessTokenCnFJkt: wrongThumb
      )
    } catch {
      mismatchedConfirmation = true
    }
    #expect(mismatchedConfirmation)
  }
}
