import { BlobRef, jsonStringToLex, RichText, type AppBskyEmbedExternal, type AppBskyEmbedImages, type AppBskyEmbedVideo } from "@atproto/api";
import type { OAuthSession } from "@atproto/oauth-client-browser";
import { getAtprotoNetwork } from "@/lib/atprotoNetwork";
import { createOAuthAgent } from "@/lib/atprotoClient";
import { composeExternalEmbed, composeLinkUrl, publicLinkUrl, type ComposeLinkPreview } from "@/lib/blueskyExternalEmbed";
import { validateBlueskyClipVideo } from "@/lib/podcasts/blueskyClipPublisher";
import type { ArticleBlob } from "@/lib/articles/articlePublishingTypes";

export type LiveUpdateAttachmentsDraft = {
  images?: { file: Blob; alt: string }[];
  video?: { file: Blob; alt: string };
  gif?: { url: string; alt: string };
  linkPreview?: ComposeLinkPreview;
};
export type LiveUpdateAttachments = LiveUpdateAttachmentsDraft;
export type LivePostDraft = LiveUpdateAttachmentsDraft & { text: string };
export type PreparedLivePostMedia = {
  pdsUrl?: string;
  images?: { blob: ArticleBlob; alt: string; aspectRatio?: { width: number; height: number } }[];
  video?: { blob: ArticleBlob; alt: string };
  gif?: { url: string; alt: string };
  external?: AppBskyEmbedExternal.Main & { $type: "app.bsky.embed.external" };
};
export const LIVE_POST_IMAGE_MAX_BYTES = 2_000_000;
export const LIVE_POST_VIDEO_MAX_BYTES = 100_000_000;

export function validateLiveUpdateAttachments(draft: LiveUpdateAttachmentsDraft): void {
  if ((draft.images?.length ?? 0) > 4) throw new Error("Choose at most four images.");
  if (Number(!!draft.images?.length) + Number(!!draft.video) + Number(!!draft.gif) > 1) throw new Error("Choose images, a video, or a GIF for each update.");
  for (const image of draft.images ?? []) {
    if (!["image/jpeg", "image/png", "image/webp"].includes(image.file.type) || image.file.size <= 0 || image.file.size > LIVE_POST_IMAGE_MAX_BYTES) throw new Error("Choose JPEG, PNG, or WebP images of at most 2 MB each.");
    if (typeof image.alt !== "string" || new TextEncoder().encode(image.alt).length > 10000) throw new Error("Image alt text must contain at most 10,000 UTF-8 bytes.");
  }
  if (draft.video) {
    if (draft.video.file.type !== "video/mp4" || draft.video.file.size < 32 || draft.video.file.size > LIVE_POST_VIDEO_MAX_BYTES) throw new Error("Choose an MP4 video of at most 100 MB.");
    if (typeof draft.video.alt !== "string" || new RichText({ text: draft.video.alt }).graphemeLength > 1000 || new TextEncoder().encode(draft.video.alt).length > 10000) throw new Error("Video alt text must contain at most 1,000 characters and 10,000 UTF-8 bytes.");
  }
  if (draft.gif) {
    const url = publicLinkUrl(draft.gif.url);
    if (!url || !url.startsWith("https:") || !new URL(url).pathname.toLowerCase().endsWith(".gif")) throw new Error("Choose a direct HTTPS GIF URL ending in .gif.");
    if (typeof draft.gif.alt !== "string" || new TextEncoder().encode(draft.gif.alt).length > 10000) throw new Error("GIF alt text must contain at most 10,000 UTF-8 bytes.");
  }
  if (draft.linkPreview && !publicLinkUrl(draft.linkPreview.uri)) throw new Error("Choose an HTTP or HTTPS link.");
}
export function validateLivePostDraft(draft: LivePostDraft): void {
  validateLiveUpdateAttachments(draft);
  if (draft.linkPreview && draft.linkPreview.uri !== composeLinkUrl(draft.text)) throw new Error("The link preview no longer matches the update's first link. Refresh the preview or remove it.");
}

async function digest(bytes: ArrayBuffer): Promise<string> {
  return Array.from(new Uint8Array(await crypto.subtle.digest("SHA-256", bytes)), byte => byte.toString(16).padStart(2, "0")).join("");
}
export async function livePostAttachmentsFingerprint(draft?: LiveUpdateAttachmentsDraft): Promise<string | undefined> {
  if (!draft || (!draft.images?.length && !draft.video && !draft.gif && !draft.linkPreview)) return undefined;
  validateLiveUpdateAttachments(draft);
  const media = async ({ file, alt }: { file: Blob; alt: string }) => ({ type: file.type, size: file.size, alt, digest: await digest(await file.arrayBuffer()) });
  const value = { images: await Promise.all((draft.images ?? []).map(media)), video: draft.video ? await media(draft.video) : null, gif: draft.gif ? { url: draft.gif.url, alt: draft.gif.alt } : null, linkPreview: draft.linkPreview ? { uri: draft.linkPreview.uri, title: draft.linkPreview.title, description: draft.linkPreview.description, image: draft.linkPreview.image ?? null } : null };
  return digest(new TextEncoder().encode(JSON.stringify(value)).buffer);
}
export async function livePostDraftFingerprint(draft: LivePostDraft): Promise<string> {
  return digest(new TextEncoder().encode(JSON.stringify({ text: draft.text, media: await livePostAttachmentsFingerprint(draft) })).buffer);
}

type PrepareArgs = { session: OAuthSession; draft: LivePostDraft; signal?: AbortSignal; assertCurrentAccount?: () => void };
type VideoJob = { jobId: string; did: string; state: string; blob?: unknown; error?: string };
const videoJobs = new WeakMap<Blob, Map<string, VideoJob>>();
function guard(args: PrepareArgs) { args.signal?.throwIfAborted(); args.assertCurrentAccount?.(); }
function asBlobRef(blob: ArticleBlob) {
  const value = jsonStringToLex(JSON.stringify(blob));
  if (!(value instanceof BlobRef)) throw new Error("The uploaded media blob reference is invalid.");
  return value;
}
function serializableBlob(blob: unknown, mimeType?: string): ArticleBlob {
  const value = JSON.parse(JSON.stringify(blob)) as ArticleBlob;
  if (value?.$type !== "blob" || typeof value.ref?.$link !== "string" || !value.ref.$link || typeof value.mimeType !== "string" || (mimeType && value.mimeType !== mimeType) || !Number.isSafeInteger(value.size) || value.size <= 0) throw new Error("The upload returned an invalid media blob.");
  return value;
}
async function pause(signal?: AbortSignal) {
  signal?.throwIfAborted();
  await new Promise<void>((resolve, reject) => {
    const abort = () => { clearTimeout(timer); reject(signal?.reason ?? new DOMException("Canceled", "AbortError")); };
    const timer = setTimeout(() => { signal?.removeEventListener("abort", abort); resolve(); }, 1000);
    signal?.addEventListener("abort", abort, { once: true });
  });
}
async function prepareVideo(args: PrepareArgs, file: Blob): Promise<ArticleBlob> {
  const network = getAtprotoNetwork();
  if (network.plcDirectory !== "https://plc.directory" || network.publicAppView !== "https://public.api.bsky.app" || network.appViewDid !== "did:web:api.bsky.app") throw new Error("Bluesky video publishing is unavailable in the isolated local sandbox.");
  await validateBlueskyClipVideo(file); guard(args);
  const jobs = videoJobs.get(file) ?? new Map<string, VideoJob>(); videoJobs.set(file, jobs);
  let job = jobs.get(args.session.did);
  if (!job) {
    const agent = createOAuthAgent(args.session);
    const { data: limitsAuth } = await agent.com.atproto.server.getServiceAuth({ aud: "did:web:video.bsky.app", lxm: "app.bsky.video.getUploadLimits" }, { signal: args.signal }); guard(args);
    const limitsResponse = await fetch("https://video.bsky.app/xrpc/app.bsky.video.getUploadLimits", { headers: { Authorization: `Bearer ${limitsAuth.token}` }, signal: args.signal, credentials: "omit", redirect: "error" }); guard(args);
    if (!limitsResponse.ok) throw new Error("Bluesky video upload limits could not be checked.");
    const limits = await limitsResponse.json() as { canUpload: boolean; remainingDailyVideos?: number; remainingDailyBytes?: number }; guard(args);
    if (limits.canUpload !== true || [limits.remainingDailyVideos, limits.remainingDailyBytes].some(value => value !== undefined && (!Number.isSafeInteger(value) || value < 0)) || (limits.remainingDailyVideos !== undefined && limits.remainingDailyVideos < 1) || (limits.remainingDailyBytes !== undefined && limits.remainingDailyBytes < file.size)) throw new Error("Your Bluesky video upload quota is unavailable or exhausted. Try again later.");
    const info = await args.session.getTokenInfo(); guard(args);
    const pds = new URL(info.aud);
    if (pds.protocol !== "https:" || pds.username || pds.password) throw new Error("Your account has an invalid PDS endpoint.");
    const { data } = await agent.com.atproto.server.getServiceAuth({ aud: `did:web:${pds.hostname}${pds.port ? `%3A${pds.port}` : ""}`, lxm: "com.atproto.repo.uploadBlob", exp: Math.floor(Date.now() / 1000) + 1800 }, { signal: args.signal }); guard(args);
    const url = new URL("https://video.bsky.app/xrpc/app.bsky.video.uploadVideo");
    url.search = new URLSearchParams({ did: args.session.did, name: "live-update.mp4" }).toString();
    const response = await fetch(url, { method: "POST", headers: { Authorization: `Bearer ${data.token}`, "Content-Type": "video/mp4" }, body: file, signal: args.signal, credentials: "omit", redirect: "error" }); guard(args);
    const result = await response.json() as VideoJob & { jobStatus?: VideoJob }; guard(args);
    job = result.jobStatus ?? result;
    // Already-processed videos may return an error status with a usable blob.
    if (!response.ok && !job.blob) throw new Error(`Bluesky video upload failed (${response.status}).`);
    if (job.did !== args.session.did || !job.jobId) throw new Error("The video service returned an invalid processing job.");
    jobs.set(args.session.did, job);
  }
  for (let attempt = 0; attempt < 120; attempt++) {
    guard(args);
    if (job.did !== args.session.did || !job.jobId) throw new Error("The video service returned a job for another account.");
    if (job.blob) {
      const blob = serializableBlob(job.blob, "video/mp4");
      if (blob.size > LIVE_POST_VIDEO_MAX_BYTES) throw new Error("The processed video exceeds 100 MB.");
      return blob;
    }
    if (job.state === "JOB_STATE_FAILED") { jobs.delete(args.session.did); throw new Error("Bluesky could not process this video. Choose another video and retry."); }
    await pause(args.signal); guard(args);
    const url = new URL("https://video.bsky.app/xrpc/app.bsky.video.getJobStatus"); url.searchParams.set("jobId", job.jobId);
    const response = await fetch(url, { signal: args.signal, credentials: "omit", redirect: "error" }); guard(args);
    if (!response.ok) throw new Error(`Bluesky video processing failed (${response.status}). Retry to check the same job.`);
    const result = await response.json() as { jobStatus: VideoJob }; guard(args);
    job = result.jobStatus;
    if (!job || job.did !== args.session.did || job.jobId !== jobs.get(args.session.did)?.jobId) throw new Error("The video service returned an invalid processing job.");
    jobs.set(args.session.did, job);
  }
  throw new Error("Video processing is still in progress. Retry to check the same job.");
}

/** Upload once before constructing either destination; preserve returned refs for retries. */
export async function prepareLivePostMedia(args: PrepareArgs): Promise<PreparedLivePostMedia | undefined> {
  validateLivePostDraft(args.draft); guard(args);
  const media: PreparedLivePostMedia = {};
  if (args.draft.images?.length || args.draft.video) {
    const info = await args.session.getTokenInfo(); guard(args);
    const pds = new URL(info.aud);
    if (pds.protocol !== "https:" || pds.username || pds.password || pds.search || pds.hash) throw new Error("Your account has an invalid PDS endpoint.");
    media.pdsUrl = pds.origin;
  }
  for (const image of args.draft.images ?? []) {
    guard(args);
    const bitmap = await createImageBitmap(image.file);
    let aspectRatio: { width: number; height: number };
    try {
      guard(args);
      if (!bitmap.width || !bitmap.height) throw new Error("The selected image has invalid dimensions.");
      aspectRatio = { width: bitmap.width, height: bitmap.height };
    } finally { bitmap.close(); }
    const { data } = await createOAuthAgent(args.session).uploadBlob(image.file, { encoding: image.file.type }); guard(args);
    const blob = serializableBlob(data.blob, image.file.type);
    if (blob.size !== image.file.size) throw new Error("The image upload size does not match the selected file.");
    (media.images ??= []).push({ blob, alt: image.alt, aspectRatio });
  }
  if (args.draft.video) media.video = { blob: await prepareVideo(args, args.draft.video.file), alt: args.draft.video.alt };
  if (args.draft.gif) media.gif = { ...args.draft.gif, url: new URL(args.draft.gif.url).href };
  if (args.draft.linkPreview) {
    media.external = await composeExternalEmbed(args.session, args.draft.text, args.draft.linkPreview, args.assertCurrentAccount); guard(args);
    if (!media.external) throw new Error("The link preview no longer matches the update's first link. Refresh the preview or remove it.");
  }
  return Object.keys(media).length ? media : undefined;
}
export function livePostMediaEmbed(media?: PreparedLivePostMedia): (AppBskyEmbedImages.Main & { $type: "app.bsky.embed.images" }) | (AppBskyEmbedVideo.Main & { $type: "app.bsky.embed.video" }) | (AppBskyEmbedExternal.Main & { $type: "app.bsky.embed.external" }) | undefined {
  if (media?.images?.length) return { $type: "app.bsky.embed.images", images: media.images.map(image => ({ image: asBlobRef(image.blob), alt: image.alt, ...(image.aspectRatio ? { aspectRatio: image.aspectRatio } : {}) })) };
  if (media?.video) return { $type: "app.bsky.embed.video", video: asBlobRef(media.video.blob), alt: media.video.alt };
  if (media?.gif) return { $type: "app.bsky.embed.external", external: { uri: media.gif.url, title: media.gif.alt || "GIF", description: media.gif.alt } };
  return media?.external;
}
