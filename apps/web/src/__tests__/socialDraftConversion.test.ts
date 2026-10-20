import { expect, it } from "bun:test";
import { segmentsToSocialDraft, socialDraftFingerprint, socialDraftToSegments, removeUnavailableDraftMedia } from "@/lib/socialDraftConversion";
import { gifEmbedURI } from "@/lib/composerMedia";

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
it("reconstructs only safe compatible GIF URLs and preserves inaccessible externals", () => {
  const asset = { id: "gif", title: "GIF", description: "", attribution: "KLIPY", url: "https://static.klipy.com/ii/abc/a.gif", poster: "https://static.klipy.com/ii/abc/a.gif", mp4: "https://static.klipy.com/ii/abc/a.mp4", width: 100, height: 200 };
  const original = { posts: [{ text: "", embedExternals: [{ uri: gifEmbedURI(asset) }] }] };
  const restored = socialDraftToSegments(original);
  expect(restored[0].media?.kind).toBe("gif");
  expect(restored[0].unavailableDraftMedia).toBe(false);
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
  expect(segmentsToSocialDraft([{ ...restoredGif[0], media: undefined }], device).posts[0].embedExternals).toBeUndefined();
});
it("keeps an explicitly removed imported external attachment out of the next native save", () => {
  const original = { deviceId: device, posts: [{ text: "Read this", embedExternals: [{ uri: "https://example.com/article", future: "preserved unless removed" }] }] };
  const segments = socialDraftToSegments(original);
  expect(segments[0].linkPreview?.uri).toBe("https://example.com/article");
  segments[0].removedLinkUrl = "https://example.com/article";
  expect(segmentsToSocialDraft(segments, device, original).posts[0].embedExternals).toBeUndefined();
});
