import GatewayCore
import HTTPTypes
import Hummingbird
import HummingbirdTesting
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

  @Test("Operations origin is always allowed")
  func operationsOrigin() {
    let config = GatewayConfig.fromEnvironment([
      "APP_ENV": "dev",
      "OAUTH_OPERATIONS_ORIGIN": "https://operations.testing.thesocialwire.app",
    ])
    let origins = GatewayCORSPolicy.allowedOrigins(
      config: config,
      env: ["CORS_ALLOWED_ORIGINS": "https://testing.thesocialwire.app"]
    )
    #expect(origins == [
      "https://operations.testing.thesocialwire.app",
      "https://testing.thesocialwire.app",
    ])
  }

  @Test("session attestation request headers are allowed and response headers are exposed")
  func sessionAttestationHeaders() async throws {
    let config = GatewayConfig.fromEnvironment([
      "APP_ENV": "dev",
      "OAUTH_PUBLIC_ORIGIN": "https://testing.thesocialwire.app",
    ])
    let router = Router(context: GatewayRequestContext.self)
    router.add(middleware: GatewayCORSPolicy.middleware(config: config, env: [:]))
    router.get("/protected") { _, _ in
      var headers = HTTPFields()
      headers[HTTPField.Name(ATProtoSessionDPoP.nonceHeaderName)!] = "pds-nonce"
      return Response(status: .ok, headers: headers)
    }
    let app = Application(
      router: router,
      configuration: .init(address: .hostname("127.0.0.1", port: 0))
    )
    let headers: HTTPFields = {
      var headers = HTTPFields()
      headers[.origin] = "https://testing.thesocialwire.app"
      return headers
    }()
    let response = try await app.test(.live) { client in
      try await client.execute(uri: "/protected", method: .get, headers: headers)
    }
    #expect(
      response.headers[.accessControlExposeHeaders]?
        .contains(ATProtoSessionDPoP.nonceHeaderName) == true
    )
    #expect(
      response.headers[HTTPField.Name(ATProtoSessionDPoP.nonceHeaderName)!] == "pds-nonce"
    )
    for headerName in [
      ATProtoSessionAttestationReceipt.receiptHeaderName,
      ATProtoSessionAttestationReceipt.requiredHeaderName,
      ATProtoSessionAttestationReceipt.upstreamPreparedHeaderName,
    ] {
      #expect(response.headers[.accessControlExposeHeaders]?.contains(headerName) == true)
    }

    let preflightHeaders: HTTPFields = {
      var headers = HTTPFields()
      headers[.origin] = "https://testing.thesocialwire.app"
      headers[.accessControlRequestMethod] = "POST"
      headers[.accessControlRequestHeaders] = [
        ATProtoSessionAttestationReceipt.receiptHeaderName,
        ATProtoSessionAttestationReceipt.requiredHeaderName,
        ATProtoSessionAttestationReceipt.upstreamPreparedHeaderName,
      ].joined(separator: ", ")
      return headers
    }()
    let preflight = try await app.test(.live) { client in
      try await client.execute(uri: "/protected", method: .options, headers: preflightHeaders)
    }
    for headerName in [
      ATProtoSessionAttestationReceipt.receiptHeaderName,
      ATProtoSessionAttestationReceipt.requiredHeaderName,
      ATProtoSessionAttestationReceipt.upstreamPreparedHeaderName,
    ] {
      #expect(
        preflight.headers[.accessControlAllowHeaders]?
          .lowercased().contains(headerName.lowercased()) == true
      )
    }
  }
}
