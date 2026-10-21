import { AppBskyEmbedExternal, AppBskyRichtextFacet } from "@atproto/api";
import type { OAuthSession } from "@atproto/oauth-client-browser";
import { createOAuthAgent } from "@/lib/atprotoClient";

import { compilePostText } from "./composePostText";

export type ComposeLinkPreview = { uri: string; title: string; description: string; image?: string };

export function composeLinkUrl(text: string): string | undefined {
  const rich = compilePostText(text);
  for (const facet of rich.facets ?? []) {
    for (const feature of facet.features) {
      if (AppBskyRichtextFacet.isLink(feature) && publicLinkUrl(feature.uri)) return feature.uri;
    }
  }
}

export function publicLinkUrl(value: string): string | undefined {
  try {
    const url = new URL(value);
    if (!["http:", "https:"].includes(url.protocol) || url.username || url.password) return;
    return url.href;
  } catch { return; }
}

/** Media failures omit the thumbnail; identity checks still prevent a stale-account write. */
export async function composeExternalEmbed(session: OAuthSession, text: string, preview: ComposeLinkPreview | undefined, assertCurrentAccount?: () => void, attachedURI?: string) {
  if (!preview || (preview.uri !== attachedURI && preview.uri !== composeLinkUrl(text)) || !publicLinkUrl(preview.uri)) return;
  const external: AppBskyEmbedExternal.External = {
    uri: preview.uri,
    title: Array.from(preview.title || new URL(preview.uri).hostname).slice(0, 300).join(""),
    description: Array.from(preview.description).slice(0, 1000).join(""),
  };
  if (preview.image && publicLinkUrl(preview.image)?.startsWith("https:")) {
    let blob: Blob | undefined;
    try {
      const response = await fetch(`/api/bluesky-card-thumb?${new URLSearchParams({ url: preview.image })}`, { signal: AbortSignal.timeout(15_000) });
      if (response.ok) blob = await response.blob();
    } catch { /* A card without a thumbnail remains usable. */ }
    assertCurrentAccount?.();
    if (blob && ["image/jpeg", "image/png", "image/webp"].includes(blob.type) && blob.size > 0 && blob.size <= 1_000_000) {
      try {
        const upload = await createOAuthAgent(session).uploadBlob(blob);
        if (upload.data.blob.size === blob.size && upload.data.blob.mimeType === blob.type) external.thumb = upload.data.blob;
      } catch { /* Upload permission or media failures must not block the text/card. */ }
      assertCurrentAccount?.();
    }
  }
  return { $type: "app.bsky.embed.external" as const, external };
}
