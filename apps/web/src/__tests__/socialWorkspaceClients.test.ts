import { describe, expect, it, spyOn } from "bun:test";
import type { OAuthSession } from "@atproto/oauth-client-browser";
import type { ModerationOpts } from "@atproto/api";
import { addSocialListMember, deleteSocialList, getSocialList, getSocialLists, ownedSocialRecord, saveSocialList } from "@/lib/socialListsClient";
import { changeSocialSavedFeed, getSocialFeedDirectory } from "@/lib/socialFeedDirectoryClient";
const did = "did:plc:alice";
const list = `at://${did}/app.bsky.graph.list/friends`;
const feed = "at://did:plc:author/app.bsky.feed.generator/news";
const cid = "bafyreihdwdcefgh4dqkjv67uzcmw7ojee6xedzdetojuzjevtenxquvyku";
const moderation: ModerationOpts = { userDid: did, prefs: { adultContentEnabled: false, labels: {}, labelers: [{ did: "did:plc:custom", labels: {} }], mutedWords: [], hiddenPosts: [] } };
function fakeSession(respond: (method: string, url: URL, body: Record<string, unknown>, headers: Headers) => unknown | Promise<unknown>): OAuthSession {
  return { did, fetchHandler: async (path: string, init?: RequestInit) => { const url = new URL(path, "https://pds.example"); return Response.json(await respond(url.pathname.split("/").at(-1)!, url, init?.body ? JSON.parse(typeof init.body === "string" ? init.body : new TextDecoder().decode(init.body as Uint8Array)) : {}, new Headers(init?.headers))); } } as unknown as OAuthSession;
}
describe("Lists and feed directory contracts", () => {
  it("routes paginated viewer reads to AppView with subscribed labelers and real search RPC", async () => {
    const methods: string[] = [];
    const session = fakeSession((method, url, _body, headers) => {
      methods.push(method); expect(headers.get("atproto-proxy")).toBe("did:web:api.bsky.app#bsky_appview");
      expect(headers.get("atproto-accept-labelers")).toContain("did:plc:custom");
      expect(url.searchParams.get("cursor")).toBe("opaque+/=");
      if (method.endsWith("getLists")) { expect(url.searchParams.get("actor")).toBe(did); return { lists: [] }; }
      if (method.endsWith("getList")) return { list: { uri: list, cid, creator: { did, handle: "alice.example" }, name: "Friends", purpose: "app.bsky.graph.defs#curatelist", indexedAt: "2026-10-10T00:00:00Z" }, items: [] };
      if (method.endsWith("getPopularFeedGenerators")) expect(url.searchParams.get("query")).toBe("science");
      return { feeds: [] };
    });
    await getSocialLists(session, "opaque+/=", undefined, moderation);
    await getSocialList(session, list, "opaque+/=", undefined, moderation);
    await getSocialFeedDirectory(session, " science ", "opaque+/=", undefined, moderation);
    await getSocialFeedDirectory(session, "", "opaque+/=", undefined, moderation);
    expect(methods).toEqual(["app.bsky.graph.getLists", "app.bsky.graph.getList", "app.bsky.unspecced.getPopularFeedGenerators", "app.bsky.feed.getSuggestedFeeds"]);
  });
  it("rejects other-account and wrong-collection writes", () => {
    const session = fakeSession(() => ({}));
    expect(() => ownedSocialRecord(session, list.replace(did, "did:plc:bob"), "app.bsky.graph.list")).toThrow("own lists");
    expect(() => ownedSocialRecord(session, list, "app.bsky.graph.listitem")).toThrow("own lists");
    expect(() => changeSocialSavedFeed(session, "https://evil.example", "save")).toThrow("Invalid feed URI");
  });
  it("edits canonical records with a CID guard and preserves purpose and unknown fields", async () => {
    const session = fakeSession((method, _url, body, headers) => {
      expect(headers.has("atproto-proxy")).toBe(false);
      if (method.endsWith("getRecord")) return { uri: list, cid, value: { $type: "app.bsky.graph.list", name: "Before", descriptionFacets: [], purpose: "app.bsky.graph.defs#modlist", createdAt: "2026-10-10T00:00:00Z", custom: "preserved" } };
      expect(body.swapRecord).toBe(cid);
      expect(body.record).toMatchObject({ name: "After", description: "Updated", purpose: "app.bsky.graph.defs#modlist", custom: "preserved" });
      expect(body.record).not.toHaveProperty("descriptionFacets");
      return { uri: list, cid };
    });
    expect(await saveSocialList(session, "After", "Updated", list)).toBe(list);
  });
  it("deletes only the target list's canonical membership before the list", async () => {
    const deleted: string[] = [];
    const session = fakeSession((method, _url, body, headers) => {
      expect(headers.has("atproto-proxy")).toBe(false);
      if (method.endsWith("listRecords")) return { records: [{ uri: `at://${did}/app.bsky.graph.listitem/a`, cid, value: { list } }, { uri: `at://${did}/app.bsky.graph.listitem/b`, cid, value: { list: `${list}other` } }] };
      deleted.push(`${body.collection}/${body.rkey}`); return {};
    });
    await deleteSocialList(session, list);
    expect(deleted).toEqual(["app.bsky.graph.listitem/a", "app.bsky.graph.list/friends"]);
  });
  it("does not create duplicate list members when canonical repo already contains them", async () => {
    const methods: string[] = [];
    const session = fakeSession(method => {
      methods.push(method);
      if (method.endsWith("getProfile")) return { did: "did:plc:member", handle: "member.example" };
      if (method.endsWith("listRecords")) return { records: [{ uri: `at://${did}/app.bsky.graph.listitem/a`, cid, value: { list, subject: "did:plc:member" } }] };
      throw new Error("Unexpected member write");
    });
    await addSocialListMember(session, list, "@member.example");
    expect(methods).toEqual(["app.bsky.actor.getProfile", "com.atproto.repo.listRecords"]);
  });
  it("serializes preference mutations and preserves unrelated/future preferences and legacy removal", async () => {
    let preferences: Record<string, unknown>[] = [
      { $type: "app.bsky.actor.defs#adultContentPref", enabled: false },
      { $type: "future.preference", payload: { untouched: true } },
      { $type: "app.bsky.actor.defs#savedFeedsPrefV2", futureField: { retained: true }, items: [{ id: "t", type: "timeline", value: "following", pinned: true }, { id: "l", type: "list", value: list, pinned: true }, { id: "f", type: "feed", value: feed, pinned: true }] },
      { $type: "app.bsky.actor.defs#savedFeedsPref", futureLegacyField: "retained", saved: [list, feed], pinned: [list, feed] },
    ];
    let active = 0; let maxActive = 0;
    const session = fakeSession(async (method, _url, body, headers) => {
      expect(headers.get("atproto-proxy")).toBe("did:web:api.bsky.app#bsky_appview");
      if (method.endsWith("getPreferences")) { active++; maxActive = Math.max(maxActive, active); return { preferences: structuredClone(preferences) }; }
      await Promise.resolve(); preferences = body.preferences as Record<string, unknown>[]; active--; return {};
    });
    await Promise.all([changeSocialSavedFeed(session, feed, "remove"), changeSocialSavedFeed(session, "at://did:plc:author/app.bsky.feed.generator/music", "pin")]);
    expect(maxActive).toBe(1);
    expect(preferences).toContainEqual({ $type: "future.preference", payload: { untouched: true } });
    expect(preferences.find(pref => pref.$type === "app.bsky.actor.defs#savedFeedsPrefV2")!.futureField).toEqual({ retained: true });
    expect(preferences.find(pref => pref.$type === "app.bsky.actor.defs#savedFeedsPref")!.futureLegacyField).toBe("retained");
    const saved = preferences.find(pref => pref.$type === "app.bsky.actor.defs#savedFeedsPrefV2")!.items as { value: string; pinned: boolean }[];
    expect(saved.map(item => item.value)).toEqual(["following", list, "at://did:plc:author/app.bsky.feed.generator/music"]);
    expect(preferences.find(pref => pref.$type === "app.bsky.actor.defs#savedFeedsPref")!.saved).not.toContain(feed);
  });
});
it("stops canonical membership cleanup if a server repeats a cursor", async () => {
  let deletedList = false;
  const session = fakeSession(method => {
    if (method.endsWith("listRecords")) return { records: [], cursor: "repeat" };
    deletedList = true; return {};
  });
  await expect(deleteSocialList(session, list)).rejects.toThrow("pagination stalled");
  expect(deletedList).toBe(false);
});
it("a failed preference write does not poison later queued writes", async () => {
  let writes = 0;
  const session = fakeSession(method => {
    if (method.endsWith("getPreferences")) return { preferences: [] };
    if (++writes === 1) throw new Error("Temporary server failure");
    return {};
  });
  await expect(changeSocialSavedFeed(session, feed, "save")).rejects.toThrow("Temporary server failure");
  await changeSocialSavedFeed(session, feed, "pin");
  expect(writes).toBe(2);
});

it("saving an existing feed preserves its position, pin state, and future item fields", async () => {
  let written: Record<string, unknown>[] = [];
  const original = [{ id: "first", type: "feed", value: feed, pinned: true, futureItemField: "retained" }, { id: "second", type: "list", value: list, pinned: true }, { id: "timeline", type: "timeline", value: "following", pinned: false }];
  const session = fakeSession((method, _url, body) => {
    if (method.endsWith("getPreferences")) return { preferences: [{ $type: "app.bsky.actor.defs#savedFeedsPrefV2", items: original }] };
    written = body.preferences as Record<string, unknown>[]; return {};
  });
  await changeSocialSavedFeed(session, feed, "save");
  expect(written[0]!.items).toEqual(original);
});
it("creates curated list records on the viewer PDS with normalized text and no AppView proxy", async () => {
  let created: Record<string, unknown> | undefined;
  const session = fakeSession((method, _url, body, headers) => {
    expect(method).toBe("com.atproto.repo.createRecord");
    expect(headers.has("atproto-proxy")).toBe(false);
    created = body;
    return { uri: list, cid };
  });
  expect(await saveSocialList(session, "  New List  ", "  Description  ")).toBe(list);
  expect(created).toMatchObject({ repo: did, collection: "app.bsky.graph.list", record: { $type: "app.bsky.graph.list", name: "New List", description: "Description", purpose: "app.bsky.graph.defs#curatelist" } });
  expect(Number.isFinite(Date.parse((created!.record as { createdAt: string }).createdAt))).toBe(true);
});
it("preserves PDS missing-scope errors so list creation exposes login recovery", async () => {
  const session = { did, fetchHandler: async () => Response.json({ error: "InsufficientScope", message: "Missing required scope repo:app.bsky.graph.list" }, { status: 403 }) } as unknown as OAuthSession;
  const error = await saveSocialList(session, "New List", "").catch(error => error);
  const { socialErrorMessage } = await import("@/lib/blueskySocialClient");
  const { SCOPE_RECOVERY_MESSAGE } = await import("@/lib/oauthScopeRecovery");
  expect(socialErrorMessage(error)).toBe(SCOPE_RECOVERY_MESSAGE);
});
it("waits for a successfully created list to index without issuing another create", async () => {
  const newUri = `at://${did}/app.bsky.graph.list/indexing`;
  let creates = 0; let reads = 0;
  const session = { did, fetchHandler: async (path: string) => {
    if (path.includes("createRecord")) { creates++; return Response.json({ uri: newUri, cid }); }
    if (++reads === 1) return Response.json({ error: "InvalidRequest", message: "List not found" }, { status: 400 });
    return Response.json({ list: { uri: newUri, cid, creator: { did, handle: "alice.example" }, name: "New List", purpose: "app.bsky.graph.defs#curatelist", indexedAt: "2026-10-10T00:00:00Z" }, items: [] });
  } } as unknown as OAuthSession;
  expect(await saveSocialList(session, "New List", "")).toBe(newUri);
  expect((await getSocialList(session, newUri)).list.name).toBe("New List");
  expect(creates).toBe(1); expect(reads).toBe(2);
});
it("does not retry unknown list links or non-indexing errors after successful creation", async () => {
  let reads = 0;
  const newUri = `at://${did}/app.bsky.graph.list/no-retry`;
  const session = { did, fetchHandler: async (path: string) => {
    if (path.includes("createRecord")) return Response.json({ uri: newUri, cid });
    reads++; return Response.json({ error: "InvalidRequest", message: "List not found" }, { status: 400 });
  } } as unknown as OAuthSession;
  await expect(getSocialList(session, `${newUri}-unknown`)).rejects.toThrow("List not found");
  expect(reads).toBe(1);
  await saveSocialList(session, "New List", "");
  session.fetchHandler = async () => { reads++; return Response.json({ error: "InvalidRequest", message: "Missing required scope" }, { status: 403 }); };
  await expect(getSocialList(session, newUri)).rejects.toThrow("Missing required scope");
  expect(reads).toBe(2);
});
it("aborts indexing backoff immediately when navigation cancels the read", async () => {
  const newUri = `at://${did}/app.bsky.graph.list/cancel-indexing`;
  const session = { did, fetchHandler: async (path: string) => path.includes("createRecord") ? Response.json({ uri: newUri, cid }) : Response.json({ error: "InvalidRequest", message: "List not found" }, { status: 400 }) } as unknown as OAuthSession;
  await saveSocialList(session, "New List", "");
  const controller = new AbortController();
  const pending = getSocialList(session, newUri, undefined, controller.signal);
  await new Promise(resolve => setTimeout(resolve, 10));
  controller.abort();
  await expect(pending).rejects.toHaveProperty("name", "AbortError");
});

it("exhausts bounded indexing retries and leaves successful creation untouched", async () => {
  const newUri = `at://${did}/app.bsky.graph.list/exhaust-indexing`;
  let creates = 0; let reads = 0;
  const session = { did, fetchHandler: async (path: string) => {
    if (path.includes("createRecord")) { creates++; return Response.json({ uri: newUri, cid }); }
    reads++; return Response.json({ error: "InvalidRequest", message: "List not found" }, { status: 400 });
  } } as unknown as OAuthSession;
  const originalTimeout = globalThis.setTimeout;
  const timeout = spyOn(globalThis, "setTimeout").mockImplementation(Object.assign((callback: (...args: unknown[]) => void, delay?: number, ...args: unknown[]) => originalTimeout(callback, Math.min(delay ?? 0, 1), ...args), originalTimeout));
  try {
    await saveSocialList(session, "New List", "");
    await expect(getSocialList(session, newUri)).rejects.toThrow("List not found");
    expect(creates).toBe(1); expect(reads).toBe(6);
    expect(timeout.mock.calls.map(call => call[1])).toEqual([500, 1_000, 2_000, 4_000, 8_000]);
  } finally { timeout.mockRestore(); }
});
