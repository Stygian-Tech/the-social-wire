import { describe, expect, it } from "bun:test";
import type { AppBskyFeedDefs, ModerationOpts } from "@atproto/api";
import { socialAuthorThread, socialAuthorThreadRoot, socialAuthorThreadUri } from "@/lib/socialAuthorThread";
const moderation: ModerationOpts = { userDid: "did:plc:viewer", prefs: { adultContentEnabled: false, labels: {}, labelers: [], mutedWords: [], hiddenPosts: [] } };
function node(id: string, parent?: AppBskyFeedDefs.ThreadViewPost, author = "did:plc:op"): AppBskyFeedDefs.ThreadViewPost & { $type: "app.bsky.feed.defs#threadViewPost"; post: AppBskyFeedDefs.PostView & { $type: "app.bsky.feed.defs#postView" } } {
  return { $type: "app.bsky.feed.defs#threadViewPost", post: { $type: "app.bsky.feed.defs#postView", uri: `at://${author}/app.bsky.feed.post/${id}`, cid: "bafyreihdwdcefgh4dqkjv67uzcmw7ojee6xedzdetojuzjevtenxquvyku", author: { did: author, handle: "op.test" }, record: { $type: "app.bsky.feed.post", text: id, createdAt: "2026-10-10T00:00:00Z", ...(parent ? { reply: { root: { uri: parent.post.uri, cid: parent.post.cid }, parent: { uri: parent.post.uri, cid: parent.post.cid } } } : {}) }, indexedAt: "2026-10-10T00:00:00Z", replyCount: 0 }, replies: [] };
}
describe("OP authored thread", () => {
  it("includes root and self-replies but stops at other authors", () => {
    const root = node("root"); const self = node("self", root); const other = node("other", root, "did:plc:other");
    self.replies = [node("self2", self)]; other.replies = [node("op-through-other", other)]; root.replies = [self, other];
    expect(socialAuthorThread(root, moderation)).toEqual({ count: 3, partial: false });
  });
  it("does not count a same-author post with the wrong parent", () => {
    const root = node("root"); root.replies = [node("unrelated")];
    expect(socialAuthorThread(root, moderation)?.count).toBe(1);
  });
  it("marks truncated, unavailable and moderated continuations as partial", () => {
    const root = node("root"); root.post.replyCount = 4;
    expect(socialAuthorThread(root, moderation)).toEqual({ count: 1, partial: true });
    root.post.replyCount = 1; root.replies = [{ $type: "app.bsky.feed.defs#notFoundPost", uri: "at://did:plc:op/app.bsky.feed.post/deleted", notFound: true }];
    expect(socialAuthorThread(root, moderation)?.partial).toBe(true);
    const self = node("self", root); self.post.author.viewer = { muted: true }; root.replies = [self];
    expect(socialAuthorThread(root, moderation)).toEqual({ count: 1, partial: true });
    root.post.author.viewer = { muted: true }; expect(socialAuthorThread(root, moderation)).toBeUndefined();
  });
  it("bounds repeated nodes and long chains", () => {
    const root = node("root"); let tail = root;
    for (let i = 0; i < 110; i++) { const child = node(`p${i}`, tail); tail.replies = [child]; tail = child; }
    tail.replies = [root];
    expect(socialAuthorThread(root, moderation)).toEqual({ count: 100, partial: true });
  });
  it("stitches fetched ancestors for a selected self-reply", () => {
    const root = node("root"); root.post.replyCount = 2;
    const self = node("self", root); self.parent = root; self.replies = [node("self2", self)];
    expect(socialAuthorThread(socialAuthorThreadRoot(self), moderation)).toEqual({ count: 3, partial: true });
    expect(root.replies).toEqual([]);
  });
  it("does not mistake another participant's chain for OP or count invalid data as complete", () => {
    const root = node("root"); const other = node("other", root, "did:plc:other");
    other.parent = root; other.replies = [node("other-self", other, "did:plc:other")];
    expect(socialAuthorThread(socialAuthorThreadRoot(other), moderation)).toBeUndefined();
    expect(socialAuthorThreadUri({ post: other.post })).toBeUndefined();
    const self = node("self", root); const invalid = node("invalid", self); invalid.post.record = {};
    root.replies = [self]; self.replies = [invalid];
    expect(socialAuthorThread(root, moderation)).toEqual({ count: 2, partial: true });
  });
  it("only fetches roots or OP self-reply candidates", () => {
    const root = node("root"); root.post.replyCount = 8;
    const self = node("self", root); const other = node("other", root, "did:plc:other");
    expect(socialAuthorThreadUri({ post: root.post })).toBe(root.post.uri);
    expect(socialAuthorThreadUri({ post: self.post, reply: { root: root.post, parent: root.post } })).toBe(root.post.uri);
    expect(socialAuthorThreadUri({ post: other.post, reply: { root: root.post, parent: root.post } })).toBeUndefined();
  });
});
