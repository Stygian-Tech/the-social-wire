import { describe, expect, it } from "bun:test";
import { type Agent, type AppBskyFeedDefs } from "@atproto/api";
import { socialReplyMetadata } from "@/lib/socialReplyMetadata";
import { hydrateSocialReplies } from "@/lib/hydrateSocialReplies";
import { PENDING_SOCIAL_REPLY_POST } from "@/lib/pendingSocialReplyPost";

const cid = "bafyreihdwdcefgh4dqkjv67uzcmw7ojee6xedzdetojuzjevtenxquvyku";
const post = (key: string): AppBskyFeedDefs.PostView => ({ uri: `at://did:plc:alice/app.bsky.feed.post/${key}`, cid, author: { did: "did:plc:alice", handle: "alice.test" }, record: { $type: "app.bsky.feed.post", text: key, createdAt: "2026-10-11T00:00:00Z" }, indexedAt: "2026-10-11T00:00:00Z" });
const parent = post("parent");
const root = post("root");
const reply: AppBskyFeedDefs.FeedViewPost = { post: { ...post("reply"), record: { ...post("reply").record, reply: { parent: { uri: parent.uri, cid }, root: { uri: root.uri, cid } } } } };
function agent(respond: (uris: string[], signal?: AbortSignal) => Promise<AppBskyFeedDefs.PostView[]>): Agent {
  return { app: { bsky: { feed: { getPosts: async (params: { uris: string[] }, options: { signal?: AbortSignal }) => ({ data: { posts: await respond(params.uris, options.signal) } }) } } } } as unknown as Agent;
}

describe("record-only social reply context", () => {
  it("recognizes references without misclassifying ordinary, malformed, or self-parent records", () => {
    expect(socialReplyMetadata(reply)?.parent).toMatchObject({ uri: parent.uri });
    expect(socialReplyMetadata(reply)?.parent).toMatchObject({ $type: PENDING_SOCIAL_REPLY_POST });
    expect(socialReplyMetadata({ post: parent })).toBeUndefined();
    expect(socialReplyMetadata({ post: { ...reply.post, record: { reply: {} } } })).toBeUndefined();
    expect(socialReplyMetadata({ post: { ...reply.post, uri: parent.uri } })).toBeUndefined();
  });
  it("hydrates the immediate parent and root once while preserving source order and repost reasons", async () => {
    const calls: string[][] = [];
    const reason = { $type: "app.bsky.feed.defs#reasonRepost" as const, by: parent.author, indexedAt: parent.indexedAt };
    const items = await hydrateSocialReplies(agent(async uris => { calls.push(uris); return [parent, root]; }), [reply, { ...reply, reason }]);
    expect(calls).toEqual([[parent.uri, root.uri]]);
    expect(items.map(item => item.post.uri)).toEqual([reply.post.uri, reply.post.uri]);
    expect(items[1]?.reason).toBe(reason);
    expect(items[0]?.reply?.parent).toMatchObject({ $type: "app.bsky.feed.defs#postView", uri: parent.uri });
  });
  it("reuses loaded parents and preserves explicit blocked context without fetching", async () => {
    let calls = 0;
    const blocked = { ...reply, reply: { parent: { $type: "app.bsky.feed.defs#blockedPost" as const, uri: parent.uri, blocked: true }, root: { ...root, $type: "app.bsky.feed.defs#postView" as const } } };
    const values = await hydrateSocialReplies(agent(async () => { calls++; return []; }), [{ post: parent }, { post: root }, reply, blocked]);
    expect(calls).toBe(0);
    expect(values[2]?.reply?.parent).toMatchObject({ uri: parent.uri, author: parent.author });
    expect(values[3]).toBe(blocked);
  });
  it("marks a parent unavailable only when a successful lookup confirms it missing", async () => {
    const [value] = await hydrateSocialReplies(agent(async () => [root]), [reply]);
    expect(value?.reply?.parent).toMatchObject({ $type: "app.bsky.feed.defs#notFoundPost", uri: parent.uri });
  });
  it("keeps temporary lookup failures unresolved for Show Thread", async () => {
    const [value] = await hydrateSocialReplies(agent(async () => { throw new Error("Timeout"); }), [reply]);
    expect(value?.reply?.parent).toMatchObject({ $type: PENDING_SOCIAL_REPLY_POST, uri: parent.uri });
  });
  it("hydrates pending references already added by a previous render", async () => {
    const pending = { ...reply, reply: socialReplyMetadata(reply) };
    const [value] = await hydrateSocialReplies(agent(async () => [parent, root]), [pending]);
    expect(value?.reply?.parent).toMatchObject({ $type: "app.bsky.feed.defs#postView", uri: parent.uri });
  });
  it("treats old placeholders without a confirmed notFound flag as unresolved", () => {
    const placeholder = { $type: "app.bsky.feed.defs#notFoundPost" as const, uri: parent.uri };
    expect(socialReplyMetadata({ ...reply, reply: { parent: placeholder, root: placeholder } })?.parent)
      .toMatchObject({ $type: PENDING_SOCIAL_REPLY_POST, uri: parent.uri });
  });
  it("retains moderation metadata and bounds hydration requests to 25 references", async () => {
    const values = Array.from({ length: 30 }, (_, index) => ({ post: { ...reply.post, uri: `${reply.post.uri}${index}`, record: { ...reply.post.record, reply: { parent: { uri: `${parent.uri}${index}`, cid }, root: { uri: root.uri, cid } } } } }));
    const sizes: number[] = [];
    await hydrateSocialReplies(agent(async uris => { sizes.push(uris.length); return []; }), values);
    expect(sizes).toEqual([25, 6]);
    const [value] = await hydrateSocialReplies(agent(async () => [{ ...parent, author: { ...parent.author, viewer: { muted: true } } }]), [reply]);
    expect(value?.reply?.parent).toMatchObject({ author: { viewer: { muted: true } } });
  });
  it("ignores unsolicited parent data and propagates missing OAuth grants", async () => {
    const [value] = await hydrateSocialReplies(agent(async () => [post("unexpected")]), [reply]);
    expect(value?.reply?.parent).toMatchObject({ $type: "app.bsky.feed.defs#notFoundPost" });
    await expect(hydrateSocialReplies(agent(async () => { throw { error: "insufficient_scope", status: 403 }; }), [reply])).rejects.toMatchObject({ error: "insufficient_scope" });
  });
  it("propagates cancellation during hydration", async () => {
    const controller = new AbortController();
    await expect(hydrateSocialReplies(agent(async (_uris, signal) => { expect(signal).toBe(controller.signal); controller.abort(); return [parent]; }), [reply], controller.signal)).rejects.toThrow();
  });
});
