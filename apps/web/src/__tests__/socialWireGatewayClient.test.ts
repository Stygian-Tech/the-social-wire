import { afterEach, beforeEach, describe, expect, it, mock } from "bun:test";
import { onOAuthSessionInvalidated } from "@/lib/auth";

const ORIG_ENV = { ...process.env };
const ORIG_FETCH = globalThis.fetch;

beforeEach(() => {
  process.env.NEXT_PUBLIC_SOCIALWIRE_API_URL = "https://api.testing.thesocialwire.app";
});

afterEach(() => {
  process.env = { ...ORIG_ENV };
  globalThis.fetch = ORIG_FETCH;
  mock.restore();
});

describe("gatewayFetch", () => {
  it("signs Social Wire gateway requests with Authorization and DPoP for the gateway URL", async () => {
    let dpopClaims: Record<string, string | number> | undefined;
    const fetchMock = mock(async (url: string, init?: RequestInit) => {
      expect(url).toBe(
        "https://api.testing.thesocialwire.app/xrpc/app.thesocialwire.appview.listEntries?authorDid=did%3Aplc%3Aalice"
      );
      const headers = new Headers(init?.headers);
      expect(headers.get("Authorization")).toBe("DPoP access-token");
      expect(headers.get("DPoP")).toBe("gateway-dpop-proof");
      expect(headers.get("Accept")).toBe("application/json");
      return new Response(JSON.stringify({ entries: [] }), { status: 200 });
    });
    globalThis.fetch = fetchMock as unknown as typeof fetch;

    const oauthSession = {
      did: "did:plc:viewer",
      getTokenSet: async () => ({
        access_token: "access-token",
        token_type: "DPoP",
      }),
      getTokenInfo: async () => ({
        aud: "https://jellybaby.us-east.host.bsky.network",
      }),
      fetchHandler: async () =>
        new Response(JSON.stringify({ records: [] }), {
          status: 200,
          headers: { "DPoP-Nonce": "fresh-pds-nonce" },
        }),
      server: {
        dpopKey: {
          bareJwk: { kty: "EC", crv: "P-256", x: "x", y: "y" },
          algorithms: ["ES256"],
          createJwt: async (_header: unknown, claims: Record<string, string | number>) => {
            dpopClaims = claims;
            return "gateway-dpop-proof";
          },
        },
        dpopNonces: {
          get: async () => undefined,
          set: async () => {},
        },
        serverMetadata: { dpop_signing_alg_values_supported: ["ES256"] },
      },
    } as never;

    const { gatewayFetch } = await import("@/lib/socialWireGatewayClient");
    const res = await gatewayFetch(
      oauthSession,
      "/xrpc/app.thesocialwire.appview.listEntries?authorDid=did%3Aplc%3Aalice"
    );

    expect(res.status).toBe(200);
    expect(fetchMock).toHaveBeenCalledTimes(1);
    expect(dpopClaims?.htm).toBe("GET");
    expect(dpopClaims?.htu).toBe(
      "https://api.testing.thesocialwire.app/xrpc/app.thesocialwire.appview.listEntries"
    );
    expect(dpopClaims?.ath).toBeTruthy();
  });

  it("retries once with the received DPoP nonce", async () => {
    const gatewayNonces = new Map<string, string>();
    const gatewayDpopHeaders: string[] = [];
    let calls = 0;
    const fetchMock = mock(async (_url: string, init?: RequestInit) => {
      gatewayDpopHeaders.push(new Headers(init?.headers).get("DPoP") ?? "");
      calls += 1;
      if (calls === 1) {
        return new Response(JSON.stringify({ error: "use_dpop_nonce" }), {
          status: 401,
          headers: { "DPoP-Nonce": "fresh-gateway-nonce" },
        });
      }
      return new Response(JSON.stringify({ ok: true }), { status: 200 });
    });
    globalThis.fetch = fetchMock as unknown as typeof fetch;

    const oauthSession = {
      did: "did:plc:viewer",
      getTokenSet: async () => ({
        access_token: "access-token",
        token_type: "DPoP",
      }),
      getTokenInfo: async () => ({
        aud: "https://jellybaby.us-east.host.bsky.network",
      }),
      fetchHandler: async () =>
        new Response(JSON.stringify({ records: [] }), {
          status: 200,
          headers: { "DPoP-Nonce": "fresh-pds-nonce" },
        }),
      server: {
        dpopKey: {
          bareJwk: { kty: "EC", crv: "P-256", x: "x", y: "y" },
          algorithms: ["ES256"],
          createJwt: async (_header: unknown, claims: Record<string, string | number>) => {
            return claims.nonce
              ? `gateway-dpop-proof:${claims.nonce}`
              : "gateway-dpop-proof";
          },
        },
        dpopNonces: {
          get: async (origin: string) => gatewayNonces.get(origin),
          set: async (origin: string, nonce: string) => {
            gatewayNonces.set(origin, nonce);
          },
        },
        serverMetadata: { dpop_signing_alg_values_supported: ["ES256"] },
      },
    } as never;

    const { gatewayFetch } = await import("@/lib/socialWireGatewayClient");
    const res = await gatewayFetch(oauthSession, "/v1/appview/bootstrap-stream");

    expect(res.status).toBe(200);
    expect(fetchMock).toHaveBeenCalledTimes(2);
    expect(gatewayNonces.get("https://api.testing.thesocialwire.app")).toBe(
      "fresh-gateway-nonce"
    );
    expect(gatewayDpopHeaders).toEqual([
      "gateway-dpop-proof",
      "gateway-dpop-proof:fresh-gateway-nonce",
    ]);
  });

  it("serializes concurrent manually-signed requests so each sees the prior response's nonce", async () => {
    const gatewayNonces = new Map<string, string>();
    const nonceClaimsSeen: (string | undefined)[] = [];
    let calls = 0;
    const fetchMock = mock(async () => {
      calls += 1;
      const call = calls;
      return new Response(JSON.stringify({ ok: true, call }), {
        status: 200,
        headers: { "DPoP-Nonce": `nonce-${call}` },
      });
    });
    globalThis.fetch = fetchMock as unknown as typeof fetch;

    const oauthSession = {
      did: "did:plc:viewer",
      getTokenSet: async () => ({
        access_token: "access-token",
        token_type: "DPoP",
      }),
      getTokenInfo: async () => ({ aud: "https://pds.example" }),
      fetchHandler: async () =>
        new Response(JSON.stringify({ records: [] }), { status: 200 }),
      server: {
        dpopKey: {
          bareJwk: { kty: "EC", crv: "P-256", x: "x", y: "y" },
          algorithms: ["ES256"],
          createJwt: async (
            _header: unknown,
            claims: Record<string, string | number>
          ) => {
            nonceClaimsSeen.push(claims.nonce as string | undefined);
            return "gateway-dpop-proof";
          },
        },
        dpopNonces: {
          get: async (origin: string) => gatewayNonces.get(origin),
          set: async (origin: string, nonce: string) => {
            gatewayNonces.set(origin, nonce);
          },
        },
        serverMetadata: { dpop_signing_alg_values_supported: ["ES256"] },
      },
    } as never;

    const { gatewayFetch } = await import("@/lib/socialWireGatewayClient");
    await Promise.all([
      gatewayFetch(oauthSession, "/xrpc/app.thesocialwire.appview.putReadMark", { method: "POST" }),
      gatewayFetch(oauthSession, "/xrpc/app.thesocialwire.appview.putReadMark", { method: "POST" }),
      gatewayFetch(oauthSession, "/xrpc/app.thesocialwire.appview.putReadMark", { method: "POST" }),
    ]);

    expect(fetchMock).toHaveBeenCalledTimes(3);
    // Each request after the first observes the nonce the prior response minted —
    // none of them race on a stale/missing nonce.
    expect(nonceClaimsSeen).toEqual([undefined, "nonce-1", "nonce-2"]);
  });

  it("invalidates the session after a final gateway 401", async () => {
    globalThis.fetch = mock(async () =>
      new Response(JSON.stringify({ error: "invalid_token" }), { status: 401 })
    ) as unknown as typeof fetch;
    const invalidations: string[] = [];
    const unsubscribe = onOAuthSessionInvalidated((did) => {
      invalidations.push(did);
    });
    const oauthSession = {
      did: "did:plc:viewer",
      getTokenSet: async () => ({
        access_token: "expired-access-token",
        token_type: "DPoP",
      }),
      getTokenInfo: async () => ({ aud: "https://pds.example" }),
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

    try {
      const { gatewayFetch } = await import("@/lib/socialWireGatewayClient");
      const response = await gatewayFetch(
        oauthSession,
        "/xrpc/app.thesocialwire.appview.listEntries",
      );

      expect(response.status).toBe(401);
      expect(invalidations).toEqual(["did:plc:viewer"]);
    } finally {
      unsubscribe();
    }
  });
});
