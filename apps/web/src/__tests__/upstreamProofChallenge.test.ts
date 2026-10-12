import { afterEach, describe, expect, it } from "bun:test";

import { gatewayFetchWithProofChallenge, isUpstreamProofRequired } from "@/lib/upstreamProofChallenge";

const originalFetch = globalThis.fetch;
const originalURL = process.env.NEXT_PUBLIC_SOCIALWIRE_API_URL;
afterEach(() => {
  globalThis.fetch = originalFetch;
  if (originalURL === undefined) delete process.env.NEXT_PUBLIC_SOCIALWIRE_API_URL;
  else process.env.NEXT_PUBLIC_SOCIALWIRE_API_URL = originalURL;
});

function fixture() {
  process.env.NEXT_PUBLIC_SOCIALWIRE_API_URL = "https://gateway.example";
  const nonces = new Map<string, string>();
  const claims: Array<Record<string, unknown>> = [];
  const session = {
    did: "did:plc:viewer",
    getTokenSet: async () => ({ access_token: "private-token", token_type: "DPoP" }),
    getTokenInfo: async () => ({ aud: "https://pds.example" }),
    server: {
      dpopKey: {
        bareJwk: { kty: "EC", crv: "P-256", x: "x", y: "y" },
        algorithms: ["ES256"],
        createJwt: async (_: unknown, value: Record<string, unknown>) => {
          claims.push(value);
          return `proof-${value.jti}`;
        },
      },
      dpopNonces: { get: async (origin: string) => nonces.get(origin), set: async (origin: string, nonce: string) => { nonces.set(origin, nonce); } },
      serverMetadata: { dpop_signing_alg_values_supported: ["ES256"] },
    },
  } as never;
  return { session, claims, nonces };
}

const path = "/xrpc/app.thesocialwire.discovery.getWire?lang=en";
const header = "X-Wire-Moderation-DPoP";
const challenge = () => Response.json({ error: "UpstreamProofRequired" }, { status: 428 });

describe("viewer cache proof negotiation", () => {
  it("uses warm caches without preparing any route proofs", async () => {
    const { session } = fixture();
    let prepared = 0;
    let requests = 0;
    globalThis.fetch = (async (_url: string, init: RequestInit) => {
      requests++;
      expect(new Headers(init.headers).has(header)).toBe(false);
      return Response.json({ items: [] });
    }) as unknown as typeof fetch;
    await gatewayFetchWithProofChallenge(session, path, {}, header, async () => { prepared++; return "unused"; });
    expect(requests).toBe(1);
    expect(prepared).toBe(0);
  });

  it("attests before preparing a cold pool and preserves it through a Gateway nonce retry", async () => {
    const { session, nonces } = fixture();
    const events: string[] = [];
    const dispatchProofs: string[] = [];
    let routes = 0;
    globalThis.fetch = (async (url: string, init: RequestInit) => {
      const headers = new Headers(init.headers);
      if (url.includes("appview.listEntries")) {
        events.push("attestation");
        return Response.json({}, { headers: { "X-ATProto-Session-Attestation-Receipt": "bound-receipt" } });
      }
      routes++;
      if (routes === 1) return challenge();
      events.push("prepared-dispatch");
      expect(headers.get(header)).toBe("pool-current-pds-nonce");
      expect(headers.get("X-ATProto-Upstream-DPoP-Prepared")).toBe("true");
      expect(headers.get("X-ATProto-Session-Attestation-Receipt")).toBe("bound-receipt");
      dispatchProofs.push(headers.get("DPoP")!);
      return routes === 2
        ? Response.json({}, { status: 401, headers: { "DPoP-Nonce": "gateway-nonce" } })
        : Response.json({ items: [] });
    }) as unknown as typeof fetch;
    const response = await gatewayFetchWithProofChallenge(session, path, {}, header, async () => {
      events.push("prepare");
      nonces.set("https://pds.example", "current-pds-nonce");
      return "pool-current-pds-nonce";
    });
    expect(response.status).toBe(200);
    expect(events).toEqual(["attestation", "prepare", "prepared-dispatch", "prepared-dispatch"]);
    expect(new Set(dispatchProofs).size).toBe(2);
  });

  it("renews an expired receipt once and stops on a repeated challenge", async () => {
    const { session } = fixture();
    let routes = 0, attestations = 0, pools = 0;
    globalThis.fetch = (async (url: string) => {
      if (url.includes("appview.listEntries")) {
        attestations++;
        return Response.json({}, { headers: { "X-ATProto-Session-Attestation-Receipt": `receipt-${attestations}` } });
      }
      if (++routes === 1) return challenge();
      return Response.json({}, { status: 428, headers: { "X-ATProto-Session-Attestation-Required": "true" } });
    }) as unknown as typeof fetch;
    const response = await gatewayFetchWithProofChallenge(session, path, {}, header, async () => `pool-${++pools}`);
    expect(response.status).toBe(428);
    expect([routes, attestations, pools]).toEqual([3, 2, 2]);
  });

  it("supports signed-JWKS sessions without an attestation receipt", async () => {
    const { session } = fixture();
    let routes = 0;
    globalThis.fetch = (async (url: string, init: RequestInit) => {
      if (url.includes("appview.listEntries")) return Response.json({});
      if (++routes === 1) return challenge();
      const headers = new Headers(init.headers);
      expect(headers.get("X-ATProto-Upstream-DPoP-Prepared")).toBe("true");
      expect(headers.has("X-ATProto-Session-Attestation-Receipt")).toBe(false);
      return Response.json({ items: [] });
    }) as unknown as typeof fetch;
    const response = await gatewayFetchWithProofChallenge(session, path, {}, header, async () => "prepared-pool");
    expect(response.status).toBe(200);
  });

  it("does not prepare a pool after the original request is cancelled", async () => {
    const { session } = fixture();
    const controller = new AbortController();
    let pools = 0;
    globalThis.fetch = (async () => { controller.abort(); return challenge(); }) as unknown as typeof fetch;
    await expect(gatewayFetchWithProofChallenge(session, path, { signal: controller.signal }, header, async () => { pools++; return "unused"; })).rejects.toThrow();
    expect(pools).toBe(0);
  });

  it("does not interpret malformed or unrelated failures as a proof challenge", async () => {
    for (const response of [new Response("{", { status: 428 }), Response.json({ error: "Other" }, { status: 428 }), challenge()]) {
      expect(await isUpstreamProofRequired(response)).toBe(response.headers.get("Content-Type")?.includes("json") === true && (await response.json()).error === "UpstreamProofRequired");
    }
    const { session } = fixture();
    let pools = 0;
    globalThis.fetch = (async () => Response.json({ error: "ModerationUnavailable" }, { status: 503 })) as unknown as typeof fetch;
    const response = await gatewayFetchWithProofChallenge(session, path, {}, header, async () => { pools++; return "unused"; });
    expect(response.status).toBe(503);
    expect(pools).toBe(0);
  });
});
