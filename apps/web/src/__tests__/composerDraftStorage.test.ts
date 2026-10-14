import { indexedDB as fakeIndexedDB } from "fake-indexeddb";
import { beforeEach, afterEach, expect, it } from "bun:test";
import { loadComposerDraft, saveComposerDraft } from "@/lib/composerDraftStorage";
import { newThreadPublication } from "@/lib/blueskyThreadClient";
import { jsonToLex, stringifyLex } from "@atproto/api";
import { AppBskyFeedPost } from "@atproto/api";

const originalIndexedDB = Object.getOwnPropertyDescriptor(globalThis, "indexedDB");
beforeEach(() => Object.defineProperty(globalThis, "indexedDB", { configurable: true, value: fakeIndexedDB }));
afterEach(() => { if (originalIndexedDB) Object.defineProperty(globalThis, "indexedDB", originalIndexedDB); else Reflect.deleteProperty(globalThis, "indexedDB"); });

it("restores ordered attachments, binary bytes, alt text, and account-scoped recovery state", async () => {
  const did = "did:plc:draft-test";
  const original = new Blob(["photo-bytes"], { type: "image/jpeg" });
  const segments = [{ id: "segment", text: "", media: { kind: "photos" as const, photos: [{ id: "photo", name: "a.jpg", original, blob: original, width: 50, height: 70, alt: "A mountain", status: "ready" as const }] } }];
  const publication = newThreadPublication(did, segments);
  publication.segments[0].record = jsonToLex({ $type: "app.bsky.feed.post", text: "", createdAt: "2026-01-01T00:00:00Z", embed: { $type: "app.bsky.embed.images", images: [{ alt: "A mountain", image: { $type: "blob", ref: { $link: "bafkreigh2akiscaildcv6ubnt36d2bk6bj3fx3xpq6xfj2vgtz3yqjv2zy" }, mimeType: "image/jpeg", size: 11 } }] } }) as AppBskyFeedPost.Record;
  publication.segments[0].attempted = true;
  await saveComposerDraft(did, "post", { version: 1, did, segments, publication });
  const restored = await loadComposerDraft(did, "post");
  expect(restored?.publication?.segments[0].rkey).toBe(publication.segments[0].rkey);
  expect(restored?.publication?.segments[0].attempted).toBe(true);
  expect(stringifyLex(restored!.publication!.segments[0].record)).toBe(stringifyLex(publication.segments[0].record));
  expect(AppBskyFeedPost.validateRecord(restored!.publication!.segments[0].record).success).toBe(true);
  const media = restored!.segments[0].media!;
  if (media.kind !== "photos") throw new Error("Wrong Media");
  expect(media.photos[0].alt).toBe("A mountain");
  expect(await media.photos[0].original.text()).toBe("photo-bytes");
  expect(await loadComposerDraft("did:plc:other", "post")).toBeUndefined();
  await saveComposerDraft(did, "post");
  expect(await loadComposerDraft(did, "post")).toBeUndefined();
});
it("serializes writes and makes interrupted preparation explicitly retryable", async () => {
  const did = "did:plc:queue-test";
  const segments = [{ id: "s", text: "old", media: { kind: "photos" as const, photos: [{ id: "p", name: "a.jpg", original: new Blob(["abc"]), alt: "", status: "preparing" as const }] } }];
  const first = saveComposerDraft(did, "post", { version: 1, did, segments });
  const last = saveComposerDraft(did, "post", { version: 1, did, segments: [{ ...segments[0], text: "new" }] });
  await Promise.all([first, last]);
  const restored = await loadComposerDraft(did, "post");
  expect(restored?.segments[0].text).toBe("new");
  expect(restored?.segments[0].media).toMatchObject({ photos: [{ status: "failed", error: "Photo Preparation Was Interrupted. Retry." }] });
});
