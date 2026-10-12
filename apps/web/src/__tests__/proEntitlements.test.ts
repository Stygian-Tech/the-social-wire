import { afterAll, afterEach, beforeEach, expect, it, spyOn } from "bun:test";
import type { OAuthSession } from "@atproto/oauth-client-browser";
import * as gateway from "@/lib/socialWireGatewayClient";
import { getProEntitlements, isProGatingEnabled, requirePro } from "@/lib/proEntitlements";

const session = { did: "did:plc:viewer" } as unknown as OAuthSession;
const fetch = spyOn(gateway, "gatewayFetch");
const originalGating = process.env.NEXT_PUBLIC_PRO_GATING_ENABLED;
beforeEach(() => { process.env.NEXT_PUBLIC_PRO_GATING_ENABLED = "true"; });
afterEach(() => {
  fetch.mockReset();
  if (originalGating === undefined) delete process.env.NEXT_PUBLIC_PRO_GATING_ENABLED;
  else process.env.NEXT_PUBLIC_PRO_GATING_ENABLED = originalGating;
});
it("defaults enforcement off and skips entitlement requests unless explicitly enabled", async () => {
  for (const flag of [undefined, "", "false", "invalid"]) {
    if (flag === undefined) delete process.env.NEXT_PUBLIC_PRO_GATING_ENABLED;
    else process.env.NEXT_PUBLIC_PRO_GATING_ENABLED = flag;
    expect(isProGatingEnabled()).toBe(false);
    await requirePro(session);
  }
  expect(fetch).not.toHaveBeenCalled();
  process.env.NEXT_PUBLIC_PRO_GATING_ENABLED = "true";
  expect(isProGatingEnabled()).toBe(true);
});
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
