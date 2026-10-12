import { describe, expect, it } from "bun:test";
import { interpretLabelValueDefinition, type ModerationOpts } from "@atproto/api";
import type { OAuthSession } from "@atproto/oauth-client-browser";
import { changeSocialLabeler, getSocialLabeler, localizedSocialLabel, socialLabelVisibility } from "@/lib/socialModerationClient";

const did = "did:plc:aaaaaaaaaaaaaaaaaaaaaaaa";
const definition = interpretLabelValueDefinition({ identifier: "spoiler", severity: "inform", blurs: "none", defaultSetting: "warn", locales: [{ lang: "en", name: "Spoiler", description: "Contains Spoilers" }, { lang: "fr", name: "Divulgation", description: "Une Divulgation" }] }, did);
function fixture({ adult = false, service = true } = {}) {
  let preferences: unknown[] = [{ $type: "app.bsky.actor.defs#labelersPref", labelers: [{ did }] }, { $type: "app.bsky.actor.defs#savedFeedsPrefV2", items: [{ id: "saved", type: "timeline", value: "following", pinned: true }] }, { $type: "app.bsky.actor.defs#adultContentPref", enabled: adult }];
  const writes: unknown[][] = [];
  const session = { did: "did:plc:bbbbbbbbbbbbbbbbbbbbbbbb", fetchHandler: async (path: string, init?: RequestInit) => {
    const method = new URL(path, "https://pds.example").pathname.split("/").at(-1);
    if (method === "app.bsky.actor.getProfile") return Response.json({ did, handle: "labels.example" });
    if (method === "app.bsky.labeler.getServices") return Response.json({ views: service ? [{ $type: "app.bsky.labeler.defs#labelerViewDetailed", uri: `at://${did}/app.bsky.labeler.service/self`, cid: "bafyreihdwdcefgh4dqkjv67uzcmw7ojee6xedzdetojuzjevtenxquvyku", creator: { did, handle: "labels.example" }, policies: { labelValues: ["spoiler"], labelValueDefinitions: [{ identifier: "spoiler", severity: "inform", blurs: "none", adultOnly: false, defaultSetting: "warn", locales: definition.locales }] }, indexedAt: "2026-10-10T00:00:00Z" }] : [] });
    if (method === "app.bsky.actor.getPreferences") return Response.json({ preferences });
    if (method === "app.bsky.actor.putPreferences") { const body = await new Response(init?.body).json(); preferences = body.preferences; writes.push(body.preferences); return Response.json({}); }
    throw new Error(`Unexpected ${method}`);
  } } as unknown as OAuthSession;
  return { session, writes, preferences: () => preferences };
}

describe("Social labeler preferences", () => {
  it("validates labeler services and localizes definitions", async () => {
    const { session } = fixture();
    const labeler = await getSocialLabeler(session, "@labels.example");
    expect(labeler.did).toBe(did);
    expect(labeler.definitions[0]?.identifier).toBe("spoiler");
    expect(localizedSocialLabel(definition, ["fr-CA"])).toEqual({ name: "Divulgation", description: "Une Divulgation" });
    expect(localizedSocialLabel(definition, ["de"])).toEqual({ name: "Spoiler", description: "Contains Spoilers" });
    await expect(getSocialLabeler(fixture({ service: false }).session, did)).rejects.toThrow("does not publish");
    await expect(getSocialLabeler(session, "https://labels.example")).rejects.toThrow("handle or DID");
  });

  it("writes per-label visibility without replacing unrelated preferences", async () => {
    const context = fixture();
    await changeSocialLabeler(context.session, { type: "label", did, label: "spoiler", visibility: "ignore" });
    expect(context.writes).toHaveLength(1);
    expect(context.preferences()).toContainEqual({ $type: "app.bsky.actor.defs#contentLabelPref", labelerDid: did, label: "spoiler", visibility: "ignore" });
    expect(context.preferences()).toContainEqual({ $type: "app.bsky.actor.defs#savedFeedsPrefV2", items: [{ id: "saved", type: "timeline", value: "following", pinned: true }] });
    await changeSocialLabeler(context.session, { type: "unsubscribe", did });
    expect(context.preferences()).toContainEqual({ $type: "app.bsky.actor.defs#labelersPref", labelers: [] });
    await changeSocialLabeler(context.session, { type: "subscribe", did });
    expect(context.preferences()).toContainEqual({ $type: "app.bsky.actor.defs#labelersPref", labelers: [{ did }] });
  });

  it("rejects mandatory labeler removal and unknown labels without writes", async () => {
    const context = fixture();
    await expect(changeSocialLabeler(context.session, { type: "unsubscribe", did: "did:plc:ar7c4by46qjdydhdevvrndac" })).rejects.toThrow("required");
    await expect(changeSocialLabeler(context.session, { type: "label", did, label: "missing", visibility: "hide" })).rejects.toThrow("no longer available");
    expect(context.writes).toHaveLength(0);
  });

  it("honors labeler overrides and disables adult or nonconfigurable labels", () => {
    const moderation: ModerationOpts = { userDid: "did:plc:viewer", prefs: { adultContentEnabled: false, labels: {}, labelers: [{ did, labels: { spoiler: "ignore" } }], mutedWords: [], hiddenPosts: [] } };
    expect(socialLabelVisibility(definition, moderation)).toEqual({ visibility: "ignore", disabled: false });
    expect(socialLabelVisibility({ ...definition, flags: ["adult"] }, moderation)).toEqual({ visibility: "hide", disabled: true });
    expect(socialLabelVisibility({ ...definition, configurable: false }, moderation)).toEqual({ visibility: "warn", disabled: true });
  });
});
