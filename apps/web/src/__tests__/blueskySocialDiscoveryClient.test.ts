import { afterEach, describe, expect, it, mock, spyOn } from "bun:test";
import type { Agent, AppBskyActorDefs, ModerationOpts } from "@atproto/api";
import type { OAuthSession } from "@atproto/oauth-client-browser";
import * as BaseClient from "@/lib/blueskySocialClient";
import { getSocialExplorePage, getSocialNotificationsPage, getSocialNotificationUnread, markSocialNotificationsSeen, notificationPostUri, nextDiscoveryCursor, type SocialNotification } from "@/lib/blueskySocialDiscoveryClient";

const did = "did:plc:viewer";
const session = { did } as unknown as OAuthSession;
const moderation: ModerationOpts = { userDid: did, prefs: { adultContentEnabled: false, labels: {}, labelers: [{ did: "did:plc:labeler", labels: {} }], mutedWords: [], hiddenPosts: [] } };
const actor: AppBskyActorDefs.ProfileView = { did: "did:plc:other", handle: "other.test" };
const restores: (() => void)[] = [];
afterEach(() => restores.splice(0).reverse().forEach(restore => restore()));
function agent() {
  const calls = {
    configureLabelers: mock(() => {}),
    suggestions: mock(async () => ({ data: { actors: [actor], cursor: "next" } })),
    actors: mock(async () => ({ data: { actors: [actor] } })),
    search: mock(async () => ({ data: { posts: [] } })),
    notifications: mock(async () => ({ data: { notifications: [] as SocialNotification[], cursor: "next", seenAt: "2026-10-10T00:00:00Z" } })),
    posts: mock(async (_params: { uris: string[] }, _options: { signal?: AbortSignal }) => { void _params; void _options; return { data: { posts: [] } }; }),
    unread: mock(async () => ({ data: { count: 3 } })),
    seen: mock(async () => ({ success: true })),
  };
  const instance = { configureLabelers: calls.configureLabelers, app: { bsky: { actor: { getSuggestions: calls.suggestions, searchActors: calls.actors }, feed: { searchPosts: calls.search, getPosts: calls.posts }, notification: { listNotifications: calls.notifications, getUnreadCount: calls.unread, updateSeen: calls.seen } } } };
  const create = spyOn(BaseClient, "createAuthenticatedAppViewAgent").mockReturnValue(instance as unknown as Agent);
  restores.push(() => create.mockRestore());
  return { ...calls, create };
}
function notification(reason = "reply", uri = "at://did:plc:other/app.bsky.feed.post/one"): SocialNotification {
  return { uri, cid: "bafyreia", author: actor, reason, record: {}, isRead: false, indexedAt: "2026-10-10T00:00:00Z" };
}

describe("authenticated discovery clients", () => {
  it("requests real suggestions, post search and actor search with cancellation and labelers", async () => {
    const calls = agent();
    const signal = new AbortController().signal;
    const args = { session, moderation, signal, kind: "posts" as const, cursor: "cursor" };
    expect((await getSocialExplorePage({ ...args, query: " " })).actors).toEqual([actor]);
    expect(calls.suggestions).toHaveBeenCalledWith({ cursor: "cursor", limit: 25 }, { signal });
    await getSocialExplorePage({ ...args, query: "  science  " });
    expect(calls.search).toHaveBeenCalledWith({ cursor: "cursor", limit: 25, q: "science", sort: "latest" }, { signal });
    await getSocialExplorePage({ ...args, query: "alice", kind: "people" });
    expect(calls.actors).toHaveBeenCalledWith({ cursor: "cursor", limit: 25, q: "alice" }, { signal });
    expect(calls.configureLabelers).toHaveBeenCalledWith(["did:plc:labeler"]);
    expect(calls.create).toHaveBeenCalledWith(session);
  });
  it("rejects moderation belonging to a different account before network requests", async () => {
    const calls = agent();
    await expect(getSocialExplorePage({ session, moderation: { ...moderation, userDid: "did:plc:other" }, query: "test", kind: "posts" })).rejects.toThrow("account changed");
    await expect(getSocialNotificationsPage({ session, moderation: { ...moderation, userDid: "did:plc:other" } })).rejects.toThrow("account changed");
    expect(calls.create).not.toHaveBeenCalled();
  });
  it("hydrates notification subjects in bounded deduplicated batches", async () => {
    const calls = agent();
    const items = Array.from({ length: 30 }, (_, index) => notification("reply", `at://did:plc:other/app.bsky.feed.post/p${index}`));
    calls.notifications.mockResolvedValue({ data: { notifications: [...items, items[0]], cursor: "next", seenAt: "2026-10-10T00:00:00Z" } });
    const signal = new AbortController().signal;
    const page = await getSocialNotificationsPage({ session, moderation, cursor: "cursor", signal });
    expect(page.notifications.length).toBe(31);
    expect(page.cursor).toBe("next");
    expect(calls.notifications).toHaveBeenCalledWith({ cursor: "cursor", limit: 30 }, { signal });
    expect(calls.posts.mock.calls.map(call => call[0].uris.length)).toEqual([25, 5]);
    expect(calls.posts.mock.calls[0][1]).toEqual({ signal });
  });
  it("resolves likes/reposts through reasonSubject or strongRefs, and other notifications safely", () => {
    const uri = "at://did:plc:viewer/app.bsky.feed.post/liked";
    expect(notificationPostUri({ ...notification("like"), reasonSubject: uri })).toBe(uri);
    expect(notificationPostUri({ ...notification("repost"), record: { subject: { uri, cid: "bafyreia" } } })).toBe(uri);
    expect(notificationPostUri(notification("follow"))).toBeUndefined();
    expect(notificationPostUri({ ...notification("like"), reasonSubject: "javascript:alert(1)" })).toBeUndefined();
    expect(notificationPostUri(notification("mention"))).toContain("/one");
  });
  it("propagates unavailable services and stops hydration after cancellation", async () => {
    const calls = agent();
    calls.search.mockRejectedValueOnce(new Error("MethodNotImplemented"));
    await expect(getSocialExplorePage({ session, moderation, query: "science", kind: "posts" })).rejects.toThrow("MethodNotImplemented");
    const controller = new AbortController();
    calls.notifications.mockImplementationOnce(async () => { controller.abort(); return { data: { notifications: [notification()], cursor: "next", seenAt: "2026-10-10T00:00:00Z" } }; });
    await expect(getSocialNotificationsPage({ session, moderation, signal: controller.signal })).rejects.toThrow();
    expect(calls.posts).not.toHaveBeenCalled();
  });
  it("reads unread counts and marks seen using the explicit timestamp", async () => {
    const calls = agent();
    const signal = new AbortController().signal;
    expect(await getSocialNotificationUnread(session, signal)).toBe(3);
    expect(calls.unread).toHaveBeenCalledWith({}, { signal });
    await markSocialNotificationsSeen(session, "2026-10-10T00:00:00Z");
    expect(calls.seen).toHaveBeenCalledWith({ seenAt: "2026-10-10T00:00:00Z" });
    expect(nextDiscoveryCursor({ cursor: "loop" }, [undefined, "loop"])).toBeUndefined();
    expect(nextDiscoveryCursor({ cursor: "next" }, [undefined])).toBe("next");
  });
});
