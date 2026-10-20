import type { AppBskyDraftDefs } from "@atproto/api";
import type { ThreadSegment } from "./blueskyThreadClient";
import { gifEmbedURI, klipyMediaURL, type ComposerPhoto } from "./composerMedia";

const DEVICE_KEY = "the-social-wire.social-draft-device.v1";

/** Refuse cloud creation if a stable device identity cannot be persisted. */
export function socialDraftDeviceId(): string {
  const stored = localStorage.getItem(DEVICE_KEY);
  if (stored && /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(stored)) return stored;
  const id = crypto.randomUUID();
  localStorage.setItem(DEVICE_KEY, id);
  return id;
}

/** Canonical comparison includes unknown native fields, independent of key order. */
export function socialDraftFingerprint(value: unknown): string {
  if (Array.isArray(value)) return `[${value.map(socialDraftFingerprint).join(",")}]`;
  if (value && typeof value === "object") return `{${Object.entries(value).filter(([, item]) => item !== undefined).sort(([a], [b]) => a.localeCompare(b)).map(([key, item]) => `${JSON.stringify(key)}:${socialDraftFingerprint(item)}`).join(",")}}`;
  return JSON.stringify(value) ?? "null";
}

function restoreGif(uri: string): ThreadSegment["media"] | undefined {
  try {
    const url = klipyMediaURL(uri);
    const width = Number(url.searchParams.get("ww"));
    const height = Number(url.searchParams.get("hh"));
    const rendition = (format: "mp4" | "webm") => {
      const name = url.searchParams.get(format);
      if (!name || !/^[A-Za-z0-9_-]+$/.test(name)) return undefined;
      return new URL(`${name}.${format}`, url).href.split("?")[0];
    };
    const asset = { id: uri, title: "GIF", description: "", attribution: "KLIPY", url: uri.split("?")[0], poster: uri.split("?")[0], width, height, mp4: rendition("mp4"), webm: rendition("webm") };
    if (gifEmbedURI(asset) !== uri) return;
    return { kind: "gif", asset, alt: "" };
  } catch { return; }
}

/** Files are never downloaded or uploaded here. Only matching local recovery owns bytes. */
export function socialDraftToSegments(draft: AppBskyDraftDefs.Draft, localSegments?: ThreadSegment[]): ThreadSegment[] {
  const photosByPath = new Map<string, ComposerPhoto | null>();
  for (const segment of localSegments ?? []) {
    if (segment.media?.kind !== "photos") continue;
    for (const photo of segment.media.photos) {
      if (!(photo.original instanceof Blob)) continue;
      const references = segment.nativeDraftPost?.embedImages?.filter(image => image.localRef.path.endsWith(`/${encodeURIComponent(photo.id)}`));
      const paths = references?.length ? references.map(image => image.localRef.path) : draft.deviceId ? [`socialwire://${draft.deviceId}/${encodeURIComponent(photo.id)}`] : [];
      for (const path of paths) {
        const previous = photosByPath.get(path);
        // Ambiguous recovery must never choose arbitrary local bytes.
        photosByPath.set(path, previous === undefined || previous === photo ? photo : null);
      }
    }
  }
  return draft.posts.map((post, index) => {
    const local = localSegments?.[index];
    const images = post.embedImages ?? [];
    const paths = images.map(image => image.localRef.path);
    const unavailableImages = images.length > 4 || new Set(paths).size !== paths.length || images.some(image => !photosByPath.get(image.localRef.path));
    const mixedMedia = !!images.length && !!post.embedExternals?.length;
    let media: ThreadSegment["media"];
    if (images.length && !unavailableImages && !mixedMedia) {
      media = { kind: "photos", photos: images.map(image => ({ ...photosByPath.get(image.localRef.path)!, alt: image.alt ?? "" })) };
    } else if (!images.length && post.embedExternals?.length === 1) {
      const uri = post.embedExternals[0].uri;
      const localGif = localSegments?.find(segment => {
        if (segment.media?.kind !== "gif") return false;
        try { return gifEmbedURI(segment.media.asset) === uri; } catch { return false; }
      })?.media;
      media = localGif ?? restoreGif(uri);
    }
    // The current composer has no video editor; preserve all video/gallery data.
    const unavailableVideos = !!post.embedVideos?.length || !!(post as AppBskyDraftDefs.DraftPost & { embedGallery?: unknown }).embedGallery;
    const unavailableExternal = (post.embedExternals?.length ?? 0) > 1 || !!post.embedExternals?.some(external => {
      try { const url = new URL(external.uri); return url.protocol !== "https:" || !!url.username || !!url.password || (url.host === "static.klipy.com" && media?.kind !== "gif"); }
      catch { return true; }
    });
    const external = post.embedExternals?.[0];
    const linkPreview = external && !unavailableExternal && !media ? { uri: external.uri, title: new URL(external.uri).hostname, description: "" } : undefined;
    return { ...local, id: local?.id ?? crypto.randomUUID(), text: post.text, media, linkPreview, nativeDraftPost: structuredClone(post), unavailableDraftMedia: unavailableImages || unavailableVideos || unavailableExternal || mixedMedia };
  });
}

/** Explicit UI removal is the only path that discards inaccessible native media. */
export function removeUnavailableDraftMedia(segment: ThreadSegment): ThreadSegment {
  if (!segment.unavailableDraftMedia) return segment;
  const post = { ...segment.nativeDraftPost, text: segment.text };
  delete post.embedImages;
  delete post.embedVideos;
  delete post.embedExternals;
  delete (post as AppBskyDraftDefs.DraftPost & { embedGallery?: unknown }).embedGallery;
  return { ...segment, nativeDraftPost: post, unavailableDraftMedia: false, media: undefined, linkPreview: undefined };
}

export function segmentsToSocialDraft(segments: ThreadSegment[], deviceId: string, original?: AppBskyDraftDefs.Draft): AppBskyDraftDefs.Draft {
  if (!segments.length || segments.length > 100) throw new Error("Drafts Must Contain Between 1 And 100 Posts.");
  const counter = new Intl.Segmenter(undefined, { granularity: "grapheme" });
  const posts = segments.map(segment => {
    if (Array.from(counter.segment(segment.text)).length > 1000 || new TextEncoder().encode(segment.text).length > 10_000) throw new Error("Draft Text Exceeds 1,000 Characters Or 10,000 Bytes.");
    const post: AppBskyDraftDefs.DraftPost = { ...structuredClone(segment.nativeDraftPost ?? {}), text: segment.text };
    // An available attachment disappearing from the editor is deliberate removal.
    // Inaccessible native attachments survive until the explicit removal helper.
    if (!segment.media && !segment.unavailableDraftMedia) {
      delete post.embedImages;
      if (post.embedExternals?.length === 1 && restoreGif(post.embedExternals[0].uri)) delete post.embedExternals;
    }
    if (segment.media?.kind === "photos" && !segment.unavailableDraftMedia) post.embedImages = segment.media.photos.map(photo => {
      const originalImage = post.embedImages?.find(image => image.localRef.path.endsWith(`/${encodeURIComponent(photo.id)}`));
      return { ...originalImage, localRef: originalImage?.localRef ?? { path: `socialwire://${deviceId}/${encodeURIComponent(photo.id)}` }, ...(originalImage && originalImage.alt === undefined && photo.alt === "" ? {} : { alt: photo.alt }) };
    });
    if (segment.media?.kind === "gif") {
      const uri = gifEmbedURI(segment.media.asset);
      post.embedExternals = [{ ...post.embedExternals?.find(external => external.uri === uri), uri }];
    }
    if (segment.quoteTo && !post.embedRecords?.length) post.embedRecords = [{ record: { uri: segment.quoteTo.uri, cid: segment.quoteTo.cid } }];
    if (segment.linkPreview && !post.embedExternals?.length && segment.removedLinkUrl !== segment.linkPreview.uri) post.embedExternals = [{ uri: segment.linkPreview.uri }];
    return post;
  });
  return { ...structuredClone(original ?? {}), deviceId: original?.deviceId ?? deviceId, posts };
}

export function socialDraftHasContent(segments: ThreadSegment[]): boolean {
  return segments.some(segment => !!segment.text.trim() || !!segment.media || !!segment.nativeDraftPost?.embedImages?.length || !!segment.nativeDraftPost?.embedVideos?.length || !!segment.nativeDraftPost?.embedExternals?.length || !!segment.nativeDraftPost?.embedRecords?.length);
}
