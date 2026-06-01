import { afterEach, describe, expect, it, mock } from "bun:test";

import { resetLatrGatewayAuthRejectedForTests } from "@/lib/latrGatewayCredentials";
import {
  LATR_CLIENT_ID_HEADER,
  LATR_OFFICIAL_CLIENT_HEADER,
  LATR_UPSTREAM_DPOP_HEADER,
  latrGatewayFetch,
} from "@/lib/latrGatewayClient";
import { LATR_GATEWAY_PROXY_PREFIX } from "@/lib/latrGatewayProxyPath";

afterEach(() => {
  resetLatrGatewayAuthRejectedForTests();
});

describe("latrGatewayFetch", () => {
  it("calls the same-origin proxy without client credential headers", async () => {
    const fetchMock = mock(async (url: string, init?: RequestInit) => {
      expect(url).toBe(`${LATR_GATEWAY_PROXY_PREFIX}/v1/latr/og-preview?url=https://example.com`);
      const headers = new Headers(init?.headers);
      expect(headers.get("Authorization")).toBe("DPoP access-token");
      expect(headers.get("DPoP")).toBe("gateway-dpop-proof");
      expect(headers.get(LATR_CLIENT_ID_HEADER)).toBeNull();
      expect(headers.get(LATR_OFFICIAL_CLIENT_HEADER)).toBeNull();
      return new Response(JSON.stringify({ ok: true }), { status: 200 });
    });
    globalThis.fetch = fetchMock as typeof fetch;

    const oauthSession = {
      getTokenSet: async () => ({
        access_token: "access-token",
        token_type: "DPoP",
      }),
      server: {
        dpopKey: {
          bareJwk: { kty: "EC", crv: "P-256", x: "x", y: "y" },
          algorithms: ["ES256"],
          createJwt: async () => "gateway-dpop-proof",
        },
        dpopNonces: {
          get: async () => undefined,
          set: async () => {},
        },
        serverMetadata: { dpop_signing_alg_values_supported: ["ES256"] },
      },
    } as never;

    await latrGatewayFetch(oauthSession, "/v1/latr/og-preview?url=https://example.com", {
      method: "GET",
    });
    expect(fetchMock).toHaveBeenCalledTimes(1);
  });

  it("retries once when the proxy returns a DPoP nonce challenge", async () => {
    let proxyCalls = 0;
    let nonceCounter = 0;

    const fetchMock = mock(async (url: string, init?: RequestInit) => {
      if (url.includes("/v1/latr/saves")) {
        proxyCalls += 1;
        if (proxyCalls === 1) {
          return new Response(JSON.stringify({ error: "Unauthorized" }), {
            status: 401,
            headers: { "DPoP-Nonce": "fresh-nonce" },
          });
        }
        return new Response(JSON.stringify({ ok: true }), { status: 200 });
      }

      nonceCounter += 1;
      return new Response(JSON.stringify({ error: "Use DPoP nonce" }), {
        status: 400,
        headers: { "DPoP-Nonce": `pds-nonce-${nonceCounter}` },
      });
    });
    globalThis.fetch = fetchMock as typeof fetch;

    const oauthSession = {
      getTokenSet: async () => ({
        access_token: "access-token",
        token_type: "DPoP",
      }),
      getTokenInfo: async () => ({ aud: "https://jellybaby.us-east.host.bsky.network" }),
      fetchHandler: fetchMock,
      server: {
        dpopNonces: {
          get: async () => undefined,
          set: async () => {},
        },
        dpopKey: {
          bareJwk: { kty: "EC", crv: "P-256", x: "x", y: "y" },
          algorithms: ["ES256"],
          createJwt: async () => "gateway-dpop-proof",
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
    expect(proxyCalls).toBe(2);
    expect(nonceCounter).toBe(6);

    const saveCall = fetchMock.mock.calls.find(([url]) =>
      String(url).includes("/v1/latr/saves")
    );
    expect(saveCall).toBeDefined();
    const saveHeaders = new Headers(saveCall?.[1]?.headers);
    expect(saveHeaders.get(LATR_UPSTREAM_DPOP_HEADER)).toBeTruthy();
  });
});
