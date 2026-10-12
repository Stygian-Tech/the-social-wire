import { afterAll, afterEach, expect, it, spyOn } from "bun:test";
import type { OAuthSession } from "@atproto/oauth-client-browser";
import * as gateway from "@/lib/socialWireGatewayClient";
import { getProEntitlements, requirePro } from "@/lib/proEntitlements";

const session = { did: "did:plc:viewer" } as unknown as OAuthSession;
const fetch = spyOn(gateway, "gatewayFetch");
afterEach(() => fetch.mockReset());
it("accepts only server entitlements bound to the authenticated viewer", async () => {
  fetch.mockResolvedValue(Response.json({ viewerDid: session.did, plan: "pro" }));
  expect(await getProEntitlements(session)).toEqual({ viewerDid: session.did, plan: "pro" });
  expect(fetch.mock.calls[0][1]).toBe("/v1/subscription/entitlements");
  expect(fetch.mock.calls[0][2]?.cache).toBe("no-store");
});
it("fails closed for unavailable, malformed, and cross-account responses", async () => {
  for (const response of [new Response(null, { status: 503 }), Response.json({ viewerDid: "did:plc:other", plan: "pro" }), Response.json({ viewerDid: session.did, plan: "trial" }), Response.json(null)]) {
    fetch.mockResolvedValue(response);
    await expect(getProEntitlements(session)).rejects.toThrow("Pro Access Could Not Be Verified");
  }
});
it("rejects free feature use and permits Pro", async () => {
  fetch.mockResolvedValue(Response.json({ viewerDid: session.did, plan: "free" }));
  await expect(requirePro(session)).rejects.toThrow("Requires Social Wire Pro");
  fetch.mockResolvedValue(Response.json({ viewerDid: session.did, plan: "pro" }));
  await requirePro(session);
});

afterAll(() => fetch.mockRestore());
