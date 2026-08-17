import { afterEach, beforeEach, describe, expect, it, mock } from "bun:test";
import { TokenRefreshError } from "@atproto/oauth-client-browser";
import { onOAuthSessionInvalidated } from "@/lib/auth";
import {
  createPdsSessionAttestationProof,
  PDS_SESSION_ATTESTATION_RECEIPT_HEADER,
  PDS_SESSION_ATTESTATION_REQUIRED_HEADER,
  PDS_SESSION_DPOP_HEADER,
  PDS_SESSION_DPOP_NONCE_HEADER,
} from "@/lib/pdsSessionAttestation";
import { LATR_UPSTREAM_DPOP_HEADER } from "latr-packages/gateway-client";

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
  it("fails closed on an advertised DPoP algorithm mismatch and accepts a matching algorithm", async () => {
    const jwtHeaders: Array<Record<string, unknown>> = [];
    const supportedAlgorithms = ["PS256"];
    const oauthSession = {
      did: "did:plc:viewer",
      getTokenSet: async () => ({ access_token: "access-token", token_type: "DPoP" }),
      getTokenInfo: async () => ({ aud: "https://pds.example" }),
      server: {
        dpopKey: {
          bareJwk: { kty: "EC", crv: "P-256", x: "x", y: "y" },
          algorithms: ["ES256"],
          createJwt: async (header: Record<string, unknown>) => {
            jwtHeaders.push(header);
            return "pds-session-proof";
          },
        },
        dpopNonces: { get: async () => undefined, set: async () => {} },
        serverMetadata: { dpop_signing_alg_values_supported: supportedAlgorithms },
      },
    } as never;

    await expect(
      createPdsSessionAttestationProof(oauthSession)
    ).rejects.toThrow("OAuth session DPoP key has no supported algorithm");
    expect(jwtHeaders).toEqual([]);

    supportedAlgorithms.push("ES256");
    await createPdsSessionAttestationProof(oauthSession);
    expect(jwtHeaders).toHaveLength(1);
    expect(jwtHeaders[0]?.alg).toBe("ES256");
  });

  it("signs Social Wire gateway requests with Authorization and DPoP for the gateway URL", async () => {
    const dpopClaims: Array<Record<string, string | number>> = [];
    const pdsFetchHandler = mock(async () =>
      new Response(JSON.stringify({ records: [] }), {
        status: 200,
        headers: { "DPoP-Nonce": "fresh-pds-nonce" },
      })
    );
    const fetchMock = mock(async (url: string, init?: RequestInit) => {
      expect(url).toBe(
        "https://api.testing.thesocialwire.app/xrpc/app.thesocialwire.appview.listEntries?authorDid=did%3Aplc%3Aalice"
      );
      const headers = new Headers(init?.headers);
      expect(headers.get("Authorization")).toBe("DPoP access-token");
      expect(headers.get("DPoP")).toBe("gateway-dpop-proof");
      expect(headers.get(PDS_SESSION_DPOP_HEADER)).toBe(
        "pds-session-attestation-proof"
      );
      expect(headers.get(PDS_SESSION_DPOP_HEADER)).not.toContain(",");
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
      fetchHandler: pdsFetchHandler,
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
    expect(dpopClaims).toHaveLength(2);
    expect(dpopClaims[0]).toMatchObject({
      htm: "GET",
      htu: "https://jellybaby.us-east.host.bsky.network/xrpc/com.atproto.server.getSession",
    });
    expect(dpopClaims[0]).not.toHaveProperty("nonce");
    expect(dpopClaims[0]?.ath).toBeTruthy();
    expect(dpopClaims[1]?.htm).toBe("GET");
    expect(dpopClaims[1]?.htu).toBe(
      "https://api.testing.thesocialwire.app/xrpc/app.thesocialwire.appview.listEntries"
    );
    expect(dpopClaims[1]?.ath).toBeTruthy();
    expect(pdsFetchHandler).not.toHaveBeenCalled();
  });

  it("warms nonce-rotating PDS attestation before minting and preserving route proofs", async () => {
    const nonceCache = new Map<string, string>();
    const sessionProofHeaders: string[] = [];
    const upstreamProofHeaders: string[] = [];
    const receiptHeaders: string[] = [];
    const pdsSessionClaims: Array<
      Record<string, string | number | undefined>
    > = [];
    const upstreamClaims: Array<Record<string, string | number>> = [];
    let gatewayCalls = 0;
    let pdsNonce = "cold-pds-nonce";
    let pdsProbeCalls = 0;
    let pdsGetSessionCalls = 0;
    let sessionProofIndex = 0;
    let routeAttempts = 0;
    const fetchMock = mock(async (url: string, init?: RequestInit) => {
      gatewayCalls += 1;
      const headers = new Headers(init?.headers);
      sessionProofHeaders.push(headers.get(PDS_SESSION_DPOP_HEADER) ?? "");
      upstreamProofHeaders.push(headers.get(LATR_UPSTREAM_DPOP_HEADER) ?? "");
      receiptHeaders.push(
        headers.get(PDS_SESSION_ATTESTATION_RECEIPT_HEADER) ?? ""
      );

      if (url.includes("app.thesocialwire.appview.listEntries")) {
        pdsGetSessionCalls += 1;
        const sessionClaim = pdsSessionClaims[pdsGetSessionCalls - 1];
        if (sessionClaim?.nonce !== pdsNonce) {
          return new Response(
            JSON.stringify({ error: "use_pds_session_dpop_nonce" }),
            {
              status: 401,
              headers: { [PDS_SESSION_DPOP_NONCE_HEADER]: pdsNonce },
            }
          );
        }
        pdsNonce = `post-attestation-pds-nonce-${pdsGetSessionCalls}`;
        return new Response(JSON.stringify({ entries: [] }), {
          status: 200,
          headers: {
            [PDS_SESSION_DPOP_NONCE_HEADER]: pdsNonce,
            [PDS_SESSION_ATTESTATION_RECEIPT_HEADER]:
              `attestation-receipt-${pdsGetSessionCalls}`,
          },
        });
      }

      expect(url).toContain("/v1/appview/bootstrap-stream");
      routeAttempts += 1;
      if (routeAttempts === 1) {
        expect(pdsNonce).toBe("route-pds-nonce-1");
        return new Response(JSON.stringify({ error: "attestation_required" }), {
          status: 428,
          headers: { [PDS_SESSION_ATTESTATION_REQUIRED_HEADER]: "true" },
        });
      }
      if (routeAttempts === 2) {
        return new Response(JSON.stringify({ error: "use_dpop_nonce" }), {
          status: 401,
          headers: { "DPoP-Nonce": "gateway-route-nonce" },
        });
      }
      expect(upstreamClaims[1]?.nonce).toBe(pdsNonce);
      pdsNonce = "post-route-pds-nonce";
      return new Response(JSON.stringify({ ok: true }), { status: 200 });
    });
    globalThis.fetch = fetchMock as unknown as typeof fetch;

    const oauthSession = {
      did: "did:plc:viewer",
      getTokenSet: async () => ({
        access_token: "access-token",
        token_type: "DPoP",
      }),
      getTokenInfo: async () => ({ aud: "https://pds.example" }),
      fetchHandler: async (input: string | URL | Request) => {
        expect(String(input)).toContain("/xrpc/com.atproto.repo.listRecords");
        pdsProbeCalls += 1;
        pdsNonce = `route-pds-nonce-${pdsProbeCalls}`;
        nonceCache.set("https://pds.example", pdsNonce);
        return new Response(JSON.stringify({ records: [] }), {
          status: 200,
          headers: { "DPoP-Nonce": pdsNonce },
        });
      },
      server: {
        dpopKey: {
          bareJwk: { kty: "EC", crv: "P-256", x: "x", y: "y" },
          algorithms: ["ES256"],
          createJwt: async (_header: unknown, claims: Record<string, string | number>) => {
            if (
              claims.htu ===
              "https://pds.example/xrpc/com.atproto.server.getSession"
            ) {
              pdsSessionClaims.push(claims);
              return `pds-session-proof-${++sessionProofIndex}`;
            }
            if (
              claims.htu ===
              "https://pds.example/xrpc/com.atproto.repo.listRecords"
            ) {
              upstreamClaims.push(claims);
              return `route-upstream-proof-${upstreamClaims.length}`;
            }
            return "gateway-dpop-proof";
          },
        },
        dpopNonces: {
          get: async (origin: string) => nonceCache.get(origin),
          set: async (origin: string, nonce: string) => {
            nonceCache.set(origin, nonce);
          },
        },
        serverMetadata: { dpop_signing_alg_values_supported: ["ES256"] },
      },
    } as never;

    const { gatewayFetch } = await import("@/lib/socialWireGatewayClient");
    const response = await gatewayFetch(
      oauthSession,
      "/v1/appview/bootstrap-stream"
    );

    expect(response.status).toBe(200);
    expect(gatewayCalls).toBe(6);
    expect(pdsGetSessionCalls).toBe(3);
    expect(pdsProbeCalls).toBe(2);
    expect(upstreamProofHeaders).toEqual([
      "",
      "",
      "route-upstream-proof-1",
      "",
      "route-upstream-proof-2",
      "route-upstream-proof-2",
    ]);
    expect(receiptHeaders).toEqual([
      "",
      "",
      "attestation-receipt-2",
      "",
      "attestation-receipt-3",
      "attestation-receipt-3",
    ]);
    expect(upstreamClaims).toHaveLength(2);
    expect(upstreamClaims.map((claims) => claims.nonce)).toEqual([
      "route-pds-nonce-1",
      "route-pds-nonce-2",
    ]);
    expect(pdsSessionClaims.map((claims) => claims.nonce)).toEqual([
      undefined,
      "cold-pds-nonce",
      "route-pds-nonce-1",
      "route-pds-nonce-1",
      "route-pds-nonce-2",
      "route-pds-nonce-2",
    ]);
    expect(sessionProofHeaders).toEqual([
      "pds-session-proof-1",
      "pds-session-proof-2",
      "pds-session-proof-3",
      "pds-session-proof-4",
      "pds-session-proof-5",
      "pds-session-proof-6",
    ]);
    expect(new Set(pdsSessionClaims.map((claims) => claims.jti)).size).toBe(6);
    expect(nonceCache.get("https://pds.example")).toBe("route-pds-nonce-2");
    expect(
      nonceCache.get("https://api.testing.thesocialwire.app")
    ).toBe("gateway-route-nonce");
  });

  it("regenerates a prepared route proof at most once across repeated attestation-required responses", async () => {
    const nonceCache = new Map<string, string>();
    const routeProofHeaders: string[] = [];
    const receiptHeaders: string[] = [];
    let gatewayCalls = 0;
    let preflightCalls = 0;
    let pdsProbeCalls = 0;
    let upstreamProofsCreated = 0;
    const fetchMock = mock(async (url: string, init?: RequestInit) => {
      gatewayCalls += 1;
      const headers = new Headers(init?.headers);
      if (url.includes("app.thesocialwire.appview.listEntries")) {
        preflightCalls += 1;
        return new Response(JSON.stringify({ entries: [] }), {
          status: 200,
          headers: {
            [PDS_SESSION_ATTESTATION_RECEIPT_HEADER]:
              `attestation-receipt-${preflightCalls}`,
          },
        });
      }

      routeProofHeaders.push(headers.get(LATR_UPSTREAM_DPOP_HEADER) ?? "");
      receiptHeaders.push(
        headers.get(PDS_SESSION_ATTESTATION_RECEIPT_HEADER) ?? ""
      );
      return new Response(JSON.stringify({ error: "attestation_required" }), {
        status: 428,
        headers: { [PDS_SESSION_ATTESTATION_REQUIRED_HEADER]: "true" },
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
      fetchHandler: async () => {
        pdsProbeCalls += 1;
        const nonce = `route-pds-nonce-${pdsProbeCalls}`;
        nonceCache.set("https://pds.example", nonce);
        return new Response(JSON.stringify({ records: [] }), {
          status: 200,
          headers: { "DPoP-Nonce": nonce },
        });
      },
      server: {
        dpopKey: {
          bareJwk: { kty: "EC", crv: "P-256", x: "x", y: "y" },
          algorithms: ["ES256"],
          createJwt: async (_header: unknown, claims: Record<string, string | number>) => {
            if (
              claims.htu ===
              "https://pds.example/xrpc/com.atproto.repo.listRecords"
            ) {
              upstreamProofsCreated += 1;
              return `route-upstream-proof-${upstreamProofsCreated}`;
            }
            return "request-proof";
          },
        },
        dpopNonces: {
          get: async (origin: string) => nonceCache.get(origin),
          set: async (origin: string, nonce: string) => {
            nonceCache.set(origin, nonce);
          },
        },
        serverMetadata: { dpop_signing_alg_values_supported: ["ES256"] },
      },
    } as never;

    const { gatewayFetch } = await import("@/lib/socialWireGatewayClient");
    const response = await gatewayFetch(
      oauthSession,
      "/v1/appview/bootstrap-stream"
    );

    expect(response.status).toBe(428);
    expect(gatewayCalls).toBe(4);
    expect(preflightCalls).toBe(2);
    expect(pdsProbeCalls).toBe(2);
    expect(upstreamProofsCreated).toBe(2);
    expect(routeProofHeaders).toEqual([
      "route-upstream-proof-1",
      "route-upstream-proof-2",
    ]);
    expect(receiptHeaders).toEqual([
      "attestation-receipt-1",
      "attestation-receipt-2",
    ]);
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
    const res = await gatewayFetch(
      oauthSession,
      "/xrpc/app.thesocialwire.appview.listEntries"
    );

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
        new Response(JSON.stringify({ records: [] }), {
          status: 200,
          headers: { "DPoP-Nonce": "pds-nonce" },
        }),
      server: {
        dpopKey: {
          bareJwk: { kty: "EC", crv: "P-256", x: "x", y: "y" },
          algorithms: ["ES256"],
          createJwt: async (
            _header: unknown,
            claims: Record<string, string | number>
          ) => {
            if (
              String(claims.htu).startsWith(
                "https://api.testing.thesocialwire.app/"
              )
            ) {
              nonceClaimsSeen.push(claims.nonce as string | undefined);
            }
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

  it("does not invalidate a locally valid session after a final gateway 401", async () => {
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
        access_token: "access-token",
        token_type: "DPoP",
      }),
      getTokenInfo: async () => ({ aud: "https://pds.example" }),
      fetchHandler: async () =>
        new Response(JSON.stringify({ records: [] }), {
          status: 200,
          headers: { "DPoP-Nonce": "pds-nonce" },
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

    try {
      const { gatewayFetch } = await import("@/lib/socialWireGatewayClient");
      const response = await gatewayFetch(
        oauthSession,
        "/xrpc/app.thesocialwire.appview.listEntries",
      );

      expect(response.status).toBe(401);
      expect(invalidations).toEqual([]);
    } finally {
      unsubscribe();
    }
  });

  it("does not invalidate the session when a DPoP nonce retry ends in a gateway 401", async () => {
    let calls = 0;
    globalThis.fetch = mock(async () => {
      calls += 1;
      if (calls === 1) {
        return new Response(JSON.stringify({ error: "use_dpop_nonce" }), {
          status: 401,
          headers: { "DPoP-Nonce": "fresh-gateway-nonce" },
        });
      }
      return new Response(JSON.stringify({ error: "invalid_token" }), {
        status: 401,
      });
    }) as unknown as typeof fetch;
    const invalidations: string[] = [];
    const unsubscribe = onOAuthSessionInvalidated((did) => {
      invalidations.push(did);
    });
    const oauthSession = {
      did: "did:plc:viewer",
      getTokenSet: async () => ({
        access_token: "access-token",
        token_type: "DPoP",
      }),
      getTokenInfo: async () => ({ aud: "https://pds.example" }),
      fetchHandler: async () =>
        new Response(JSON.stringify({ records: [] }), {
          status: 200,
          headers: { "DPoP-Nonce": "pds-nonce" },
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

    try {
      const { gatewayFetch } = await import("@/lib/socialWireGatewayClient");
      const response = await gatewayFetch(
        oauthSession,
        "/xrpc/app.thesocialwire.appview.listEntries",
      );

      expect(response.status).toBe(401);
      expect(globalThis.fetch).toHaveBeenCalledTimes(2);
      expect(invalidations).toEqual([]);
    } finally {
      unsubscribe();
    }
  });

  it("does not let a telemetry 401 invalidate the session", async () => {
    globalThis.fetch = mock(async () =>
      new Response(JSON.stringify({ error: "invalid_token" }), {
        status: 401,
      })
    ) as unknown as typeof fetch;
    const invalidations: string[] = [];
    const unsubscribe = onOAuthSessionInvalidated((did) => {
      invalidations.push(did);
    });
    const oauthSession = {
      did: "did:plc:viewer",
      getTokenSet: async () => ({
        access_token: "access-token",
        token_type: "DPoP",
      }),
      getTokenInfo: async () => ({ aud: "https://pds.example" }),
      fetchHandler: async () =>
        new Response(JSON.stringify({ records: [] }), {
          status: 200,
          headers: { "DPoP-Nonce": "pds-nonce" },
        }),
      server: {
        dpopKey: {
          bareJwk: { kty: "EC", crv: "P-256", x: "x", y: "y" },
          algorithms: ["ES256"],
          createJwt: async () => "dpop-proof",
        },
        dpopNonces: {
          get: async () => undefined,
          set: async () => {},
        },
        serverMetadata: { dpop_signing_alg_values_supported: ["ES256"] },
      },
    } as never;

    try {
      const { recordClientPerformance } = await import(
        "@/lib/clientPerformanceTelemetry"
      );
      const response = await recordClientPerformance(oauthSession, {
        event: "feed_error",
        durationMs: 100,
        feedType: "aggregate",
        cacheState: "miss",
        outcome: "error",
      });

      expect(response.status).toBe(401);
      expect(invalidations).toEqual([]);
    } finally {
      unsubscribe();
    }
  });

  it("still invalidates the session after a terminal token refresh failure", async () => {
    const did = "did:plc:viewer";
    const failure = new TokenRefreshError(did, "The session was revoked");
    const invalidations: Array<{ did: string; cause: unknown }> = [];
    const unsubscribe = onOAuthSessionInvalidated((invalidatedDid, cause) => {
      invalidations.push({ did: invalidatedDid, cause });
    });
    const oauthSession = {
      did,
      getTokenInfo: async () => ({ aud: "https://pds.example" }),
      getTokenSet: async () => {
        throw failure;
      },
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

      await expect(
        gatewayFetch(oauthSession, "/v1/telemetry/client-performance")
      ).rejects.toBe(failure);
      expect(invalidations).toEqual([{ did, cause: failure }]);
    } finally {
      unsubscribe();
    }
  });
});
