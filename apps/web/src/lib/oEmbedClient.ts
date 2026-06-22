import type { OEmbedResponse } from "@/lib/oEmbed";
import { getCachedOEmbed, setCachedOEmbed } from "@/lib/oEmbedCache";

export type OEmbedFetchResult =
  | { ok: true; oembed: OEmbedResponse; canonicalUrl: string; pageAtUri?: string }
  | { ok: false; pageAtUri?: string };

export async function fetchOEmbedForPage(
  pageUrl: string,
  signal?: AbortSignal
): Promise<OEmbedFetchResult> {
  const cached = getCachedOEmbed(pageUrl);
  if (cached) {
    return cached.status === "hit"
      ? {
          ok: true,
          oembed: cached.oembed,
          canonicalUrl: cached.canonicalUrl,
          pageAtUri: cached.pageAtUri,
        }
      : { ok: false, pageAtUri: cached.pageAtUri };
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
      pageAtUri?: string;
    };
    if (body.ok && body.oembed) {
      const hit = {
        status: "hit" as const,
        oembed: body.oembed,
        canonicalUrl: body.canonicalUrl ?? pageUrl,
        pageAtUri: body.pageAtUri,
      };
      setCachedOEmbed(pageUrl, hit);
      return {
        ok: true,
        oembed: body.oembed,
        canonicalUrl: hit.canonicalUrl,
        pageAtUri: body.pageAtUri,
      };
    }
    setCachedOEmbed(pageUrl, { status: "miss", pageAtUri: body.pageAtUri });
    return { ok: false, pageAtUri: body.pageAtUri };
  } catch {
    if (signal?.aborted) {
      return { ok: false };
    }
    setCachedOEmbed(pageUrl, { status: "miss" });
    return { ok: false };
  }
}
