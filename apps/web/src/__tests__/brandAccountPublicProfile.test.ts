import { afterEach, expect, spyOn, test } from "bun:test";
import { getBrandAccountPublicProfile } from "@/lib/brandAccounts/brandAccountPublicProfile";

const restores: (() => void)[] = [];
afterEach(() => restores.splice(0).reverse().forEach(restore => restore()));
test("reads public AppView without OAuth credentials, validates DID and sanitizes avatars", async () => {
  const responder = Object.assign(async (input: Parameters<typeof fetch>[0], init?: Parameters<typeof fetch>[1]) => {
    const request = input instanceof Request ? input : new Request(input, init);
    expect(request.url).toBe("https://public.example/xrpc/app.bsky.actor.getProfile?actor=did%3Aplc%3Abrand");
    expect(request.headers.get("authorization")).toBeNull(); expect(request.headers.get("dpop")).toBeNull();
    return Response.json({ did: "did:plc:brand", handle: "brand.test", displayName: " Brand ", avatar: "javascript:alert(1)" });
  }, { preconnect: globalThis.fetch.preconnect });
  const fetchSpy = spyOn(globalThis, "fetch").mockImplementation(responder); restores.push(() => fetchSpy.mockRestore());
  expect(await getBrandAccountPublicProfile("did:plc:brand", "https://public.example")).toEqual({ did: "did:plc:brand", handle: "brand.test", displayName: "Brand", avatar: undefined });
  fetchSpy.mockResolvedValue(Response.json({ did: "did:plc:wrong", handle: "wrong.test" }));
  await expect(getBrandAccountPublicProfile("did:plc:brand", "https://public.example")).rejects.toThrow("Unavailable");
});
