import { describe, expect, it } from "bun:test";
import { interpretLabelValueDefinition, type AppBskyFeedDefs } from "@atproto/api";
import { socialPostLabels } from "@/lib/socialPostLabels";
import type { SocialModerationOpts } from "@/lib/socialModerationTypes";

const did = "did:plc:labeler";
const definition = interpretLabelValueDefinition({ identifier: "verified", severity: "inform", blurs: "none", defaultSetting: "ignore", locales: [{ lang: "en", name: "Verified", description: "Verified by this service." }] }, did);
const moderation: SocialModerationOpts = {
  userDid: "did:plc:viewer",
  prefs: { adultContentEnabled: true, labels: {}, labelers: [{ did, labels: {} }], mutedWords: [], hiddenPosts: [] },
  labelDefs: { [did]: [definition] },
  labelerProfiles: { [did]: { displayName: "Verification Service", handle: "verify.example" } },
  labelerAvatars: { [did]: "https://images.example/labeler.png" },
};
const label = { src: did, uri: "at://did:plc:author/app.bsky.feed.post/a", val: "verified", cts: "2026-10-10T00:00:00Z" };
const post: AppBskyFeedDefs.PostView = {
  uri: label.uri, cid: "bafyreia", indexedAt: label.cts,
  author: { did: "did:plc:author", displayName: "Post Author", handle: "author.example", avatar: "https://images.example/author.png" },
  record: { $type: "app.bsky.feed.post", text: "Test", createdAt: label.cts }, labels: [label],
};

describe("Post label source identity", () => {
  it("attaches the matching service profile and avatar to post and author labels", () => {
    const labels = socialPostLabels({ ...post, author: { ...post.author, labels: [{ ...label, uri: post.author.did }] } }, moderation);
    expect(labels).toHaveLength(2);
    for (const result of labels) expect(result).toMatchObject({ source: did, self: false, displayName: "Verification Service", handle: "verify.example", avatar: "https://images.example/labeler.png" });
  });

  it("uses the author's profile and avatar for self-labels", () => {
    const result = socialPostLabels({ ...post, labels: [{ ...label, src: post.author.did, val: "porn" }] }, moderation)[0];
    expect(result).toMatchObject({ source: post.author.did, self: true, displayName: "Post Author", handle: "author.example", avatar: "https://images.example/author.png" });
  });

  it("preserves labels when optional profile metadata is unavailable", () => {
    const result = socialPostLabels(post, { ...moderation, labelerProfiles: undefined, labelerAvatars: undefined })[0];
    expect(result?.source).toBe(did);
    expect(result?.handle).toBeUndefined();
    expect(result?.displayName).toBeUndefined();
    expect(result?.avatar).toBeUndefined();
  });

  it("withholds a blocked author's display name and avatar but preserves its handle", () => {
    const author = { ...post.author, viewer: { blocking: "at://did:plc:viewer/app.bsky.graph.block/one" } };
    const result = socialPostLabels({ ...post, author, labels: [{ ...label, src: author.did, val: "porn" }] }, moderation)[0];
    expect(result?.displayName).toBeUndefined();
    expect(result?.avatar).toBeUndefined();
    expect(result?.handle).toBe("author.example");
  });

  it("does not expose unsafe author avatar URLs or empty display names", () => {
    const author = { ...post.author, displayName: "  ", avatar: "javascript:alert(1)" };
    const result = socialPostLabels({ ...post, author, labels: [{ ...label, src: author.did, val: "porn" }] }, moderation)[0];
    expect(result?.displayName).toBeUndefined();
    expect(result?.avatar).toBeUndefined();
  });
});
