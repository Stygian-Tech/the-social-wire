import type { OEmbedResponse } from "@/lib/oEmbed";

export type CachedOEmbedLookup =
  | { status: "hit"; oembed: OEmbedResponse; canonicalUrl: string }
  | { status: "miss" };

const oEmbedCache = new Map<string, CachedOEmbedLookup>();

export function getCachedOEmbed(pageUrl: string): CachedOEmbedLookup | undefined {
  return oEmbedCache.get(pageUrl);
}

export function setCachedOEmbed(pageUrl: string, value: CachedOEmbedLookup): void {
  oEmbedCache.set(pageUrl, value);
}
