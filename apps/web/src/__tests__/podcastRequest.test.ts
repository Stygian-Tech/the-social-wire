import { afterEach, expect, it, spyOn } from "bun:test";
import type { OAuthSession } from "@atproto/oauth-client-browser";
import * as gateway from "@/lib/socialWireGatewayClient";
import { podcastRequest } from "@/lib/podcasts/client";

const restores: (() => void)[] = [];
afterEach(() => restores.splice(0).forEach(restore => restore()));

it("renders structured API errors as messages without object coercion", async () => {
  const fetch = spyOn(gateway, "gatewayFetch").mockResolvedValue(new Response(JSON.stringify({ error: { message: "Analysis Is Unavailable" } }), { status: 503 }));
  restores.push(() => fetch.mockRestore());
  await expect(podcastRequest({} as OAuthSession, "silences?episodeId=episode")).rejects.toThrow("Analysis Is Unavailable");
  fetch.mockResolvedValue(new Response(JSON.stringify({ error: { code: "Unavailable" } }), { status: 503 }));
  await expect(podcastRequest({} as OAuthSession, "silences?episodeId=episode")).rejects.toThrow("Podcasts request failed (503)");
});
