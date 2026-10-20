import type { DraftAttachment } from "./socialDraftAttachmentClient";

export type GifAsset = {
  id: string; title: string; description: string; url: string; poster: string;
  mp4?: string; webm?: string; width: number; height: number; attribution: string;
};
export type ComposerPhoto = {
  id: string; name: string; original: Blob; blob?: Blob; width?: number; height?: number;
  privateAttachment?: { ownerDid: string; original: DraftAttachment; prepared: DraftAttachment };
  alt: string; status: "preparing" | "ready" | "failed"; error?: string;
};
export type ComposerMedia = { kind: "photos"; photos: ComposerPhoto[] } | { kind: "gif"; asset: GifAsset; alt: string };

export function mediaReady(media?: ComposerMedia): boolean {
  if (!media) return true;
  if (media.kind === "gif") { try { gifEmbedURI(media.asset); return media.alt.length <= 2000; } catch { return false; } }
  return media.photos.length > 0 && media.photos.length <= 4 && media.photos.every(photo => photo.status === "ready" && !!photo.blob && !!photo.width && !!photo.height && photo.alt.length <= 2000);
}

export function mediaHasContent(media?: ComposerMedia): boolean {
  return !!media && mediaReady(media);
}

export function missingMediaAlt(media?: ComposerMedia): boolean {
  return media?.kind === "photos" ? media.photos.some(photo => !photo.alt.trim()) : media?.kind === "gif" ? !media.alt.trim() : false;
}

export function klipyMediaURL(value: string): URL {
  const url = new URL(value);
  if (url.protocol !== "https:" || url.host !== "static.klipy.com" || url.username || url.password || !url.pathname.startsWith("/ii/") || url.hash) throw new Error("Invalid GIF Media URL");
  return url;
}

export function gifEmbedURI(asset: GifAsset): string {
  const url = klipyMediaURL(asset.url);
  if (!url.pathname.endsWith(".gif") || !Number.isSafeInteger(asset.width) || !Number.isSafeInteger(asset.height) || asset.width <= 0 || asset.height <= 0 || asset.width > 20000 || asset.height > 20000) throw new Error("Invalid GIF Dimensions Or Format");
  url.searchParams.set("ww", String(asset.width));
  url.searchParams.set("hh", String(asset.height));
  const directory = url.pathname.slice(0, url.pathname.lastIndexOf("/") + 1);
  for (const format of ["mp4", "webm"] as const) {
    url.searchParams.delete(format);
    const source = asset[format];
    if (!source) continue;
    const rendition = klipyMediaURL(source);
    const filename = rendition.pathname.slice(directory.length);
    if (!rendition.pathname.startsWith(directory) || !new RegExp(`^[A-Za-z0-9_-]+\\.${format}$`).test(filename)) throw new Error("Incompatible GIF Rendition");
    url.searchParams.set(format, filename.slice(0, -(format.length + 1)));
  }
  if (!url.searchParams.has("mp4") && !url.searchParams.has("webm")) throw new Error("This GIF Has No Compatible Video Rendition");
  return url.href;
}
