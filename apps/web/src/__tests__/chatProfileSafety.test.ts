import { describe, expect, it } from "bun:test";
import type { ModerationOpts } from "@atproto/api";
import { chatProfileSafety } from "@/lib/chatProfileSafety";

const viewer = "did:plc:abcdefghijklmnopqrstuvwx";
const member = { did: "did:plc:zzzzzzzzzzzzzzzzzzzzzzzz", handle: "someone.test" };
const moderation: ModerationOpts = { userDid: viewer, prefs: { adultContentEnabled: false, labels: {}, labelers: [], mutedWords: [], hiddenPosts: [] } };

describe("chat profile safety", () => {
  it("fails closed before moderation loads, for missing members, and across account changes", () => {
    expect(chatProfileSafety(member, viewer)).toEqual({ hidden: true, noOverride: true });
    expect(chatProfileSafety(undefined, viewer, moderation)).toEqual({ hidden: true, noOverride: true });
    expect(chatProfileSafety(member, "did:plc:other", moderation)).toEqual({ hidden: true, noOverride: true });
  });
  it("allows a known unmoderated participant and the current viewer", () => {
    expect(chatProfileSafety(member, viewer, moderation)).toEqual({ hidden: false, noOverride: false });
    expect(chatProfileSafety({ ...member, did: viewer }, viewer, moderation)).toEqual({ hidden: false, noOverride: false });
  });
  it("hides blocked and blocking participants in bodies and previews", () => {
    expect(chatProfileSafety({ ...member, viewer: { blockedBy: true } }, viewer, moderation).hidden).toBe(true);
    expect(chatProfileSafety({ ...member, viewer: { blocking: `at://${viewer}/app.bsky.graph.block/block` } }, viewer, moderation).hidden).toBe(true);
  });
});
