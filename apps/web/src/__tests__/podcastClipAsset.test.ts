import { afterEach, expect, it, spyOn } from "bun:test";
import type { OAuthSession } from "@atproto/oauth-client-browser";
import * as gateway from "@/lib/socialWireGatewayClient";
import { fetchPodcastClipAsset } from "@/lib/podcasts/clipAsset";
const session = { did: "did:plc:owner" } as unknown as OAuthSession;
afterEach(() => { for (const restore of restores.splice(0)) restore(); });
const restores: (() => void)[] = [];

it("fetches draft MP4 through authenticated gateway and guards each async boundary", async () => {
  const fetch = spyOn(gateway, "gatewayFetch").mockResolvedValue(new Response("video", { headers: { "Content-Type": "video/mp4" } }));
  restores.push(() => fetch.mockRestore());
  let checks = 0;
  const abort = new AbortController();
  const blob = await fetchPodcastClipAsset({ session, clipId: "private/id", format: "video", signal: abort.signal, assertCurrentAccount: () => { checks++; } });
  expect(fetch).toHaveBeenCalledWith(session, "/v1/podcasts/assets?clipId=private%2Fid&format=video", { signal: abort.signal });
  expect(blob.type).toBe("video/mp4"); expect(checks).toBe(3);
});
it("rejects wrong media types and discards stale account media", async () => {
  const fetch = spyOn(gateway, "gatewayFetch").mockResolvedValue(new Response("error", { headers: { "Content-Type": "text/html" } }));
  restores.push(() => fetch.mockRestore());
  await expect(fetchPodcastClipAsset({ session, clipId: "id", format: "video" })).rejects.toThrow("Unavailable");
  let calls = 0;
  fetch.mockResolvedValue(new Response("video", { headers: { "Content-Type": "video/mp4" } }));
  await expect(fetchPodcastClipAsset({ session, clipId: "id", format: "video", assertCurrentAccount: () => { if (++calls > 1) throw new Error("Account Changed"); } })).rejects.toThrow("Account Changed");
});
it("aborted preview never requests or exposes media", async () => {
  const fetch = spyOn(gateway, "gatewayFetch"); restores.push(() => fetch.mockRestore());
  const abort = new AbortController(); abort.abort();
  await expect(fetchPodcastClipAsset({ session, clipId: "id", format: "video", signal: abort.signal })).rejects.toThrow();
  expect(fetch).not.toHaveBeenCalled();
});
