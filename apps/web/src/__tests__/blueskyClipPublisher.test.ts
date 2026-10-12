import { afterEach, beforeEach, describe, expect, it, spyOn } from "bun:test";
import type { OAuthSession } from "@atproto/oauth-client-browser";
import type { PodcastClip } from "@/lib/podcasts/client";
import { ensureValidTid } from "@atproto/syntax";
import { PodcastClipAlreadyPublishedError, publishBlueskyPodcastClip, validateBlueskyClipVideo } from "@/lib/podcasts/blueskyClipPublisher";
const cid = "bafyreihdwdcefgh4dqkjv67uzcmw7ojee6xedzdetojuzjevtenxquvyku";
const clip = (id: string): PodcastClip => ({ id, episodeId: "episode", startSeconds: 0, endSeconds: 20, title: "Podcast Clip", status: "complete", createdAt: "2026-10-11T12:00:00.000Z" });
function mp4(seconds = 20): Blob {
  function box(name: string, content: Uint8Array) { const b = new Uint8Array(content.length + 8); new DataView(b.buffer).setUint32(0, b.length); b.set(new TextEncoder().encode(name), 4); b.set(content, 8); return b; }
  const timing = new Uint8Array(20), view = new DataView(timing.buffer); view.setUint32(12, 1000); view.setUint32(16, seconds * 1000);
  return new Blob([box("ftyp", new Uint8Array(8)), box("moov", box("mvhd", timing))], { type: "video/mp4" });
}
type Call = { method: string; body?: Record<string, unknown>; url: URL };
function setup(options: { quota?: Record<string, unknown>; processing?: boolean; wrongDid?: boolean; ambiguous?: boolean; afterRequest?: () => void; onVideoRequest?: (method: string) => void; finishLost?: boolean; owner?: string; existingUri?: string } = {}) {
  const did = options.owner ?? "did:plc:alice";
  const calls: Call[] = [], videoCalls: { method: string; init?: RequestInit }[] = [];
  let record: Record<string, unknown> | undefined; let finishes = 0; let uploadStatuses = 0;
  const session = {
    did, getTokenInfo: async () => ({ aud: "https://alice.pds.example" }),
    fetchHandler: async (path: string, init?: RequestInit) => {
      const url = new URL(path, "https://alice.pds.example"), method = url.pathname.split("/").at(-1)!;
      const body = init?.body ? await new Response(init.body).json() as Record<string, unknown> : undefined;
      if (method === "com.atproto.repo.createRecord" && body?.collection === "app.bsky.feed.post") ensureValidTid(String(body.rkey));
      calls.push({ method, body, url }); let response: Response;
      if (method === "com.atproto.repo.getRecord") response = record ? Response.json({ uri: options.existingUri ?? `at://${did}/app.bsky.feed.post/${url.searchParams.get("rkey")}`, cid, value: record }) : Response.json({ error: "RecordNotFound" }, { status: 400 });
      else if (method === "com.atproto.server.getServiceAuth") response = Response.json({ token: "service-token" });
      else if (method === "com.atproto.identity.resolveHandle") response = Response.json({ did: "did:plc:bob" });
      else if (method === "com.atproto.repo.createRecord") { record = body!.record as Record<string, unknown>; if (options.ambiguous) throw new TypeError("Connection lost after commit"); response = Response.json({ uri: `at://${did}/app.bsky.feed.post/${body!.rkey}`, cid }); }
      else throw new Error(`Unexpected PDS call ${method}`);
      options.afterRequest?.(); return response;
    },
  } as unknown as OAuthSession;
  const job = { jobId: "processing-job", did: options.wrongDid ? "did:plc:other" : did, state: options.processing ? "JOB_STATE_PROCESSING" : "JOB_STATE_COMPLETED", blob: { $type: "blob", ref: { $link: cid }, mimeType: "video/mp4", size: mp4().size } };
  const preconnect = globalThis.fetch.preconnect;
  const fetchSpy = spyOn(globalThis, "fetch").mockImplementation(Object.assign(async (input: Parameters<typeof fetch>[0], init?: Parameters<typeof fetch>[1]) => {
    const url = new URL(String(input)); expect(url.origin).toBe("https://video.bsky.app"); expect(init?.credentials).toBe("omit"); expect(init?.redirect).toBe("error");
    const method = url.pathname.split("/").at(-1)!; videoCalls.push({ method, init }); options.onVideoRequest?.(method);
    if (method === "app.bsky.video.getUploadLimits") return Response.json(options.quota ?? { canUpload: true, remainingDailyVideos: 3, remainingDailyBytes: 1000 });
    if (method === "app.bsky.video.startUpload") return Response.json({ jobId: "upload", partSizeBytes: 1024, partCount: 1 });
    if (method === "app.bsky.video.uploadPart") return Response.json({ partNumber: 1, sizeBytes: mp4().size });
    if (method === "app.bsky.video.getJobStatus") { job.state = "JOB_STATE_COMPLETED"; return Response.json({ jobStatus: job }); }
    if (method === "app.bsky.video.finishUpload") {
      finishes++; if (options.finishLost && finishes <= 2) throw new TypeError("Lost finish response");
      return Response.json({ jobStatus: job });
    }
    if (method === "app.bsky.video.getUploadStatus") { uploadStatuses++; return Response.json(uploadStatuses === 1 ? { state: "finishing" } : { state: "completed", jobStatus: job }); }
    if (method === "app.bsky.video.abortUpload") return Response.json({ state: "aborted" });
    throw new Error(`Unexpected video call ${method}`);
  }, { preconnect }));
  return { session, calls, videoCalls, fetchSpy, getRecord: () => record };
}
const previousEnv = process.env.NEXT_PUBLIC_APP_ENV;
beforeEach(() => { process.env.NEXT_PUBLIC_APP_ENV = "prod"; });
afterEach(() => { if (previousEnv === undefined) delete process.env.NEXT_PUBLIC_APP_ENV; else process.env.NEXT_PUBLIC_APP_ENV = previousEnv; });
describe("native Bluesky podcast video publishing", () => {
  it("validates actual MP4 duration and rejects overlong, malformed, wrong MIME videos", async () => {
    const tooLarge = mp4(); Object.defineProperty(tooLarge, "size", { value: 300_000_001 });
    await expect(validateBlueskyClipVideo(tooLarge)).rejects.toThrow("300 MB");
    await validateBlueskyClipVideo(mp4(600)); await expect(validateBlueskyClipVideo(mp4(601))).rejects.toThrow("10 minutes");
    await expect(validateBlueskyClipVideo(new Blob(["fake video"], { type: "video/mp4" }))).rejects.toThrow();
    await expect(validateBlueskyClipVideo(new Blob([mp4()], { type: "video/webm" }))).rejects.toThrow(); await expect(validateBlueskyClipVideo(mp4(0))).rejects.toThrow();
  });
  it("checks quota, delegates to viewer PDS, uploads multipart and creates native video with UTF8 facets", async () => {
    const s = setup(), statuses: string[] = [];
    try {
      expect((await publishBlueskyPodcastClip({ session: s.session, clip: clip("native"), video: mp4(), text: "é @bob.test https://example.com #podcast", onProgress: status => statuses.push(status) })).cid).toBe(cid);
      expect(s.calls.filter(x => x.method === "com.atproto.server.getServiceAuth").map(x => Object.fromEntries(x.url.searchParams))).toEqual([{ aud: "did:web:video.bsky.app", lxm: "app.bsky.video.getUploadLimits" }, { aud: "did:web:alice.pds.example", lxm: "com.atproto.repo.uploadBlob", exp: expect.any(String) }, { aud: "did:web:alice.pds.example", lxm: "com.atproto.repo.uploadBlob", exp: expect.any(String) }]);
      expect(Date.parse(s.getRecord()!.createdAt as string)).toBeGreaterThan(Date.now() - 10_000);
      expect(s.getRecord()).toMatchObject({ $type: "app.bsky.feed.post", embed: { $type: "app.bsky.embed.video", video: { mimeType: "video/mp4" }, alt: "Podcast Clip" }, facets: [{ index: { byteStart: 3, byteEnd: 12 }, features: [{ $type: "app.bsky.richtext.facet#mention", did: "did:plc:bob" }] }, expect.anything(), expect.anything()] });
      expect(s.videoCalls.map(x => x.method)).toEqual(["app.bsky.video.getUploadLimits", "app.bsky.video.startUpload", "app.bsky.video.uploadPart", "app.bsky.video.finishUpload"]); expect(statuses.at(-1)).toBe("Published");
    } finally { s.fetchSpy.mockRestore(); }
  });
  it("reconciles ambiguous commit and repeated call without duplicate upload or post", async () => {
    const s = setup({ ambiguous: true });
    try {
      const args = { session: s.session, clip: clip("retry"), video: mp4(), text: "hello" }, first = await publishBlueskyPodcastClip(args);
      expect(await publishBlueskyPodcastClip(args)).toEqual(first); expect(s.calls.filter(x => x.method === "com.atproto.repo.createRecord")).toHaveLength(1); expect(s.videoCalls.filter(x => x.method === "app.bsky.video.startUpload")).toHaveLength(1);
      try {
        await publishBlueskyPodcastClip({ ...args, text: "different" });
        throw new Error("Expected conflict");
      } catch (error) {
        expect(error).toBeInstanceOf(PodcastClipAlreadyPublishedError);
        expect(error).toMatchObject({ uri: first.uri, cid: first.cid });
      }
    } finally { s.fetchSpy.mockRestore(); }
  });
  it("rejects exhausted daily quotas before upload", async () => {
    for (const quota of [{ canUpload: false }, { canUpload: true, remainingDailyVideos: 0 }, { canUpload: true, remainingDailyBytes: 1 }]) {
      const s = setup({ quota }); try { await expect(publishBlueskyPodcastClip({ session: s.session, clip: clip("quota"), video: mp4(), text: "" })).rejects.toThrow("quota"); expect(s.videoCalls).toHaveLength(1); expect(s.calls.some(x => x.method === "com.atproto.repo.createRecord")).toBe(false); } finally { s.fetchSpy.mockRestore(); }
    }
  });
  it("rejects foreign processing job without publishing", async () => {
    const s = setup({ wrongDid: true }); try { await expect(publishBlueskyPodcastClip({ session: s.session, clip: clip("foreign"), video: mp4(), text: "" })).rejects.toThrow("another account"); expect(s.calls.some(x => x.method === "com.atproto.repo.createRecord")).toBe(false); } finally { s.fetchSpy.mockRestore(); }
  });
  it("blocks isolated sandbox before API calls", async () => {
    process.env.NEXT_PUBLIC_APP_ENV = "local"; const old = process.env.NEXT_PUBLIC_LOCAL_ATPROTO_PLC_URL; process.env.NEXT_PUBLIC_LOCAL_ATPROTO_PLC_URL = "https://plc.atmosbox.test"; const s = setup();
    try { await expect(publishBlueskyPodcastClip({ session: s.session, clip: clip("local"), video: mp4(), text: "" })).rejects.toThrow("isolated local sandbox"); expect(s.calls).toHaveLength(0); expect(s.videoCalls).toHaveLength(0); }
    finally { s.fetchSpy.mockRestore(); if (old === undefined) delete process.env.NEXT_PUBLIC_LOCAL_ATPROTO_PLC_URL; else process.env.NEXT_PUBLIC_LOCAL_ATPROTO_PLC_URL = old; }
  });
  it("guards account change after read before service auth or mutation", async () => {
    let changed = false; const s = setup({ afterRequest: () => { changed = true; } });
    try { await expect(publishBlueskyPodcastClip({ session: s.session, clip: clip("switch"), video: mp4(), text: "", assertCurrentAccount: () => { if (changed) throw new Error("Account changed"); } })).rejects.toThrow("Account changed"); expect(s.calls).toHaveLength(1); expect(s.videoCalls).toHaveLength(0); } finally { s.fetchSpy.mockRestore(); }
  });
  it("cancels an incomplete multipart reservation without a post", async () => {
    const controller = new AbortController();
    const s = setup({ onVideoRequest: method => { if (method === "app.bsky.video.uploadPart") controller.abort(); } });
    try {
      await expect(publishBlueskyPodcastClip({ session: s.session, clip: clip("upload-cancel"), video: mp4(), text: "", signal: controller.signal })).rejects.toThrow();
      expect(s.videoCalls.at(-1)?.method).toBe("app.bsky.video.abortUpload");
      expect(s.calls.some(x => x.method === "com.atproto.repo.createRecord")).toBe(false);
    } finally { s.fetchSpy.mockRestore(); }
  });
  it("retains an account-scoped processing job on cancellation and polls without reupload on retry", async () => {
    const controller = new AbortController(), s = setup({ processing: true });
    try {
      const args = { session: s.session, clip: clip("processing-retry"), video: mp4(), text: "hello" };
      await expect(publishBlueskyPodcastClip({ ...args, signal: controller.signal, onProgress: status => { if (status === "Processing Video") controller.abort(); } })).rejects.toThrow();
      expect((await publishBlueskyPodcastClip(args)).cid).toBe(cid);
      expect(s.videoCalls.filter(x => x.method === "app.bsky.video.startUpload")).toHaveLength(1);
      expect(s.videoCalls.filter(x => x.method === "app.bsky.video.getJobStatus")).toHaveLength(1);
      expect(new Headers(s.videoCalls.find(x => x.method === "app.bsky.video.getJobStatus")?.init?.headers).has("authorization")).toBe(false);
    } finally { s.fetchSpy.mockRestore(); }
  });
  it("adopts an accepted finish after finishing status without aborting or reuploading", async () => {
    const s = setup({ finishLost: true });
    try {
      expect((await publishBlueskyPodcastClip({ session: s.session, clip: clip("finish-lost"), video: mp4(), text: "hello" })).cid).toBe(cid);
      expect(s.videoCalls.filter(x => x.method === "app.bsky.video.startUpload")).toHaveLength(1);
      expect(s.videoCalls.filter(x => x.method === "app.bsky.video.uploadPart")).toHaveLength(1);
      expect(s.videoCalls.filter(x => x.method === "app.bsky.video.getUploadStatus")).toHaveLength(2);
      expect(s.videoCalls.some(x => x.method === "app.bsky.video.abortUpload")).toBe(false);
    } finally { s.fetchSpy.mockRestore(); }
  });
  it("uses distinct deterministic post keys for two accounts sharing a clip ID", async () => {
    const keys: unknown[] = [];
    for (const owner of ["did:plc:alice", "did:plc:bob"]) {
      const s = setup({ owner });
      try {
        await publishBlueskyPodcastClip({ session: s.session, clip: clip("shared-id"), video: mp4(), text: "hello" });
        const create = s.calls.find(x => x.method === "com.atproto.repo.createRecord")!;
        expect(create.body!.repo).toBe(owner); keys.push(create.body!.rkey);
      } finally { s.fetchSpy.mockRestore(); }
    }
    expect(keys[0]).not.toBe(keys[1]);
  });
  it("rechecks the active account immediately before creating a post", async () => {
    let changed = false; const s = setup();
    try {
      await expect(publishBlueskyPodcastClip({ session: s.session, clip: clip("final-switch"), video: mp4(), text: "hello", onProgress: status => { if (status === "Publishing Post") changed = true; }, assertCurrentAccount: () => { if (changed) throw new Error("Account changed"); } })).rejects.toThrow("Account changed");
      expect(s.calls.some(x => x.method === "com.atproto.repo.createRecord")).toBe(false);
    } finally { s.fetchSpy.mockRestore(); }
  });
  it("does not expose a link for a foreign or malformed record at the deterministic key", async () => {
    for (const invalid of ["foreign", "malformed"]) {
      const s = setup({ existingUri: invalid === "foreign" ? "at://did:plc:other/app.bsky.feed.post/foreign" : undefined });
      try {
        const args = { session: s.session, clip: clip(`invalid-${invalid}`), video: mp4(), text: "original" };
        await publishBlueskyPodcastClip(args);
        if (invalid === "malformed") s.getRecord()!.embed = { $type: "app.bsky.embed.video" };
        let failure: unknown;
        try { await publishBlueskyPodcastClip({ ...args, text: "changed" }); } catch (error) { failure = error; }
        expect(failure).toBeInstanceOf(Error);
        expect(failure).not.toBeInstanceOf(PodcastClipAlreadyPublishedError);
        expect(failure).not.toHaveProperty("uri");
      } finally { s.fetchSpy.mockRestore(); }
    }
  });
  it("honors preaborted requests without network", async () => {
    const s = setup(); try { await expect(publishBlueskyPodcastClip({ session: s.session, clip: clip("abort"), video: mp4(), text: "", signal: AbortSignal.abort() })).rejects.toThrow(); expect(s.calls).toHaveLength(0); expect(s.videoCalls).toHaveLength(0); } finally { s.fetchSpy.mockRestore(); }
  });
});
