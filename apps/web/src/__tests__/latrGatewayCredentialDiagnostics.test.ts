import { afterEach, describe, expect, it, mock } from "bun:test";

import {
  buildLatrGatewayCredentialDiagnostics,
  interpretProbeResponse,
  probeLatrGatewayServerCredentials,
} from "@/lib/latrGatewayCredentialDiagnostics";

const ORIG_FETCH = globalThis.fetch;

afterEach(() => {
  globalThis.fetch = ORIG_FETCH;
  delete process.env.LATR_GATEWAY_CLIENT_ID;
  delete process.env.LATR_GATEWAY_API_KEY;
  delete process.env.LATR_GATEWAY_CLIENT_CREDENTIAL;
});

describe("interpretProbeResponse", () => {
  it("treats missing_auth as successful app credential validation", () => {
    const probe = interpretProbeResponse(401, {
      error: "missing_auth",
      message: "Missing Authorization header",
    });
    expect(probe.ok).toBe(true);
    expect(probe.code).toBe("missing_auth");
  });

  it("treats invalid_client_credential as failure", () => {
    const probe = interpretProbeResponse(403, {
      error: "invalid_client_credential",
      message: "Invalid gateway client credentials",
    });
    expect(probe.ok).toBe(false);
  });
});

describe("buildLatrGatewayCredentialDiagnostics", () => {
  it("reports split developer auth mode without exposing api key", async () => {
    process.env.LATR_GATEWAY_CLIENT_ID = "the-social-wire-web";
    process.env.LATR_GATEWAY_API_KEY = "lk_test_secret_key";

    globalThis.fetch = mock(async () =>
      new Response(
        JSON.stringify({ error: "missing_auth", message: "Missing Authorization header" }),
        { status: 401 }
      )
    ) as unknown as typeof fetch;

    const diagnostics = await buildLatrGatewayCredentialDiagnostics();
    expect(diagnostics.authMode).toBe("split-developer");
    expect(diagnostics.clientId).toBe("the-social-wire-web");
    expect(diagnostics.apiKeyHint).toBe("lk_test…_key");
    expect(diagnostics.probe.ok).toBe(true);
  });

  it("warns when split and official env vars are both configured", async () => {
    process.env.LATR_GATEWAY_CLIENT_ID = "the-social-wire-web";
    process.env.LATR_GATEWAY_API_KEY = "lk_test_secret_key";
    process.env.LATR_GATEWAY_CLIENT_CREDENTIAL = "dGVzdA==";

    globalThis.fetch = mock(async () =>
      new Response(JSON.stringify({ error: "missing_auth" }), { status: 401 })
    ) as unknown as typeof fetch;

    const diagnostics = await buildLatrGatewayCredentialDiagnostics();
    expect(diagnostics.authMode).toBe("official-client");
    expect(
      diagnostics.warnings.some((warning) =>
        warning.includes("official credential takes precedence")
      )
    ).toBe(true);
  });
});

describe("probeLatrGatewayServerCredentials", () => {
  it("returns missing_env when credentials are absent", async () => {
    const probe = await probeLatrGatewayServerCredentials();
    expect(probe.ok).toBe(false);
    expect(probe.code).toBe("missing_env");
  });
});
