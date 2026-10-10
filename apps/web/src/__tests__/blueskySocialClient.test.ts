import { describe, expect, it } from "bun:test";
import type { AppBskyFeedDefs, ModerationOpts } from "@atproto/api";
import type { OAuthSession } from "@atproto/oauth-client-browser";
import { flattenSocialPages, getBlueskySocialCatalog, getBlueskySocialPage, nextSocialCursor, SOCIAL_FOLLOWING_FEED, socialFeedFromSearchParams, socialFeedHref, socialFeedsFromPreferences } from "@/lib/blueskySocialClient";

const feedUri = "at://did:plc:feeds/app.bsky.feed.generator/news";
const listUri = "at://did:plc:lists/app.bsky.graph.list/friends";
const baseLabeler = "did:plc:ar7c4by46qjdydhdevvrndac";
const customLabeler = "did:plc:custom";
const moderation: ModerationOpts = { userDid: "did:plc:alice", prefs: { adultContentEnabled: false, labels: {}, labelers: [{ did: customLabeler, labels: {} }], mutedWords: [], hiddenPosts: [] } };

function fakeSession(respond: (method: string, url: URL, headers: Headers) => unknown | Promise<unknown>): OAuthSession {
  return {
    did: "did:plc:alice",
    fetchHandler: async (path: string, init?: RequestInit) => {
      const url = new URL(path, "https://alice.pds.example");
      const value = await respond(url.pathname.split("/").at(-1)!, url, new Headers(init?.headers));
      return Response.json(value);
    },
  } as unknown as OAuthSession;
}

function labelerView(did: string) {
  return { $type: "app.bsky.labeler.defs#labelerViewDetailed", uri: `at://${did}/app.bsky.labeler.service/self`, cid: "bafyreihdwdcefgh4dqkjv67uzcmw7ojee6xedzdetojuzjevtenxquvyku", creator: { did, handle: "labeler.example" }, policies: { labelValues: [] }, indexedAt: "2026-10-09T00:00:00Z" };
}

describe("Social feed contracts", () => {
  it("keeps Following, pinned generators, and saved lists with correct routes", () => {
    const feeds = socialFeedsFromPreferences([
      { id: "t", type: "timeline", value: "following", pinned: true },
      { id: "l", type: "list", value: listUri, pinned: false },
      { id: "f", type: "feed", value: feedUri, pinned: true },
      { id: "d", type: "feed", value: feedUri, pinned: false },
      { id: "bad", type: "feed", value: listUri, pinned: true },
      { id: "other", type: "future-type", value: "other", pinned: true },
    ]);
    expect(feeds.map(feed => feed.kind)).toEqual(["following", "feed", "list"]);
    expect(socialFeedHref(feeds[0]!)).toBe("/social");
    for (const feed of feeds.slice(1)) {
      expect(socialFeedFromSearchParams(new URL(socialFeedHref(feed), "https://example.com").searchParams)).toMatchObject({ kind: feed.kind, uri: feed.uri });
    }
    expect(() => socialFeedFromSearchParams(new URLSearchParams({ feed: "javascript:alert(1)" }))).toThrow("invalid");
    expect(() => socialFeedFromSearchParams(new URLSearchParams({ feed: feedUri, list: listUri }))).toThrow("one social feed");
  });

  it("routes Following, generators, and lists through viewer OAuth with subscribed labelers", async () => {
    const methods: string[] = [];
    const session = fakeSession((method, url, headers) => {
      methods.push(method);
      expect(headers.get("atproto-proxy")).toBe("did:web:api.bsky.app#bsky_appview");
      expect(headers.get("atproto-accept-labelers")).toContain(customLabeler);
      expect(url.searchParams.get("cursor")).toBe("opaque+/=");
      if (method.endsWith("getFeed")) expect(url.searchParams.get("feed")).toBe(feedUri);
      if (method.endsWith("getListFeed")) expect(url.searchParams.get("list")).toBe(listUri);
      return { feed: [], cursor: "next" };
    });
    for (const feed of [SOCIAL_FOLLOWING_FEED, { kind: "feed" as const, uri: feedUri, name: "News", pinned: true }, { kind: "list" as const, uri: listUri, name: "Friends", pinned: false }]) {
      expect(await getBlueskySocialPage({ session, feed, moderation, cursor: "opaque+/=" })).toEqual({ feed: [], cursor: "next" });
    }
    expect(methods).toEqual(["app.bsky.feed.getTimeline", "app.bsky.feed.getFeed", "app.bsky.feed.getListFeed"]);
    await expect(getBlueskySocialPage({ session, feed: SOCIAL_FOLLOWING_FEED, moderation: { ...moderation, userDid: "did:plc:bob" } })).rejects.toThrow("account changed");
  });

  it("loads real preferences and definitions before exposing a catalog", async () => {
    const methods: string[] = [];
    const session = fakeSession((method, _url, headers) => {
      methods.push(method);
      expect(headers.get("atproto-proxy")).toBe("did:web:api.bsky.app#bsky_appview");
      if (method === "app.bsky.actor.getPreferences") return { preferences: [
        { $type: "app.bsky.actor.defs#savedFeedsPrefV2", items: [{ id: "f", type: "feed", value: feedUri, pinned: true }] },
        { $type: "app.bsky.actor.defs#labelersPref", labelers: [{ did: customLabeler }] },
      ] };
      if (method === "app.bsky.labeler.getServices") return { views: [labelerView(baseLabeler), labelerView(customLabeler)] };
      if (method === "app.bsky.feed.getFeedGenerators") return { feeds: [{ uri: feedUri, cid: "bafyreihdwdcefgh4dqkjv67uzcmw7ojee6xedzdetojuzjevtenxquvyku", did: "did:plc:feedservice", creator: { did: "did:plc:feeds", handle: "feeds.example" }, displayName: "Network News", indexedAt: "2026-10-09T00:00:00Z" }] };
      throw new Error(`Unexpected ${method}`);
    });
    const catalog = await getBlueskySocialCatalog(session);
    expect(catalog.feeds[1]?.name).toBe("Network News");
    expect(catalog.moderation.userDid).toBe("did:plc:alice");
    expect(catalog.moderation.labelDefs).toHaveProperty(customLabeler);
    expect(methods).toEqual(["app.bsky.actor.getPreferences", "app.bsky.labeler.getServices", "app.bsky.feed.getFeedGenerators"]);
  });

  it("fails closed when a subscribed moderation service is missing", async () => {
    const session = fakeSession(method => method === "app.bsky.actor.getPreferences"
      ? { preferences: [{ $type: "app.bsky.actor.defs#labelersPref", labelers: [{ did: customLabeler }] }] }
      : { views: [labelerView(baseLabeler)] });
    await expect(getBlueskySocialCatalog(session)).rejects.toThrow("moderation settings");
  });

  it("deduplicates overlapping pages without losing separate reposts and stops cursor loops", () => {
    const post = { uri: "at://did:plc:author/app.bsky.feed.post/one" } as AppBskyFeedDefs.PostView;
    const original = { post };
    const repost = { post, reason: { $type: "app.bsky.feed.defs#reasonRepost" as const, by: { did: "did:plc:bob", handle: "bob.example" }, indexedAt: "2026-10-09T00:00:00Z" } };
    expect(flattenSocialPages([{ feed: [original, repost] }, { feed: [original, repost] }])).toHaveLength(2);
    expect(nextSocialCursor({ feed: [], cursor: "again" }, [undefined, "again"])).toBeUndefined();
    expect(nextSocialCursor({ feed: [], cursor: "next" }, [undefined, "again"])).toBe("next");
  });
});
