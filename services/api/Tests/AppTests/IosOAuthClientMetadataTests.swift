import Foundation
import Testing

@testable import App

@Suite("IosOAuthClientMetadata")
struct IosOAuthClientMetadataTests {
  @Test("native URL scheme reverses host labels")
  func nativeScheme() {
    #expect(IosOAuthClientMetadata.nativeURLScheme(host: "thesocialwire.app") == "app.thesocialwire")
    #expect(IosOAuthClientMetadata.nativeURLScheme(host: "app.example.com") == "com.example.app")
  }

  @Test("buildJSON encodes client_id and redirect_uris for origin")
  func buildJSONShape() throws {
    let data = try IosOAuthClientMetadata.buildJSON(publicOrigin: "https://example.com")
    let obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(obj["client_id"] as? String == "https://example.com/ios-client-metadata.json")
    let redirects = try #require(obj["redirect_uris"] as? [String])
    #expect(redirects == ["com.example:/oauth/callback"])
    #expect(obj["application_type"] as? String == "native")
    #expect(obj["dpop_bound_access_tokens"] as? Bool == true)
  }

  @Test("buildJSON can anchor client_id on API host while redirect uses branded native host")
  func buildJSONWithNativeRedirectOverride() throws {
    let data = try IosOAuthClientMetadata.buildJSON(
      publicOrigin: "https://api.example.com",
      nativeRedirectHost: "thesocialwire.app"
    )
    let obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(obj["client_id"] as? String == "https://api.example.com/ios-client-metadata.json")
    let redirects = try #require(obj["redirect_uris"] as? [String])
    #expect(redirects == ["app.thesocialwire:/oauth/callback"])
  }

  @Test("buildJSON includes port in client_id when present in origin")
  func buildJSONWithPort() throws {
    let data = try IosOAuthClientMetadata.buildJSON(publicOrigin: "http://127.0.0.1:8090")
    let obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(obj["client_id"] as? String == "http://127.0.0.1:8090/ios-client-metadata.json")
    let redirects = try #require(obj["redirect_uris"] as? [String])
    #expect(redirects.first == "1.0.0.127:/oauth/callback")
  }
}
