import GatewayCore
import Testing

@Suite("Gateway CORS policy")
struct GatewayCORSPolicyTests {
  @Test("allowed origins fall back to OAUTH_PUBLIC_ORIGIN")
  func allowedOriginsFromOAuthPublicOrigin() {
    let config = GatewayConfig.fromEnvironment([
      "APP_ENV": "dev",
      "OAUTH_PUBLIC_ORIGIN": "https://testing.thesocialwire.app",
    ])
    let origins = GatewayCORSPolicy.allowedOrigins(config: config, env: [:])
    #expect(origins == ["https://testing.thesocialwire.app"])
  }

  @Test("local env adds loopback dev origins")
  func localLoopbackOrigins() {
    let config = GatewayConfig.fromEnvironment([
      "APP_ENV": "local",
      "OAUTH_PUBLIC_ORIGIN": "https://testing.thesocialwire.app",
    ])
    let origins = GatewayCORSPolicy.allowedOrigins(config: config, env: [:])
    #expect(origins.contains("https://testing.thesocialwire.app"))
    #expect(origins.contains("http://localhost:3000"))
    #expect(origins.contains("http://127.0.0.1:3000"))
  }

  @Test("CORS_ALLOWED_ORIGINS overrides oauth public origin")
  func explicitAllowedOrigins() {
    let config = GatewayConfig.fromEnvironment([
      "APP_ENV": "dev",
      "OAUTH_PUBLIC_ORIGIN": "https://testing.thesocialwire.app",
    ])
    let origins = GatewayCORSPolicy.allowedOrigins(
      config: config,
      env: ["CORS_ALLOWED_ORIGINS": "https://preview.example.test"]
    )
    #expect(origins == ["https://preview.example.test"])
  }
}
