import { afterEach, expect, it, mock, spyOn } from "bun:test";
import type { OAuthSession } from "@atproto/oauth-client-browser";
import { gatewayFetch } from "@/lib/socialWireGatewayClient";
import { PDS_SESSION_ATTESTATION_RECEIPT_HEADER as RECEIPT, PDS_SESSION_ATTESTATION_REQUIRED_HEADER as REQUIRED } from "@/lib/pdsSessionAttestation";
const originalFetch = globalThis.fetch;
const originalOrigin = process.env.NEXT_PUBLIC_SOCIALWIRE_API_URL;
afterEach(() => {
  globalThis.fetch = originalFetch;
  if (originalOrigin === undefined) delete process.env.NEXT_PUBLIC_SOCIALWIRE_API_URL;
  else process.env.NEXT_PUBLIC_SOCIALWIRE_API_URL = originalOrigin;
});
function deferred<T>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>(yes => { resolve = yes; });
  return { promise, resolve };
}
async function until(predicate: () => boolean) {
  for (let attempt = 0; attempt < 1000 && !predicate(); attempt++) await new Promise(resolve => setTimeout(resolve, 1));
  expect(predicate()).toBe(true);
}
function session() {
  let token = "first-token";
  const nonces = new Map<string, string>();
  const oauth = {
    did: "did:plc:reader", getTokenSet: async () => ({ access_token: token, token_type: "DPoP" }),
    getTokenInfo: async () => ({ aud: "https://pds.example" }),
    fetchHandler: async () => new Response("{}", { headers: { "DPoP-Nonce": "pds-nonce" } }),
    server: {
      dpopKey: { bareJwk: { kty: "EC" }, algorithms: ["ES256"], createJwt: async (_: unknown, claims: unknown) => JSON.stringify(claims) },
      dpopNonces: { get: async (origin: string) => nonces.get(origin), set: async (origin: string, value: string) => { nonces.set(origin, value); } },
      serverMetadata: { dpop_signing_alg_values_supported: ["ES256"] },
    },
  } as unknown as OAuthSession;
  process.env.NEXT_PUBLIC_SOCIALWIRE_API_URL = "https://api.testing.thesocialwire.app";
  return { oauth, rotate() { token = "second-token"; } };
}
const feed = "/xrpc/app.thesocialwire.appview.getFeed";
const circle = "/xrpc/app.thesocialwire.discovery.getCircleEdition";
const ok = (receipt?: string) => new Response("{}", { headers: receipt ? { [RECEIPT]: receipt } : {} });
const expired = () => new Response("{}", { status: 428, headers: { [REQUIRED]: "true" } });
it("shares cold attestation and lets feed and prepared bootstrap pass a held Circle response", async () => {
  const { oauth } = session(); const held = deferred<Response>(); let warms = 0; let circleStarted = false;
  globalThis.fetch = mock(async (input, init) => {
    const path = String(input); const headers = new Headers(init?.headers);
    if (path.includes("listEntries")) { warms++; return ok("receipt"); }
    expect(headers.get(RECEIPT)).toBe("receipt");
    if (path.endsWith("bootstrap-stream")) expect(headers.get("X-ATProto-Upstream-DPoP")).toBeTruthy();
    else expect(headers.get("X-ATProto-Upstream-DPoP-Prepared")).toBe("true");
    if (path.endsWith("getCircleEdition")) { circleStarted = true; return held.promise; }
    return ok();
  }) as unknown as typeof fetch;
  const slow = gatewayFetch(oauth, circle); const fast = gatewayFetch(oauth, feed);
  expect((await fast).status).toBe(200); await until(() => circleStarted);
  expect(warms).toBe(1);
  expect((await gatewayFetch(oauth, "/v1/appview/bootstrap-stream")).status).toBe(200);
  expect(warms).toBe(2); held.resolve(ok()); await slow;
});
it("coalesces concurrent expired receipts and bounds repeated 428 refreshes", async () => {
  const { oauth } = session(); let warms = 0; let rejectReceipt = false; let alwaysReject = false;
  globalThis.fetch = mock(async (input, init) => {
    if (String(input).includes("listEntries")) { warms++; return ok(`receipt-${warms}`); }
    const receipt = new Headers(init?.headers).get(RECEIPT);
    return alwaysReject || rejectReceipt && receipt === "receipt-1" ? expired() : ok();
  }) as unknown as typeof fetch;
  await gatewayFetch(oauth, feed); rejectReceipt = true;
  const responses = await Promise.all([gatewayFetch(oauth, feed), gatewayFetch(oauth, circle)]);
  expect(responses.map(response => response.status)).toEqual([200, 200]); expect(warms).toBe(2);
  alwaysReject = true;
  expect((await gatewayFetch(oauth, feed)).status).toBe(428); expect(warms).toBe(3);
});
it("separates receipt reuse by token, OAuth session and Gateway origin", async () => {
  const first = session(); let warms = 0;
  globalThis.fetch = mock(async input => String(input).includes("listEntries") ? (warms++, ok(`receipt-${warms}`)) : ok()) as unknown as typeof fetch;
  await gatewayFetch(first.oauth, feed); await gatewayFetch(first.oauth, circle); expect(warms).toBe(1);
  first.rotate(); await gatewayFetch(first.oauth, feed); expect(warms).toBe(2);
  const second = session(); await gatewayFetch(second.oauth, feed); expect(warms).toBe(3);
  process.env.NEXT_PUBLIC_SOCIALWIRE_API_URL = "https://other.example";
  await gatewayFetch(first.oauth, feed); expect(warms).toBe(4);
});
it("cancels one warm waiter without dispatching its read or canceling the shared warm-up", async () => {
  const { oauth } = session(); const warm = deferred<Response>(); let warms = 0; const reads: string[] = [];
  globalThis.fetch = mock(async input => {
    if (String(input).includes("listEntries")) { warms++; return warm.promise; }
    reads.push(String(input)); return ok();
  }) as unknown as typeof fetch;
  const controller = new AbortController();
  const canceled = gatewayFetch(oauth, circle, { signal: controller.signal }).catch(error => error);
  const live = gatewayFetch(oauth, feed); await until(() => warms === 1);
  controller.abort(); expect((await canceled).name).toBe("AbortError"); warm.resolve(ok("receipt"));
  expect((await live).status).toBe(200); expect(reads).toHaveLength(1); expect(reads[0]).toContain("getFeed");
});
it("does not dispatch an aborted write queued behind another ceremony", async () => {
  const { oauth } = session(); const held = deferred<Response>(); let calls = 0;
  globalThis.fetch = mock(async () => { calls++; return calls === 1 ? held.promise : ok(); }) as unknown as typeof fetch;
  const first = gatewayFetch(oauth, "/write", { method: "POST" }); await until(() => calls === 1);
  const controller = new AbortController();
  const canceled = gatewayFetch(oauth, "/write", { method: "POST", signal: controller.signal }).catch(error => error);
  controller.abort(); expect((await canceled).name).toBe("AbortError"); held.resolve(ok()); await first;
  await new Promise(resolve => setTimeout(resolve, 0)); expect(calls).toBe(1);
});
it("preserves serialized authentication when a public-JWKS warm-up issues no receipt", async () => {
  const { oauth } = session(); let calls = 0;
  globalThis.fetch = mock(async (_input, init) => {
    calls++; expect(new Headers(init?.headers).get("X-ATProto-Upstream-DPoP-Prepared")).toBeNull(); return ok();
  }) as unknown as typeof fetch;
  expect((await gatewayFetch(oauth, feed)).status).toBe(200);
  expect((await gatewayFetch(oauth, circle)).status).toBe(200); expect(calls).toBe(3);
});

it("refreshes its token binding when the token rotates during an in-flight warm-up", async () => {
  const env = session(); const held = deferred<Response>(); let warms = 0; const receipts: string[] = [];
  globalThis.fetch = mock(async (input, init) => {
    const headers = new Headers(init?.headers);
    if (String(input).includes("listEntries")) {
      warms++; return warms === 1 ? held.promise : ok("second-token-receipt");
    }
    const receipt = headers.get(RECEIPT)!; receipts.push(receipt);
    expect(headers.get("Authorization")).toBe("DPoP second-token");
    return receipt === "first-token-receipt" ? expired() : ok();
  }) as unknown as typeof fetch;
  const first = gatewayFetch(env.oauth, feed); await until(() => warms === 1);
  env.rotate(); held.resolve(ok("first-token-receipt"));
  expect((await first).status).toBe(200); expect(warms).toBe(2);
  expect(receipts).toEqual(["first-token-receipt", "second-token-receipt"]);
  await gatewayFetch(env.oauth, circle); expect(warms).toBe(2);
});
it("rechecks no-receipt capability after a bounded interval and normalizes relative paths", async () => {
  const { oauth } = session(); let warms = 0;
  const now = Date.now(); const clock = spyOn(Date, "now").mockReturnValue(now);
  globalThis.fetch = mock(async input => {
    if (String(input).includes("listEntries")) { warms++; return warms === 1 ? ok() : ok("new-receipt"); }
    return ok();
  }) as unknown as typeof fetch;
  try {
    await gatewayFetch(oauth, feed.slice(1)); await gatewayFetch(oauth, feed); expect(warms).toBe(1);
    clock.mockReturnValue(now + 50_001); await gatewayFetch(oauth, feed); expect(warms).toBe(2);
  } finally { clock.mockRestore(); }
});
