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

  @Test("Swift scope string stays aligned with web client-metadata.json")
  func parityWithWebGolden() throws {
    let url = try repoPublicClientMetadataURL()
    let data = try Data(contentsOf: url)
    let obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    let webScope = try #require(obj["scope"] as? String)
    #expect(webScope == ATProtoOAuthScopes.webScope)
  }

  @Test("Recommend permission is limited to the web client that exposes the action")
  func recommendPermissionIsClientSpecific() {
    let recommend = "repo:site.standard.graph.recommend?action=create&action=delete"
    #expect(ATProtoOAuthScopes.webScope.contains(recommend))
    #expect(!ATProtoOAuthScopes.iosScope.contains(recommend))
  }
}
