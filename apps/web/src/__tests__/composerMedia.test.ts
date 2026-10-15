import { afterEach, expect, it, spyOn } from "bun:test";
import { AppBskyFeedPost } from "@atproto/api";
import type { OAuthSession } from "@atproto/oauth-client-browser";
import { gifEmbedURI, type ComposerMedia, type GifAsset } from "@/lib/composerMedia";
import { prepareBlueskyPost } from "@/lib/blueskyComposeClient";
import { composeMediaEmbed } from "@/lib/blueskyMediaEmbed";
import { newThreadPublication, publishBlueskyThread, validThreadText } from "@/lib/blueskyThreadClient";
import * as klipy from "@/lib/klipyClient";

const asset: GifAsset = { id: "123", title: "Celebrate", description: "A person celebrating", url: "https://static.klipy.com/ii/example/full.gif?keep=yes", poster: "https://static.klipy.com/ii/example/still.jpg", mp4: "https://static.klipy.com/ii/example/video.mp4", width: 280, height: 498, attribution: "Powered by KLIPY" };
const restores: (() => void)[] = [];
afterEach(() => restores.splice(0).reverse().forEach(restore => restore()));
function sessionFor(upload: (method: string) => void = () => {}) {
  return { did: "did:plc:alice", fetchHandler: async (path: string, init: RequestInit) => {
    upload(new URL(path, "https://pds.example").pathname);
    const blob = await new Response(init.body).blob();
    return Response.json({ blob: { $type: "blob", ref: { $link: "bafkreigh2akiscaildcv6ubnt36d2bk6bj3fx3xpq6xfj2vgtz3yqjv2zy" }, mimeType: new Headers(init.headers).get("content-type"), size: blob.size } });
  } } as unknown as OAuthSession;
}
function provider() {
  const resolve = spyOn(klipy, "getComposerGifs").mockResolvedValue({ results: [asset], next: "" });
  const poster = spyOn(klipy, "getGifPoster").mockResolvedValue(new Blob(["abc"], { type: "image/jpeg" }));
  restores.push(() => resolve.mockRestore(), () => poster.mockRestore());
  return { resolve, poster };
}
it("serializes dimensions and exact rendition slugs without losing existing query parameters", () => {
  const uri = new URL(gifEmbedURI(asset));
  expect(uri.hostname).toBe("static.klipy.com");
  expect(Object.fromEntries(uri.searchParams)).toEqual({ keep: "yes", ww: "280", hh: "498", mp4: "video" });
  for (const patch of [{ url: "https://static.klipy.com.evil/ii/a.gif" }, { width: Infinity }, { mp4: "https://static.klipy.com/ii/other/v.mp4" }, { mp4: undefined }]) expect(() => gifEmbedURI({ ...asset, ...patch })).toThrow();
});
it("posts a media-only GIF independently of text URLs, with user alt text", async () => {
  const mocks = provider();
  const record = await prepareBlueskyPost({ session: sessionFor(), text: "", media: { kind: "gif", asset, alt: "Celebrating a win" } });
  expect(AppBskyFeedPost.validateRecord(record).success).toBe(true);
  expect(record).toMatchObject({ text: "", embed: { $type: "app.bsky.embed.external", external: { uri: gifEmbedURI(asset), description: "Alt: Celebrating a win" } } });
  expect(mocks.resolve.mock.calls[0][1]).toEqual({ id: "123" });
});
it("distinguishes provider descriptions from author descriptions and preserves quote context", async () => {
  provider();
  const quote = { uri: "at://did:plc:bob/app.bsky.feed.post/one", cid: "bafkreigh2akiscaildcv6ubnt36d2bk6bj3fx3xpq6xfj2vgtz3yqjv2zy", author: { did: "did:plc:bob", handle: "bob.test" }, record: { $type: "app.bsky.feed.post", text: "Hi", createdAt: "2026-01-01T00:00:00Z" }, indexedAt: "2026-01-01T00:00:00Z" };
  const record = await prepareBlueskyPost({ session: sessionFor(), text: "Reaction", media: { kind: "gif", asset, alt: "" }, quoteTo: quote });
  expect(record).toMatchObject({ embed: { $type: "app.bsky.embed.recordWithMedia", record: { record: { uri: quote.uri } }, media: { external: { description: `ALT: ${asset.description}` } } } });
});
it("preserves independent photo ordering and descriptions in a valid image embed", async () => {
  const media: ComposerMedia = { kind: "photos", photos: ["second", "first"].map(id => ({ id, name: id, original: new Blob(["abc"]), blob: new Blob(["abc"], { type: "image/jpeg" }), width: 200, height: 300, status: "ready", alt: id })) };
  const embed = await composeMediaEmbed(sessionFor(), media);
  expect(embed).toMatchObject({ $type: "app.bsky.embed.images", images: [{ alt: "second" }, { alt: "first" }] });
  expect(validThreadText("", media)).toBe(true);
  expect(validThreadText("hello", { kind: "photos", photos: [{ ...media.photos[0], status: "failed" }] })).toBe(false);
});
it("fails before writes for incompatible embeds and propagates required poster failures", async () => {
  const mocks = provider();
  let uploads = 0;
  const session = sessionFor(() => uploads++);
  await expect(prepareBlueskyPost({ session, text: "https://example.com", media: { kind: "gif", asset, alt: "" }, linkPreview: { uri: "https://example.com", title: "Link", description: "" } })).rejects.toThrow("Choose Media");
  mocks.poster.mockRejectedValue(new Error("GIF Preview Unavailable"));
  await expect(composeMediaEmbed(session, { kind: "gif", asset, alt: "" })).rejects.toThrow("GIF Preview Unavailable");
  expect(uploads).toBe(0);
});
it("requires a durable attempted-write checkpoint before sending a record", async () => {
  let writes = 0;
  const session = sessionFor(() => writes++);
  const publication = newThreadPublication(session.did, [{ id: "a", text: "Hello" }]);
  await expect(publishBlueskyThread({ session, publication, assertCurrentAccount: () => {}, checkpoint: async () => { if (publication.segments[0].attempted) throw new Error("Storage Full"); } })).rejects.toThrow("Storage Full");
  expect(writes).toBe(0);
});
