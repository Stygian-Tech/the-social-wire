import Foundation
import Testing

@testable import App

@Suite("WebOAuthClientMetadata")
struct WebOAuthClientMetadataTests {
  @Test("`client_id` targets hosted Swift metadata route")
  func clientIdUsesOAuthRoute() throws {
    let blob = try WebOAuthClientMetadata.buildJSON(publicOrigin: "https://api.example.com")
    let obj = try #require(try JSONSerialization.jsonObject(with: blob) as? [String: Any])
    #expect(obj["client_id"] as? String == "https://api.example.com/oauth/client-metadata.json")
  }
}
