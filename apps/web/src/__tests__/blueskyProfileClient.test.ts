import { describe, expect, it } from "bun:test";
import type { ModerationOpts } from "@atproto/api";
import type { OAuthSession } from "@atproto/oauth-client-browser";
import { getBlueskyProfilePage, type ProfileSection } from "@/lib/blueskyProfileClient";
const did = "did:plc:alice";
const moderation: ModerationOpts = { userDid: did, prefs: { adultContentEnabled: false, labels: {}, labelers: [{ did: "did:web:labeler.test", labels: {} }], mutedWords: [], hiddenPosts: [] } };
describe("viewer profile feed transport", () => {
  it("routes every tab through viewer OAuth with matching filters, subscription headers, cursor, and signal", async () => {
    const signal = new AbortController().signal;
    const calls: { method: string; filter: string | null }[] = [];
    const session = { did, fetchHandler: async (path: string, init?: RequestInit) => {
      const url = new URL(path, "https://pds.test");
      const headers = new Headers(init?.headers);
      expect(url.searchParams.get("actor")).toBe(did);
      expect(url.searchParams.get("cursor")).toBe("opaque+/=");
      expect(url.searchParams.get("limit")).toBe("30");
      expect(headers.get("atproto-proxy")).toBe("did:web:api.bsky.app#bsky_appview");
      expect(headers.get("atproto-accept-labelers")).toContain("did:web:labeler.test");
      expect(init?.signal).toBe(signal);
      calls.push({ method: url.pathname.split("/").at(-1)!, filter: url.searchParams.get("filter") });
      return Response.json({ feed: [], cursor: "next" });
    } } as unknown as OAuthSession;
    for (const tab of ["posts", "replies", "media", "likes"] as const) expect(await getBlueskyProfilePage({ session, tab, moderation, cursor: "opaque+/=", signal })).toEqual({ feed: [], cursor: "next" });
    expect(calls).toEqual([
      { method: "app.bsky.feed.getAuthorFeed", filter: "posts_no_replies" },
      { method: "app.bsky.feed.getAuthorFeed", filter: "posts_with_replies" },
      { method: "app.bsky.feed.getAuthorFeed", filter: "posts_with_media" },
      { method: "app.bsky.feed.getActorLikes", filter: null },
    ]);
  });
  it("returns only actual replies while retaining the upstream continuation cursor", async () => {
    const post = { uri: `at://${did}/app.bsky.feed.post/one`, cid: "bafyreihdwdcefgh4dqkjv67uzcmw7ojee6xedzdetojuzjevtenxquvyku", author: { did, handle: "alice.test" }, indexedAt: "2026-10-09T00:00:00Z" };
    const record = { $type: "app.bsky.feed.post", text: "Post", createdAt: "2026-10-09T00:00:00Z" };
    const reply = { ...post, uri: `at://${did}/app.bsky.feed.post/reply`, record: { ...record, reply: { root: { uri: post.uri, cid: post.cid }, parent: { uri: post.uri, cid: post.cid } } } };
    const session = { did, fetchHandler: async () => Response.json({ cursor: "reply-page-2", feed: [{ post: { ...post, record } }, { post: reply }] }) } as unknown as OAuthSession;
    const page = await getBlueskyProfilePage({ session, tab: "replies", moderation });
    expect(page.feed.map(item => item.post.uri)).toEqual([reply.uri]);
    expect(page.cursor).toBe("reply-page-2");
  });

  it("refuses mismatched safety identity and invalid tabs before any transport", async () => {
    const session = { did, fetchHandler: async () => { throw new Error("Transport should not run"); } } as unknown as OAuthSession;
    await expect(getBlueskyProfilePage({ session, tab: "posts", moderation: { ...moderation, userDid: "did:plc:bob" } })).rejects.toThrow("account changed");
    await expect(getBlueskyProfilePage({ session, tab: "unknown" as ProfileSection, moderation })).rejects.toThrow("tab is invalid");
  });
});
