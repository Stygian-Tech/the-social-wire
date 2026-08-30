import Foundation
import Testing
@testable import WireCore

@Suite("The Wire corpus service trust")
struct WireCorpusServiceTrustTests {
  @Test("body-authenticated requests bind the digest into the signature")
  func bodyDigestBinding() throws {
    let secret = String(repeating: "s", count: 32)
    let body = Data("{\"actorHashes\":[\"opaque\"]}".utf8)
    let digest = WireCorpusServiceTrust.bodyDigest(body)
    let timestamp = Date(timeIntervalSince1970: 1_800_000_000)
    let headers = try WireCorpusServiceTrust.signedHeaders(
      secret: secret,
      serviceID: "development-appview",
      method: "POST",
      target: "/internal/wire/v1/circle-candidates",
      bodyDigest: digest,
      timestamp: timestamp,
      nonce: "11111111-1111-4111-8111-111111111111"
    )

    try WireCorpusServiceTrust.verify(
      secret: secret,
      expectedServiceID: "development-appview",
      presentedServiceID: headers.serviceID,
      method: "POST",
      target: "/internal/wire/v1/circle-candidates",
      timestamp: headers.timestamp,
      nonce: headers.nonce,
      signature: headers.signature,
      bodyDigest: digest,
      now: timestamp
    )
    #expect(throws: WireCorpusServiceTrustError.invalidSignature) {
      try WireCorpusServiceTrust.verify(
        secret: secret,
        expectedServiceID: "development-appview",
        presentedServiceID: headers.serviceID,
        method: "POST",
        target: "/internal/wire/v1/circle-candidates",
        timestamp: headers.timestamp,
        nonce: headers.nonce,
        signature: headers.signature,
        bodyDigest: String(repeating: "0", count: 64),
        now: timestamp
      )
    }
  }

  private let secret = String(repeating: "s", count: 32)
  private let now = Date(timeIntervalSince1970: 2_000_000_000)

  @Test("matching dedicated service request verifies")
  func roundTrip() throws {
    let target = "/internal/wire/v1/feed?language=en&limit=500"
    let headers = try WireCorpusServiceTrust.signedHeaders(
      secret: secret,
      serviceID: "development-appview",
      method: "GET",
      target: target,
      timestamp: now
    )
    try WireCorpusServiceTrust.verify(
      secret: secret,
      expectedServiceID: "development-appview",
      presentedServiceID: headers.serviceID,
      method: "GET",
      target: target,
      timestamp: headers.timestamp,
      nonce: headers.nonce,
      signature: headers.signature,
      now: now.addingTimeInterval(30)
    )
  }

  @Test("query tampering is rejected")
  func queryTampering() throws {
    let headers = try WireCorpusServiceTrust.signedHeaders(
      secret: secret,
      serviceID: "development-appview",
      method: "GET",
      target: "/internal/wire/v1/feed?limit=50",
      timestamp: now
    )
    #expect(throws: WireCorpusServiceTrustError.invalidSignature) {
      try WireCorpusServiceTrust.verify(
        secret: secret,
        expectedServiceID: "development-appview",
        presentedServiceID: headers.serviceID,
        method: "GET",
        target: "/internal/wire/v1/feed?limit=500",
        timestamp: headers.timestamp,
        nonce: headers.nonce,
        signature: headers.signature,
        now: now
      )
    }
  }

  @Test("wrong service and stale timestamp are rejected")
  func identityAndFreshness() throws {
    let headers = try WireCorpusServiceTrust.signedHeaders(
      secret: secret,
      serviceID: "development-appview",
      method: "GET",
      target: "/internal/wire/v1/catalog",
      timestamp: now
    )
    #expect(throws: WireCorpusServiceTrustError.invalidServiceID) {
      try WireCorpusServiceTrust.verify(
        secret: secret,
        expectedServiceID: "production-appview",
        presentedServiceID: headers.serviceID,
        method: "GET",
        target: "/internal/wire/v1/catalog",
        timestamp: headers.timestamp,
        nonce: headers.nonce,
        signature: headers.signature,
        now: now
      )
    }
    #expect(throws: WireCorpusServiceTrustError.expiredTimestamp) {
      try WireCorpusServiceTrust.verify(
        secret: secret,
        expectedServiceID: "development-appview",
        presentedServiceID: headers.serviceID,
        method: "GET",
        target: "/internal/wire/v1/catalog",
        timestamp: headers.timestamp,
        nonce: headers.nonce,
        signature: headers.signature,
        now: now.addingTimeInterval(61)
      )
    }
  }

  @Test("secrets and service identifiers are bounded")
  func validation() {
    #expect(throws: WireCorpusServiceTrustError.invalidSecret) {
      _ = try WireCorpusServiceTrust.signedHeaders(
        secret: "short",
        serviceID: "development-appview",
        method: "GET",
        target: "/internal/wire/v1/catalog",
        timestamp: now
      )
    }
    #expect(throws: WireCorpusServiceTrustError.invalidServiceID) {
      try WireCorpusServiceTrust.validateServiceID("viewer/did")
    }
  }
}
