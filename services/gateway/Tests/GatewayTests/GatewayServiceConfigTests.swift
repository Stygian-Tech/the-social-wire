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
