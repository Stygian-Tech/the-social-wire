import Foundation
import Testing

@testable import GatewayCore

@Suite("OperationsOAuthClientMetadata")
struct OperationsOAuthClientMetadataTests {
  @Test("uses public Gateway client ID and protected console callback")
  func buildsIdentityOnlyMetadata() throws {
    let data = try OperationsOAuthClientMetadata.buildJSON(
      publicOrigin: "https://api.testing.thesocialwire.app",
      redirectOrigin: "https://operations.testing.thesocialwire.app"
    )
    let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

    #expect(
      object["client_id"] as? String
        == "https://api.testing.thesocialwire.app/operations-oauth-client-metadata.json"
    )
    #expect(
      object["redirect_uris"] as? [String]
        == ["https://operations.testing.thesocialwire.app/callback"]
    )
    #expect(object["client_uri"] as? String == "https://api.testing.thesocialwire.app")
    #expect(object["scope"] as? String == "atproto")
    #expect(object["client_name"] as? String == "The Social Wire Operations")
  }

  @Test("configured Operations client is accepted by known-client policy")
  func configAllowsOperationsClient() {
    let clientId = "https://api.testing.thesocialwire.app/operations-oauth-client-metadata.json"
    let config = GatewayConfig.fromEnvironment([
      "APP_ENV": "dev",
      "OAUTH_GATEWAY_REQUIRE_KNOWN_CLIENT": "true",
      "OAUTH_OPERATIONS_CLIENT_ID": clientId,
    ])

    #expect(config.oauthGateway.allowedClientIds.contains(clientId))
  }
}
