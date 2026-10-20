import type { AppBskyDraftDefs } from "@atproto/api";
import type { ThreadSegment } from "./blueskyThreadClient";
import { gifEmbedURI, klipyMediaURL, type ComposerPhoto } from "./composerMedia";

import { assertDraftAttachmentActor, describeDraftAttachment, downloadDraftAttachment, uploadDraftAttachment, type DraftAttachmentActor, type DraftAttachmentManifest, type DraftAttachmentRef } from "./socialDraftAttachmentClient";

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

/** Pure conversion matches exact references; authenticated byte recovery is separate. */
export function socialDraftToSegments(draft: AppBskyDraftDefs.Draft, localSegments?: ThreadSegment[]): ThreadSegment[] {
  const photosByPath = new Map<string, ComposerPhoto | null>();
  for (const segment of localSegments ?? []) {
    if (segment.media?.kind !== "photos") continue;
    for (const photo of segment.media.photos) {
      if (!(photo.original instanceof Blob)) continue;
      if (photo.privateAttachment) {
        const path = privatePhotoPath(photo);
        const previous = photosByPath.get(path);
        photosByPath.set(path, previous === undefined || previous === photo ? photo : null);
        continue;
      }
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
      const originalImage = post.embedImages?.find(image => (photo.privateAttachment ? (image.localRef.path === privatePhotoPath(photo) || image.localRef.path.startsWith(`socialwire-private://v1/photo/${photo.privateAttachment.original.assetId}/`)) : image.localRef.path.endsWith(`/${encodeURIComponent(photo.id)}`)));
      return { ...originalImage, localRef: photo.privateAttachment ? { ...originalImage?.localRef, path: privatePhotoPath(photo) } : originalImage?.localRef ?? { path: `socialwire://${deviceId}/${encodeURIComponent(photo.id)}` }, ...(originalImage && originalImage.alt === undefined && photo.alt === "" ? {} : { alt: photo.alt }) };
    });
    if (segment.media?.kind === "gif") {
      const uri = gifEmbedURI(segment.media.asset);
      post.embedExternals = [{ ...post.embedExternals?.find(external => external.uri === uri), uri }];
    }
    if (segment.quoteTo && !post.embedRecords?.length) post.embedRecords = [{ record: { uri: segment.quoteTo.uri, cid: segment.quoteTo.cid } }];
    if (segment.removedLinkUrl && post.embedExternals) {
      post.embedExternals = post.embedExternals.filter(external => external.uri !== segment.removedLinkUrl);
      if (!post.embedExternals.length) delete post.embedExternals;
    }
    if (segment.linkPreview && !post.embedExternals?.length && segment.removedLinkUrl !== segment.linkPreview.uri) post.embedExternals = [{ uri: segment.linkPreview.uri }];
    return post;
  });
  return { ...structuredClone(original ?? {}), deviceId: original?.deviceId ?? deviceId, posts };
}

export function socialDraftHasContent(segments: ThreadSegment[]): boolean {
  return segments.some(segment => !!segment.text.trim() || !!segment.media || !!segment.nativeDraftPost?.embedImages?.length || !!segment.nativeDraftPost?.embedVideos?.length || !!segment.nativeDraftPost?.embedExternals?.length || !!segment.nativeDraftPost?.embedRecords?.length);
}


export function privatePhotoPath(photo: ComposerPhoto): string {
  if (!photo.privateAttachment) throw new Error("Private Photo Has Not Been Checkpointed.");
  return `socialwire-private://v1/photo/${photo.privateAttachment.original.assetId}/${photo.privateAttachment.prepared.assetId}`;
}
const privatePhotoPattern = /^socialwire-private:\/\/v1\/photo\/([0-9a-f-]{36})\/([0-9a-f-]{36})$/i;
export function hasPrivateDraftPhotos(draft?: AppBskyDraftDefs.Draft): boolean {
  return !!draft?.posts.some(post => post.embedImages?.some(image => image.localRef.path.startsWith("socialwire-private:")));
}
export function privateDraftPhotoRefs(draft: AppBskyDraftDefs.Draft): DraftAttachmentRef[] {
  const refs = new Map<string, DraftAttachmentRef>();
  for (const post of draft.posts) for (const image of post.embedImages ?? []) {
    const path = image.localRef.path;
    if (!path.startsWith("socialwire-private:")) continue;
    const match = privatePhotoPattern.exec(path);
    if (!match) throw new Error("Invalid Private Photo Reference. Reattach The Photo.");
    for (const [assetId, role] of [[match[1], "original"], [match[2], "prepared"]] as const) {
      const ref = { assetId, role, ref: path };
      refs.set(`${path}:${role}`, ref);
    }
  }
  return [...refs.values()];
}

/** The callback must durably save IDs and both files before any request is sent. */
export async function preparePrivateDraftPhotos(actor: DraftAttachmentActor, segments: ThreadSegment[], checkpoint: (prepared: ThreadSegment[]) => Promise<void>): Promise<void> {
  let prepared = segments;
  for (const segment of segments) {
    if (segment.media?.kind !== "photos") continue;
    for (const photo of segment.media.photos) {
      assertDraftAttachmentActor(actor);
      if (photo.status !== "ready" || !photo.blob || !photo.width || !photo.height) throw new Error("Photo Preparation Is Incomplete. Retry Or Reattach The Photo Before Saving.");
      const previous = photo.privateAttachment?.ownerDid === actor.viewerDid ? photo.privateAttachment : undefined;
      const original = await describeDraftAttachment(photo.original, photo.name, previous?.original);
      const output = await describeDraftAttachment(photo.blob, photo.name, previous?.prepared);
      assertDraftAttachmentActor(actor);
      const replace = (value: ComposerPhoto) => { prepared = prepared.map(item => item.media?.kind === "photos" ? { ...item, media: { ...item.media, photos: item.media.photos.map(candidate => candidate.id === photo.id && candidate.original === photo.original && candidate.blob === photo.blob ? value : candidate) } } : item); };
      let portable = { ...photo, privateAttachment: { ownerDid: actor.viewerDid, original, prepared: output } };
      replace(portable);
      await checkpoint(prepared);
      assertDraftAttachmentActor(actor);
      const originalReady = await uploadDraftAttachment(actor, original, photo.original);
      const preparedReady = await uploadDraftAttachment(actor, output, photo.blob);
      portable = { ...portable, privateAttachment: { ownerDid: actor.viewerDid, original: originalReady, prepared: preparedReady } };
      replace(portable);
      await checkpoint(prepared);
    }
  }
}

/** Download only exact manifest matches, never fetch native paths or PDS blobs. */
export async function restorePrivateDraftPhotos(actor: DraftAttachmentActor, draft: AppBskyDraftDefs.Draft, manifest: DraftAttachmentManifest, local?: ThreadSegment[]): Promise<ThreadSegment[]> {
  const recovered: ThreadSegment[] = [];
  if (manifest.deleted) throw new Error("Private Draft Attachments Were Deleted. Reattach The Photos.");
  const paths = new Set(draft.posts.flatMap(post => (post.embedImages ?? []).map(image => image.localRef.path)).filter(path => path.startsWith("socialwire-private:")));
  const downloadedPaths = new Set<string>();
  for (const path of paths) {
    // Local unsynced edits and their bytes remain authoritative during recovery.
    const available = local?.flatMap(segment => segment.media?.kind === "photos" ? segment.media.photos : []).filter(photo => photo.privateAttachment?.ownerDid === actor.viewerDid && privatePhotoPath(photo) === path && photo.original instanceof Blob && photo.blob instanceof Blob && photo.status === "ready");
    if (available?.length === 1) continue;
    const match = privatePhotoPattern.exec(path);
    if (!match) throw new Error("Invalid Private Photo Reference. Reattach The Photo.");
    const original = manifest.attachments.find(item => item.assetId === match[1] && item.ref === path && item.role === "original")?.asset;
    const prepared = manifest.attachments.find(item => item.assetId === match[2] && item.ref === path && item.role === "prepared")?.asset;
    if (!original || !prepared || original.kind !== "photo" || prepared.kind !== "photo" || !original.contentType.startsWith("image/") || !prepared.contentType.startsWith("image/")) throw new Error("Private Draft Photo Is Missing. Retry Or Reattach It On The Original Device.");
    const originalBlob = await downloadDraftAttachment(actor, original);
    const blob = await downloadDraftAttachment(actor, prepared);
    assertDraftAttachmentActor(actor);
    const bitmap = await createImageBitmap(blob, { imageOrientation: "from-image" });
    const { width, height } = bitmap;
    bitmap.close();
    if (!width || !height || width > 20000 || height > 20000) throw new Error("Private Draft Photo Dimensions Are Invalid. Reattach The Photo.");
    assertDraftAttachmentActor(actor);
    const photo: ComposerPhoto = { id: prepared.assetId, name: original.name, original: originalBlob, blob, width, height, alt: "", status: "ready", privateAttachment: { ownerDid: actor.viewerDid, original, prepared } };
    downloadedPaths.add(path);
    recovered.push({ id: crypto.randomUUID(), text: "", media: { kind: "photos", photos: [photo] } });
  }
  // Recovered paths supersede local copies; retain unrelated device-bound bytes.
  const remaining = local?.map(segment => segment.media?.kind === "photos" ? { ...segment, media: { ...segment.media, photos: segment.media.photos.filter(photo => !photo.privateAttachment || !downloadedPaths.has(privatePhotoPath(photo))) } } : segment);
  return socialDraftToSegments(draft, [...(remaining ?? []), ...recovered]);
}
