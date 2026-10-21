import { describe, expect, it } from "bun:test";
import type { AppBskyFeedDefs, ModerationOpts } from "@atproto/api";
import type { OAuthSession } from "@atproto/oauth-client-browser";
import { flattenSocialPages, getBlueskySocialCatalog, getBlueskySocialPage, hydrateBlueskySocialPage, nextSocialCursor, SOCIAL_FOLLOWING_FEED, socialFeedFromSearchParams, socialFeedHref, socialFeedsFromPreferences, safeSocialFeedAvatarUrl } from "@/lib/blueskySocialClient";

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
  it("returns feed rows before fetching reply context, then hydrates them separately", async () => {
    const cid = "bafyreihdwdcefgh4dqkjv67uzcmw7ojee6xedzdetojuzjevtenxquvyku";
    const parent = { uri: "at://did:plc:parent/app.bsky.feed.post/one", cid,
      author: { did: "did:plc:parent", handle: "parent.test" },
      record: { $type: "app.bsky.feed.post", text: "Parent", createdAt: "2026-10-12T00:00:00Z" }, indexedAt: "2026-10-12T00:00:00Z" };
    const reply = { post: { ...parent, uri: "at://did:plc:reply/app.bsky.feed.post/one", record: { ...parent.record, text: "Reply", reply: { parent: { uri: parent.uri, cid }, root: { uri: parent.uri, cid } } } } };
    const methods: string[] = [];
    const session = fakeSession(method => {
      methods.push(method);
      if (method === "app.bsky.feed.getTimeline") return { feed: [reply] };
      if (method === "app.bsky.feed.getPosts") return { posts: [parent] };
      throw new Error(`Unexpected ${method}`);
    });
    const page = await getBlueskySocialPage({ session, feed: SOCIAL_FOLLOWING_FEED, moderation, deferReplyHydration: true });
    expect(page.feed[0]?.reply).toBeUndefined();
    expect(methods).toEqual(["app.bsky.feed.getTimeline"]);
    const hydrated = await hydrateBlueskySocialPage(session, page, new AbortController().signal, moderation);
    expect(methods).toEqual(["app.bsky.feed.getTimeline", "app.bsky.feed.getPosts"]);
    expect(hydrated.feed[0]?.reply?.parent).toMatchObject({ uri: parent.uri, author: parent.author });
  });
  it("accepts only HTTPS avatar URLs without credentials", () => {
    expect(safeSocialFeedAvatarUrl("https://images.example/feed.png")).toBe("https://images.example/feed.png");
    for (const value of [undefined, "http://images.example/feed.png", "javascript:alert(1)", "data:image/png;base64,abc", "/image.png", "https://user:password@images.example/feed.png"]) {
      expect(safeSocialFeedAvatarUrl(value)).toBeUndefined();
    }
  });

  for (const profileLabel of [undefined, "porn"] as const) {
    it(`loads safe list avatars while withholding moderated creator avatars (${profileLabel ?? "unlabeled"})`, async () => {
      const session = fakeSession(method => {
        if (method === "app.bsky.actor.getPreferences") return { preferences: [{ $type: "app.bsky.actor.defs#savedFeedsPrefV2", items: [{ id: "l", type: "list", value: listUri, pinned: false }] }] };
        if (method === "app.bsky.labeler.getServices") return { views: [labelerView(baseLabeler)] };
        if (method === "app.bsky.graph.getList") return { list: { uri: listUri, cid: "bafyreihdwdcefgh4dqkjv67uzcmw7ojee6xedzdetojuzjevtenxquvyku", creator: { did: "did:plc:lists", handle: "lists.example", labels: profileLabel ? [{ src: baseLabeler, uri: "at://did:plc:lists/app.bsky.actor.profile/self", val: profileLabel, cts: "2026-10-09T00:00:00Z" }] : [] }, name: "Friends", avatar: "https://images.example/list.png", purpose: "app.bsky.graph.defs#curatelist", indexedAt: "2026-10-09T00:00:00Z" }, items: [] };
        throw new Error(`Unexpected ${method}`);
      });
      const catalog = await getBlueskySocialCatalog(session);
      expect(catalog.feeds[1]?.avatar).toBe(profileLabel ? undefined : "https://images.example/list.png");
    });
  }

  for (const unsafe of ["blocked", "muted", "content label", "creator label"] as const) {
    it(`withholds ${unsafe} generator and list names without losing saved routes`, async () => {
      const creator = { did: "did:plc:other", handle: "other.example", viewer: { blocking: unsafe === "blocked" ? "at://did:plc:alice/app.bsky.graph.block/one" : undefined, muted: unsafe === "muted" }, labels: unsafe === "creator label" ? [{ src: baseLabeler, uri: "did:plc:other", val: "!hide", cts: "2026-10-09T00:00:00Z" }] : [] };
      const labels = (uri: string) => unsafe === "content label" ? [{ src: baseLabeler, uri, val: "!hide", cts: "2026-10-09T00:00:00Z" }] : [];
      const session = fakeSession(method => {
        if (method === "app.bsky.actor.getPreferences") return { preferences: [{ $type: "app.bsky.actor.defs#savedFeedsPrefV2", items: [{ id: "f", type: "feed", value: feedUri, pinned: true }, { id: "l", type: "list", value: listUri, pinned: false }] }] };
        if (method === "app.bsky.labeler.getServices") return { views: [labelerView(baseLabeler)] };
        if (method === "app.bsky.feed.getFeedGenerators") return { feeds: [{ uri: feedUri, cid: "bafyreihdwdcefgh4dqkjv67uzcmw7ojee6xedzdetojuzjevtenxquvyku", did: "did:plc:feedservice", creator, displayName: "Unsafe Feed Name", avatar: "https://images.example/hidden-feed.png", labels: labels(feedUri), indexedAt: "2026-10-09T00:00:00Z" }] };
        if (method === "app.bsky.graph.getList") return { list: { uri: listUri, cid: "bafyreihdwdcefgh4dqkjv67uzcmw7ojee6xedzdetojuzjevtenxquvyku", creator, name: "Unsafe List Name", avatar: "https://images.example/hidden-list.png", purpose: "app.bsky.graph.defs#curatelist", labels: labels(listUri), indexedAt: "2026-10-09T00:00:00Z" }, items: [] };
        throw new Error(`Unexpected ${method}`);
      });
      const catalog = await getBlueskySocialCatalog(session);
      expect(catalog.feeds.slice(1)).toEqual([{ kind: "feed", uri: feedUri, name: "Saved Feed", pinned: true }, { kind: "list", uri: listUri, name: "Saved List", pinned: false }]);
    });
  }

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

  it("returns timeline content without requesting optional reply context on the critical path", async () => {
    const cid = "bafyreihdwdcefgh4dqkjv67uzcmw7ojee6xedzdetojuzjevtenxquvyku";
    const methods: string[] = [];
    const post = { uri: "at://did:plc:author/app.bsky.feed.post/reply", cid, author: { did: "did:plc:author", handle: "author.test" }, indexedAt: "2026-10-09T00:00:00Z", record: { $type: "app.bsky.feed.post", text: "A reply", createdAt: "2026-10-09T00:00:00Z", reply: { root: { uri: "at://did:plc:parent/app.bsky.feed.post/root", cid }, parent: { uri: "at://did:plc:parent/app.bsky.feed.post/root", cid } } } };
    const session = fakeSession(method => { methods.push(method); if (method === "app.bsky.feed.getTimeline") return { feed: [{ post }], cursor: "next" }; throw new Error("Optional context must be deferred"); });
    const page = await getBlueskySocialPage({ session, feed: SOCIAL_FOLLOWING_FEED, moderation, deferReplyHydration: true });
    expect(page.feed[0]?.post.uri).toBe(post.uri);
    expect(page.cursor).toBe("next");
    expect(methods).toEqual(["app.bsky.feed.getTimeline"]);
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
      if (method === "app.bsky.feed.getFeedGenerators") return { feeds: [{ uri: feedUri, cid: "bafyreihdwdcefgh4dqkjv67uzcmw7ojee6xedzdetojuzjevtenxquvyku", did: "did:plc:feedservice", creator: { did: "did:plc:feeds", handle: "feeds.example" }, displayName: "Network News", avatar: "https://images.example/feed.png", indexedAt: "2026-10-09T00:00:00Z" }] };
      throw new Error(`Unexpected ${method}`);
    });
    const catalog = await getBlueskySocialCatalog(session);
    expect(catalog.feeds[1]?.name).toBe("Network News");
    expect(catalog.feeds[1]?.avatar).toBe("https://images.example/feed.png");
    expect(catalog.moderation.userDid).toBe("did:plc:alice");
    expect(catalog.moderation.labelDefs).toHaveProperty(customLabeler);
    expect(methods).toEqual(["app.bsky.actor.getPreferences", "app.bsky.labeler.getServices", "app.bsky.feed.getFeedGenerators"]);
  });

  it("loads brand moderation without requiring saved-feed navigation grants", async () => {
    const methods: string[] = [];
    const session = fakeSession(method => {
      methods.push(method);
      if (method === "app.bsky.actor.getPreferences") return { preferences: [{ $type: "app.bsky.actor.defs#savedFeedsPrefV2", items: [{ id: "f", type: "feed", value: feedUri, pinned: true }] }] };
      if (method === "app.bsky.labeler.getServices") return { views: [labelerView(baseLabeler)] };
      throw new Error(`Unexpected brand grant ${method}`);
    });
    const catalog = await getBlueskySocialCatalog(session, undefined, { includeFeeds: false });
    expect(catalog.feeds).toEqual([]);
    expect(catalog.moderation.userDid).toBe(session.did);
    expect(methods).toEqual(["app.bsky.actor.getPreferences", "app.bsky.labeler.getServices"]);
  });

  it("exposes verified moderation before optional saved-feed metadata completes", async () => {
    let finish!: (data: unknown) => void;
    const metadata = new Promise<unknown>(resolve => { finish = resolve; });
    let ready: Awaited<ReturnType<typeof getBlueskySocialCatalog>> | undefined;
    const session = fakeSession(method => {
      if (method === "app.bsky.actor.getPreferences") return { preferences: [{ $type: "app.bsky.actor.defs#savedFeedsPrefV2", items: [{ id: "f", type: "feed", value: feedUri, pinned: true }] }] };
      if (method === "app.bsky.labeler.getServices") return { views: [labelerView(baseLabeler)] };
      if (method === "app.bsky.feed.getFeedGenerators") return metadata;
      throw new Error(`Unexpected ${method}`);
    });
    const pending = getBlueskySocialCatalog(session, undefined, { onReady: catalog => { ready = catalog; } });
    await new Promise(resolve => setTimeout(resolve, 20));
    expect(ready?.moderation.userDid).toBe(session.did);
    expect(ready?.feeds[1]?.name).toBe("Saved Feed");
    finish({ feeds: [] });
    await pending;
  });

  describe("catalog refresh metadata", () => {
    const otherLabeler = "did:plc:otherlabeler";
    const newFeedUri = "at://did:plc:feeds/app.bsky.feed.generator/new";
    const items = [{ id: "f", type: "feed", value: feedUri, pinned: true }, { id: "l", type: "list", value: listUri, pinned: false }];
    function catalogSession(options: {
      items?: typeof items;
      labelers?: string[];
      adultContentEnabled?: boolean;
      changedDefinitions?: boolean;
      viewer?: string;
      unsafe?: boolean;
      metadata?: (method: string) => Promise<unknown>;
    } = {}) {
      const session = fakeSession(async method => {
        if (method === "app.bsky.actor.getPreferences") return { preferences: [
          { $type: "app.bsky.actor.defs#savedFeedsPrefV2", items: options.items ?? items },
          { $type: "app.bsky.actor.defs#adultContentPref", enabled: options.adultContentEnabled ?? false },
          { $type: "app.bsky.actor.defs#labelersPref", labelers: (options.labelers ?? [customLabeler, otherLabeler]).map(did => ({ did })) },
        ] };
        if (method === "app.bsky.labeler.getServices") return { views: [baseLabeler, customLabeler, otherLabeler].map(did => ({
          ...labelerView(did),
          policies: { labelValues: ["test-label"], labelValueDefinitions: [{ identifier: "test-label", severity: options.changedDefinitions ? "alert" : "inform", blurs: "none", defaultSetting: "warn", locales: [{ lang: "en", name: "Test Label", description: "Test definition" }] }] },
        })) };
        if (method === "app.bsky.feed.getFeedGenerators" || method === "app.bsky.graph.getList") {
          if (options.metadata) return options.metadata(method);
          const creator = { did: "did:plc:feeds", handle: "feeds.example", viewer: options.unsafe ? { blocking: "at://did:plc:alice/app.bsky.graph.block/one" } : {} };
          const common = { cid: "bafyreihdwdcefgh4dqkjv67uzcmw7ojee6xedzdetojuzjevtenxquvyku", creator, indexedAt: "2026-10-09T00:00:00Z" };
          if (method === "app.bsky.feed.getFeedGenerators") return { feeds: [{ ...common, uri: feedUri, did: "did:plc:feedservice", displayName: "Network News", avatar: "https://images.example/feed.png" }] };
          return { list: { ...common, uri: listUri, name: "Network Friends", avatar: "https://images.example/list.png", purpose: "app.bsky.graph.defs#curatelist" }, items: [] };
        }
        throw new Error(`Unexpected ${method}`);
      });
      return options.viewer ? { ...session, did: options.viewer } as OAuthSession : session;
    }
    const placeholders: import("@/lib/blueskySocialClient").SocialFeed[] = [{ kind: "feed", uri: feedUri, name: "Saved Feed", pinned: true }, { kind: "list", uri: listUri, name: "Saved List", pinned: false }];

    it("retains names and avatars in onReady during a same-safety metadata stall with reordered labelers", async () => {
      const previousCatalog = await getBlueskySocialCatalog(catalogSession());
      let finish!: (error: Error) => void;
      const metadata = new Promise<unknown>((_resolve, reject) => { finish = reject; });
      let markReady!: (catalog: Awaited<ReturnType<typeof getBlueskySocialCatalog>>) => void;
      const ready = new Promise<Awaited<ReturnType<typeof getBlueskySocialCatalog>>>(resolve => { markReady = resolve; });
      let completed = false;
      const pending = getBlueskySocialCatalog(catalogSession({ labelers: [otherLabeler, customLabeler], metadata: () => metadata }), undefined, { previousCatalog, onReady: markReady }).then(catalog => { completed = true; return catalog; });
      try {
        const catalog = await ready;
        expect(completed).toBe(false);
        expect(catalog.feeds).toEqual(previousCatalog.feeds);
        expect(catalog.feeds.slice(1).map(feed => [feed.name, feed.avatar])).toEqual([["Network News", "https://images.example/feed.png"], ["Network Friends", "https://images.example/list.png"]]);
      } finally {
        finish(new Error("Metadata offline"));
        await pending;
      }
    });

    it("uses fresh membership and pinning, leaves new rows as placeholders, and matches both URI and kind", async () => {
      const previousCatalog = await getBlueskySocialCatalog(catalogSession());
      let ready: Awaited<ReturnType<typeof getBlueskySocialCatalog>> | undefined;
      const metadata = async () => { throw new Error("Metadata offline"); };
      const catalog = await getBlueskySocialCatalog(catalogSession({ items: [{ ...items[0]!, pinned: false }, { id: "new", type: "feed", value: newFeedUri, pinned: true }], metadata }), undefined, { previousCatalog, onReady: value => { ready = value; } });
      const expected: import("@/lib/blueskySocialClient").SocialFeed[] = [SOCIAL_FOLLOWING_FEED, { kind: "feed", uri: newFeedUri, name: "Saved Feed", pinned: true }, { kind: "feed", uri: feedUri, name: "Network News", avatar: "https://images.example/feed.png", pinned: false }];
      expect(ready?.feeds).toEqual(expected);
      expect(catalog.feeds).toEqual(expected);
      expect(catalog.feeds.some(feed => feed.uri === listUri)).toBe(false);
      const wrongKind = { ...previousCatalog, feeds: previousCatalog.feeds.map(feed => feed.uri === feedUri ? { ...feed, kind: "list" as const } : feed) };
      const mismatched = await getBlueskySocialCatalog(catalogSession({ items: [items[0]!], metadata }), undefined, { previousCatalog: wrongKind });
      expect(mismatched.feeds[1]).toEqual(placeholders[0]);
    });

    for (const change of ["preferences", "definitions", "viewer"] as const) {
      it(`does not reuse decorations when ${change} change`, async () => {
        const previousCatalog = await getBlueskySocialCatalog(catalogSession());
        let ready: Awaited<ReturnType<typeof getBlueskySocialCatalog>> | undefined;
        const catalog = await getBlueskySocialCatalog(catalogSession({ adultContentEnabled: change === "preferences", changedDefinitions: change === "definitions", viewer: change === "viewer" ? "did:plc:bob" : undefined, metadata: async () => { throw new Error("Metadata offline"); } }), undefined, { previousCatalog, onReady: value => { ready = value; } });
        expect(ready?.feeds.slice(1)).toEqual(placeholders);
        expect(catalog.feeds.slice(1)).toEqual(placeholders);
        expect(catalog.moderation.userDid).toBe(change === "viewer" ? "did:plc:bob" : "did:plc:alice");
      });
    }

    for (const kind of ["feed", "list"] as const) {
      it(`reports optional ${kind} metadata failure while retaining compatible names and avatars`, async () => {
        const savedItems = items.filter(item => item.type === kind);
        const previousCatalog = await getBlueskySocialCatalog(catalogSession({ items: savedItems }));
        const catalog = await getBlueskySocialCatalog(catalogSession({ items: savedItems, metadata: async () => { throw new Error(`${kind} metadata unavailable`); } }), undefined, { previousCatalog });
        expect(catalog.feeds).toEqual(previousCatalog.feeds);
        expect(catalog.metadataError).toBe("This social feed could not be loaded. Please retry.");
        expect(catalog.moderation.userDid).toBe("did:plc:alice");
      });
    }

    it("removes retained names and avatars when fresh successful metadata is unsafe", async () => {
      const previousCatalog = await getBlueskySocialCatalog(catalogSession());
      let ready: Awaited<ReturnType<typeof getBlueskySocialCatalog>> | undefined;
      const catalog = await getBlueskySocialCatalog(catalogSession({ unsafe: true }), undefined, { previousCatalog, onReady: value => { ready = value; } });
      expect(ready?.feeds).toEqual(previousCatalog.feeds);
      expect(catalog.feeds.slice(1)).toEqual(placeholders);
      expect(catalog.metadataError).toBeUndefined();
    });

    it("does not expose a previous catalog when required safety definitions fail", async () => {
      const previousCatalog = await getBlueskySocialCatalog(catalogSession());
      let ready = false;
      const session = fakeSession(method => {
        if (method === "app.bsky.actor.getPreferences") return { preferences: [{ $type: "app.bsky.actor.defs#savedFeedsPrefV2", items }, { $type: "app.bsky.actor.defs#labelersPref", labelers: [{ did: customLabeler }] }] };
        if (method === "app.bsky.labeler.getServices") return { views: [labelerView(baseLabeler)] };
        throw new Error(`Unexpected ${method}`);
      });
      await expect(getBlueskySocialCatalog(session, undefined, { previousCatalog, onReady: () => { ready = true; } })).rejects.toThrow("moderation settings");
      expect(ready).toBe(false);
    });
  });

  it("fails closed when a subscribed moderation service is missing", async () => {
    const session = fakeSession(method => method === "app.bsky.actor.getPreferences"
      ? { preferences: [{ $type: "app.bsky.actor.defs#labelersPref", labelers: [{ did: customLabeler }] }] }
      : { views: [labelerView(baseLabeler)] });
    await expect(getBlueskySocialCatalog(session)).rejects.toThrow("moderation settings");
  });

  it("reuses the definitions response for labeler identities and withholds blocked names and avatars", async () => {
    for (const blocked of [false, true]) {
      let serviceRequests = 0;
      const session = fakeSession(method => {
        if (method === "app.bsky.actor.getPreferences") return { preferences: [{ $type: "app.bsky.actor.defs#savedFeedsPrefV2", items: [] }] };
        if (method === "app.bsky.labeler.getServices") {
          serviceRequests += 1;
          const service = labelerView(baseLabeler);
          return { views: [{ ...service, creator: { ...service.creator, displayName: "  Example Labeler  ", avatar: "https://images.example/labeler.png", viewer: blocked ? { blocking: "at://did:plc:alice/app.bsky.graph.block/one" } : {} } }] };
        }
        throw new Error(`Unexpected ${method}`);
      });
      const catalog = await getBlueskySocialCatalog(session);
      expect(catalog.moderation.labelerAvatars?.[baseLabeler]).toBe(blocked ? undefined : "https://images.example/labeler.png");
      expect(catalog.moderation.labelerProfiles?.[baseLabeler]).toEqual(blocked ? { handle: "labeler.example" } : { displayName: "Example Labeler", handle: "labeler.example" });
      expect(serviceRequests).toBe(1);
    }
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
