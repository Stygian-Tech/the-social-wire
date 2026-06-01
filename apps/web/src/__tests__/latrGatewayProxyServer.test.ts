import { afterEach, describe, expect, it } from "bun:test";

import {
  buildLatrGatewayServerAuthHeaders,
  hasLatrGatewayServerCredentials,
  latrGatewayServerCredentialsHelpText,
} from "@/lib/latrGatewayProxyServer";

const originalClientId = process.env.LATR_GATEWAY_CLIENT_ID;
const originalApiKey = process.env.LATR_GATEWAY_API_KEY;
const originalCredential = process.env.LATR_GATEWAY_CLIENT_CREDENTIAL;

afterEach(() => {
  if (originalClientId === undefined) delete process.env.LATR_GATEWAY_CLIENT_ID;
  else process.env.LATR_GATEWAY_CLIENT_ID = originalClientId;
  if (originalApiKey === undefined) delete process.env.LATR_GATEWAY_API_KEY;
  else process.env.LATR_GATEWAY_API_KEY = originalApiKey;
  if (originalCredential === undefined) delete process.env.LATR_GATEWAY_CLIENT_CREDENTIAL;
  else process.env.LATR_GATEWAY_CLIENT_CREDENTIAL = originalCredential;
});

describe("latrGatewayProxyServer", () => {
  it("builds developer auth headers from server env", () => {
    delete process.env.LATR_GATEWAY_CLIENT_CREDENTIAL;
    process.env.LATR_GATEWAY_CLIENT_ID = "the-social-wire-web";
    process.env.LATR_GATEWAY_API_KEY = "lk_test_key";

    expect(hasLatrGatewayServerCredentials()).toBe(true);
    expect(buildLatrGatewayServerAuthHeaders()).toEqual({
      "X-Latr-Client-Id": "the-social-wire-web",
      "X-Latr-API-Key": "lk_test_key",
    });
  });

  it("builds official client auth headers from server env", () => {
    delete process.env.LATR_GATEWAY_CLIENT_ID;
    delete process.env.LATR_GATEWAY_API_KEY;
    process.env.LATR_GATEWAY_CLIENT_CREDENTIAL = "dGVzdA==";

    expect(hasLatrGatewayServerCredentials()).toBe(true);
    expect(buildLatrGatewayServerAuthHeaders()).toEqual({
      "X-Latr-Official-Client": "dGVzdA==",
    });
  });

  it("documents server-side env names", () => {
    expect(latrGatewayServerCredentialsHelpText()).toContain("LATR_GATEWAY_CLIENT_ID");
  });
});
