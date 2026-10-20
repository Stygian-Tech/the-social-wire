"use client";

import type { ComposerGif } from "@/lib/composerMedia";
import { SocialGifPlayer } from "./SocialGifPlayer";

/** Object URLs exist only for this mounted preview, never in draft/query storage. */
export function SocialComposerGifPreview({ media }: { media: ComposerGif }) {
  const files = media.privateFiles?.files;
  if (media.unavailable) return <p role="status" className="text-sm">GIF Files Are Unavailable. Retry Draft Sync Or Reselect The GIF.</p>;
  if (files && (!files.gif || !files.poster)) return <p role="status" className="text-sm">Preparing Private GIF Preview…</p>;
  return <SocialGifPlayer key={media.asset.id} source={files ? "" : media.asset.url} poster={files ? undefined : media.asset.poster} mp4={files ? undefined : media.asset.mp4} webm={files ? undefined : media.asset.webm} files={files ? { gif: files.gif?.blob, poster: files.poster?.blob, mp4: files.mp4?.blob, webm: files.webm?.blob } : undefined} alt={media.alt || media.asset.description || media.asset.title} width={media.asset.width} height={media.asset.height} />;
}
