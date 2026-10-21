import { afterEach, describe, expect, it, spyOn } from "bun:test";
import { AppBskyEmbedExternal } from "@atproto/api";
import type { OAuthSession } from "@atproto/oauth-client-browser";
import { composeExternalEmbed, composeLinkUrl } from "@/lib/blueskyExternalEmbed";

const preview = { uri: "https://example.com/story", title: "Story", description: "Summary", image: "https://example.com/thumb.jpg" };
const thumb = { $type: "blob", ref: { $link: "bafkreigh2akiscaildcv6ubnt36d2bk6bj3fx3xpq6xfj2vgtz3yqjv2zy" }, mimeType: "image/jpeg", size: 3 };
let restore: (() => void) | undefined;
afterEach(() => { restore?.(); restore = undefined; });
function sessionFor(upload: () => unknown) {
  return { did: "did:plc:alice", fetchHandler: async () => Response.json(upload()) } as unknown as OAuthSession;
}
function fetchImage(response: () => Promise<Response>) {
  const spy = spyOn(globalThis, "fetch").mockImplementation(Object.assign(response, { preconnect: globalThis.fetch.preconnect }));
  restore = () => spy.mockRestore();
  return spy;
}

describe("composer external cards", () => {
  it("permits only the explicitly attached URI to bypass the text-link guard", async () => {
    const session = sessionFor(() => { throw new Error("Unexpected upload"); });
    const card = { uri: preview.uri, title: preview.title, description: preview.description };
    expect(await composeExternalEmbed(session, "Read this", card)).toBeUndefined();
    expect(await composeExternalEmbed(session, "Read this", card, undefined, "https://example.com/other")).toBeUndefined();
    const embed = await composeExternalEmbed(session, "Read this", card, undefined, card.uri);
    expect(embed?.external.uri).toBe(card.uri);
    expect(AppBskyEmbedExternal.validateMain(embed).success).toBe(true);
  });
  it("shares native facet detection for HTTP(S), punctuation and Unicode", () => {
    expect(composeLinkUrl("é Read (https://example.com/story).")).toBe(preview.uri);
    expect(composeLinkUrl("http://example.com/story")).toBe("http://example.com/story");
    expect(composeLinkUrl("example.com/story")).toBe(preview.uri);
    expect(composeLinkUrl("mailto:hello@example.com")).toBeUndefined();
    expect(composeLinkUrl("https://user:password@example.com/story")).toBeUndefined();
  });
  it("uploads a thumbnail blob to the selected PDS and serializes its reference", async () => {
    let uploads = 0;
    const session = sessionFor(() => { uploads++; return { blob: thumb }; });
    const fetch = fetchImage(async () => new Response(new Uint8Array([1, 2, 3]), { headers: { "Content-Type": "image/jpeg" } }));
    const embed = await composeExternalEmbed(session, preview.uri, preview);
    expect(fetch.mock.calls[0][0]).toBe(`/api/bluesky-card-thumb?${new URLSearchParams({ url: preview.image })}`);
    expect(uploads).toBe(1);
    expect(embed!.external.thumb?.toJSON()).toEqual(thumb);
    expect(AppBskyEmbedExternal.validateMain(embed).success).toBe(true);
  });
  it("keeps a valid card when thumbnail upload fails", async () => {
    const session = sessionFor(() => { throw new Error("Upload failed"); });
    fetchImage(async () => new Response(new Uint8Array([1, 2, 3]), { headers: { "Content-Type": "image/jpeg" } }));
    const embed = await composeExternalEmbed(session, preview.uri, preview);
    expect(embed!.external).not.toHaveProperty("thumb");
    expect(AppBskyEmbedExternal.validateMain(embed).success).toBe(true);
  });
  it("skips oversized media and bounds metadata to native limits", async () => {
    let uploads = 0;
    const session = sessionFor(() => { uploads++; return { blob: thumb }; });
    fetchImage(async () => new Response(new Uint8Array(1_000_001), { headers: { "Content-Type": "image/jpeg" } }));
    const embed = await composeExternalEmbed(session, preview.uri, { ...preview, title: "👩".repeat(400), description: "👩".repeat(1100) });
    expect(uploads).toBe(0);
    expect(embed!.external).not.toHaveProperty("thumb");
    expect(AppBskyEmbedExternal.validateMain(embed).success).toBe(true);
  });
  it("propagates account changes after media fetch before uploading", async () => {
    let uploads = 0;
    const session = sessionFor(() => { uploads++; return { blob: thumb }; });
    fetchImage(async () => { throw new Error("Image unavailable"); });
    await expect(composeExternalEmbed(session, preview.uri, preview, () => { throw new Error("Account changed"); })).rejects.toThrow("Account changed");
    expect(uploads).toBe(0);
  });
});
