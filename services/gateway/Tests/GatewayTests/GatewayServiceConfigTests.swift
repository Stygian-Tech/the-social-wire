import Testing

@testable import Gateway

@Suite("Gateway service configuration")
struct GatewayServiceConfigTests {
  @Test("hosted Gateway requires a shared PDS attestation receipt secret")
  func hostedReceiptSecretIsRequired() {
    #expect(throws: GatewayServiceConfigError.missingPDSAttestationReceiptSecret) {
      _ = try GatewayServiceConfig.fromEnvironment([
        "APP_ENV": "dev",
        "DATABASE_URL": "postgresql://localhost/gateway-test",
      ])
    }
  }

  @Test("PDS attestation receipt secret must contain at least 32 bytes")
  func receiptSecretLengthIsValidated() {
    #expect(throws: GatewayServiceConfigError.invalidPDSAttestationReceiptSecret) {
      _ = try GatewayServiceConfig.fromEnvironment([
        "APP_ENV": "dev",
        "DATABASE_URL": "postgresql://localhost/gateway-test",
        "PDS_ATTESTATION_RECEIPT_SECRET": "too-short",
      ])
    }
  }

  @Test("hosted replicas accept a valid shared PDS attestation receipt secret")
  func validHostedReceiptSecret() throws {
    _ = try GatewayServiceConfig.fromEnvironment([
      "APP_ENV": "dev",
      "DATABASE_URL": "postgresql://localhost/gateway-test",
      "PDS_ATTESTATION_RECEIPT_SECRET": "shared-hosted-attestation-receipt-secret",
    ])
  }

  @Test("Projection Pool readiness origin supersedes the legacy Charybdis variable")
  func projectionPoolReadinessOrigin() throws {
    let config = try GatewayServiceConfig.fromEnvironment([
      "APP_ENV": "dev",
      "DATABASE_URL": "postgresql://localhost/gateway-test",
      "PDS_ATTESTATION_RECEIPT_SECRET": "shared-hosted-attestation-receipt-secret",
      "PROJECTION_POOL_BASE_URL": " http://projection-pool.railway.internal:8080/ ",
      "CHARYBDIS_BASE_URL": "http://charybdis.railway.internal:8082",
    ])

    #expect(config.projectionPoolBaseURL == "http://projection-pool.railway.internal:8080/")
  }

  @Test("legacy Charybdis readiness origin remains a rollout fallback")
  func legacyCharybdisReadinessOrigin() throws {
    let config = try GatewayServiceConfig.fromEnvironment([
      "APP_ENV": "dev",
      "DATABASE_URL": "postgresql://localhost/gateway-test",
      "PDS_ATTESTATION_RECEIPT_SECRET": "shared-hosted-attestation-receipt-secret",
      "CHARYBDIS_BASE_URL": "http://charybdis.railway.internal:8082",
    ])

    #expect(config.projectionPoolBaseURL == "http://charybdis.railway.internal:8082")
  }

  @Test("invalid Wire modes fail closed")
  func invalidWireModeIsRejected() {
    #expect(throws: GatewayServiceConfigError.invalidWireFeedMode("enabled")) {
      _ = try GatewayServiceConfig.fromEnvironment([
        "APP_ENV": "dev",
        "DATABASE_URL": "postgresql://localhost/gateway-test",
        "PDS_ATTESTATION_RECEIPT_SECRET": "shared-hosted-attestation-receipt-secret",
        "WIRE_FEED_MODE": "enabled",
      ])
    }
  }
}
