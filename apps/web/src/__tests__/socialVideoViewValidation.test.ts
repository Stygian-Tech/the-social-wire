import { describe, expect, it } from "bun:test";
import { Agent, AppBskyEmbedVideo, moderatePost, type ModerationOpts } from "@atproto/api";
import type { OAuthSession } from "@atproto/oauth-client-browser";
import { createAuthenticatedAppViewAgent, getBlueskySocialPage, SOCIAL_FOLLOWING_FEED, type SocialFeed } from "@/lib/blueskySocialClient";

const cid = "bafyreihdwdcefgh4dqkjv67uzcmw7ojee6xedzdetojuzjevtenxquvyku";
const did = "did:plc:alice";
const moderation: ModerationOpts = {
  userDid: did,
  prefs: { adultContentEnabled: false, labels: {}, labelers: [{ did: "did:plc:labeler", labels: {} }], mutedWords: [], hiddenPosts: [] },
};

function videoPost(alt: unknown = "Description ".repeat(120)) {
  return {
    $type: "app.bsky.feed.defs#postView",
    uri: "at://did:plc:author/app.bsky.feed.post/video",
    cid,
    author: { did: "did:plc:author", handle: "author.test" },
    record: { $type: "app.bsky.feed.post", text: "Video", createdAt: "2026-10-25T00:00:00Z" },
    embed: { $type: "app.bsky.embed.video#view", cid, playlist: "https://video.example/playlist.m3u8", alt },
    labels: [{ src: "did:plc:labeler", uri: "at://did:plc:author/app.bsky.feed.post/video", val: "!hide", cts: "2026-10-25T00:00:00Z" }],
    indexedAt: "2026-10-25T00:00:00Z",
  };
}

function sessionFor(feed: unknown): OAuthSession {
  return { did, fetchHandler: async () => Response.json({ feed, cursor: "next-page" }) } as unknown as OAuthSession;
}

const feeds: SocialFeed[] = [
  SOCIAL_FOLLOWING_FEED,
  { kind: "feed", uri: "at://did:plc:feeds/app.bsky.feed.generator/news", name: "News", pinned: true },
  { kind: "list", uri: "at://did:plc:lists/app.bsky.graph.list/friends", name: "Friends", pinned: false },
];

describe("Social video view validation", () => {
  for (const feed of feeds) {
    it(`preserves over-limit alt text, neighboring rows, pagination and moderation in ${feed.kind}`, async () => {
      const post = videoPost();
      const neighbor = { ...post, uri: "at://did:plc:author/app.bsky.feed.post/neighbor", embed: undefined };
      const page = await getBlueskySocialPage({ session: sessionFor([{ post: neighbor }, { post }]), feed, moderation, deferReplyHydration: true });
      expect(page.feed.map(item => item.post.uri)).toEqual([neighbor.uri, post.uri]);
      expect(page.cursor).toBe("next-page");
      expect(page.feed[1]?.post.embed).toMatchObject({ alt: post.embed.alt });
      expect(page.feed[1]?.post.labels).toEqual(post.labels);
      expect(moderatePost(page.feed[1]!.post, moderation).ui("contentList").filter).toBe(true);
    });
  }

  it("does not relax global SDK validation or video record authoring limits", async () => {
    const post = videoPost();
    const session = sessionFor([{ post }]);
    const standard = new Agent(session);
    expect(() => standard.lex.assertValidXrpcOutput("app.bsky.feed.getTimeline", { feed: [{ post }] })).toThrow("1000 graphemes");
    await expect(standard.getTimeline()).rejects.toThrow("invalid response");
    await getBlueskySocialPage({ session, feed: SOCIAL_FOLLOWING_FEED, moderation, deferReplyHydration: true });
    await expect(new Agent(session).getTimeline()).rejects.toThrow("invalid response");
    const agent = createAuthenticatedAppViewAgent(session);
    expect(agent.lex.getDef("app.bsky.embed.video")).toEqual(standard.lex.getDef("app.bsky.embed.video"));
    expect(AppBskyEmbedVideo.validateView(post.embed).success).toBe(false);
  });

  for (const alt of [42, "a".repeat(10001), "🦋".repeat(2501)]) {
    it(`still rejects invalid video alt type or byte length (${typeof alt === "string" ? alt.length : typeof alt})`, async () => {
      await expect(getBlueskySocialPage({ session: sessionFor([{ post: videoPost(alt) }]), feed: SOCIAL_FOLLOWING_FEED, moderation, deferReplyHydration: true })).rejects.toThrow();
    });
  }

  it("still rejects invalid required post fields and moderation data", async () => {
    for (const post of [
      { ...videoPost(), author: { did: 42, handle: "author.test" } },
      { ...videoPost(), labels: [{ src: "did:plc:labeler", val: "!hide", cts: 42 }] },
      { ...videoPost(), embed: { ...videoPost().embed, playlist: 42 } },
    ]) {
      await expect(getBlueskySocialPage({ session: sessionFor([{ post }]), feed: SOCIAL_FOLLOWING_FEED, moderation, deferReplyHydration: true })).rejects.toThrow();
    }
  });

  it("leaves image validation unchanged", async () => {
    const session = sessionFor([]);
    expect(createAuthenticatedAppViewAgent(session).lex.get("app.bsky.embed.images")).toEqual(new Agent(session).lex.get("app.bsky.embed.images"));
    const post = { ...videoPost(), embed: { $type: "app.bsky.embed.images#view", images: [{ thumb: "https://images.example/thumb.jpg", fullsize: "https://images.example/full.jpg", alt: 42 }] } };
    await expect(getBlueskySocialPage({ session: sessionFor([{ post }]), feed: SOCIAL_FOLLOWING_FEED, moderation, deferReplyHydration: true })).rejects.toThrow("invalid response");
  });

  it("accepts the existing byte bound without truncating Unicode descriptions", async () => {
    const post = videoPost("🦋".repeat(2500));
    const page = await getBlueskySocialPage({ session: sessionFor([{ post }]), feed: SOCIAL_FOLLOWING_FEED, moderation, deferReplyHydration: true });
    expect(page.feed[0]?.post.embed).toMatchObject({ alt: post.embed.alt });
  });

  it("accepts video alt in quoted posts and reply context with the same bounded validation", async () => {
    const post = videoPost();
    const outer = { ...post, uri: "at://did:plc:author/app.bsky.feed.post/quote", embed: { $type: "app.bsky.embed.record#view", record: { $type: "app.bsky.embed.record#viewRecord", uri: post.uri, cid, author: post.author, value: post.record, indexedAt: post.indexedAt, embeds: [post.embed] } } };
    const page = await getBlueskySocialPage({ session: sessionFor([{ post: outer, reply: { root: post, parent: post } }]), feed: SOCIAL_FOLLOWING_FEED, moderation, deferReplyHydration: true });
    expect(page.feed[0]?.post.embed).toEqual(outer.embed);
    expect(page.feed[0]?.reply?.parent).toMatchObject({ embed: post.embed });
  });
});
