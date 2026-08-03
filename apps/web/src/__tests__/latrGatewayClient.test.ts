import { afterEach, describe, expect, it, mock } from "bun:test";

import { resetLatrGatewayAuthRejectedForTests } from "@/lib/latrGatewayCredentials";
import {
  LATR_GATEWAY_DPOP_HEADER,
  LATR_CLIENT_ID_HEADER,
  LATR_OFFICIAL_CLIENT_HEADER,
  LATR_UPSTREAM_DPOP_HEADER,
  latrGatewayFetch,
} from "@/lib/latrGatewayClient";
import { LATR_GATEWAY_PROXY_PREFIX } from "@/lib/latrGatewayProxyPath";

const ORIG_FETCH = globalThis.fetch;
const ORIG_LOCATION_DESCRIPTOR = Object.getOwnPropertyDescriptor(
  globalThis,
  "location"
);

afterEach(() => {
  resetLatrGatewayAuthRejectedForTests();
  globalThis.fetch = ORIG_FETCH;
  if (ORIG_LOCATION_DESCRIPTOR) {
    Object.defineProperty(globalThis, "location", ORIG_LOCATION_DESCRIPTOR);
  } else {
    delete (globalThis as { location?: Location }).location;
  }
});

describe("latrGatewayFetch", () => {
  it("calls the same-origin proxy and splits proxy and upstream L@tr DPoP proofs", async () => {
    Object.defineProperty(globalThis, "location", {
      configurable: true,
      value: new URL("https://testing.thesocialwire.app/saved"),
    });
    const dpopClaims: Array<Record<string, string | number>> = [];

    const fetchMock = mock(async (url: string, init?: RequestInit) => {
      if (url.startsWith("https://jellybaby.us-east.host.bsky.network/xrpc/")) {
        expect(url).toContain("/xrpc/com.atproto.repo.listRecords?");
        return new Response(JSON.stringify({ records: [] }), {
          status: 200,
          headers: { "DPoP-Nonce": "pds-nonce" },
        });
      }

      expect(url).toBe(`${LATR_GATEWAY_PROXY_PREFIX}/v1/latr/og-preview?url=https://example.com`);
      const headers = new Headers(init?.headers);
      expect(headers.get("Authorization")).toBe("DPoP access-token");
      expect(headers.get("DPoP")).toBe("same-origin-dpop-proof");
      expect(headers.get(LATR_GATEWAY_DPOP_HEADER)).toBe("latr-dpop-proof");
      expect(headers.get(LATR_UPSTREAM_DPOP_HEADER)).toBe(
        "pds-session-attestation-proof"
      );
      expect(headers.get(LATR_CLIENT_ID_HEADER)).toBeNull();
      expect(headers.get(LATR_OFFICIAL_CLIENT_HEADER)).toBeNull();
      return new Response(JSON.stringify({ ok: true }), { status: 200 });
    });
    globalThis.fetch = fetchMock as unknown as typeof fetch;

    const oauthSession = {
      getTokenSet: async () => ({
        access_token: "access-token",
        token_type: "DPoP",
      }),
      getTokenInfo: async () => ({
        aud: "https://jellybaby.us-east.host.bsky.network",
      }),
      fetchHandler: fetchMock as unknown as typeof fetch,
      server: {
        dpopKey: {
          bareJwk: { kty: "EC", crv: "P-256", x: "x", y: "y" },
          algorithms: ["ES256"],
          createJwt: async (_header: unknown, claims: Record<string, string | number>) => {
            dpopClaims.push(claims);
            if (
              claims.htu ===
              "https://jellybaby.us-east.host.bsky.network/xrpc/com.atproto.server.getSession"
            ) {
              return "pds-session-attestation-proof";
            }
            return String(claims.htu).startsWith("https://api.testing.latr.link/")
              ? "latr-dpop-proof"
              : "same-origin-dpop-proof";
          },
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
    expect(fetchMock).toHaveBeenCalledTimes(2);
    expect(dpopClaims[0]?.htm).toBe("GET");
    expect(dpopClaims[0]?.htu).toBe(
      "https://testing.thesocialwire.app/api/latr-gateway/v1/latr/og-preview"
    );
    expect(dpopClaims[0]?.ath).toBeTruthy();
    expect(dpopClaims[1]?.htm).toBe("GET");
    expect(dpopClaims[1]?.htu).toBe(
      "https://api.testing.latr.link/v1/latr/og-preview"
    );
    expect(dpopClaims[1]?.ath).toBeTruthy();
    expect(dpopClaims[2]?.htm).toBe("GET");
    expect(dpopClaims[2]?.htu).toBe(
      "https://jellybaby.us-east.host.bsky.network/xrpc/com.atproto.server.getSession"
    );
    expect(dpopClaims[2]?.nonce).toBe("pds-nonce");
    expect(dpopClaims[2]?.ath).toBeTruthy();
  });

  it("retries once when the proxy returns a DPoP nonce challenge", async () => {
    Object.defineProperty(globalThis, "location", {
      configurable: true,
      value: new URL("https://testing.thesocialwire.app/saved"),
    });
    let proxyCalls = 0;
    let nonceCounter = 0;
    const gatewayNonces = new Map<string, string>();
    const dpopClaims: Array<Record<string, string | number>> = [];

    const fetchMock = mock(async (...args: Parameters<typeof fetch>) => {
      const [url] = args;
      if (String(url).includes("/v1/latr/saves")) {
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
    globalThis.fetch = fetchMock as unknown as typeof fetch;

    const oauthSession = {
      getTokenSet: async () => ({
        access_token: "access-token",
        token_type: "DPoP",
      }),
      getTokenInfo: async () => ({ aud: "https://jellybaby.us-east.host.bsky.network" }),
      fetchHandler: fetchMock as unknown as typeof fetch,
      server: {
        dpopNonces: {
          get: async (origin: string) => gatewayNonces.get(origin),
          set: async (origin: string, nonce: string) => {
            gatewayNonces.set(origin, nonce);
          },
        },
        dpopKey: {
          bareJwk: { kty: "EC", crv: "P-256", x: "x", y: "y" },
          algorithms: ["ES256"],
          createJwt: async (_header: unknown, claims: Record<string, string | number>) => {
            dpopClaims.push(claims);
            return "gateway-dpop-proof";
          },
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
    // Each request gets two createRecord and two putRecord proofs, including the retry.
    expect(nonceCounter).toBe(8);

    const saveCall = fetchMock.mock.calls.find(([url]) =>
      String(url).includes("/v1/latr/saves")
    );
    expect(saveCall).toBeDefined();
    const saveHeaders = new Headers(saveCall?.[1]?.headers);
    expect(saveHeaders.get(LATR_UPSTREAM_DPOP_HEADER)).toBeTruthy();
    expect(gatewayNonces.get("https://testing.thesocialwire.app")).toBeUndefined();
    expect(gatewayNonces.get("https://api.testing.latr.link")).toBe(
      "fresh-nonce"
    );
    const latrBoundClaims = dpopClaims.filter((claims) =>
      String(claims.htu).startsWith("https://api.testing.latr.link/")
    );
    expect(latrBoundClaims[0]?.htu).toBe("https://api.testing.latr.link/v1/latr/saves");
    expect(latrBoundClaims[0]?.nonce).toBeUndefined();
    expect(latrBoundClaims[1]?.nonce).toBe("fresh-nonce");
  });

  it("signs GET saves with a PDS-bound proof pool for paginated listRecords", async () => {
    Object.defineProperty(globalThis, "location", {
      configurable: true,
      value: new URL("https://testing.thesocialwire.app/saved"),
    });
    const dpopClaims: Array<Record<string, string | number>> = [];
    let pdsNonceCounter = 0;

    const fetchMock = mock(async (_url: string, init?: RequestInit) => {
      const headers = new Headers(init?.headers);
      expect(headers.get(LATR_UPSTREAM_DPOP_HEADER)?.split(",")).toHaveLength(8);
      return new Response(JSON.stringify({ records: [] }), { status: 200 });
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
      fetchHandler: async () => {
        pdsNonceCounter += 1;
        return new Response(JSON.stringify({ records: [] }), {
          status: 200,
          headers: { "DPoP-Nonce": `pds-nonce-${pdsNonceCounter}` },
        });
      },
      server: {
        dpopKey: {
          bareJwk: { kty: "EC", crv: "P-256", x: "x", y: "y" },
          algorithms: ["ES256"],
          createJwt: async (_header: unknown, claims: Record<string, string | number>) => {
            dpopClaims.push(claims);
            return String(claims.htu).endsWith("/xrpc/com.atproto.repo.listRecords")
              ? "list-records-proof"
              : "latr-dpop-proof";
          },
        },
        dpopNonces: {
          get: async () => undefined,
          set: async () => {},
        },
        serverMetadata: { dpop_signing_alg_values_supported: ["ES256"] },
      },
    } as never;

    await latrGatewayFetch(oauthSession, "/v1/latr/saves", { method: "GET" });

    const upstreamClaims = dpopClaims.filter((claims) =>
      String(claims.htu).endsWith("/xrpc/com.atproto.repo.listRecords")
    );
    expect(upstreamClaims).toHaveLength(8);
    expect(
      upstreamClaims.every(
        (claims) =>
          claims.htm === "GET" &&
          claims.htu ===
            "https://jellybaby.us-east.host.bsky.network/xrpc/com.atproto.repo.listRecords"
      )
    ).toBe(true);
    expect(new Set(upstreamClaims.map((claims) => claims.nonce)).size).toBe(8);
  });
});
