"use client";

/* eslint-disable @next/next/no-img-element -- Publisher thumbnails use the bounded image proxy. */
import { useState } from "react";
import type { ComposeLinkPreview } from "@/lib/blueskyExternalEmbed";
import { socialHttpsUrl } from "./socialUrls";

export function SocialComposeLinkCard({ preview, loading, unavailable, remove, disabled }: { preview?: ComposeLinkPreview; loading: boolean; unavailable: boolean; remove: () => void; disabled: boolean }) {
  const [failedImage, setFailedImage] = useState<string>();
  if (loading) return <p role="status" className="text-xs text-muted-foreground">Loading Link Preview…</p>;
  if (unavailable) return <p role="status" className="text-xs text-muted-foreground">Link Preview Unavailable. You Can Still Post the Link.</p>;
  if (!preview) return null;
  const image = socialHttpsUrl(preview.image);
  return <section aria-label="Link Preview" className="min-w-0 overflow-hidden rounded-xl border">
    {image && failedImage !== image ? <img src={`/api/bluesky-card-thumb?${new URLSearchParams({ url: image })}`} alt="" className="max-h-48 w-full object-cover" onError={() => setFailedImage(image)} /> : null}
    <div className="space-y-1 p-3 [overflow-wrap:anywhere]">
      <p className="line-clamp-2 text-sm font-medium">{preview.title}</p>
      {preview.description ? <p className="line-clamp-3 text-xs text-muted-foreground">{preview.description}</p> : null}
      <a href={preview.uri} target="_blank" rel="noopener noreferrer" className="block truncate text-xs text-muted-foreground">{preview.uri}</a>
      <button type="button" disabled={disabled} onClick={remove} className="text-xs underline">Remove Link Preview</button>
    </div>
  </section>;
}
