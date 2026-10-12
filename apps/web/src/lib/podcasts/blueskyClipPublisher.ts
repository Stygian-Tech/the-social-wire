import { AppBskyEmbedVideo, AppBskyRichtextFacet, ComAtprotoRepoStrongRef, RichText, type AppBskyFeedPost, type AppBskyVideoDefs } from "@atproto/api";
import type { OAuthSession } from "@atproto/oauth-client-browser";
import { createOAuthAgent } from "@/lib/atprotoClient";
import { getAtprotoNetwork } from "@/lib/atprotoNetwork";
import { createAuthenticatedAppViewAgent } from "@/lib/blueskySocialClient";
import type { PodcastClip } from "./client";
import { PodcastClipAlreadyPublishedError } from "./podcastClipAlreadyPublishedError";
import { podcastClipPostRkey } from "./podcastClipPostRkey";
export { PodcastClipAlreadyPublishedError } from "./podcastClipAlreadyPublishedError";

export const BLUESKY_CLIP_MAX_BYTES = 300_000_000;
export const BLUESKY_CLIP_MAX_SECONDS = 600;
const VIDEO_ORIGIN = "https://video.bsky.app";
export type BlueskyPodcastClipPublishArgs = {
  session: OAuthSession;
  clip: PodcastClip;
  video: Blob;
  text: string;
  signal?: AbortSignal;
  assertCurrentAccount?: () => void;
  onProgress?: (status: string) => void;
};
type Upload = { jobId: string; partSizeBytes: number; partCount: number };
// Private, account-scoped processing IDs survive UI retries, never browser storage.
const pendingJobs = new Map<string, AppBskyVideoDefs.JobStatus>();
const pendingUploads = new Map<string, { upload: Upload; nextPart: number }>();
const activePublishes = new Set<string>();

function guard(args: BlueskyPodcastClipPublishArgs) {
  args.signal?.throwIfAborted();
  args.assertCurrentAccount?.();
}
function progress(args: BlueskyPodcastClipPublishArgs, status: string) { guard(args); args.onProgress?.(status); guard(args); }
async function pause(signal?: AbortSignal) {
  signal?.throwIfAborted();
  await new Promise<void>((resolve, reject) => {
    const abort = () => { clearTimeout(timer); reject(signal?.reason ?? new DOMException("Canceled", "AbortError")); };
    const timer = setTimeout(() => { signal?.removeEventListener("abort", abort); resolve(); }, 1000);
    signal?.addEventListener("abort", abort, { once: true });
  });
}

/** Read MP4 metadata in small slices, without copying a 300MB video into memory. */
export async function validateBlueskyClipVideo(video: Blob): Promise<void> {
  if (video.type !== "video/mp4" || video.size < 32 || video.size > BLUESKY_CLIP_MAX_BYTES) throw new Error("Choose an MP4 video of at most 300 MB.");
  const header = new Uint8Array(await video.slice(0, 12).arrayBuffer());
  if (new TextDecoder().decode(header.slice(4, 8)) !== "ftyp") throw new Error("The generated video is not a valid MP4.");
  async function findBox(start: number, end: number, wanted: string): Promise<{ start: number; end: number } | undefined> {
    for (let offset = start, count = 0; offset + 8 <= end && count < 10_000; count++) {
      const bytes = await video.slice(offset, offset + 16).arrayBuffer();
      const view = new DataView(bytes);
      const type = new TextDecoder().decode(new Uint8Array(bytes, 4, 4));
      const rawSize = view.getUint32(0);
      const size = rawSize === 1 ? Number(view.getBigUint64(8)) : rawSize === 0 ? end - offset : rawSize;
      const headerSize = rawSize === 1 ? 16 : 8;
      if (!Number.isSafeInteger(size) || size < headerSize || offset + size > end) throw new Error("The generated MP4 has invalid metadata.");
      if (type === wanted) return { start: offset + headerSize, end: offset + size };
      offset += size;
    }
  }
  const movie = await findBox(0, video.size, "moov");
  const timing = movie && await findBox(movie.start, movie.end, "mvhd");
  if (!timing || timing.end - timing.start < 20) throw new Error("The generated MP4 is missing duration metadata.");
  const view = new DataView(await video.slice(timing.start, Math.min(timing.end, timing.start + 32)).arrayBuffer());
  const version = view.getUint8(0);
  if (version > 1 || (version === 1 && view.byteLength < 32)) throw new Error("The generated MP4 has invalid duration metadata.");
  const scale = view.getUint32(version === 1 ? 20 : 12);
  const ticks = version === 1 ? Number(view.getBigUint64(24)) : view.getUint32(16);
  const seconds = ticks / scale;
  if (!scale || !Number.isFinite(seconds) || seconds <= 0 || seconds > BLUESKY_CLIP_MAX_SECONDS) throw new Error("Bluesky videos must be at most 10 minutes long.");
}

/** Official multipart flow: social-app/src/lib/media/video/multipart/{api,upload}.ts. */
export async function publishBlueskyPodcastClip(args: BlueskyPodcastClipPublishArgs): Promise<{ uri: string; cid: string }> {
  guard(args);
  const { session, clip, video, text } = args;
  const duration = clip.endSeconds - clip.startSeconds;
  const richText = new RichText({ text });
  if (!clip.id || clip.status !== "complete" || !Number.isFinite(duration) || clip.startSeconds < 0 || duration <= 0 || duration > BLUESKY_CLIP_MAX_SECONDS || !Number.isFinite(Date.parse(clip.createdAt))) throw new Error("Generate a ready clip of at most 10 minutes before publishing.");
  if (richText.graphemeLength > 300 || new TextEncoder().encode(text).length > 3000) throw new Error("Posts must contain at most 300 characters and 3,000 UTF-8 bytes.");
  await validateBlueskyClipVideo(video); guard(args);
  const network = getAtprotoNetwork();
  if (network.plcDirectory !== "https://plc.directory" || network.publicAppView !== "https://public.api.bsky.app" || network.appViewDid !== "did:web:api.bsky.app") throw new Error("Bluesky video publishing is unavailable in the isolated local sandbox.");
  const rkey = await podcastClipPostRkey(session.did, clip.id, clip.createdAt); guard(args);
  const key = `${session.did}/${rkey}`;
  if (activePublishes.has(key)) throw new Error("This clip is already being published.");
  activePublishes.add(key);
  const agent = createOAuthAgent(session);
  const alt = clip.title.slice(0, 1000);
  const uri = `at://${session.did}/app.bsky.feed.post/${rkey}`;
  async function existing(): Promise<{ uri: string; cid: string } | undefined> {
    guard(args);
    try {
      const { data } = await agent.com.atproto.repo.getRecord({ repo: session.did, collection: "app.bsky.feed.post", rkey }, { signal: args.signal }); guard(args);
      const record = data.value as AppBskyFeedPost.Record;
      const embed = record.embed;
      if (data.uri !== uri || !data.cid || !ComAtprotoRepoStrongRef.validateMain({ uri: data.uri, cid: data.cid }).success || record.$type !== "app.bsky.feed.post" || typeof record.text !== "string" || !Number.isFinite(Date.parse(record.createdAt)) || !AppBskyEmbedVideo.isMain(embed) || embed.alt !== alt || !embed.video || embed.video.mimeType !== "video/mp4" || !Number.isSafeInteger(embed.video.size) || embed.video.size <= 0 || embed.video.size > BLUESKY_CLIP_MAX_BYTES) throw new Error("The existing clip post could not be verified. Reload before trying again.");
      if (record.text !== text) throw new PodcastClipAlreadyPublishedError(data.uri, data.cid);
      return { uri: data.uri, cid: data.cid };
    } catch (error) {
      guard(args);
      if (error && typeof error === "object" && "error" in error && error.error === "RecordNotFound") return undefined;
      throw error;
    }
  }
  async function request<T>(method: string, token?: string, body?: BodyInit, params?: Record<string, string>, contentType = "application/json", signal = args.signal): Promise<T> {
    guard(args);
    const url = new URL(`/xrpc/${method}`, VIDEO_ORIGIN);
    for (const [k, v] of Object.entries(params ?? {})) url.searchParams.set(k, v);
    const response = await fetch(url, { method: body === undefined ? "GET" : "POST", headers: { ...(token ? { Authorization: `Bearer ${token}` } : {}), ...(body ? { "Content-Type": contentType } : {}) }, body, signal, credentials: "omit", redirect: "error" }); guard(args);
    if (!response.ok) throw new Error(`Bluesky video service failed (${response.status}). Please retry.`);
    const data = await response.json(); guard(args); return data as T;
  }
  let upload: Upload | undefined;
  let uploadToken: string | undefined;
  let finished = false;
  try {
    progress(args, "Checking Existing Post");
    const found = await existing();
    if (found) { progress(args, "Published"); return found; }
    await richText.detectFacets(createAuthenticatedAppViewAgent(session)); guard(args);
    const facets = richText.facets?.map(facet => ({ ...facet, features: facet.features.filter(feature => !AppBskyRichtextFacet.isMention(feature) || feature.did.startsWith("did:")) })).filter(facet => facet.features.length);
    let job = pendingJobs.get(key);
    if (!job) {
      const reservation = pendingUploads.get(key);
      if (!reservation) {
        progress(args, "Checking Upload Limits");
        const { data: limitsAuth } = await agent.com.atproto.server.getServiceAuth({ aud: "did:web:video.bsky.app", lxm: "app.bsky.video.getUploadLimits" }, { signal: args.signal }); guard(args);
        const limits = await request<{ canUpload: boolean; remainingDailyVideos?: number; remainingDailyBytes?: number }>("app.bsky.video.getUploadLimits", limitsAuth.token);
        if ([limits.remainingDailyVideos, limits.remainingDailyBytes].some(value => value !== undefined && (!Number.isSafeInteger(value) || value < 0)) || limits.canUpload !== true || (limits.remainingDailyVideos !== undefined && limits.remainingDailyVideos < 1) || (limits.remainingDailyBytes !== undefined && limits.remainingDailyBytes < video.size)) throw new Error("Your Bluesky video upload quota is unavailable or exhausted. Try again later.");
      }
      const info = await session.getTokenInfo(); guard(args);
      const pds = new URL(info.aud);
      if (pds.protocol !== "https:" || pds.username || pds.password) throw new Error("Your account has an invalid PDS endpoint.");
      const audience = `did:web:${pds.hostname}${pds.port ? `%3A${pds.port}` : ""}`;
      const { data: uploadAuth } = await agent.com.atproto.server.getServiceAuth({ aud: audience, lxm: "com.atproto.repo.uploadBlob", exp: Math.floor(Date.now() / 1000) + 1800 }, { signal: args.signal }); guard(args);
      uploadToken = uploadAuth.token;
      progress(args, "Uploading Video");
      upload = reservation?.upload ?? await request<Upload>("app.bsky.video.startUpload", uploadToken, JSON.stringify({ sizeBytes: video.size, mimeType: "video/mp4", name: `${rkey}.mp4` }));
      if (!upload.jobId || upload.partCount > 10_000 || !Number.isSafeInteger(upload.partSizeBytes) || upload.partSizeBytes <= 0 || upload.partSizeBytes > BLUESKY_CLIP_MAX_BYTES || upload.partCount !== Math.ceil(video.size / upload.partSizeBytes)) throw new Error("Bluesky returned an invalid video upload plan.");
      const state = reservation ?? { upload, nextPart: 1 };
      pendingUploads.set(key, state);
      for (let partNumber = state.nextPart; partNumber <= upload.partCount; partNumber++) {
        const start = (partNumber - 1) * upload.partSizeBytes;
        const chunk = video.slice(start, Math.min(video.size, start + upload.partSizeBytes));
        const receipt = await request<{ partNumber: number; sizeBytes: number }>("app.bsky.video.uploadPart", uploadToken, chunk, { jobId: upload.jobId, partNumber: String(partNumber) }, "application/octet-stream");
        if (receipt.partNumber !== partNumber || receipt.sizeBytes !== chunk.size) throw new Error("Bluesky returned an invalid video upload receipt.");
        state.nextPart = partNumber + 1;
      }
      // Finish stores this credential for the later PDS blob upload. Refresh it
      // after transferring parts so slow uploads do not leave an expired grant.
      const { data: finishAuth } = await agent.com.atproto.server.getServiceAuth({ aud: audience, lxm: "com.atproto.repo.uploadBlob", exp: Math.floor(Date.now() / 1000) + 1800 }, { signal: args.signal }); guard(args);
      uploadToken = finishAuth.token;
      for (let attempt = 0; attempt < 60; attempt++) {
        try {
          const result = await request<{ jobStatus: AppBskyVideoDefs.JobStatus }>("app.bsky.video.finishUpload", uploadToken, JSON.stringify({ jobId: upload.jobId }));
          job = result.jobStatus;
          break;
        } catch (error) {
          guard(args);
          const status = await request<{ state: string; jobStatus?: AppBskyVideoDefs.JobStatus }>("app.bsky.video.getUploadStatus", uploadToken, undefined, { jobId: upload.jobId });
          if (status.state === "completed" && status.jobStatus) { job = status.jobStatus; break; }
          if (["failed", "aborted", "expired"].includes(status.state)) { pendingUploads.delete(key); throw new Error("Bluesky could not finish this video upload. Please retry."); }
          if (status.state !== "finishing") throw error;
          await pause(args.signal); guard(args);
        }
      }
      if (!job) throw new Error("Video upload is still finishing. Retry to check the same upload.");
      if (job.did !== session.did || !job.jobId || typeof job.state !== "string") { pendingUploads.delete(key); throw new Error("Bluesky returned a video job for another account."); }
      pendingUploads.delete(key);
      finished = true;
      pendingJobs.set(key, job);
    }
    progress(args, "Processing Video");
    for (let attempt = 0; attempt < 900; attempt++) {
      guard(args);
      if (job.did !== session.did || !job.jobId) { pendingJobs.delete(key); throw new Error("Bluesky returned a video job for another account."); }
      if (job.state === "JOB_STATE_FAILED") { pendingJobs.delete(key); throw new Error("Bluesky could not process this video. Please regenerate the clip and retry."); }
      if (job.state === "JOB_STATE_COMPLETED") break;
      await pause(args.signal); guard(args);
      ({ jobStatus: job } = await request<{ jobStatus: AppBskyVideoDefs.JobStatus }>("app.bsky.video.getJobStatus", undefined, undefined, { jobId: job.jobId }));
      pendingJobs.set(key, job);
    }
    if (job.state !== "JOB_STATE_COMPLETED" || !job.blob || job.blob.mimeType !== "video/mp4" || !Number.isSafeInteger(job.blob.size) || job.blob.size <= 0 || job.blob.size > BLUESKY_CLIP_MAX_BYTES) throw new Error("Video processing is not ready yet. Retry to check the same job.");
    const record: AppBskyFeedPost.Record = { $type: "app.bsky.feed.post", text, createdAt: new Date().toISOString(), ...(facets?.length ? { facets } : {}), embed: { $type: "app.bsky.embed.video", video: job.blob, alt } };
    progress(args, "Publishing Post");
    try {
      const { data } = await agent.com.atproto.repo.createRecord({ repo: session.did, collection: "app.bsky.feed.post", rkey, record }, { signal: args.signal }); guard(args);
      if (data.uri !== uri || !data.cid) throw new Error("Bluesky returned an invalid post reference.");
      pendingJobs.delete(key); progress(args, "Published"); return { uri: data.uri, cid: data.cid };
    } catch (error) {
      guard(args);
      const recovered = await existing();
      if (recovered) { pendingJobs.delete(key); progress(args, "Published"); return recovered; }
      throw error;
    }
  } finally {
    activePublishes.delete(key);
    if (upload && uploadToken && !finished && (args.signal?.aborted || !pendingUploads.has(key))) {
      pendingUploads.delete(key);
      // Cancellation releases the reservation only if the same account is current.
      try {
        args.assertCurrentAccount?.();
        await fetch(`${VIDEO_ORIGIN}/xrpc/app.bsky.video.abortUpload`, { method: "POST", headers: { Authorization: `Bearer ${uploadToken}`, "Content-Type": "application/json" }, body: JSON.stringify({ jobId: upload.jobId }), credentials: "omit", redirect: "error", signal: AbortSignal.timeout(5000) });
      } catch { /* The service expires reservations if cleanup is unavailable. */ }
    }
  }
}
