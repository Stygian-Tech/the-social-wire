import type { OEmbedResponse } from "@/lib/oEmbed";
import { getCachedOEmbed, setCachedOEmbed } from "@/lib/oEmbedCache";

export type OEmbedFetchResult =
  | { ok: true; oembed: OEmbedResponse; canonicalUrl: string }
  | { ok: false };

export async function fetchOEmbedForPage(
  pageUrl: string,
  signal?: AbortSignal
): Promise<OEmbedFetchResult> {
  const cached = getCachedOEmbed(pageUrl);
  if (cached) {
    return cached.status === "hit"
      ? { ok: true, oembed: cached.oembed, canonicalUrl: cached.canonicalUrl }
      : { ok: false };
  }

  try {
    const res = await fetch(`/api/oembed?url=${encodeURIComponent(pageUrl)}`, {
      signal,
    });
    if (!res.ok) {
      setCachedOEmbed(pageUrl, { status: "miss" });
      return { ok: false };
    }
    const body = (await res.json()) as {
      ok?: boolean;
      oembed?: OEmbedResponse;
      canonicalUrl?: string;
    };
    if (body.ok && body.oembed) {
      const hit = {
        status: "hit" as const,
        oembed: body.oembed,
        canonicalUrl: body.canonicalUrl ?? pageUrl,
      };
      setCachedOEmbed(pageUrl, hit);
      return { ok: true, oembed: body.oembed, canonicalUrl: hit.canonicalUrl };
    }
    setCachedOEmbed(pageUrl, { status: "miss" });
    return { ok: false };
  } catch {
    if (signal?.aborted) {
      return { ok: false };
    }
    setCachedOEmbed(pageUrl, { status: "miss" });
    return { ok: false };
  }
}
