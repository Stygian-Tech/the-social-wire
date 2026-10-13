import { describe, expect, it } from "bun:test";
import { AppBskyFeedDefs, type ModerationOpts } from "@atproto/api";
import { groupSocialFeedItems } from "@/lib/socialFeedGrouping";
import { flattenSocialPages } from "@/lib/blueskySocialClient";

const moderation: ModerationOpts = { userDid: "did:plc:viewer", prefs: { adultContentEnabled: false, labels: {}, labelers: [{ did: "did:plc:ar7c4by46qjdydhdevvrndac", labels: {} }], mutedWords: [], hiddenPosts: [] } };
function post(id: string): AppBskyFeedDefs.PostView & { $type: "app.bsky.feed.defs#postView" } {
  return { $type: "app.bsky.feed.defs#postView", uri: `at://did:plc:author/app.bsky.feed.post/${id}`, cid: "bafyreihdwdcefgh4dqkjv67uzcmw7ojee6xedzdetojuzjevtenxquvyku", author: { did: "did:plc:author", handle: "author.test" }, record: { $type: "app.bsky.feed.post", text: id, createdAt: "2026-10-10T00:00:00Z" }, indexedAt: "2026-10-10T00:00:00Z" };
}
const parent = post("parent");
const child = { post: post("reply"), reply: { parent, root: parent } };
describe("Social feed reply grouping", () => {
  it("removes standalone parents on either side without moving remaining source rows", () => {
    const other = { post: post("other") };
    expect(groupSocialFeedItems([{ post: parent }, other, child], moderation)).toEqual([other, child]);
    expect(groupSocialFeedItems([child, other, { post: parent }], moderation)).toEqual([child, other]);
  });
  it("deduplicates across loaded pages while retaining distinct repost attribution", () => {
    const repost = { post: parent, reason: { $type: "app.bsky.feed.defs#reasonRepost" as const, by: { did: "did:plc:reposter", handle: "reposter.test" }, indexedAt: parent.indexedAt } };
    const pages = [{ feed: [child] }, { feed: [{ post: parent }, repost, child] }];
    expect(groupSocialFeedItems(flattenSocialPages(pages), moderation)).toEqual([child, repost]);
  });
  it("does not suppress distinct replies or other attributed rows", () => {
    const grandparent = post("grandparent");
    const parentReply = { post: parent, reply: { parent: grandparent, root: grandparent } };
    const secondReply = { ...child, post: post("second-reply") };
    const pinned = { post: parent, reason: { $type: "app.bsky.feed.defs#reasonPin" as const } };
    expect(groupSocialFeedItems([child, parentReply, secondReply, pinned], moderation)).toEqual([child, parentReply, secondReply, pinned]);
  });
  for (const state of ["blocked", "muted", "hidden", "label", "invalid"] as const) it(`does not replace a standalone parent with ${state} context`, () => {
    const unsafe = { ...parent, author: { ...parent.author, viewer: { blocking: state === "blocked" ? "at://did:plc:viewer/app.bsky.graph.block/one" : undefined, muted: state === "muted" } }, record: state === "invalid" ? {} : parent.record, labels: state === "label" ? [{ src: "did:plc:ar7c4by46qjdydhdevvrndac", uri: parent.uri, val: "!hide", cts: parent.indexedAt }] : [] };
    const prefs = state === "hidden" ? { ...moderation, prefs: { ...moderation.prefs, hiddenPosts: [parent.uri] } } : moderation;
    const item = { ...child, reply: { parent: unsafe, root: parent } };
    expect(groupSocialFeedItems([item, { post: parent }], prefs)).toHaveLength(state === "invalid" ? 2 : 1);
  });
  it("resolves unavailable context from a parent on a later loaded page", () => {
    const missing = { ...child, reply: { parent: { $type: "app.bsky.feed.defs#notFoundPost" as const, uri: parent.uri, notFound: true }, root: parent } };
    const grouped = groupSocialFeedItems(flattenSocialPages([{ feed: [missing] }, { feed: [{ post: parent }] }]), moderation);
    expect(grouped).toHaveLength(1);
    expect(grouped[0]?.reply?.parent).toMatchObject({ uri: parent.uri, author: parent.author });
    const absent = { ...missing, reply: { ...missing.reply, root: post("other-root") } };
    expect(groupSocialFeedItems([absent], moderation)[0]?.reply?.parent).toEqual(missing.reply.parent);
  });
  it("resolves missing record-only context and uses the immediate parent in nested replies", () => {
    const root = post("root");
    const recordOnly = { post: { ...child.post, record: { ...child.post.record as object, reply: { parent: { uri: parent.uri, cid: parent.cid }, root: { uri: root.uri, cid: root.cid } } } } };
    const grouped = groupSocialFeedItems([recordOnly, { post: root }, { post: parent }], moderation);
    expect(grouped[0]?.reply?.parent).toMatchObject({ uri: parent.uri });
    expect(grouped[0]?.reply?.root).toMatchObject({ uri: root.uri });
    expect(grouped.map(item => item.post.uri)).toEqual([child.post.uri, root.uri]);
  });
  it("does not hide a parent when its reply is withheld or invalid", () => {
    const withheld = { ...child, post: { ...child.post, author: { ...child.post.author, viewer: { muted: true } } } };
    const invalid = { ...child, post: { ...child.post, record: {} } };
    for (const item of [withheld, invalid]) expect(groupSocialFeedItems([item, { post: parent }], moderation)).toHaveLength(2);
  });
  it("recomputes from supplied moderation and items without retaining another account's suppression", () => {
    expect(groupSocialFeedItems([child, { post: parent }], moderation)).toHaveLength(1);
    const otherViewer = { ...moderation, userDid: "did:plc:other", prefs: { ...moderation.prefs, hiddenPosts: [child.post.uri] } };
    expect(groupSocialFeedItems([child, { post: parent }], otherViewer)).toHaveLength(2);
    expect(groupSocialFeedItems([{ post: parent }], moderation)).toHaveLength(1);
  });
});
