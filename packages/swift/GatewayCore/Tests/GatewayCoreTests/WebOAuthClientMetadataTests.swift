import Foundation
import Testing

@testable import GatewayCore

@Suite("WebOAuthClientMetadata")
struct WebOAuthClientMetadataTests {
  @Test("`client_id` targets hosted Swift metadata route")
  func clientIdUsesOAuthRoute() throws {
    let blob = try WebOAuthClientMetadata.buildJSON(publicOrigin: "https://api.example.com")
    let obj = try #require(try JSONSerialization.jsonObject(with: blob) as? [String: Any])
    #expect(obj["client_id"] as? String == "https://api.example.com/oauth-client-metadata.json")
  }

  @Test("redirect_uris can target a separate SPA origin")
  func redirectUsesSpaOrigin() throws {
    let blob = try WebOAuthClientMetadata.buildJSON(
      publicOrigin: "https://api.example.com",
      redirectOrigin: "https://spa.example.com"
    )
    let obj = try #require(try JSONSerialization.jsonObject(with: blob) as? [String: Any])
    #expect(obj["client_id"] as? String == "https://api.example.com/oauth-client-metadata.json")
    #expect(obj["redirect_uris"] as? [String] == ["https://spa.example.com/callback"])
    #expect(obj["client_uri"] as? String == "https://api.example.com")
  }
}
