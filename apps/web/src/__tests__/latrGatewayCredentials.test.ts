import { afterEach, describe, expect, it } from "bun:test";

import {
  isLatrGatewayAuthRejected,
  isLatrGatewayInvalidClientCredentialResponse,
  latrGatewayCredentialsHelpText,
  markLatrGatewayAuthRejected,
  resetLatrGatewayAuthRejectedForTests,
} from "@/lib/latrGatewayCredentials";

afterEach(() => {
  resetLatrGatewayAuthRejectedForTests();
});

describe("latrGatewayCredentials", () => {
  it("recognizes invalid client credential responses", () => {
    expect(
      isLatrGatewayInvalidClientCredentialResponse(403, {
        error: "invalid_client_credential",
        message: "Invalid gateway client credentials",
      })
    ).toBe(true);
    expect(
      isLatrGatewayInvalidClientCredentialResponse(503, {
        error: "missing_client_credential",
      })
    ).toBe(true);
    expect(isLatrGatewayInvalidClientCredentialResponse(401, {})).toBe(false);
  });

  it("marks auth rejected for circuit breaker", () => {
    markLatrGatewayAuthRejected();
    expect(isLatrGatewayAuthRejected()).toBe(true);
  });

  it("documents server-side credential configuration", () => {
    expect(latrGatewayCredentialsHelpText()).toContain("LATR_GATEWAY_CLIENT_ID");
  });
});
