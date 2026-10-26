import { afterEach, describe, expect, it, spyOn } from "bun:test";
import type { OAuthSession } from "@atproto/oauth-client-browser";
import type { AppBskyFeedDefs } from "@atproto/api";
import * as Gateway from "@/lib/socialWireGatewayClient";
import { projectMediaPage, uniqueMediaPosts } from "@/lib/mediaFeedClient";

const session = { did: "did:plc:viewer" } as unknown as OAuthSession;
function post(key: string): AppBskyFeedDefs.FeedViewPost {
  return { post: { uri: `at://did:plc:author/app.bsky.feed.post/${key}`, cid: "bafyreia", author: { did: "did:plc:author", handle: "author.test" }, record: { $type: "app.bsky.feed.post", text: "Photo", createdAt: "2026-10-26T12:00:00Z" }, indexedAt: "2026-10-26T12:00:00Z", embed: { $type: "app.bsky.embed.images#view", images: [{ thumb: "https://cdn.test/thumb.jpg", fullsize: "https://cdn.test/full.jpg", alt: "A flower" }] } } };
}
let restore = () => {};
afterEach(() => restore());
describe("live Media projection", () => {
  it("sends only source identity and embed, preserves source order/cursor, ignores injected identities", async () => {
    const a = post("a"), b = post("b");
    const fetch = spyOn(Gateway, "gatewayFetch").mockResolvedValue(Response.json({ uris: [b.post.uri, "at://did:plc:injected/app.bsky.feed.post/x", a.post.uri] }));
    restore = () => fetch.mockRestore();
    const controller = new AbortController();
    const result = await projectMediaPage(session, { feed: [a, b], cursor: "next" }, "photos", controller.signal);
    expect(result).toEqual({ feed: [a, b], cursor: "next" });
    expect(fetch.mock.calls[0][0]).toBe(session);
    expect(fetch.mock.calls[0][1]).toBe("/v1/media/project");
    expect(fetch.mock.calls[0][2]?.signal).toBe(controller.signal);
    expect(JSON.parse(String(fetch.mock.calls[0][2]?.body))).toEqual({ mode: "photos", posts: [a, b].map(({ post }) => ({ uri: post.uri, embed: post.embed })) });
  });
  it("keeps cursor continuation when a scanned page has no matching media", async () => {
    const fetch = spyOn(Gateway, "gatewayFetch").mockResolvedValue(Response.json({ uris: [] }));
    restore = () => fetch.mockRestore();
    expect(await projectMediaPage(session, { feed: [post("a")], cursor: "next" }, "short-videos")).toEqual({ feed: [], cursor: "next" });
  });
  it("fails closed on service failures and malformed response shapes", async () => {
    const fetch = spyOn(Gateway, "gatewayFetch").mockResolvedValue(new Response("Unavailable", { status: 503 }));
    restore = () => fetch.mockRestore();
    await expect(projectMediaPage(session, { feed: [] }, "photos")).rejects.toThrow("unavailable");
    fetch.mockResolvedValue(Response.json({ uris: [42] }));
    await expect(projectMediaPage(session, { feed: [] }, "photos")).rejects.toThrow("invalid response");
  });
  it("retires a late projection response even if transport ignores cancellation", async () => {
    const controller = new AbortController();
    const fetch = spyOn(Gateway, "gatewayFetch").mockImplementation(async () => { controller.abort(); return Response.json({ uris: [] }); });
    restore = () => fetch.mockRestore();
    await expect(projectMediaPage(session, { feed: [] }, "photos", controller.signal)).rejects.toThrow();
  });
  it("deduplicates originals/reposts/page overlaps by canonical post URI", () => {
    const a = post("a"), b = post("b");
    expect(uniqueMediaPosts([{ feed: [a, a] }, { feed: [b, a] }])).toEqual([a, b]);
  });
});
