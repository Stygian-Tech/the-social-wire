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
}
