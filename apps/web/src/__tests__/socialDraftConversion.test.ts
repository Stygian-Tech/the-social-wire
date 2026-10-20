import { afterEach, expect, it, spyOn } from "bun:test";
import { segmentsToSocialDraft, socialDraftFingerprint, socialDraftToSegments, removeUnavailableDraftMedia, preparePrivateDraftPhotos, restorePrivateDraftPhotos, privatePhotoPath, privateDraftPhotoRefs, replaceSocialDraftMedia, preparePrivateDraftGifs, restorePrivateDraftGifs, privateDraftGifRefs } from "@/lib/socialDraftConversion";
import { gifEmbedURI } from "@/lib/composerMedia";

import * as Klipy from "@/lib/klipyClient";
import * as Attachments from "@/lib/socialDraftAttachmentClient";
import type { OAuthSession } from "@atproto/oauth-client-browser";
import type { ThreadSegment } from "@/lib/blueskyThreadClient";

const restores: (() => void)[] = [];
afterEach(() => restores.splice(0).reverse().forEach(restore => restore()));
const actor = { viewerDid: "did:plc:photo-owner", session: { did: "did:plc:photo-owner" } as unknown as OAuthSession };
const device = "6d1d2e3f-1234-4567-8901-123456789012";
it("roundtrips raw markdown, native gates, labels, languages, records, and unknown media metadata", () => {
  const original = {
    deviceId: device, langs: ["fr"], threadgateAllow: [{ $type: "app.bsky.feed.threadgate#followingRule" as const }], postgateEmbeddingRules: [{ $type: "app.bsky.feed.postgate#disableRule" as const }], future: { nested: true },
    posts: [{ text: "**raw** [source](https://example.com)", labels: { $type: "com.atproto.label.defs#selfLabels" as const, values: [{ val: "porn" }] }, embedRecords: [{ record: { uri: "at://did:plc:a/app.bsky.feed.post/one", cid: "cid" } }], embedImages: [{ localRef: { path: "native/photo", future: 1 }, alt: "Photo", gallery: 2 }], embedVideos: [{ localRef: { path: "native/video" }, captions: [{ lang: "fr", content: "Caption" }] }], embedExternals: [{ uri: "https://example.com", future: true }] }],
  };
  const segments = socialDraftToSegments(original);
  expect(segments[0].unavailableDraftMedia).toBe(true);
  expect(segmentsToSocialDraft(segments, device, original)).toEqual(original);
  segments[0].text = "Edited raw _source_";
  expect(segmentsToSocialDraft(segments, device, original).posts[0]).toEqual({ ...original.posts[0], text: segments[0].text });
  const removed = removeUnavailableDraftMedia(segments[0]);
  const post = segmentsToSocialDraft([removed], device, original).posts[0];
  expect(post.embedImages).toBeUndefined(); expect(post.embedVideos).toBeUndefined();
  expect(post.embedRecords).toEqual(original.posts[0].embedRecords);
});
it("retains local photo bytes without putting bytes or publication journals in native payloads", () => {
  const photo = { id: "photo", name: "p.jpg", original: new Blob(["private"]), blob: new Blob(["private"]), width: 10, height: 10, alt: "Alt", status: "ready" as const };
  const local = [{ id: "segment", text: "", media: { kind: "photos" as const, photos: [photo] } }];
  const native = segmentsToSocialDraft(local, device);
  expect(JSON.stringify(native)).not.toContain("private");
  expect(native.posts[0].embedImages?.[0].localRef.path).toBe(`socialwire://${device}/photo`);
  expect(socialDraftToSegments(native)[0].unavailableDraftMedia).toBe(true);
  const restored = socialDraftToSegments(native, local)[0];
  expect(restored.unavailableDraftMedia).toBe(false);
  expect(restored.media).toEqual(local[0].media);
});

function localPhotoSegment(id: string) {
  return { id, text: id, media: { kind: "photos" as const, photos: [{ id, name: `${id}.jpg`, original: new Blob([id]), blob: new Blob([id]), width: 10, height: 20, alt: `Local ${id}`, status: "ready" as const }] } };
}

it("does not restore remotely removed photos, GIFs, or link previews from local recovery", () => {
  const photo = localPhotoSegment("removed");
  const gif = socialDraftToSegments({ posts: [{ text: "GIF", embedExternals: [{ uri: "https://static.klipy.com/ii/abc/a.gif?ww=100&hh=100&mp4=a" }] }] })[0];
  const local = [photo, gif, { id: "link", text: "Link", linkPreview: { uri: "https://example.com", title: "Old", description: "" } }];
  const remote = { deviceId: device, posts: local.map(() => ({ text: "Removed attachment" })) };
  const restored = socialDraftToSegments(remote, local);
  expect(restored.every(segment => !segment.media && !segment.linkPreview && !segment.unavailableDraftMedia)).toBe(true);
  expect(segmentsToSocialDraft(restored, device, remote)).toEqual(remote);
});

it("marks replacement and foreign-device photo references unavailable without borrowing old bytes", () => {
  const local = [localPhotoSegment("photo")];
  for (const path of [`socialwire://${device}/replacement`, "socialwire://another-device/photo", "untrusted/prefix/photo"]) {
    const remote = { deviceId: device, posts: [{ text: "Replacement", embedImages: [{ localRef: { path }, alt: "Remote" }] }] };
    const restored = socialDraftToSegments(remote, local);
    expect(restored[0].media).toBeUndefined();
    expect(restored[0].unavailableDraftMedia).toBe(true);
    expect(segmentsToSocialDraft(restored, device, remote)).toEqual(remote);
  }
});

it("matches photos across reordered posts and image references, using remote order and alt text", async () => {
  const first = localPhotoSegment("first");
  const second = localPhotoSegment("second");
  const local = [first, second];
  const native = segmentsToSocialDraft(local, device);
  const remote = { ...native, posts: [{ text: "Reordered", embedImages: [
    { ...native.posts[1].embedImages![0], alt: "Remote second", future: { preserved: true } },
    { ...native.posts[0].embedImages![0], alt: "Remote first" },
  ] }] };
  const restored = socialDraftToSegments(remote, local);
  expect(restored[0].unavailableDraftMedia).toBe(false);
  const media = restored[0].media;
  if (media?.kind !== "photos") throw new Error("Missing Matched Photos");
  expect(media.photos.map(photo => photo.id)).toEqual(["second", "first"]);
  expect(media.photos.map(photo => photo.alt)).toEqual(["Remote second", "Remote first"]);
  expect(media.photos[0].original).toBe(second.media.photos[0].original);
  expect(await media.photos[1].original.text()).toBe("first");
  expect(segmentsToSocialDraft(restored, device, remote)).toEqual(remote);
});

it("preserves invalid mixed, duplicate, and partially missing references until explicit removal", () => {
  const local = [localPhotoSegment("photo")];
  const image = segmentsToSocialDraft(local, device).posts[0].embedImages![0];
  for (const post of [
    { text: "Partial", embedImages: [image, { localRef: { path: `socialwire://${device}/missing` }, alt: "Missing" }] },
    { text: "Duplicate", embedImages: [image, image] },
    { text: "Mixed", embedImages: [image], embedExternals: [{ uri: "https://example.com", future: true }] },
    { text: "Gallery", embedImages: [image], embedGallery: { future: true } },
  ]) {
    const remote = { deviceId: device, posts: [post] };
    const restored = socialDraftToSegments(remote, local);
    expect(restored[0].unavailableDraftMedia).toBe(true);
    expect(segmentsToSocialDraft(restored, device, remote)).toEqual(remote);
    const removed = removeUnavailableDraftMedia(restored[0]);
    expect(segmentsToSocialDraft([removed], device, remote).posts).toEqual([{ text: post.text }]);
  }
});

it("uses exact saved local references and refuses ambiguous or missing file recovery", () => {
  const segment = localPhotoSegment("photo");
  const native = segmentsToSocialDraft([segment], device);
  const local = { ...segment, nativeDraftPost: native.posts[0] };
  // A later editing device does not change the identity of the referenced bytes.
  const remote = { ...native, deviceId: "another-editing-device" };
  const restored = socialDraftToSegments(remote, [local]);
  expect(restored[0].unavailableDraftMedia).toBe(false);
  if (restored[0].media?.kind !== "photos") throw new Error("Missing Matched Photo");
  expect(restored[0].media.photos[0].original).toBe(segment.media.photos[0].original);
  expect(segmentsToSocialDraft(restored, device, remote)).toEqual(remote);

  const noAlt = { ...remote, posts: [{ text: "No Alt", embedImages: [{ localRef: native.posts[0].embedImages![0].localRef }] }] };
  const withoutAlt = socialDraftToSegments(noAlt, [local]);
  if (withoutAlt[0].media?.kind !== "photos") throw new Error("Missing Matched Photo");
  expect(withoutAlt[0].media.photos[0].alt).toBe("");
  expect(segmentsToSocialDraft(withoutAlt, device, noAlt)).toEqual(noAlt);

  const duplicate = { ...localPhotoSegment("photo"), nativeDraftPost: native.posts[0] };
  const ambiguous = socialDraftToSegments(remote, [local, duplicate]);
  expect(ambiguous[0].unavailableDraftMedia).toBe(true);
  expect(ambiguous[0].media).toBeUndefined();
  expect(segmentsToSocialDraft(ambiguous, device, remote)).toEqual(remote);

  const missingBytes = { ...local, media: { kind: "photos" as const, photos: [{ ...segment.media.photos[0], original: undefined as unknown as Blob }] } };
  expect(socialDraftToSegments(remote, [missingBytes])[0].unavailableDraftMedia).toBe(true);
});
it("preserves compatible imported GIF metadata as unavailable until files are recovered or reselected", () => {
  const asset = { id: "gif", title: "GIF", description: "", attribution: "KLIPY", url: "https://static.klipy.com/ii/abc/a.gif", poster: "https://static.klipy.com/ii/abc/a.gif", mp4: "https://static.klipy.com/ii/abc/a.mp4", width: 100, height: 200 };
  const original = { posts: [{ text: "", embedExternals: [{ uri: gifEmbedURI(asset) }] }] };
  const restored = socialDraftToSegments(original);
  expect(restored[0].media?.kind).toBe("gif");
  expect(restored[0].unavailableDraftMedia).toBe(true);
  expect(segmentsToSocialDraft(restored, device).posts).toEqual(original.posts);
  const broken = { posts: [{ text: "", embedExternals: [{ uri: "https://static.klipy.com/ii/abc/a.gif" }] }] };
  expect(socialDraftToSegments(broken)[0].unavailableDraftMedia).toBe(true);
  expect(segmentsToSocialDraft(socialDraftToSegments(broken), device).posts).toEqual(broken.posts);
});
it("enforces native draft limits in graphemes and UTF-8 bytes without compiling markdown", () => {
  expect(segmentsToSocialDraft([{ id: "s", text: "👨‍👩‍👧‍👦".repeat(400) }], device).posts[0].text).toHaveLength(4400);
  expect(() => segmentsToSocialDraft([{ id: "s", text: "a".repeat(1001) }], device)).toThrow("1,000");
  expect(() => segmentsToSocialDraft([{ id: "s", text: "👨‍👩‍👧‍👦".repeat(401) }], device)).toThrow("10,000");
  expect(() => segmentsToSocialDraft(Array.from({ length: 101 }, (_, index) => ({ id: `${index}`, text: "a" })), device)).toThrow("100 Posts");
  expect(socialDraftFingerprint({ b: 2, a: 1 })).toBe(socialDraftFingerprint({ a: 1, b: 2 }));
});
it("preserves unsupported galleries and blocks them until explicit removal", () => {
  const original = { posts: [{ text: "Gallery", embedGallery: { images: [{ localRef: { path: "native/gallery" } }], future: true } }] };
  const restored = socialDraftToSegments(original);
  expect(restored[0].unavailableDraftMedia).toBe(true);
  expect(segmentsToSocialDraft(restored, device).posts).toEqual(original.posts);
  const removed = removeUnavailableDraftMedia(restored[0]);
  expect(segmentsToSocialDraft([removed], device).posts).toEqual([{ text: "Gallery" }]);
  expect(removed.unavailableDraftMedia).toBe(false);
});
it("does not resurrect deliberately removed local photos or GIFs", () => {
  const photos = [{ id: "s", text: "", media: { kind: "photos" as const, photos: [{ id: "p", name: "p.jpg", original: new Blob(["photo"]), alt: "Photo", status: "ready" as const }] } }];
  const native = segmentsToSocialDraft(photos, device);
  const restored = socialDraftToSegments(native, photos);
  expect(restored[0].unavailableDraftMedia).toBe(false);
  expect(segmentsToSocialDraft([{ ...restored[0], media: undefined }], device).posts[0].embedImages).toBeUndefined();
  const gif = { posts: [{ text: "", embedExternals: [{ uri: "https://static.klipy.com/ii/abc/a.gif?ww=100&hh=100&mp4=a" }] }] };
  const restoredGif = socialDraftToSegments(gif);
  expect(restoredGif[0].media?.kind).toBe("gif");
  expect(segmentsToSocialDraft([replaceSocialDraftMedia(restoredGif[0], undefined)], device).posts[0].embedExternals).toBeUndefined();
});
it("keeps an explicitly removed imported external attachment out of the next native save", () => {
  const original = { deviceId: device, posts: [{ text: "Read this", embedExternals: [{ uri: "https://example.com/article", future: "preserved unless removed" }] }] };
  const segments = socialDraftToSegments(original);
  expect(segments[0].linkPreview?.uri).toBe("https://example.com/article");
  segments[0].removedLinkUrl = "https://example.com/article";
  expect(segmentsToSocialDraft(segments, device, original).posts[0].embedExternals).toBeUndefined();
});


it("never uploads before both files and stable asset metadata are durably checkpointed", async () => {
  const photo = { ...localPhotoSegment("p").media.photos[0], original: new Blob(["original"], { type: "image/png" }), blob: new Blob(["prepared"], { type: "image/jpeg" }) };
  const upload = spyOn(Attachments, "uploadDraftAttachment").mockRejectedValue(new Error("Should Not Upload")); restores.push(() => upload.mockRestore());
  let checkpoint: ThreadSegment[] | undefined;
  await expect(preparePrivateDraftPhotos(actor, [{ id: "s", text: "", media: { kind: "photos", photos: [photo] } }], async segments => { checkpoint = segments; throw new Error("Disk Full"); })).rejects.toThrow("Disk Full");
  expect(upload).not.toHaveBeenCalled();
  const media = checkpoint?.[0].media;
  if (media?.kind !== "photos") throw new Error("Missing Photo");
  expect(media.photos[0].privateAttachment?.original.sha256).toHaveLength(64);
  expect(media.photos[0].privateAttachment?.prepared.sha256).toHaveLength(64);
});
it("roundtrips private photos across reordered posts and image references with native metadata preserved", async () => {
  const uploads = spyOn(Attachments, "uploadDraftAttachment").mockImplementation(async (_actor, asset) => ({ ...asset, state: "ready" })); restores.push(() => uploads.mockRestore());
  let local: ThreadSegment[] = [localPhotoSegment("first"), localPhotoSegment("second")].map(segment => ({ ...segment, media: { ...segment.media, photos: segment.media.photos.map(photo => ({ ...photo, original: new Blob([photo.id], { type: "image/png" }), blob: new Blob([photo.id], { type: "image/jpeg" }) })) } }));
  await preparePrivateDraftPhotos(actor, local, async prepared => { local = prepared; });
  const native = segmentsToSocialDraft(local, device);
  const remote = { ...native, posts: [{ text: "Reordered", embedImages: [ { ...native.posts[1].embedImages![0], alt: "Second" }, { ...native.posts[0].embedImages![0], alt: "First" } ] }] };
  const restored = socialDraftToSegments(remote, local);
  expect(restored[0].unavailableDraftMedia).toBe(false);
  const media = restored[0].media;
  if (media?.kind !== "photos") throw new Error("Missing Photos");
  expect(media.photos.map(photo => photo.id)).toEqual(["second", "first"]);
  expect(media.photos.map(privatePhotoPath)).toEqual(remote.posts[0].embedImages.map(image => image.localRef.path));
  expect(segmentsToSocialDraft(restored, device, remote)).toEqual(remote);
  expect(privateDraftPhotoRefs(remote)).toHaveLength(4);
});
it("refuses a mismatched manifest rather than borrowing another attachment or fetching native paths", async () => {
  const original = await Attachments.describeDraftAttachment(new Blob(["original"], { type: "image/png" }), "p.png");
  const prepared = await Attachments.describeDraftAttachment(new Blob(["prepared"], { type: "image/jpeg" }), "p.png");
  const path = `socialwire-private://v1/photo/${original.assetId}/${prepared.assetId}`;
  const download = spyOn(Attachments, "downloadDraftAttachment").mockRejectedValue(new Error("Should Not Download")); restores.push(() => download.mockRestore());
  const manifest = { draftId: "draft", revision: 1, deleted: false, attachments: [ { assetId: original.assetId, role: "original" as const, ref: path, asset: original }, { assetId: prepared.assetId, role: "prepared" as const, ref: "different-ref", asset: prepared } ] };
  await expect(restorePrivateDraftPhotos(actor, { posts: [{ text: "", embedImages: [{ localRef: { path } }] }] }, manifest)).rejects.toThrow("Missing");
  expect(download).not.toHaveBeenCalled();
  const foreign = { posts: [{ text: "", embedImages: [{ localRef: { path: "file:///private/image.jpg" } }] }] };
  expect((await restorePrivateDraftPhotos(actor, foreign, { ...manifest, attachments: [] }))[0].unavailableDraftMedia).toBe(true);
  expect(download).not.toHaveBeenCalled();
});
it("allocates owner-specific IDs instead of reusing portable metadata from a different account", async () => {
  const original = await Attachments.describeDraftAttachment(new Blob(["original"], { type: "image/png" }), "p.jpg");
  const prepared = await Attachments.describeDraftAttachment(new Blob(["prepared"], { type: "image/jpeg" }), "p.jpg");
  const photo = { ...localPhotoSegment("p").media.photos[0], original: new Blob(["original"], { type: "image/png" }), blob: new Blob(["prepared"], { type: "image/jpeg" }), privateAttachment: { ownerDid: "did:plc:other", original, prepared } };
  const uploads = spyOn(Attachments, "uploadDraftAttachment").mockImplementation(async (_actor, asset) => ({ ...asset, state: "ready" })); restores.push(() => uploads.mockRestore());
  let result: ThreadSegment[] = [];
  await preparePrivateDraftPhotos(actor, [{ id: "s", text: "", media: { kind: "photos", photos: [photo] } }], async segments => { result = segments; });
  const media = result[0].media;
  if (media?.kind !== "photos") throw new Error("Missing Photo");
  expect(media.photos[0].privateAttachment?.ownerDid).toBe(actor.viewerDid);
  expect(media.photos[0].privateAttachment?.original.assetId).not.toBe(original.assetId);
  expect(media.photos[0].privateAttachment?.prepared.assetId).not.toBe(prepared.assetId);
});
it("retains immutable GIF metadata privately without serializing file bytes or Blob URLs into native drafts", async () => {
  const { lexicons } = await import("@atproto/api");
  const asset = { id: "catalog", title: "GIF Title", description: "Provider description", attribution: "KLIPY", url: "https://static.klipy.com/ii/a/a.gif", poster: "https://static.klipy.com/ii/a/p.jpg", mp4: "https://static.klipy.com/ii/a/v.mp4", width: 10, height: 20 };
  const native = segmentsToSocialDraft([{ id: "s", text: "", media: { kind: "gif", asset, alt: "Author description" } }], device);
  expect(() => lexicons.assertValidXrpcInput("app.bsky.draft.createDraft", { draft: native })).not.toThrow();
  const media = socialDraftToSegments(native)[0].media;
  if (media?.kind !== "gif") throw new Error("Missing GIF Metadata");
  expect(media.asset).toEqual(asset); expect(media.alt).toBe("Author description"); expect(media.unavailable).toBe(true);
  expect(JSON.stringify(native)).not.toContain("blob:"); expect(JSON.stringify(native)).not.toContain("privateFiles");
});
it.each(["", "application/octet-stream"])("privately uploads legacy ready photos with sniffed original MIME without changing bytes or Blob identity: %s", async mime => {
  const bytes = new Uint8Array([137, 80, 78, 71, 13, 10, 26, 10]); const original = new Blob([bytes], { type: mime });
  const photo = { ...localPhotoSegment("legacy").media.photos[0], original, blob: new Blob(["prepared"], { type: "image/jpeg" }) };
  const upload = spyOn(Attachments, "uploadDraftAttachment").mockImplementation(async (_actor, asset, blob) => {
    if (asset.contentType === "image/png") { expect(blob.type).toBe("image/png"); expect(new Uint8Array(await blob.arrayBuffer())).toEqual(bytes); }
    return { ...asset, state: "ready" };
  }); restores.push(() => upload.mockRestore());
  let recovered: ThreadSegment[] = [];
  await preparePrivateDraftPhotos(actor, [{ id: "s", text: "", media: { kind: "photos", photos: [photo] } }], async segments => { recovered = segments; });
  const media = recovered[0].media;
  if (media?.kind !== "photos") throw new Error("Missing Legacy Photo");
  expect(media.photos[0].original).toBe(original); expect(media.photos[0].id).toBe("legacy"); expect(media.photos[0].privateAttachment?.original.contentType).toBe("image/png");
});


function repeatedGifSegments(): ThreadSegment[] {
  const asset = { id: "same-gif", title: "GIF", description: "Provider description", attribution: "KLIPY", url: "https://static.klipy.com/ii/shared/full.gif", poster: "https://static.klipy.com/ii/shared/poster.jpg", mp4: "https://static.klipy.com/ii/shared/video.mp4", webm: "https://static.klipy.com/ii/shared/video.webm", width: 10, height: 20 };
  return ["First", "Second"].map(label => ({ id: label.toLowerCase(), text: `${label} Post`, nativeDraftPost: { text: `${label} Post`, future: { setting: label } }, media: { kind: "gif", asset, alt: `${label} Description` } }));
}
function gifFileServer() {
  const files = new Map<string, { asset: Attachments.DraftAttachment; blob: Blob }>();
  const fetch = spyOn(Klipy, "getGifFile").mockImplementation(async (_actor, _id, rendition) => new Blob([rendition], { type: rendition === "gif" ? "image/gif" : rendition === "poster" ? "image/jpeg" : `video/${rendition}` }));
  const upload = spyOn(Attachments, "uploadDraftAttachment").mockImplementation(async (_actor, asset, blob) => {
    const ready = { ...asset, state: "ready" as const }; files.set(asset.assetId, { asset: ready, blob }); return ready;
  });
  const download = spyOn(Attachments, "downloadDraftAttachment").mockImplementation(async (_actor, asset) => files.get(asset.assetId)!.blob);
  restores.push(() => fetch.mockRestore(), () => upload.mockRestore(), () => download.mockRestore());
  return { files, fetch, upload, download };
}
function gifDescriptions(segments: ThreadSegment[]) { return segments.map(segment => segment.media?.kind === "gif" ? segment.media.alt : undefined); }
it("restores each repeated GIF post's own description while reusing shared local bytes", async () => {
  gifFileServer(); let local = repeatedGifSegments();
  await preparePrivateDraftGifs(actor, local, async prepared => { local = prepared; });
  const native = segmentsToSocialDraft(local, device);
  const restored = socialDraftToSegments(native, local);
  expect(gifDescriptions(restored)).toEqual(["First Description", "Second Description"]);
  expect(segmentsToSocialDraft(restored, device, native)).toEqual(native);
  if (restored[0].media?.kind !== "gif" || restored[1].media?.kind !== "gif") throw new Error("Missing GIFs");
  expect(restored[0].media.privateFiles?.files.gif?.blob).toBe(restored[1].media.privateFiles?.files.gif?.blob);
});
it("uses each current native post's metadata when a repeated GIF moves or changes remotely", () => {
  const local = socialDraftToSegments(segmentsToSocialDraft(repeatedGifSegments(), device));
  const native = segmentsToSocialDraft(repeatedGifSegments(), device);
  const reordered = { ...native, posts: [...native.posts].reverse() };
  expect(gifDescriptions(socialDraftToSegments(reordered, local))).toEqual(["Second Description", "First Description"]);
  const newer = repeatedGifSegments();
  if (newer[1].media?.kind !== "gif") throw new Error("Missing GIF");
  newer[1].media.alt = "Remotely Edited Second Description";
  expect(gifDescriptions(socialDraftToSegments(segmentsToSocialDraft(newer, device), local))).toEqual(["First Description", "Remotely Edited Second Description"]);
});
it("preserves an unsynced local description only on the repeated GIF post matching its native baseline", () => {
  const native = segmentsToSocialDraft(repeatedGifSegments(), device);
  const local = socialDraftToSegments(native);
  if (local[1].media?.kind !== "gif") throw new Error("Missing GIF");
  local[1].media.alt = "Unsynced Second Description";
  const restored = socialDraftToSegments(native, local);
  expect(gifDescriptions(restored)).toEqual(["First Description", "Unsynced Second Description"]);
  expect(restored.map(segment => (segment.nativeDraftPost as { future?: unknown }).future)).toEqual([{ setting: "First" }, { setting: "Second" }]);
});
it("retains distinct repeated-GIF descriptions across fresh-device downloads and the second conversion pass", async () => {
  const server = gifFileServer(); let local = repeatedGifSegments();
  await preparePrivateDraftGifs(actor, local, async prepared => { local = prepared; });
  const native = segmentsToSocialDraft(local, device);
  const manifest = { draftId: "draft", revision: 1, deleted: false, attachments: privateDraftGifRefs(local).map(ref => ({ ...ref, asset: server.files.get(ref.assetId)!.asset })) };
  const fresh = await restorePrivateDraftGifs(actor, native, manifest);
  expect(gifDescriptions(fresh)).toEqual(["First Description", "Second Description"]);
  const secondPass = socialDraftToSegments(native, fresh);
  expect(gifDescriptions(secondPass)).toEqual(["First Description", "Second Description"]);
  expect(segmentsToSocialDraft(secondPass, device, native)).toEqual(native);
  expect(privateDraftGifRefs(secondPass)).toHaveLength(4);
});
it("checkpoints one canonical replacement across repeated GIFs before uploading a retired asset's new ID", async () => {
  const server = gifFileServer(); let local = repeatedGifSegments();
  await preparePrivateDraftGifs(actor, local, async prepared => { local = prepared; });
  const retired = new Set(server.files.keys());
  server.upload.mockImplementation(async (_actor, asset, blob) => {
    if (retired.has(asset.assetId)) throw Object.assign(new Error("Retired"), { status: 409, error: "AssetRetired" });
    const rendition = asset.name.split(".").at(-1) as "gif" | "poster" | "mp4" | "webm";
    for (const segment of local) {
      if (segment.media?.kind !== "gif") throw new Error("Missing GIF");
      expect(segment.media.privateFiles?.files[rendition]?.asset.assetId).toBe(asset.assetId);
    }
    const ready = { ...asset, state: "ready" as const }; server.files.set(asset.assetId, { asset: ready, blob }); return ready;
  });
  await preparePrivateDraftGifs(actor, local, async prepared => { local = prepared; });
  const refs = privateDraftGifRefs(local);
  expect(refs).toHaveLength(4); expect(refs.every(ref => !retired.has(ref.assetId))).toBe(true);
  expect(gifDescriptions(local)).toEqual(["First Description", "Second Description"]);
});
