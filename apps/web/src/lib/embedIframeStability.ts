/** URLs that repeatedly reload inside sandboxed iframes (SSR/hydration loops). */
const unstableEmbedCache = new Set<string>();

export const IFRAME_LOAD_STORM_WINDOW_MS = 8_000;
export const IFRAME_LOAD_STORM_MAX_LOADS = 3;

export function isCachedUnstableEmbed(iframeSrc: string): boolean {
  return unstableEmbedCache.has(iframeSrc);
}

export function markUnstableEmbed(iframeSrc: string): void {
  unstableEmbedCache.add(iframeSrc);
}

/** Returns updated load timestamps and whether the embed should be treated as unstable. */
export function registerIframeLoadEvent(
  timestamps: number[],
  now = Date.now()
): { timestamps: number[]; unstable: boolean } {
  const recent = timestamps.filter((t) => now - t < IFRAME_LOAD_STORM_WINDOW_MS);
  recent.push(now);
  return {
    timestamps: recent,
    unstable: recent.length >= IFRAME_LOAD_STORM_MAX_LOADS,
  };
}

/** @internal Test helper */
export function clearUnstableEmbedCacheForTests(): void {
  unstableEmbedCache.clear();
}
