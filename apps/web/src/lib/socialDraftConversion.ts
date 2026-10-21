import type { AppBskyDraftDefs } from "@atproto/api";
import type { ThreadSegment } from "./blueskyThreadClient";
import { gifEmbedURI, klipyMediaURL, type ComposerPhoto, type ComposerMedia, type ComposerGif, type GifAsset, isGifCatalogId, gifRenditions } from "./composerMedia";

import { assertDraftAttachmentActor, describeDraftAttachment, downloadDraftAttachment, uploadDraftAttachment, draftAttachmentSHA256, isRetiredDraftAttachment, type DraftAttachmentActor, type DraftAttachmentManifest, type DraftAttachmentRef } from "./socialDraftAttachmentClient";

import { getGifFile, validateGifFile } from "./klipyClient";

const GIF_METADATA = "app.thesocialwire.socialDraft.gif";
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
    return { kind: "gif", asset, alt: "", unavailable: true };
  } catch { return; }
}

function matchingGif(media: ComposerMedia | undefined, uri: string): boolean {
  if (media?.kind !== "gif") return false;
  try { return gifEmbedURI(media.asset) === uri; } catch { return false; }
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
      const native = nativeGifMetadata(post.embedExternals[0]) ?? restoreGif(uri);
      const candidates = (localSegments ?? []).filter(segment => matchingGif(segment.media, uri));
      // Only a matching post baseline can carry unsynced author metadata. A URI
      // identifies shared bytes, not the particular post or its description.
      const exact = candidates.filter(segment => segment.nativeDraftPost && socialDraftFingerprint(segment.nativeDraftPost) === socialDraftFingerprint(post));
      const exactPost = local && exact.includes(local) ? local : exact.length === 1 ? exact[0] : undefined;
      const positional = local && !local.nativeDraftPost && local.text === post.text && matchingGif(local.media, uri) && (native?.kind !== "gif" || !isGifCatalogId(native.asset.id) || local.media?.kind === "gif" && local.media.alt === native.alt) ? local : undefined;
      const own = (exactPost ?? positional)?.media;
      const metadata = own?.kind === "gif" ? own : native;
      if (metadata?.kind === "gif") {
        const donor = [own, ...candidates.map(segment => segment.media)].find(candidate => candidate?.kind === "gif" && candidate.privateFiles?.identity === uri && (!isGifCatalogId(metadata.asset.id) || candidate.asset.id === metadata.asset.id));
        if (donor?.kind === "gif" && donor.privateFiles) {
          const asset = isGifCatalogId(metadata.asset.id) ? metadata.asset : donor.asset;
          media = { ...metadata, asset, privateFiles: donor.privateFiles, unavailable: !gifRenditions(asset).every(rendition => donor.privateFiles!.files[rendition]?.blob instanceof Blob) };
        } else media = metadata;
      }
    }
    // The current composer has no video editor; preserve all video/gallery data.
    const unavailableVideos = !!post.embedVideos?.length || !!(post as AppBskyDraftDefs.DraftPost & { embedGallery?: unknown }).embedGallery;
    const unavailableExternal = (post.embedExternals?.length ?? 0) > 1 || !!post.embedExternals?.some(external => {
      try { const url = new URL(external.uri); return url.protocol !== "https:" || !!url.username || !!url.password || (url.host === "static.klipy.com" && media?.kind !== "gif"); }
      catch { return true; }
    });
    const external = post.embedExternals?.[0];
    const linkPreview = external && !unavailableExternal && !media ? { uri: external.uri, title: new URL(external.uri).hostname, description: "" } : undefined;
    return { ...local, id: local?.id ?? crypto.randomUUID(), text: post.text, media, linkPreview, nativeDraftPost: structuredClone(post), unavailableDraftMedia: unavailableImages || unavailableVideos || unavailableExternal || mixedMedia || !!(media?.kind === "gif" && media.unavailable) };
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
      const external = { ...post.embedExternals?.find(external => external.uri === uri), uri };
      if (isGifCatalogId(segment.media.asset.id) && !segment.media.unavailable) Object.assign(external, { [GIF_METADATA]: { version: 1, asset: segment.media.asset, alt: segment.media.alt } });
      post.embedExternals = [external];
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
      const head = new Uint8Array(await photo.original.slice(0, 4).arrayBuffer());
      const sniffedType = head[0] === 255 && head[1] === 216 && head[2] === 255 ? "image/jpeg" : head[0] === 137 && head[1] === 80 && head[2] === 78 && head[3] === 71 ? "image/png" : photo.original.type;
      // Preserve the editor's original Blob identity; upload an exact-byte typed
      // view when resuming photos prepared before MIME normalization existed.
      const originalBlob = sniffedType === photo.original.type ? photo.original : photo.original.slice(0, photo.original.size, sniffedType);
      const original = await describeDraftAttachment(originalBlob, photo.name, previous?.original);
      const output = await describeDraftAttachment(photo.blob, photo.name, previous?.prepared);
      assertDraftAttachmentActor(actor);
      const replace = (value: ComposerPhoto) => { prepared = prepared.map(item => item.media?.kind === "photos" ? { ...item, media: { ...item.media, photos: item.media.photos.map(candidate => candidate.id === photo.id && candidate.original === photo.original && candidate.blob === photo.blob ? value : candidate) } } : item); };
      let portable = { ...photo, privateAttachment: { ownerDid: actor.viewerDid, original, prepared: output } };
      replace(portable);
      await checkpoint(prepared);
      assertDraftAttachmentActor(actor);
      for (const [which, blob] of [["original", originalBlob], ["prepared", photo.blob]] as const) {
        let asset = portable.privateAttachment[which];
        let ready;
        try { ready = await uploadDraftAttachment(actor, asset, blob); }
        catch (error) {
          if (!isRetiredDraftAttachment(error)) throw error;
          assertDraftAttachmentActor(actor);
          asset = { ...asset, assetId: crypto.randomUUID(), state: "reserved" };
          portable = { ...portable, privateAttachment: { ...portable.privateAttachment, [which]: asset } };
          replace(portable);
          await checkpoint(prepared);
          ready = await uploadDraftAttachment(actor, asset, blob);
        }
        portable = { ...portable, privateAttachment: { ...portable.privateAttachment, [which]: ready } };
        replace(portable);
        await checkpoint(prepared);
      }
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


function nativeGifMetadata(external: { uri: string }): ComposerGif | undefined {
  const metadata = (external as unknown as Record<string, unknown>)[GIF_METADATA] as { version?: number; asset?: GifAsset; alt?: string } | undefined;
  try {
    if (metadata?.version !== 1 || !metadata.asset || ["id", "title", "description", "url", "poster", "attribution"].some(key => typeof metadata.asset![key as keyof GifAsset] !== "string") || !isGifCatalogId(metadata.asset.id) || typeof metadata.alt !== "string" || metadata.alt.length > 2000 || gifEmbedURI(metadata.asset) !== external.uri) return;
    klipyMediaURL(metadata.asset.poster);
    return { kind: "gif", asset: structuredClone(metadata.asset), alt: metadata.alt, unavailable: true };
  } catch { return; }
}
export function hasDraftGifs(draft?: AppBskyDraftDefs.Draft): boolean {
  return !!draft?.posts.some(post => post.embedExternals?.some(external => !!restoreGif(external.uri)));
}
export async function privateGifReferenceKey(asset: GifAsset): Promise<string> {
  if (!isGifCatalogId(asset.id)) throw new Error("Reselect This GIF To Privately Sync Its Files.");
  return `socialwire-private://v1/gif/${asset.id}/${await draftAttachmentSHA256(new Blob([gifEmbedURI(asset)]))}`;
}
const gifRefPattern = /^socialwire-private:\/\/v1\/gif\/([A-Za-z0-9_-]{1,128})\/([0-9a-f]{64})\/(gif|poster|mp4|webm)$/;
export function privateDraftGifRefs(segments: ThreadSegment[]): DraftAttachmentRef[] {
  const refs = new Map<string, DraftAttachmentRef>();
  for (const segment of segments) {
    const media = segment.media;
    if (media?.kind !== "gif") continue;
    if (media.unavailable || !media.privateFiles || media.privateFiles.identity !== gifEmbedURI(media.asset)) throw new Error("GIF Files Are Unavailable. Retry Or Reselect The GIF.");
    for (const rendition of gifRenditions(media.asset)) {
      const file = media.privateFiles.files[rendition];
      if (!file || file.asset.state !== "ready") throw new Error("Private GIF Upload Is Pending. Retry Before Closing.");
      const ref: DraftAttachmentRef = { assetId: file.asset.assetId, role: rendition === "mp4" || rendition === "webm" ? "video" : rendition, ref: `${media.privateFiles.referenceKey}/${rendition}` };
      const previous = refs.get(ref.ref);
      if (previous && previous.assetId !== ref.assetId) throw new Error("Private GIF Files Have Conflicting References. Reselect The GIF.");
      refs.set(ref.ref, ref);
    }
  }
  return [...refs.values()];
}
/** Snapshot immutable provider metadata and all bytes locally before private uploads. */
export async function preparePrivateDraftGifs(actor: DraftAttachmentActor, segments: ThreadSegment[], checkpoint: (prepared: ThreadSegment[]) => Promise<void>): Promise<void> {
  let prepared = segments;
  const canonical = new Map<string, NonNullable<ComposerGif["privateFiles"]>>();
  for (const segment of segments) {
    const media = segment.media;
    if (media?.kind !== "gif") continue;
    if (!isGifCatalogId(media.asset.id)) throw new Error("Reselect This GIF To Privately Sync Its Files. Its Existing Draft Content Is Preserved.");
    assertDraftAttachmentActor(actor);
    const identity = gifEmbedURI(media.asset);
    const referenceKey = await privateGifReferenceKey(media.asset);
    const shared = prepared.find(item => item.id !== segment.id && item.media?.kind === "gif" && item.media.privateFiles?.ownerDid === actor.viewerDid && item.media.privateFiles.identity === identity)?.media;
    const previous = canonical.get(referenceKey) ?? (media.privateFiles?.ownerDid === actor.viewerDid && media.privateFiles.identity === identity ? media.privateFiles : shared?.kind === "gif" ? shared.privateFiles : undefined);
    let files = { ...previous?.files };
    const replace = async () => {
      const privateFiles = { ownerDid: actor.viewerDid, identity, referenceKey, files };
      canonical.set(referenceKey, privateFiles);
      // Every occurrence must durably adopt a retired ID's replacement before
      // its upload. Keep each post's metadata and settings independent.
      prepared = prepared.map(item => item.media?.kind === "gif" && item.media.asset.id === media.asset.id && matchingGif(item.media, identity) ? { ...item, media: { ...item.media, privateFiles, unavailable: !gifRenditions(item.media.asset).every(rendition => !!files[rendition]?.blob) }, unavailableDraftMedia: false } : item);
      await checkpoint(prepared);
      assertDraftAttachmentActor(actor);
    };
    for (const rendition of gifRenditions(media.asset)) {
      const existing = files[rendition];
      const blob = existing?.blob ?? await getGifFile(actor, media.asset.id, rendition);
      assertDraftAttachmentActor(actor);
      validateGifFile(blob, rendition);
      const asset = await describeDraftAttachment(blob, `${media.asset.id}.${rendition}`, existing?.asset, rendition === "mp4" || rendition === "webm" ? "video" : rendition);
      files = { ...files, [rendition]: { asset, blob } };
      // Interrupted retrieval resumes from these exact bytes and IDs too.
      await replace();
    }
    for (const rendition of gifRenditions(media.asset)) {
      const file = files[rendition]!;
      let asset;
      try { asset = await uploadDraftAttachment(actor, file.asset, file.blob); }
      catch (error) {
        if (!isRetiredDraftAttachment(error)) throw error;
        assertDraftAttachmentActor(actor);
        const replacement = { ...file.asset, assetId: crypto.randomUUID(), state: "reserved" as const };
        files = { ...files, [rendition]: { ...file, asset: replacement } };
        await replace();
        asset = await uploadDraftAttachment(actor, replacement, file.blob);
      }
      files = { ...files, [rendition]: { ...file, asset } };
      await replace();
    }
  }
}

export async function restorePrivateDraftGifs(actor: DraftAttachmentActor, draft: AppBskyDraftDefs.Draft, manifest: DraftAttachmentManifest, local?: ThreadSegment[]): Promise<ThreadSegment[]> {
  let restored = socialDraftToSegments(draft, local);
  for (const [index, post] of draft.posts.entries()) {
    if (post.embedExternals?.length !== 1 || !restoreGif(post.embedExternals[0].uri)) continue;
    const uri = post.embedExternals[0].uri;
    const hash = await draftAttachmentSHA256(new Blob([uri]));
    assertDraftAttachmentActor(actor);
    const references = manifest.attachments.filter(item => gifRefPattern.exec(item.ref)?.[2] === hash);
    const ids = new Set(references.map(item => gifRefPattern.exec(item.ref)![1]));
    let media = restored[index].media;
    if (media?.kind !== "gif") continue;
    if (!references.length) {
      // A catalog-backed local recovery can still finish an interrupted upload.
      if (!isGifCatalogId(media.asset.id)) restored[index] = { ...restored[index], unavailableDraftMedia: true, media: { ...media, unavailable: true } };
      continue;
    }
    if (manifest.deleted || ids.size !== 1) throw new Error("Private GIF Manifest Is Unavailable. Retry Or Reselect The GIF.");
    const id = [...ids][0];
    if (isGifCatalogId(media.asset.id) && media.asset.id !== id) throw new Error("Private GIF Identity Does Not Match Its Manifest. Reselect The GIF.");
    media = { ...media, asset: { ...media.asset, id } };
    const referenceKey = await privateGifReferenceKey(media.asset);
    const previous = media.privateFiles?.ownerDid === actor.viewerDid && media.privateFiles.identity === uri ? media.privateFiles : undefined;
    const files: NonNullable<ComposerGif["privateFiles"]>["files"] = {};
    for (const rendition of gifRenditions(media.asset)) {
      const role = rendition === "mp4" || rendition === "webm" ? "video" : rendition;
      const matches = references.filter(item => item.ref === `${referenceKey}/${rendition}` && item.role === role);
      const asset = matches[0]?.asset;
      if (matches.length !== 1 || !asset || asset.kind !== role || asset.state !== "ready") throw new Error("Private GIF File Is Missing. Retry Or Reselect The GIF.");
      const cached = previous?.files[rendition];
      const blob = cached?.asset.assetId === asset.assetId && cached.asset.sha256 === asset.sha256 ? cached.blob : await downloadDraftAttachment(actor, asset);
      assertDraftAttachmentActor(actor);
      validateGifFile(blob, rendition);
      files[rendition] = { asset, blob };
    }
    restored = restored.map((segment, currentIndex) => currentIndex === index ? { ...segment, unavailableDraftMedia: !!post.embedImages?.length || !!post.embedVideos?.length || !!(post as { embedGallery?: unknown }).embedGallery, media: { ...media as ComposerGif, unavailable: false, privateFiles: { ownerDid: actor.viewerDid, identity: uri, referenceKey, files } } } : segment);
  }
  return restored;
}

/** Explicitly replacing/removing a device-bound GIF must not resurrect its URI. */
export function replaceSocialDraftMedia(segment: ThreadSegment, media?: ComposerMedia): ThreadSegment {
  const post = segment.nativeDraftPost;
  const onlyGif = segment.media?.kind === "gif" && !!segment.media.unavailable && !post?.embedImages?.length && !post?.embedVideos?.length && !(post as { embedGallery?: unknown } | undefined)?.embedGallery;
  if (!onlyGif || media?.kind === "gif" && media.unavailable) return { ...segment, media };
  const nativeDraftPost = post ? { ...post } : undefined;
  if (nativeDraftPost) delete nativeDraftPost.embedExternals;
  return { ...segment, media, unavailableDraftMedia: false, nativeDraftPost };
}
