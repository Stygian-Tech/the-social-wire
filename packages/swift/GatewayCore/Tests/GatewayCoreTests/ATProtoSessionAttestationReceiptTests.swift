import Foundation
import Testing

@testable import GatewayCore

@Suite("ATProto session attestation receipts")
struct ATProtoSessionAttestationReceiptTests {
  private let secret = "shared-gateway-attestation-receipt-secret"
  private let token = "header.payload.signature"
  private let did = "did:plc:receiptviewer"
  private let jkt = "exact-case-sensitive-thumbprint"
  private let now = Date(timeIntervalSince1970: 2_000_000_000)

  @Test("round trip is portable across Gateway instances")
  func roundTripAcrossInstances() throws {
    let issuer = try ATProtoSessionAttestationReceipt(secret: secret)
    let verifier = try ATProtoSessionAttestationReceipt(secret: secret)
    let receipt = try issuer.issue(
      accessTokenJWT: token,
      did: did,
      cnfJkt: jkt,
      tokenExpiresAt: now.addingTimeInterval(30),
      authoritativeValidUntil: now.addingTimeInterval(45),
      now: now
    )

    let claims = try verifier.verify(
      receipt,
      accessTokenJWT: token,
      expectedDID: did,
      expectedCnFJkt: jkt,
      tokenExpiresAt: now.addingTimeInterval(30),
      now: now.addingTimeInterval(1)
    )
    #expect(claims.did == did)
    #expect(claims.cnfJkt == jkt)
    #expect(claims.validUntil == now.addingTimeInterval(30))
  }

  @Test("tampering, a different secret, or a different binding is rejected")
  func rejectsForgeryAndWrongBindings() throws {
    let authority = try ATProtoSessionAttestationReceipt(secret: secret)
    let receipt = try authority.issue(
      accessTokenJWT: token,
      did: did,
      cnfJkt: jkt,
      tokenExpiresAt: now.addingTimeInterval(120),
      authoritativeValidUntil: now.addingTimeInterval(60),
      now: now
    )
    let final = try #require(receipt.last)
    let tampered = String(receipt.dropLast()) + (final == "A" ? "B" : "A")
    let wrongAuthority = try ATProtoSessionAttestationReceipt(
      secret: "different-gateway-attestation-receipt-key"
    )

    for (candidateAuthority, candidateReceipt, candidateToken, candidateDID, candidateJKT) in [
      (authority, tampered, token, did, jkt),
      (wrongAuthority, receipt, token, did, jkt),
      (authority, receipt, "different-token", did, jkt),
      (authority, receipt, token, "did:plc:different", jkt),
      (authority, receipt, token, did, "Exact-case-sensitive-thumbprint"),
    ] {
      #expect(throws: ATProtoSessionAttestationReceipt.Error.invalid) {
        _ = try candidateAuthority.verify(
          candidateReceipt,
          accessTokenJWT: candidateToken,
          expectedDID: candidateDID,
          expectedCnFJkt: candidateJKT,
          tokenExpiresAt: now.addingTimeInterval(120),
          now: now.addingTimeInterval(1)
        )
      }
    }
  }

  @Test("expired receipts are distinguishable only after authentic binding verification")
  func rejectsExpiry() throws {
    let authority = try ATProtoSessionAttestationReceipt(secret: secret)
    let receipt = try authority.issue(
      accessTokenJWT: token,
      did: did,
      cnfJkt: jkt,
      tokenExpiresAt: now.addingTimeInterval(120),
      authoritativeValidUntil: now.addingTimeInterval(30),
      now: now
    )

    #expect(throws: ATProtoSessionAttestationReceipt.Error.expired) {
      _ = try authority.verify(
        receipt,
        accessTokenJWT: token,
        expectedDID: did,
        expectedCnFJkt: jkt,
        tokenExpiresAt: now.addingTimeInterval(120),
        now: now.addingTimeInterval(30)
      )
    }
    #expect(throws: ATProtoSessionAttestationReceipt.Error.invalid) {
      _ = try authority.verify(
        receipt,
        accessTokenJWT: "wrong-token",
        expectedDID: did,
        expectedCnFJkt: jkt,
        tokenExpiresAt: now.addingTimeInterval(120),
        now: now.addingTimeInterval(30)
      )
    }
  }

  @Test("secrets shorter than 32 bytes fail closed")
  func rejectsShortSecret() {
    #expect(throws: ATProtoSessionAttestationReceipt.Error.invalidSecret) {
      _ = try ATProtoSessionAttestationReceipt(secret: "too-short")
    }
  }
}
