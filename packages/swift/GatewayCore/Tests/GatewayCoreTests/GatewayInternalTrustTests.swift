import Foundation
import Testing

@testable import GatewayCore

@Suite("GatewayInternalTrust")
struct GatewayInternalTrustTests {
  @Test("signed headers verify for matching request")
  func roundTrip() throws {
    let secret = "test-internal-secret"
    let did = "did:plc:abc123"
    let method = "GET"
    let path = "/v1/publications/sidebar"

    let headers = try GatewayInternalTrust.signedHeaders(
      secret: secret,
      did: did,
      method: method,
      pathWithQuery: path
    )

    let timestamp = headers.first(where: { $0.name == GatewayInternalTrust.timestampHeaderName })?.value
    let signature = headers.first(where: { $0.name == GatewayInternalTrust.signatureHeaderName })?.value
    #expect(timestamp != nil)
    #expect(signature != nil)

    try GatewayInternalTrust.verify(
      secret: secret,
      did: did,
      method: method,
      pathWithQuery: path,
      timestamp: timestamp!,
      signature: signature!
    )
  }

  @Test("query string is included in canonical path")
  func queryIncluded() throws {
    let secret = "test-internal-secret"
    let did = "did:plc:abc123"
    let path = "/v1/appview/unread-counts?publicationIds=pub-1,pub-2"

    let headers = try GatewayInternalTrust.signedHeaders(
      secret: secret,
      did: did,
      method: "GET",
      pathWithQuery: path
    )

    try GatewayInternalTrust.verify(
      secret: secret,
      did: did,
      method: "GET",
      pathWithQuery: path,
      timestamp: headers[1].value,
      signature: headers[2].value
    )
  }

  @Test("rejects tampered DID")
  func rejectsTamperedDid() {
    let secret = "test-internal-secret"
    let headers = try? GatewayInternalTrust.signedHeaders(
      secret: secret,
      did: "did:plc:abc123",
      method: "GET",
      pathWithQuery: "/v1/publications/sidebar"
    )
    #expect(headers != nil)

    #expect(throws: GatewayInternalTrust.TrustError.self) {
      try GatewayInternalTrust.verify(
        secret: secret,
        did: "did:plc:other",
        method: "GET",
        pathWithQuery: "/v1/publications/sidebar",
        timestamp: headers![1].value,
        signature: headers![2].value
      )
    }
  }

  @Test("canonical query encoding matches across percent-encoding variants")
  func canonicalQueryEncoding() {
    let path = "/v1/appview/entries"
    let encoded = GatewayInternalTrust.canonicalPathWithQuery(
      path: path,
      query: "authorDid=did%3Aplc%3Aabc&filter=all&limit=50"
    )
    let decoded = GatewayInternalTrust.canonicalPathWithQuery(
      path: path,
      query: "filter=all&authorDid=did:plc:abc&limit=50"
    )
    #expect(encoded == decoded)
    #expect(encoded.contains("authorDid="))
    #expect(encoded.contains("filter=all"))
  }

  @Test("rejects stale timestamps")
  func rejectsStaleTimestamp() {
    let secret = "test-internal-secret"
    let stale = Date().addingTimeInterval(-600)
    let headers = try? GatewayInternalTrust.signedHeaders(
      secret: secret,
      did: "did:plc:abc123",
      method: "GET",
      pathWithQuery: "/v1/publications/sidebar",
      timestamp: stale
    )
    #expect(headers != nil)

    #expect(throws: GatewayInternalTrust.TrustError.self) {
      try GatewayInternalTrust.verify(
        secret: secret,
        did: "did:plc:abc123",
        method: "GET",
        pathWithQuery: "/v1/publications/sidebar",
        timestamp: headers![1].value,
        signature: headers![2].value
      )
    }
  }
}
