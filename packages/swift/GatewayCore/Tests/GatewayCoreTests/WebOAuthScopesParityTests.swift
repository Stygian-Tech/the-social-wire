import Foundation
import Testing

@testable import GatewayCore

@Suite("ATProtoOAuthScopes parity")
struct WebOAuthScopesParityTests {
  private func repoPublicClientMetadataURL() throws -> URL {
    // …/packages/swift/GatewayCore/Tests/GatewayCoreTests/<this file>.swift → repo root
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent() // GatewayCoreTests
      .deletingLastPathComponent() // Tests
      .deletingLastPathComponent() // GatewayCore
      .deletingLastPathComponent() // swift
      .deletingLastPathComponent() // packages
      .deletingLastPathComponent() // repo root (the-social-wire)
      .appending(component: "apps")
      .appending(component: "web")
      .appending(component: "public")
      .appending(component: "client-metadata.json")
  }

  private func repoPublicIosClientMetadataURL() throws -> URL {
    try repoPublicClientMetadataURL()
      .deletingLastPathComponent()
      .appending(component: "ios-client-metadata.json")
  }

  @Test("Swift scope string stays aligned with web client-metadata.json")
  func parityWithWebGolden() throws {
    let url = try repoPublicClientMetadataURL()
    let data = try Data(contentsOf: url)
    let obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    let webScope = try #require(obj["scope"] as? String)
    #expect(webScope == ATProtoOAuthScopes.webScope)
  }

  @Test("Swift iOS scope string stays aligned with public iOS client metadata")
  func parityWithIosGolden() throws {
    let data = try Data(contentsOf: repoPublicIosClientMetadataURL())
    let obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    let iosScope = try #require(obj["scope"] as? String)
    #expect(iosScope == ATProtoOAuthScopes.iosScope)
  }

  @Test("Standard.site social permissions are limited to the web client")
  func standardSiteSocialPermissionsAreClientSpecific() {
    let standardSocial = "include:site.standard.authSocial"
    #expect(ATProtoOAuthScopes.webScope.contains(standardSocial))
    #expect(!ATProtoOAuthScopes.iosScope.contains(standardSocial))
    #expect(ATProtoOAuthScopes.iosScope.contains("repo:site.standard.graph.subscription"))
  }

  @Test("UserInput permissions are limited to the web client that exposes feedback")
  func userInputPermissionsAreClientSpecific() {
    let userInput = "include:app.userinput.authFull"
    #expect(ATProtoOAuthScopes.webScope.contains(userInput))
    #expect(!ATProtoOAuthScopes.iosScope.contains(userInput))
  }

  @Test("Bluesky actions use published application permission sets")
  func blueskyPermissionSets() {
    #expect(ATProtoOAuthScopes.webScope.contains("include:app.bsky.authCreatePosts"))
    #expect(ATProtoOAuthScopes.webScope.contains("include:app.bsky.authDeleteContent"))
    #expect(!ATProtoOAuthScopes.webScope.contains("repo:app.bsky.feed.post?action=create"))
  }
}
