import { describe, expect, it } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { interpretLabelValueDefinition, type AppBskyFeedDefs, type ModerationOpts } from "@atproto/api";
import { socialPostLabels } from "@/lib/socialPostLabels";
import { SocialPostLabels } from "@/components/Social/SocialPostLabels";

const did = "did:plc:labeler";
const definition = interpretLabelValueDefinition({ identifier: "verified", severity: "inform", blurs: "none", defaultSetting: "ignore", locales: [{ lang: "en", name: "Verified", description: "Verified by this service." }] }, did);
const moderation: ModerationOpts = { userDid: "did:plc:viewer", prefs: { adultContentEnabled: true, labels: {}, labelers: [{ did, labels: {} }], mutedWords: [], hiddenPosts: [] }, labelDefs: { [did]: [definition] } };
const label = { src: did, uri: "at://did:plc:author/app.bsky.feed.post/a", val: "verified", cts: "2026-10-10T00:00:00Z" };
const post: AppBskyFeedDefs.PostView = { uri: label.uri, cid: "bafyreia", author: { did: "did:plc:author", handle: "author.test" }, indexedAt: label.cts, record: { $type: "app.bsky.feed.post", text: "Test", createdAt: label.cts }, labels: [label] };

describe("Post label badges", () => {
  it("shows localized subscribed informational labels even when set to Show", () => {
    expect(socialPostLabels(post, moderation)).toHaveLength(1);
    expect(renderToStaticMarkup(<SocialPostLabels post={post} moderation={moderation} />)).toContain("Verified");
  });
  it("attaches the matching labeler avatar without using it for author self-labels", () => {
    const withAvatar = { ...moderation, labelerAvatars: { [did]: "https://images.example/labeler.png", [post.author.did]: "https://images.example/author.png" } };
    expect(socialPostLabels(post, withAvatar)[0]?.avatar).toBe("https://images.example/labeler.png");
    expect(socialPostLabels({ ...post, labels: [{ ...label, src: post.author.did, val: "porn" }] }, withAvatar)[0]?.avatar).toBeUndefined();
  });
  it("does not display unknown sources, unknown values, or internal system labels", () => {
    const value = { ...post, labels: [{ ...label, src: "did:plc:unknown" }, { ...label, val: "unknown" }, { ...label, val: "!hide" }] };
    expect(socialPostLabels(value, moderation)).toEqual([]);
  });
  it("deduplicates repeated labels and respects newer negations", () => {
    expect(socialPostLabels({ ...post, labels: [label, label] }, moderation)).toHaveLength(1);
    const negation = { ...label, neg: true, cts: "2026-10-10T01:00:00Z" };
    expect(socialPostLabels({ ...post, labels: [negation, label] }, moderation)).toEqual([]);
  });
  it("omits expired and malformed expiration labels", () => {
    for (const exp of ["2026-10-09T00:00:00Z", "invalid"]) expect(socialPostLabels({ ...post, labels: [{ ...label, exp }] }, moderation, Date.parse(label.cts))).toEqual([]);
  });
  it("keeps account and content labels distinct so one negation cannot remove the other", () => {
    const value = { ...post, author: { ...post.author, labels: [{ ...label, uri: post.author.did }] }, labels: [{ ...label, neg: true }] };
    expect(socialPostLabels(value, moderation)).toHaveLength(1);
  });
  it("shows standard author self-label badges without trusting arbitrary author definitions", () => {
    expect(socialPostLabels({ ...post, labels: [{ ...label, src: post.author.did, val: "porn" }] }, moderation)).toHaveLength(1);
    expect(socialPostLabels({ ...post, labels: [{ ...label, src: post.author.did }] }, moderation)).toEqual([]);
  });
});
