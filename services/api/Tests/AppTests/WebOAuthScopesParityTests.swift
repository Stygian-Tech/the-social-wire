import Foundation
import Testing

@testable import App

@Suite("ATProtoOAuthScopes parity")
struct WebOAuthScopesParityTests {
  private func repoPublicClientMetadataURL() throws -> URL {
    // …/social-wire/services/api/Tests/AppTests/<this file>.swift → repo root
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent() // AppTests
      .deletingLastPathComponent() // Tests
      .deletingLastPathComponent() // services/api
      .deletingLastPathComponent() // services
      .deletingLastPathComponent() // repo root (the-social-wire)
      .appending(component: "apps")
      .appending(component: "web")
      .appending(component: "public")
      .appending(component: "client-metadata.json")
  }

  @Test("Swift scope string stays aligned with web client-metadata.json")
  func parityWithWebGolden() throws {
    let url = try repoPublicClientMetadataURL()
    let data = try Data(contentsOf: url)
    let obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    let webScope = try #require(obj["scope"] as? String)
    #expect(webScope == ATProtoOAuthScopes.scope)
  }
}
