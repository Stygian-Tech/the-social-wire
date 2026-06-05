import Foundation
import Testing
@testable import Gateway

@Suite("LatrIosProxyCredentials")
struct LatrIosProxyCredentialsTests {
  @Test("returns nil without LATR_IOS_PROXY_URL")
  func missingBaseURL() {
    #expect(LatrIosProxyCredentials.Config.fromEnvironment([:]) == nil)
  }

  @Test("detects split developer credentials from LATR_IOS_PROXY_*")
  func splitCredentials() {
    let config = LatrIosProxyCredentials.Config.fromEnvironment([
      "LATR_IOS_PROXY_URL": "https://api.testing.latr.link",
      "LATR_IOS_PROXY_CLIENT_ID": "the-social-wire-ios",
      "LATR_IOS_PROXY_API_KEY": "api-key",
    ])
    #expect(config?.hasServerCredentials == true)
    #expect(config?.authHeaders()["X-Latr-Client-Id"] == "the-social-wire-ios")
    #expect(config?.authHeaders()["X-Latr-API-Key"] == "api-key")
  }

  @Test("prefers official credential when present")
  func officialCredential() {
    let config = LatrIosProxyCredentials.Config.fromEnvironment([
      "LATR_IOS_PROXY_URL": "https://api.testing.latr.link",
      "LATR_IOS_PROXY_CLIENT_CREDENTIAL": "the-social-wire-ios=secret",
      "LATR_IOS_PROXY_CLIENT_ID": "the-social-wire-ios",
      "LATR_IOS_PROXY_API_KEY": "api-key",
    ])
    #expect(config?.authHeaders()["X-Latr-Official-Client"] == "the-social-wire-ios=secret")
    #expect(config?.authHeaders()["X-Latr-Client-Id"] == nil)
  }

  @Test("accepts deprecated LATR_GATEWAY_* aliases")
  func legacyGatewayAliases() {
    let config = LatrIosProxyCredentials.Config.fromEnvironment([
      "LATR_GATEWAY_URL": "https://api.testing.latr.link",
      "LATR_GATEWAY_CLIENT_ID": "legacy-client",
      "LATR_GATEWAY_API_KEY": "legacy-key",
    ])
    #expect(config?.hasServerCredentials == true)
    #expect(config?.authHeaders()["X-Latr-Client-Id"] == "legacy-client")
  }

  @Test("prefers LATR_IOS_PROXY_* over deprecated LATR_GATEWAY_*")
  func primaryOverridesLegacy() {
    let config = LatrIosProxyCredentials.Config.fromEnvironment([
      "LATR_IOS_PROXY_URL": "https://api.latr.link",
      "LATR_GATEWAY_URL": "https://api.testing.latr.link",
      "LATR_IOS_PROXY_CLIENT_ID": "ios-client",
      "LATR_GATEWAY_CLIENT_ID": "legacy-client",
      "LATR_IOS_PROXY_API_KEY": "ios-key",
      "LATR_GATEWAY_API_KEY": "legacy-key",
    ])
    #expect(config?.baseURL == "https://api.latr.link")
    #expect(config?.authHeaders()["X-Latr-Client-Id"] == "ios-client")
    #expect(config?.authHeaders()["X-Latr-API-Key"] == "ios-key")
  }
}
