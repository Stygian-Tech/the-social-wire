import Foundation
import Hummingbird
import Testing

@testable import App

@Suite("OAuthGatewayClientPolicy")
struct OAuthGatewayClientPolicyTests {
  @Test("permissive policy allows any client claims")
  func permissiveAllows() throws {
    let policy = OAuthGatewayClientPolicy.permissive
    try policy.assertAllowedJWTClient(
      clientIdClaim: "https://unknown.example/client",
      azpClaim: nil,
      audiences: []
    )
  }

  @Test("requireKnownClient rejects unknown client_id and aud")
  func rejectsUnknownClient() {
    let policy = OAuthGatewayClientPolicy(
      allowedClientIds: ["https://api.example/ios-client-metadata.json"],
      allowedAudiences: ["https://api.example"],
      requireKnownClient: true
    )

    #expect(throws: HTTPError.self) {
      try policy.assertAllowedJWTClient(
        clientIdClaim: "https://other.example/client",
        azpClaim: nil,
        audiences: ["https://wrong.example"]
      )
    }
  }

  @Test("requireKnownClient accepts matching client_id")
  func acceptsClientId() throws {
    let allowed = "https://thesocialwire.app/client-metadata.json"
    let policy = OAuthGatewayClientPolicy(
      allowedClientIds: [allowed],
      allowedAudiences: [],
      requireKnownClient: true
    )
    try policy.assertAllowedJWTClient(
      clientIdClaim: allowed,
      azpClaim: nil,
      audiences: []
    )
  }

  @Test("requireKnownClient accepts matching azp when client_id absent")
  func acceptsAzp() throws {
    let allowed = "https://api.example/ios-client-metadata.json"
    let policy = OAuthGatewayClientPolicy(
      allowedClientIds: [allowed],
      allowedAudiences: [],
      requireKnownClient: true
    )
    try policy.assertAllowedJWTClient(
      clientIdClaim: nil,
      azpClaim: allowed,
      audiences: []
    )
  }

  @Test("requireKnownClient accepts matching audience")
  func acceptsAudience() throws {
    let policy = OAuthGatewayClientPolicy(
      allowedClientIds: [],
      allowedAudiences: ["https://api.thesocialwire.app"],
      requireKnownClient: true
    )
    try policy.assertAllowedJWTClient(
      clientIdClaim: nil,
      azpClaim: nil,
      audiences: ["https://other.example", "https://api.thesocialwire.app"]
    )
  }

  @Test("requireKnownClient with empty allowlists throws forbidden")
  func emptyAllowlistsForbidden() {
    let policy = OAuthGatewayClientPolicy(
      allowedClientIds: [],
      allowedAudiences: [],
      requireKnownClient: true
    )
    #expect(throws: HTTPError.self) {
      try policy.assertAllowedJWTClient(clientIdClaim: "x", azpClaim: nil, audiences: [])
    }
  }
}

@Suite("OAuthGatewayPolicyParser")
struct OAuthGatewayPolicyParserTests {
  @Test("delimiterTokenSet splits comma and whitespace")
  func delimiterTokenSet() {
    let set = OAuthGatewayPolicyParser.delimiterTokenSet(
      "https://a.example, https://b.example\nhttps://c.example"
    )
    #expect(set.count == 3)
    #expect(set.contains("https://a.example"))
    #expect(set.contains("https://b.example"))
    #expect(set.contains("https://c.example"))
  }

  @Test("truthy recognizes common flag values")
  func truthyFlags() {
    for value in ["1", "true", "YES", "on"] {
      #expect(OAuthGatewayPolicyParser.truthy(value) == true)
    }
    #expect(OAuthGatewayPolicyParser.truthy("false") == false)
    #expect(OAuthGatewayPolicyParser.truthy(nil) == false)
  }
}
