import { describe, expect, it } from "bun:test";
import type { AppBskyFeedDefs, ModerationOpts } from "@atproto/api";
import { isSocialInteractionHidden } from "@/lib/socialInteractionModeration";

const options: ModerationOpts = { userDid: "did:plc:viewer", prefs: { adultContentEnabled: false, labels: {}, labelers: [], mutedWords: [], hiddenPosts: [] } };
function post(id: string): AppBskyFeedDefs.PostView {
  return { uri: `at://did:plc:${id}/app.bsky.feed.post/one`, cid: "bafyreihdwdcefgh4dqkjv67uzcmw7ojee6xedzdetojuzjevtenxquvyku",
    author: { did: `did:plc:${id}`, handle: `${id}.test` },
    record: { $type: "app.bsky.feed.post", text: id, createdAt: "2026-10-12T00:00:00Z" }, indexedAt: "2026-10-12T00:00:00Z" };
}
const safe = post("safe");
function quote(source: AppBskyFeedDefs.PostView): AppBskyFeedDefs.PostView {
  return { ...safe, embed: { $type: "app.bsky.embed.record#view", record: {
    $type: "app.bsky.embed.record#viewRecord", uri: source.uri, cid: source.cid,
    author: source.author, value: source.record, indexedAt: source.indexedAt, labels: source.labels,
    embeds: source.embed ? [source.embed] : undefined,
  } } };
}

describe("moderation of whole social interactions", () => {
  for (const state of ["muted", "blocking", "blockedBy"] as const) {
    const source = { ...post("source"), author: { ...post("source").author, viewer: {
      [state]: state === "blocking" ? "at://did:plc:viewer/app.bsky.graph.block/one" : true,
    } } };
    it(`hides replies, quotes, media quotes, and reposts involving a ${state} source`, () => {
      expect(isSocialInteractionHidden({ post: safe, reply: { parent: { ...source, $type: "app.bsky.feed.defs#postView" }, root: { ...safe, $type: "app.bsky.feed.defs#postView" } } }, options)).toBe(true);
      expect(isSocialInteractionHidden({ post: quote(source) }, options)).toBe(true);
      const quoted = quote(source).embed!;
      const mediaQuote = { ...safe, embed: { $type: "app.bsky.embed.recordWithMedia#view", record: quoted, media: { $type: "app.bsky.embed.images#view", images: [] } } } as AppBskyFeedDefs.PostView;
      expect(isSocialInteractionHidden({ post: mediaQuote }, options)).toBe(true);
      expect(isSocialInteractionHidden({ post: source, reason: { $type: "app.bsky.feed.defs#reasonRepost", by: safe.author, indexedAt: safe.indexedAt } }, options)).toBe(true);
    });
  }
  it("hides blocked reply and quote sentinels and moderated reposters", () => {
    const blocked = { $type: "app.bsky.feed.defs#blockedPost" as const, uri: safe.uri, blocked: true };
    expect(isSocialInteractionHidden({ post: safe, reply: { parent: blocked, root: blocked } }, options)).toBe(true);
    expect(isSocialInteractionHidden({ post: { ...safe, embed: { $type: "app.bsky.embed.record#view", record: { $type: "app.bsky.embed.record#viewBlocked", uri: safe.uri, blocked: true, author: { did: safe.author.did } } } } }, options)).toBe(true);
    expect(isSocialInteractionHidden({ post: safe, reason: { $type: "app.bsky.feed.defs#reasonRepost", by: { ...safe.author, viewer: { muted: true } }, indexedAt: safe.indexedAt } }, options)).toBe(true);
  });
  it("keeps accessible interactions and missing posts visible without treating missing as moderated", () => {
    const missing = { $type: "app.bsky.feed.defs#notFoundPost" as const, uri: "at://did:plc:gone/app.bsky.feed.post/one", notFound: true };
    expect(isSocialInteractionHidden({ post: safe, reply: { parent: missing, root: missing } }, options)).toBe(false);
    expect(isSocialInteractionHidden({ post: quote(post("visible")) }, options)).toBe(false);
  });
  it("hides interactions when moderation preferences change", () => {
    const source = post("source");
    const item = { post: quote(source) };
    expect(isSocialInteractionHidden(item, options)).toBe(false);
    expect(isSocialInteractionHidden(item, { ...options, prefs: { ...options.prefs, hiddenPosts: [source.uri] } })).toBe(true);
    expect(isSocialInteractionHidden(item, options)).toBe(false);
  });
});
