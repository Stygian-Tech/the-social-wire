import { describe, expect, it } from "bun:test";

import {
  latrGatewayErrorForDisplay,
  latrGatewayErrorMessage,
  latrGatewayErrorPresentation,
} from "@/lib/latrGatewayErrors";

describe("latrGatewayErrorMessage", () => {
  it("explains invalid client credentials", () => {
    const message = latrGatewayErrorMessage(403, {
      error: "invalid_client_credential",
      message: "Invalid gateway client credentials",
    });
    expect(message).toContain("LATR_GATEWAY_CLIENT_CREDENTIAL");
  });

  it("explains OAuth client allowlist failures", () => {
    const message = latrGatewayErrorMessage(403, {
      error: "client_forbidden",
      message: "OAuth client not allowed",
    });
    expect(message).toContain("OAUTH_GATEWAY_ALLOWED_CLIENT_IDS");
  });

  it("passes through pds_forbidden messages", () => {
    const message = latrGatewayErrorMessage(403, {
      error: "pds_forbidden",
      message: "Missing com.latr.saved.item scope",
    });
    expect(message).toBe("Missing com.latr.saved.item scope");
  });
});

describe("latrGatewayErrorPresentation", () => {
  it("uses a short headline for client_forbidden", () => {
    const presentation = latrGatewayErrorPresentation(403, {
      error: "client_forbidden",
    });
    expect(presentation.headline).toBe("L@tr gateway blocked this sign-in.");
    expect(presentation.detail).toContain("OAUTH_GATEWAY_ALLOWED_CLIENT_IDS");
  });
});

describe("latrGatewayErrorForDisplay", () => {
  it("maps thrown client_forbidden errors to headline and detail", () => {
    const presentation = latrGatewayErrorForDisplay(
      new Error(
        latrGatewayErrorMessage(403, { error: "client_forbidden" })
      )
    );
    expect(presentation.headline).toBe("L@tr gateway blocked this sign-in.");
    expect(presentation.detail).toBeDefined();
  });
});
