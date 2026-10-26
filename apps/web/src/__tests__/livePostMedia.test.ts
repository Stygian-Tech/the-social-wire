import { afterEach, expect, spyOn, test } from "bun:test";
import type { Agent } from "@atproto/api";
import type { OAuthSession } from "@atproto/oauth-client-browser";
import * as Atproto from "@/lib/atprotoClient";
import { livePostAttachmentsFingerprint, livePostMediaEmbed, prepareLivePostMedia, validateLiveUpdateAttachments } from "@/lib/livePosts/livePostMedia";
const session = { did: "did:plc:alice", getTokenInfo: async () => ({ aud: "https://pds.example" }) } as unknown as OAuthSession;
const file = new Blob(["image"], { type: "image/png" });
const blob = { $type: "blob" as const, ref: { $link: "bafkreigh2akiscaildc6mkqkqtpge5hh6xj4sm2c5w5k7yctquopzkq4am" }, mimeType: "image/png", size: file.size };
const restores: (() => void)[] = [];
afterEach(() => { for (const restore of restores.splice(0).reverse()) restore(); });
function bitmap() {
  const original = Object.getOwnPropertyDescriptor(globalThis, "createImageBitmap");
  Object.defineProperty(globalThis, "createImageBitmap", { configurable: true, value: async () => ({ width: 640, height: 480, close() {} }) });
  restores.push(() => { if (original) Object.defineProperty(globalThis, "createImageBitmap", original); else Reflect.deleteProperty(globalThis, "createImageBitmap"); });
}
test("reject mixed media, invalid GIFs, excessive counts, and unsupported files", () => {
  expect(() => validateLiveUpdateAttachments({ images: Array.from({ length: 5 }, () => ({ file, alt: "" })) })).toThrow("four");
  expect(() => validateLiveUpdateAttachments({ images: [{ file, alt: "" }], gif: { url: "https://example.com/a.gif", alt: "" } })).toThrow("Choose images");
  expect(() => validateLiveUpdateAttachments({ images: [{ file: new Blob(["svg"], { type: "image/svg+xml" }), alt: "" }] })).toThrow("JPEG");
  expect(() => validateLiveUpdateAttachments({ gif: { url: "http://example.com/a.gif", alt: "" } })).toThrow("HTTPS");
  expect(() => validateLiveUpdateAttachments({ gif: { url: "https://example.com/page", alt: "" } })).toThrow(".gif");
});
test("fingerprints are byte stable and distinguish changed alt and file contents", async () => {
  const hash = await livePostAttachmentsFingerprint({ images: [{ file, alt: "Scene" }] });
  expect(hash).toMatch(/^[a-f0-9]{64}$/);
  expect(await livePostAttachmentsFingerprint({ images: [{ file: new Blob(["image"], { type: "image/png" }), alt: "Scene" }] })).toBe(hash);
  expect(await livePostAttachmentsFingerprint({ images: [{ file, alt: "Changed" }] })).not.toBe(hash);
  expect(await livePostAttachmentsFingerprint({ images: [{ file: new Blob(["other"], { type: "image/png" }), alt: "Scene" }] })).not.toBe(hash);
  expect(await livePostAttachmentsFingerprint()).toBeUndefined();
});
test("image uploads preserve original bytes, dimensions, alt and real PDS endpoint", async () => {
  bitmap(); let uploads = 0, guards = 0;
  const spy = spyOn(Atproto, "createOAuthAgent").mockReturnValue({ uploadBlob: async (body: Blob, options: { encoding: string }) => { uploads++; expect(body).toBe(file); expect(options.encoding).toBe("image/png"); return { data: { blob } }; } } as unknown as Agent); restores.push(() => spy.mockRestore());
  const media = await prepareLivePostMedia({ session, draft: { text: "Image", images: [{ file, alt: "Scene" }] }, assertCurrentAccount: () => { guards++; } });
  expect(uploads).toBe(1); expect(guards).toBeGreaterThan(2);
  expect(JSON.parse(JSON.stringify(media))).toEqual({ pdsUrl: "https://pds.example", images: [{ blob, alt: "Scene", aspectRatio: { width: 640, height: 480 } }] });
  expect(livePostMediaEmbed(media)).toMatchObject({ $type: "app.bsky.embed.images", images: [{ alt: "Scene", aspectRatio: { width: 640, height: 480 } }] });
});
test("account changes during upload reject prepared media", async () => {
  bitmap(); let switched = false;
  const spy = spyOn(Atproto, "createOAuthAgent").mockReturnValue({ uploadBlob: async () => { switched = true; return { data: { blob } }; } } as unknown as Agent); restores.push(() => spy.mockRestore());
  await expect(prepareLivePostMedia({ session, draft: { text: "Image", images: [{ file, alt: "" }] }, assertCurrentAccount: () => { if (switched) throw new Error("Account changed"); } })).rejects.toThrow("Account changed");
});
function mp4() {
  const bytes = new Uint8Array(52), view = new DataView(bytes.buffer);
  view.setUint32(0, 16); bytes.set(new TextEncoder().encode("ftyp"), 4);
  view.setUint32(16, 36); bytes.set(new TextEncoder().encode("moov"), 20);
  view.setUint32(24, 28); bytes.set(new TextEncoder().encode("mvhd"), 28);
  view.setUint32(44, 1000); view.setUint32(48, 10000);
  return new Blob([bytes], { type: "video/mp4" });
}
test("video uses quota checks, PDS service authorization, processed blob and job reuse", async () => {
  const video = mp4(), calls: string[] = [], auth: { aud: string; lxm: string }[] = [];
  const spy = spyOn(Atproto, "createOAuthAgent").mockReturnValue({ com: { atproto: { server: { getServiceAuth: async (args: { aud: string; lxm: string }) => { auth.push(args); return { data: { token: "service-token" } }; } } } } } as unknown as Agent); restores.push(() => spy.mockRestore());
  const mockFetch: typeof fetch = Object.assign(async (input: Parameters<typeof fetch>[0], options?: Parameters<typeof fetch>[1]) => {
    const url = String(input); calls.push(url);
    if (url.includes("getUploadLimits")) return Response.json({ canUpload: true, remainingDailyVideos: 2, remainingDailyBytes: 100000 });
    expect(options?.body).toBe(video); expect(options?.headers).toMatchObject({ Authorization: "Bearer service-token", "Content-Type": "video/mp4" });
    return Response.json({ jobId: "job", did: session.did, state: "JOB_STATE_COMPLETED", blob: { ...blob, mimeType: "video/mp4", size: 52 } });
  }, { preconnect: globalThis.fetch.preconnect });
  const fetchSpy = spyOn(globalThis, "fetch").mockImplementation(mockFetch); restores.push(() => fetchSpy.mockRestore());
  const args = { session, draft: { text: "Video", video: { file: video, alt: "Moving scene" } } };
  expect((await prepareLivePostMedia(args))?.video?.alt).toBe("Moving scene");
  expect(auth).toMatchObject([{ aud: "did:web:video.bsky.app", lxm: "app.bsky.video.getUploadLimits" }, { aud: "did:web:pds.example", lxm: "com.atproto.repo.uploadBlob" }]);
  expect(calls).toHaveLength(2); await prepareLivePostMedia(args); expect(calls).toHaveLength(2);
});
test("GIFs keep original animation URL and alt, text-only drafts make no media", async () => {
  const media = await prepareLivePostMedia({ session, draft: { text: "GIF", gif: { url: "https://example.com/animated.gif", alt: "Waving" } } });
  expect(livePostMediaEmbed(media)).toEqual({ $type: "app.bsky.embed.external", external: { uri: "https://example.com/animated.gif", title: "Waving", description: "Waving" } });
  expect(await prepareLivePostMedia({ session, draft: { text: "Only text" } })).toBeUndefined();
});
test("exhausted video quota prevents a video transfer", async () => {
  const spy = spyOn(Atproto, "createOAuthAgent").mockReturnValue({ com: { atproto: { server: { getServiceAuth: async () => ({ data: { token: "service-token" } }) } } } } as unknown as Agent); restores.push(() => spy.mockRestore());
  let requests = 0;
  const mockFetch: typeof fetch = Object.assign(async () => { requests++; return Response.json({ canUpload: false }); }, { preconnect: globalThis.fetch.preconnect });
  const fetchSpy = spyOn(globalThis, "fetch").mockImplementation(mockFetch); restores.push(() => fetchSpy.mockRestore());
  await expect(prepareLivePostMedia({ session, draft: { text: "Video", video: { file: mp4(), alt: "" } } })).rejects.toThrow("quota");
  expect(requests).toBe(1);
});
test("a processing result belonging to another account is refused", async () => {
  const spy = spyOn(Atproto, "createOAuthAgent").mockReturnValue({ com: { atproto: { server: { getServiceAuth: async () => ({ data: { token: "service-token" } }) } } } } as unknown as Agent); restores.push(() => spy.mockRestore());
  const mockFetch: typeof fetch = Object.assign(async (input: Parameters<typeof fetch>[0]) => String(input).includes("getUploadLimits") ? Response.json({ canUpload: true }) : Response.json({ jobId: "foreign", did: "did:plc:bob", blob: { ...blob, mimeType: "video/mp4" } }), { preconnect: globalThis.fetch.preconnect });
  const fetchSpy = spyOn(globalThis, "fetch").mockImplementation(mockFetch); restores.push(() => fetchSpy.mockRestore());
  await expect(prepareLivePostMedia({ session, draft: { text: "Video", video: { file: mp4(), alt: "" } } })).rejects.toThrow("invalid processing job");
});
test("mismatched link previews fail before any image upload", async () => {
  const spy = spyOn(Atproto, "createOAuthAgent"); restores.push(() => spy.mockRestore());
  await expect(prepareLivePostMedia({ session, draft: { text: "https://example.com/new", images: [{ file, alt: "" }], linkPreview: { uri: "https://example.com/old", title: "Old", description: "" } } })).rejects.toThrow("no longer matches");
  expect(spy).not.toHaveBeenCalled();
});
