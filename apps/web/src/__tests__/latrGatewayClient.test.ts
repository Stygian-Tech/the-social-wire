import { afterEach, describe, expect, it, mock } from "bun:test";

import {
  LATR_OFFICIAL_CLIENT_HEADER,
  latrGatewayFetch,
} from "@/lib/latrGatewayClient";

const originalCredential = process.env.NEXT_PUBLIC_LATR_GATEWAY_CLIENT_CREDENTIAL;

afterEach(() => {
  if (originalCredential === undefined) {
    delete process.env.NEXT_PUBLIC_LATR_GATEWAY_CLIENT_CREDENTIAL;
  } else {
    process.env.NEXT_PUBLIC_LATR_GATEWAY_CLIENT_CREDENTIAL = originalCredential;
  }
});

describe("latrGatewayFetch", () => {
  it("sends official client credential header when configured", async () => {
    process.env.NEXT_PUBLIC_LATR_GATEWAY_CLIENT_CREDENTIAL = "dGVzdC1zb2NpYWwtd2lyZQ==";

    const fetchHandler = mock(async (_url: string, init?: RequestInit) => {
      const headers = new Headers(init?.headers);
      expect(headers.get(LATR_OFFICIAL_CLIENT_HEADER)).toBe(
        "dGVzdC1zb2NpYWwtd2lyZQ=="
      );
      return new Response(JSON.stringify({ ok: true }), { status: 200 });
    });

    const oauthSession = { fetchHandler } as never;

    await latrGatewayFetch(oauthSession, "/v1/latr/og-preview?url=https://example.com", {
      method: "GET",
    });
    expect(fetchHandler).toHaveBeenCalledTimes(1);
  });

  it("retries once when the gateway returns a DPoP nonce challenge", async () => {
    const fetchHandler = mock(async () => {
      if (fetchHandler.mock.calls.length === 1) {
        return new Response(JSON.stringify({ error: "Unauthorized" }), {
          status: 401,
          headers: { "DPoP-Nonce": "fresh-nonce" },
        });
      }
      return new Response(JSON.stringify({ ok: true }), { status: 200 });
    });

    const oauthSession = {
      fetchHandler,
      getTokenInfo: async () => ({ aud: "https://jellybaby.us-east.host.bsky.network" }),
      getTokenSet: async () => ({ access_token: "access-token" }),
      server: {
        dpopKey: {
          bareJwk: { kty: "EC", crv: "P-256", x: "x", y: "y" },
          algorithms: ["ES256"],
          createJwt: async () => "upstream-proof",
        },
        serverMetadata: { dpop_signing_alg_values_supported: ["ES256"] },
      },
    } as never;

    const res = await latrGatewayFetch(oauthSession, "/v1/latr/saves", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ kind: "subject", subjectUri: "at://did/entry" }),
    });

    expect(res.status).toBe(200);
    expect(fetchHandler).toHaveBeenCalledTimes(2);
  });
});
